package editor

import "core:fmt"
import "core:mem"
import sdl "vendor:sdl3"
import gfx "../engine/gfx"
import input "../engine/input"
import strings "core:strings"
import im "moonhug:external/odin-imgui"
import im_sdl "moonhug:external/odin-imgui/imgui_impl_sdl3"
import im_sdlgpu "moonhug:external/odin-imgui/imgui_impl_sdlgpu3"
import "inspector"
import "menu"
import clip "clipboard"
import "undo"
import "../engine/serialization"
import "../engine/registration"
import "core:os"
import "../engine"
import "core:path/filepath"
import "../engine/log"
import "core:encoding/uuid"

main :: proc() {
    when ODIN_DEBUG {
        track: mem.Tracking_Allocator
        mem.tracking_allocator_init(&track, context.allocator)
        context.allocator = mem.tracking_allocator(&track)

        defer {
            for _, entry in track.allocation_map {
                fmt.eprintf("leak %v bytes @ %v\n", entry.size, entry.location)
            }
            for entry in track.bad_free_array {
                fmt.eprintf("bad free @ %v\n", entry.location)
            }
            mem.tracking_allocator_destroy(&track)
        }
    }

    cwd, _ := os.get_working_directory(context.temp_allocator)
    if !strings.has_suffix(cwd, "moonhug") {
        moonhug_dir, _ := filepath.join({cwd, "moonhug"}, context.temp_allocator)
        os.set_working_directory(moonhug_dir)
    }

    win_w, win_h, win_x, win_y := load_editor_settings()
    has_saved_settings := win_w > 0 && win_h > 0
    // Window starts hidden so saved geometry applies before first present.
    if !gfx.init(WINDOW_TITLE, has_saved_settings ? win_w : 800, has_saved_settings ? win_h : 600, show = false) {
        fmt.eprintln("gfx init failed (is SDL3 installed? brew install sdl3)")
        return
    }
    defer gfx.shutdown()

    if has_saved_settings && win_x >= 0 && win_y >= 0 {
        gfx.set_window_geometry(win_x, win_y, win_w, win_h)
    } else if !has_saved_settings {
        apply_default_window_size()
    }
    gfx.show_window()
    // Dock icon is applied AFTER the first focus event (see the main loop),
    // NOT here: setApplicationIconImage during the launch activation
    // handshake could wedge key-window status when a click landed early —
    // keyboard dead for the whole session, mouse fine, only an app switch
    // repaired it (Help/Input Debug was built to diagnose this).
    dock_icon_pending := true

    // Setup ImGui
    im.CHECKVERSION()
    ctx := im.CreateContext()
    defer im.DestroyContext(ctx)

    // Enable docking (drag window title bars to dock/undock)
    io := im.GetIO()
    io.ConfigFlags += {.DockingEnable}

    // Load UI fonts (default text font + merged Material Symbols icons). Must run
    // before the backend builds the font atlas texture.
    editor_fonts_init()

    // SDL3 platform backend (input, DisplaySize, clipboard, text input) +
    // SDLGPU3 renderer backend.
    im_sdl.InitForSDLGPU(gfx.window())
    defer im_sdl.Shutdown()
    imgui_gpu_info := im_sdlgpu.InitInfo{
        Device            = gfx.device(),
        ColorTargetFormat = gfx.swapchain_format(),
        MSAASamples       = ._1,
    }
    im_sdlgpu.Init(&imgui_gpu_info)
    defer im_sdlgpu.Shutdown()

    apply_editor_theme()

    // Init user context and world
    uc := new(engine.UserContext)
    context.user_ptr = uc

    w := new(engine.World)
    engine.w_init(w)
    engine.ctx_get().world = w

    undo_stack := new(undo.Undo_Stack)
    undo.init(undo_stack)
    undo.install(undo_stack)
    // Selection restore/record goes through hooks (undo can't import editor).
    selection_undo_install()
    defer selection_undo_shutdown()
    defer { undo.destroy(undo_stack); free(undo_stack) }

    defer { engine.world_destroy_all(w); free(w) }
    defer free(uc)

    phase_editor_run(.EditorInit)
    defer phase_editor_run(.EditorShutdown)

    for !menu.quit_requested && !gfx.quit_requested() {
        // Events feed both the editor input snapshot and imgui (the SDL3
        // backend owns keyboard/mouse/text/clipboard/DisplaySize/DeltaTime).
        gfx.poll_events(proc(e: ^sdl.Event) { im_sdl.ProcessEvent(e) })

        // Unity-style Auto Refresh: re-scan assets when the editor window
        // regains focus (git checkouts, external editors). Incremental
        // mtime-diff — an unchanged tree costs one stat pass.
        if input.focus_gained() {
            engine.asset_db_refresh()
            project_dir_cache_invalidate()
            if dock_icon_pending {
                dock_icon_pending = false
                set_dock_icon("../EditorIcon.png") // cwd was normalized to moonhug/ at startup
            }
        }

        if !gfx.frame_begin() do continue

        // Start ImGui frame
        im_sdlgpu.NewFrame()
        im_sdl.NewFrame()
        im.NewFrame()

        menu.draw_menu_bar()
        draw_tool_bar()
        // Dockspace host under the toolbar; must precede the dockable views'
        // Begin() calls (dock.odin — builds the default layout on first run).
        draw_dockspace()

        _process_undo_shortcuts()

        // ImGui UI
        if menu.show_inspector {
            draw_hierarchy_inspector()
        }

        if menu.show_project_inspector {
            inspector.view_inspector_draw()
        }

        if menu.show_project {
            draw_project_view()
        }

        if menu.show_console {
            draw_console_view()
        }

        if menu.show_history {
            draw_history_view()
        }

        if menu.show_hierarchy {
            draw_hierarchy_view()
        }

        if menu.show_scene {
            draw_scene_view()
        }

        if menu.show_game {
            draw_game_view()
        }

        if menu.show_input_debug {
            draw_input_debug()
        }

        if menu.show_output {
            draw_output_view()
        }

        draw_about_popup()
        draw_status_bar()

        // Selection undo steps (Unity model): diff selection against the
        // frame's baseline after all views handled input.
        selection_undo_track()

        // Render. Scene/game views already encoded their offscreen passes
        // into this frame's command buffer during the UI calls above; imgui's
        // copy passes (PrepareDrawData) must come BEFORE the swapchain render
        // pass, and its draw happens inside it (pass_end callback).
        im.Render()
        dd := im.GetDrawData()
        im_sdlgpu.PrepareDrawData(dd, gfx.command_buffer())
        if gfx.pass_begin_swapchain([4]f32{0.96, 0.96, 0.96, 1}, depth = false) {
            gfx.pass_end(proc(cmd: ^sdl.GPUCommandBuffer, rp: ^sdl.GPURenderPass) {
                im_sdlgpu.RenderDrawData(im.GetDrawData(), cmd, rp)
            })
        }
        gfx.frame_end()

        free_all(context.temp_allocator)
    }

    save_editor_settings()
}

@(phase={key=engine.Phase.EditorInit, order=0, mode=Editor})
editor_init :: proc() {

	log.info("Editor Init")
	log.error("test error")
	log.warning("test warning")
    registration.register_packages()
    inspector.init()
    serialization.init()
    clip.init()
    registration.register_type_guids()
    _init_context_menu_registry()
    init_project_view()
    engine.asset_pipeline_init()
    engine.asset_db_init("assets")
    engine.asset_pipeline_import_all()
    engine.texture_cache_init()
    engine.mesh_cache_init()
    engine.material_cache_init()
    engine.shader_cache_init()
    engine.animation_clip_cache_init()
    open_scenes_from_settings()

    init_scene_view()
    init_game_view()
    setup_menu_items()

    return

    setup_menu_items :: proc() {
        _register_menu_items()
        register_create_asset_menus()
        register_component_menus()

        top_order := make(map[string]int)
        defer delete(top_order)

        top_order["File"] = 0
        top_order["View"] = 1
        top_order["Edit"] = 4
        top_order["View/Theme"] = -10
        top_order["Assets"] = 8
        // Create submenu pinned to the top of the Assets menu (Unity).
        top_order["Assets/Create"] = -100
        top_order["GameObject"] = 10 // creation band also mirrors into the hierarchy popup
        top_order["Component"] = 15
        top_order["Tools"] = 20 // plugin/tooling menu items (e.g. packages)
        top_order["Help"] = 30
        menu.sort_top_menu(top_order)
    }
}

open_scenes_from_settings :: proc() {
    for guid_str in editor_settings.open_scene_guids {
        guid, err := uuid.read(guid_str)
        if err != nil do continue
        path, ok := engine.asset_db_get_path(guid)
        if !ok do continue
        engine.scene_load_additive_path(path)
    }
}

@(phase={key=engine.Phase.EditorShutdown, order=0, mode=Editor})
editor_shutdown :: proc() {
    join_play_thread()
    shutdown_game_view()
    shutdown_scene_view()
    engine.texture_cache_shutdown()
    engine.mesh_cache_shutdown()
    engine.material_cache_shutdown()
    engine.shader_cache_shutdown()
    engine.asset_db_shutdown()
    engine.sm_shutdown()
    engine.scene_lib_shutdown()
    _shutdown_context_menu_registry()
    inspector.shutdown_registries()
    shutdown_hierarchy_views()
    shutdown_project_view()
    menu.shutdown_menu()
    log.info("Editor Shutdown")
    log.shutdown()
}

@(menu_item={path="Assets/Create/Scene", order=0, shortcut=""})
scene_create_menu :: proc() {
	scene := engine.scene_new()
	save_path, _ := filepath.join({projectViewData.currentPath, "Scene.scene"}, context.temp_allocator)
	engine.scene_save(scene, save_path)
}

// Creates a prefab variant of the currently-selected scene asset, written
// alongside it as "<name>_Variant.scene". Registered into the same menu system
// as "Create/Scene", so it appears in the project panel's right-click menu and
// the top Assets menu. Acts on projectViewData.selectedFile (the asset the user
// last clicked); no-op with a console note if no .scene is selected.
@(menu_item={path="Assets/Create/Scene Variant", order=-10, shortcut=""})
scene_create_variant_menu :: proc() {
	if !strings.has_suffix(projectViewData.selectedFile, ".scene") {
		fmt.println("[Editor] Create Scene Variant: select a .scene asset first")
		return
	}
	// selectedFile holds the FULL path (search results span folders).
	create_scene_variant(projectViewData.selectedFile)
}

@(menu_separator={path="Assets/Create", order=-9})
scene_create_variant_separator :: proc() {}

// Ctrl+Z / Ctrl+Shift+Z live on the Edit/Undo and Edit/Redo menu items
// (hierarchy_menu.odin) — only the Ctrl+Y redo alias is handled here.
_process_undo_shortcuts :: proc() {
	if engine.ctx_get().is_playmode do return
	s := undo.get()
	if s == nil do return

	redo_chord_y := im.KeyChord(im.Key.ImGuiMod_Ctrl) | im.KeyChord(im.Key.Y)
	if im.Shortcut(redo_chord_y, {.RouteGlobal}) {
		undo.apply_redo(s)
	}
}
