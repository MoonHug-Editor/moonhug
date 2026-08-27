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
import wnd "moonhug:editor/window"
import "moonhug:editor/preview"
import "../engine/serialization"
import "../engine/registration"
import "core:os"
import "../engine"
import "moonhug:engine_editor/asset_pipeline"
import "moonhug:editor/progress"
import crash_journal "../engine/crash_journal"
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

    if os.is_dir("moonhug/engine") {
        cwd, _ := os.get_working_directory(context.temp_allocator)
        moonhug_dir, _ := filepath.join({cwd, "moonhug"}, context.temp_allocator)
        os.set_working_directory(moonhug_dir)
    }

    // Before anything that can fault: from here on a crash lands in
    // logs/crash_<pid>.log with a stack (docs/CrashJournal.md).
    crash_journal.init(VERSION)
    // Must be set HERE, not inside init: assertion_failure_proc lives on the
    // context, so it only persists in the scope that assigns it.
    context.assertion_failure_proc = crash_journal.assertion_failure
    for arg in os.args[1:] {
        if arg == "--crash-test" {
            fmt.eprintfln("crash journal self-test: writing %s and faulting", crash_journal.path())
            crash_journal.test_crash()
        }
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
    // From here reports draw pumped frames — startup shows progress instead
    // of a black window (progress_overlay.odin).
    progress_overlay_install()

    // Init user context and world
    uc := new(engine.UserContext)
    context.user_ptr = uc
    uc.is_editor = true // engine.application_is_editor; never changes at runtime

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

    progress.begin("Starting MoonHug")
    phase_editor_run(.EditorInit)
    progress.end()
    defer phase_editor_run(.EditorShutdown)
    queue_scenes_from_settings()
    frames_presented := 0

    // Resolve which host Simulate ticks, from the generated table
    // (sim_hosts_generated.odin) and the persisted setting. Must follow
    // load_editor_settings.
    simulate_init()
    defer simulate_shutdown()
    _register_editor_windows() // plugin @(editor_window) declarations
    // Reopen what was open last session — declarations must exist first.
    wnd.open_saved(editor_settings.open_window_ids[:])
    defer wnd.shutdown()
    defer preview.shutdown()
    _register_project_settings() // @(project_settings) vars -> settings tabs
    defer settings_shutdown()
    defer thumbnails_shutdown()
    defer asset_previews_shutdown()
    defer preview_world_shutdown()
    mcp_bridge_init() // agent bridge on loopback TCP (docs/McpBridge.md)
    defer mcp_bridge_shutdown()

    for !menu.quit_requested && !gfx.quit_requested() {
        // Startup scenes load here, one per frame, once the dock layout has
        // settled (imgui sizes docked windows over the first few frames) —
        // the user sees the full layout, then scenes appear, instead of a
        // blank window behind a blocking load.
        SCENE_LOAD_WARMUP_FRAMES :: 3
        if frames_presented >= SCENE_LOAD_WARMUP_FRAMES do load_next_pending_scene()

        // Events feed both the editor input snapshot and imgui (the SDL3
        // backend owns keyboard/mouse/text/clipboard/DisplaySize/DeltaTime).
        gfx.poll_events(proc(e: ^sdl.Event) { im_sdl.ProcessEvent(e) })

        // Unity-style Auto Refresh: re-scan assets when the editor window
        // regains focus (git checkouts, external editors). Incremental
        // mtime-diff — an unchanged tree costs one stat pass.
        if input.focus_gained() {
            asset_pipeline.asset_db_refresh()
            project_dir_cache_invalidate()
            if dock_icon_pending {
                dock_icon_pending = false
                set_dock_icon("../EditorIcon.png") // cwd was normalized to moonhug/ at startup
            }
        }

        if !gfx.frame_begin() do continue
        progress_overlay_frame_scope(true)

        // Publish the selection for package editor windows (the read side of
        // the UserContext inspector channel — engine/user_context.odin).
        // Once per frame rather than at every mutation site: selection moves
        // from clicks, picking, pending-select and undo restore alike.
        engine.inspector_set_active_selection(sel_scene_active())

        // Thumbnail generation before ANY view draws: scene previews spawn and
        // destroy live content within this call, so nothing leaks into the
        // frame's visible rendering (thumbnails.odin).
        thumbnails_tick()

        // Agent bridge: before views draw, so screenshot readbacks see the
        // PREVIOUS frame's submitted render targets (mcp_bridge.odin).
        mcp_bridge_tick()

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
        _process_simulate_shortcuts()

        // Advance the in-editor simulation before the views draw, so hierarchy,
        // inspector and scene all show the same frame. Placed AFTER the toolbar
        // so a Stop pressed this frame takes effect before the tick, never
        // ticking a scene that is already being torn down.
        sim_tick(gfx.delta_time())

        // ImGui UI
        if menu.show_inspector {
            draw_hierarchy_inspector()
        }

        if menu.show_project_inspector {
            inspector.view_inspector_draw(&menu.show_project_inspector)
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

        // Package editor views (animation, playable graph, ...) — each owns
        // its own visibility flag (editor/preview).
        preview.draw_views()

        // The scrub preview poses the world ONLY for the scene/game render:
        // apply here, restore right after, so every other consumer of the
        // world this frame (saves, undo, inspector) sees authored values.
        preview.apply_all()
        if menu.show_scene {
            draw_scene_view()
        }

        if menu.show_game {
            draw_game_view()
        }
        preview.restore_all()

        if menu.show_input_debug {
            draw_input_debug()
        }

        if menu.show_output {
            draw_output_view()
        }

        // Plugin-opened windows (editor/window, docs/Plugins.md).
        wnd.draw_all()

        draw_about_popup()
        draw_status_bar()
        draw_pending_scene_overlay()

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
            // A queued full-window screenshot copies the swapchain HERE: the UI
            // has drawn into it and the command buffer is still open. Costs
            // nothing on frames nobody asked for one.
            mcp_bridge_capture_frame()
        }
        gfx.frame_end()
        progress_overlay_frame_scope(false)
        frames_presented += 1

        free_all(context.temp_allocator)
    }
    delete(_pending_scene_loads)

    save_editor_settings()
    settings_save_all()
}

@(phase={key=engine.Phase.EditorInit, order=0, mode=Editor})
editor_init :: proc() {
    registration.register_packages()
    inspector.init()
    phase_editor_run(.SerializationInit)
    phase_editor_run(.ImportersInit)
    phase_editor_run(.TweenNodesInit)
    clip.init()
    registration.register_type_guids()
    _init_context_menu_registry()
    _register_asset_previews()
    init_project_view()
    progress.report("Scanning assets")
    engine.asset_catalog_auto = true // editor maintains library/catalog.json
    asset_pipeline.asset_pipeline_init()
    engine.asset_db_init("assets")
    asset_pipeline.asset_pipeline_import_all()
    progress.report("Initializing caches")
    engine.texture_cache_init()
    engine.mesh_cache_init()
    engine.material_cache_init()
    engine.shader_cache_init()

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
        top_order["Edit"] = 4
        top_order["Assets"] = 8
        // Create submenu pinned to the top of the Assets menu (Unity).
        top_order["Assets/Create"] = -100
        top_order["GameObject"] = 10 // creation band also mirrors into the hierarchy popup
        top_order["Component"] = 15
        top_order["Tools"] = 20 // plugin/tooling menu items (e.g. packages)
        // Window menu sits before Help (Unity). Submenus first: General,
        // then domain groups (Animation), separator at -7, Theme, Reset
        // Layout (item order 20).
        top_order["Window"] = 25
        top_order["Window/General"] = -20
        top_order["Window/Animation"] = -15
        top_order["Window/Theme"] = 10
        top_order["Help"] = 30
        menu.sort_top_menu(top_order)
    }
}

// The scenes to reopen, resolved once at startup. The main loop loads ONE
// per frame after the first full frame presented — views and dock layout
// are ready, each scene appears on the next frame, and the UI never blanks
// behind a blocking load.
_pending_scene_loads: [dynamic]string

queue_scenes_from_settings :: proc() {
    for guid_str in editor_settings.open_scene_guids {
        guid, err := uuid.read(guid_str)
        if err != nil do continue
        path, ok := engine.asset_db_get_path(guid)
        if !ok do continue
        append(&_pending_scene_loads, strings.clone(path))
    }
}

// One pending scene per call (the per-frame step). The frame presented just
// before this call drew the loading overlay, so THAT is what the user sees
// while the load blocks.
load_next_pending_scene :: proc() {
    if len(_pending_scene_loads) == 0 do return
    path := _pending_scene_loads[0]
    ordered_remove(&_pending_scene_loads, 0)
    defer delete(path)
    // No pumped frames here — an overlay-only frame would blank the views.
    progress_overlay_frame_scope(true)
    defer progress_overlay_frame_scope(false)
    engine.scene_load_additive_path(path)
}

// Drawn as part of the NORMAL frame while scene loads are pending — the
// views stay visible behind it.
draw_pending_scene_overlay :: proc() {
    if len(_pending_scene_loads) == 0 do return
    vp := im.GetMainViewport()
    im.SetNextWindowPos(
        im.Vec2{vp.Pos.x + vp.Size.x * 0.5, vp.Pos.y + vp.Size.y * 0.5},
        .Always, im.Vec2{0.5, 0.5},
    )
    im.SetNextWindowSize(im.Vec2{420, 0}, .Always)
    if im.Begin("##scene_loading", nil,
        {.NoTitleBar, .NoResize, .NoMove, .NoCollapse, .NoSavedSettings, .NoDocking}) {
        im.TextUnformatted("Loading scene")
        im.ProgressBar(-1 * f32(im.GetTime()), im.Vec2{-1, 0}, "")
        im.TextDisabled("%s", fmt.ctprintf("%s", _pending_scene_loads[0]))
    }
    im.End()
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
	if engine.application_is_playing() do return
	s := undo.get()
	if s == nil do return

	redo_chord_y := im.KeyChord(im.Key.ImGuiMod_Ctrl) | im.KeyChord(im.Key.Y)
	if im.Shortcut(redo_chord_y, {.RouteGlobal}) {
		undo.apply_redo(s)
	}
}
