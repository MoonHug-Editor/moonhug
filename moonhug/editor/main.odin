package editor

import "core:fmt"
// Debug builds only (the tracking allocator below) — @(require) keeps -vet
// from reading it as unused in a release build.
@(require) import "core:mem"
import sdl "vendor:sdl3"
import gfx "moonhug:libs/gfx"
import input "moonhug:libs/input"
import strings "core:strings"
import im "moonhug:external/odin-imgui"
import "moonhug:libs/gizmos"
import im_sdl "moonhug:external/odin-imgui/imgui_impl_sdl3"
import im_sdlgpu "moonhug:external/odin-imgui/imgui_impl_sdlgpu3"
import "inspector"
import "menu"
import clip "clipboard"
import "undo"
import wnd "moonhug:editor/window"
import "moonhug:editor/keymap"
import "moonhug:editor/command_palette"
import "moonhug:editor/workspace"
import "moonhug:editor/widgets"
import "moonhug:editor/preview"
import "moonhug:editor/thumbnails"
import "moonhug:registration"
import "core:os"
import core "moonhug:libs/core"
import asset_pipeline "moonhug:editor/assets"
import assets "moonhug:libs/assets"
import "moonhug:editor/progress"
import crash_journal "moonhug:libs/crash_journal"
import "moonhug:libs/log"
import "core:encoding/uuid"
import "moonhug:editor/session"

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

    // Anchor at moonhug/ before anything reads a relative path. Detection is
    // by directory content, not folder name (libs/assets/project_root.odin).
    assets.project_chdir_root()

    // Before anything that can fault: from here on a crash lands in
    // logs/crash_<pid>.log with a stack (docs/general/CrashJournal.md).
    crash_journal.init(VERSION)
    // Must be set HERE, not inside init: assertion_failure_proc lives on the
    // context, so it only persists in the scope that assigns it.
    context.assertion_failure_proc = crash_journal.assertion_failure
    // --hidden keeps the editor's window off the screen: a scenario run
    // drives it through the bridge (moonhug/scenarios).
    hidden := false
    for arg in os.args[1:] {
        if arg == "--crash-test" {
            fmt.eprintfln("crash journal self-test: writing %s and faulting", crash_journal.path())
            crash_journal.test_crash()
        }
        if arg == "--hidden" do hidden = true
    }

    win_w, win_h, win_x, win_y := load_editor_settings()
    has_saved_settings := win_w > 0 && win_h > 0
    // Window starts hidden so saved geometry applies before first present.
    if !gfx.init(strings.clone_to_cstring(main_window_title(), context.temp_allocator), has_saved_settings ? win_w : 800, has_saved_settings ? win_h : 600, show = false) {
        fmt.eprintln("gfx init failed (is SDL3 installed? brew install sdl3)")
        return
    }
    // SDL's macOS menu bar exists once the window does: its Cmd+W must go
    // before the first key press (dock_icon_darwin.odin).
    drop_window_close_key()
    defer gfx.shutdown()

    if has_saved_settings && win_x >= 0 && win_y >= 0 {
        gfx.set_window_geometry(win_x, win_y, win_w, win_h)
    } else if !has_saved_settings {
        apply_default_window_size()
    }
    // The window is shown further down, once the theme is applied and a frame
    // in its colours is ready: it never shows black or another theme's colours.
    // Dock icon is applied AFTER the first focus event (see the main loop),
    // NOT here: setApplicationIconImage during the launch activation
    // handshake could wedge key-window status when a click landed early —
    // keyboard dead for the whole session, mouse fine, only an app switch
    // repaired it (Help/Input Debug was built to diagnose this).
    dock_icon_pending := true

    // Setup ImGui
    im.CHECKVERSION()
    ctx := im.CreateContext()
    // Before imgui's first frame reads imgui.ini (the loading screen renders
    // frames during startup): the plugin window declarations, then the saved
    // window placement renamed onto the windows' current ids.
    _register_editor_windows()
    // Keys go to the clicked window (window/window.odin focused), never the
    // hovered one, then to the window hosting it.
    keymap.focused_path = proc() -> []string {
        w := wnd.focused()
        if w == nil do return nil
        path := make([dynamic]string, context.temp_allocator)
        append(&path, w.id)
        if h := wnd.find(w.host); h != nil do append(&path, h.id)
        return path[:]
    }
    // While the game runs in a focused Game window, plain keys are the game's,
    // as they are a text field's while it is typed in.
    keymap.key_source.text = proc() -> bool {
        return im.GetIO().WantTextInput || (sim_is_active() && game_window_focused)
    }
    migrate_imgui_ini()
    defer im.DestroyContext(ctx)

    // Docking (drag window title bars to dock/undock), and floating windows
    // when dragged outside the main window
    // (imgui_viewports.odin).
    io := im.GetIO()
    io.ConfigFlags += {.DockingEnable, .ViewportsEnable}
    // A window dragged out alone keeps a tab bar instead of a title bar, so it
    // carries the tab menu button (dock_tab_menu.odin) like a docked window.
    io.ConfigDockingAlwaysTabBar = true

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
    imgui_viewports_init()

    apply_editor_theme()
    // From here reports draw pumped frames — startup shows progress instead
    // of a black window (progress_overlay.odin).
    progress_overlay_install()
    // A frame in the theme's colours before the window shows and one right
    // after: where a hidden window takes no frame, the second one is the first.
    progress_overlay_first_frame()
    if !hidden do gfx.show_window()
    progress_overlay_first_frame()

    // The installed engine's user context, world and caches, from its
    // EngineInit subscribers. nil with no engine.
    phase_editor_run(.EngineInit)
    context.user_ptr = core.user_context

    undo_stack := new(undo.Undo_Stack)
    undo.init(undo_stack)
    undo.install(undo_stack)
    // Selection restore/record goes through hooks (undo can't import editor).
    selection_undo_install()
    defer selection_undo_shutdown()
    defer { undo.destroy(undo_stack); free(undo_stack) }

    defer phase_editor_run(.EngineShutdown)

    progress.begin("Starting MoonHug")
    phase_editor_run(.EditorInit)
    progress.end()
    // The keymaps after EditorInit registered the menu items, so every
    // command a keymap names exists when it binds, and the conflict log sees
    // the menu's shortcuts. Then the developer's overrides, machine-wide in
    // the OS user's config folder, applied over the declared bindings and to
    // any keymap registered later (editor/keymap).
    _register_editor_keymaps()
    // The values the commands with arguments last ran with, now they exist.
    for id, args in editor_settings.command_args {
        if c := keymap.command(id); c != nil do keymap.command_args_set_json(c, transmute([]u8)args)
    }
    keymap.overrides_path = strings.clone(core.system_settings_file("Shortcuts"))
    keymap.overrides_load()
    keymap.log_conflicts()
    defer phase_editor_run(.EditorShutdown)
    queue_scenes_from_settings()
    frames_presented := 0

    // Resolve which host Simulate ticks, from the generated table sim_world
    // set in EditorInit and the persisted setting. Must follow
    // load_editor_settings and EditorInit.
    simulate_init()
    defer simulate_shutdown()
    // Reopen what was open last session — declarations must exist first. A
    // first run opens the windows the default layout docks.
    window_states_restore()
    wnd.open_saved(editor_settings.open_window_ids[:])
    wnd.close_guard = window_close_guard
    if !editor_settings.has_window_state {
        wnd.open_saved({"Scene", "Game", "Hierarchy", "Inspector", "Project", "Project Inspector", "Console", "Output"})
    }
    defer wnd.shutdown()
    defer workspace.shutdown()
    defer preview.shutdown()
    _register_project_settings() // @(project_settings) vars -> settings tabs
    project_plugins_register()   // the Plugins tab: plugins/ with a link toggle each
    defer settings_shutdown()
    defer thumbnails.shutdown()
    mcp_bridge_init() // agent bridge on loopback TCP (docs/core/McpBridge.md)
    defer mcp_bridge_shutdown()

    // Quitting with unsaved files asks first (quit_prompt.odin).
    for !quit_gate() {
        relaunch_tick()
        // Startup scenes load here, one per frame, once the dock layout has
        // settled (imgui sizes docked windows over the first few frames) —
        // the user sees the full layout, then scenes appear, instead of a
        // blank window behind a blocking load.
        SCENE_LOAD_WARMUP_FRAMES :: 3
        if frames_presented >= SCENE_LOAD_WARMUP_FRAMES do load_next_pending_scene()
        // The selection and inspector locks of the last run, once every
        // reopened scene is in (selection_persist.odin).
        if frames_presented >= SCENE_LOAD_WARMUP_FRAMES && len(_pending_scene_loads) == 0 do selection_persist_restore()

        // Events feed both the editor input snapshot and imgui (the SDL3
        // backend owns keyboard/mouse/text/clipboard/DisplaySize/DeltaTime).
        // Waits for the next frame (frame_pacing.odin): the frame-rate cap,
        // and the idle throttle that input ends at once.
        frame_pacing_wait(proc(e: ^sdl.Event) { im_sdl.ProcessEvent(e) })

        // Unity-style Auto Refresh: re-scan assets when the editor window
        // regains focus (git checkouts, external editors). Incremental
        // mtime-diff — an unchanged tree costs one stat pass.
        if input.focus_gained() {
            asset_pipeline.asset_db_refresh()
            project_dir_cache_invalidate()
            if dock_icon_pending {
                dock_icon_pending = false
                set_dock_icon("../EditorIcon.png") // cwd was normalized to moonhug/ at startup
                set_app_menu_title(main_window_title())
                drop_window_close_key()
            }
        }

        if !gfx.frame_begin() do continue
        progress_overlay_frame_scope(true)

        // Publish the selection for package editor windows (the read side of
        // the UserContext inspector channel — plugins/engine/user_context.odin).
        // Once per frame rather than at every mutation site: selection moves
        // from clicks, picking, pending-select and undo restore alike.
        selection_publish()

        // Reimports an Apply asked for last frame, before any window draws: a
        // reimport frees the asset's GPU textures (editor/assets/import.odin).
        asset_pipeline.asset_pipeline_reimport_pending()

        // Thumbnail generation before ANY window draws: scene previews spawn and
        // destroy live content within this call, so nothing leaks into the
        // frame's visible rendering (editor/thumbnails).
        thumbnails.tick()

        // Agent bridge: before windows draw, so screenshot readbacks see the
        // PREVIOUS frame's submitted render targets (mcp_bridge.odin).
        mcp_bridge_tick()

        // Start ImGui frame
        im_sdlgpu.NewFrame()
        im_sdl.NewFrame()
        // Agent input scripts queue their events after the backend's, before
        // imgui reads the queue (mcp_input.odin).
        mcp_bridge_input_feed()
        im.NewFrame()
        // An open dialog owns the keyboard, before anything reads a key
        // (widgets/dialog.odin).
        widgets.dialog_frame_begin()
        widgets.text_input_escape_frame() // Escape commits text fields (widgets/text_input.odin)
        // Agent layout changes, before the dockspace and the windows draw
        // (mcp_window_tools.odin).
        mcp_bridge_window_ops()

        menu.draw_menu_bar()
        draw_tool_bar()
        // Dockspace host under the toolbar; must precede the dockable windows'
        // Begin() calls (dock.odin — builds the default layout on first run).
        draw_dockspace()

        // Every key binding resolves here, before the windows draw
        // (editor/keymap): menu shortcuts, the scene tools, the flythrough.
        keymap.frame()

        // A Play requested LAST frame starts here: the frame in between let
        // every editor preview restore the world it had posed, so the
        // snapshot captures authored values and tracks release together
        // (sim.request_start).
        sim_start_pending()

        // Advance the in-editor simulation before the windows draw, so hierarchy,
        // inspector and scene all show the same frame. Placed AFTER the toolbar
        // so a Stop pressed this frame takes effect before the tick, never
        // ticking a scene that is already being torn down.
        // The game reads input only while the Game window has focus
        // (window_game.odin); editor windows read it unblocked.
        // Application focus for the game is the Game window's focus during a
        // run (window_game.odin); the tick is the game scope, editor windows
        // read outside it.
        game_window_frame_begin()
        // Gameplay gizmos measure against the game camera: the sim draws them
        // once, and the Game window is the one they are for (docs/core/Gizmos.md).
        if v, ok := _game_gizmo_view(); ok do gizmos.set_view(v)
        input.set_app_focused(!sim_is_active() || game_window_focused)
        input.set_game_scope(true)
        sim_tick(gfx.delta_time())
        input.set_game_scope(false)

        // ImGui UI. The windows are window instances, drawn with the other
        // windows (wnd.draw_all). Their per-frame bookkeeping runs here,
        // whether or not one is visible.
        session.scene_windows_frame_begin()
        window_locks_prune()
        project_inspectors_follow()

        project_frame_begin()

        // Package windows' once-per-frame work (editor/preview): the
        // Animation window's transport.
        preview.frame_all()

        // The scrub preview poses the world ONLY for the scene/game render:
        // apply here, restore right after, so every other consumer of the
        // world this frame (saves, undo, inspector) sees authored values.
        preview.apply_all()
        // Handles and gizmo hooks record once per frame, before any window
        // renders: every window draws the same shapes (gizmo_pass.odin).
        gizmo_pass()
        wnd.draw("Scene")
        scene_windows_render_hosted()

        wnd.draw(GAME)
        preview.restore_all()

        // Plugin-opened windows (editor/window, docs/core/Plugins.md).
        wnd.draw_all()
        command_palette.draw()
        adjust_last_draw()

        draw_about_popup()
        // Confirmations and other modal questions (widgets/dialog.odin).
        widgets.dialog_draw()
        draw_status_bar()
        draw_pending_scene_overlay()

        // Import settings undo steps: a finished change to a settings document
        // becomes one step (inspector/import_settings_docs.odin).
        // Working copies record the same way (inspector/asset_doc_copies.odin).
        may_finish := _frame_may_finish_edit()
        inspector.import_settings_track(may_finish)
        inspector.asset_doc_copies_track(may_finish)

        // Selection undo steps (Unity model): diff selection against the
        // frame's baseline after all windows handled input.
        selection_undo_track()

        // The tab menu button on windows floating outside the dockspace, now
        // that their hosts have begun this frame.
        tab_menu_draw_floating()
        maximize_after_windows()

        // Render. Scene/Game windows already encoded their offscreen passes
        // into this frame's command buffer during the UI calls above; imgui's
        // copy passes (PrepareDrawData) must come BEFORE the swapchain render
        // pass, and its draw happens inside it (pass_end callback).
        im.Render()
        dd := im.GetDrawData()
        im_sdlgpu.PrepareDrawData(dd, gfx.command_buffer())
        if gfx.pass_begin_swapchain(theme_clear_color(), depth = false) {
            gfx.pass_end(proc(cmd: ^sdl.GPUCommandBuffer, rp: ^sdl.GPURenderPass) {
                im_sdlgpu.RenderDrawData(im.GetDrawData(), cmd, rp)
            })
            // A queued full-window screenshot copies the swapchain HERE: the UI
            // has drawn into it and the command buffer is still open. Costs
            // nothing on frames nobody asked for one.
            mcp_bridge_capture_frame()
        }
        gfx.frame_end()
        imgui_platform_windows()
        progress_overlay_frame_scope(false)
        frames_presented += 1

        free_all(context.temp_allocator)
    }
    delete(_pending_scene_loads)

    save_editor_settings()
    settings_save_all()
}

@(phase={key=core.Phase.EditorInit, order=0, mode=Editor})
editor_init :: proc() {
    registration.register_packages()
    // Type keys before the phases, the same order as the app and the tests:
    // SerializationInit subscribers look them up.
    registration.register_type_guids()
    // Documents live on this allocator, the one drawers and undo writes use.
    inspector.doc_allocator = context.allocator
    inspector.init()
    // Every doc_on_changed and doc_on_saved declaration (registration/doc_hooks_generated.odin).
    registration.register_doc_hooks()
    registration.register_property_drawers()
    // Every @(provider_install) proc (providers_generated.odin): they fill the
    // registries inspector.init just created.
    install_providers()
    phase_editor_run(.SerializationInit)
    registration.register_importers()
    phase_editor_run(.ImportersInit)
    clip.init()
    inspector.selected_sub = _inspected_sub
    init_project_window()
    progress.report("Scanning assets")
    asset_pipeline.asset_pipeline_init()
    assets.asset_db_init("assets")
    asset_pipeline.asset_pipeline_import_all()
    init_scene_window()
    init_game_window()
    setup_menu_items()

    return

    setup_menu_items :: proc() {
        _register_menu_items()
        _register_window_chrome()
        _load_user_settings() // @(user_settings) vars -> UserSettings/*.json
        _load_system_settings() // @(system_settings) vars -> <config dir>/MoonHug/*.json
        register_create_asset_menus()
        session.scene_windows_register_menus()

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
        // The Window menu sits before Help. Submenus first: General,
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
// per frame after the first full frame presented — windows and dock layout
// are ready, each scene appears on the next frame, and the UI never blanks
// behind a blocking load.
_pending_scene_loads: [dynamic]string

queue_scenes_from_settings :: proc() {
    for guid_str in editor_settings.open_scene_guids {
        guid, err := uuid.read(guid_str)
        if err != nil do continue
        path, ok := assets.asset_db_get_path(guid)
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
    // No pumped frames here — an overlay-only frame would blank the windows.
    progress_overlay_frame_scope(true)
    defer progress_overlay_frame_scope(false)
    asset_pipeline.asset_open_additive(path)
}

// Drawn as part of the NORMAL frame while scene loads are pending — the
// windows stay visible behind it.
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

@(phase={key=core.Phase.EditorShutdown, order=0, mode=Editor})
editor_shutdown :: proc() {
    join_play_thread()
    shutdown_game_window()
    shutdown_scene_window()
    assets.asset_db_shutdown()
    inspector.shutdown_registries()
    session.scene_windows_shutdown()
    selection_shutdown()
    shutdown_project_window()
    clip.shutdown()
    _save_user_settings()
    _save_system_settings()
    menu.shutdown_menu()
    shortcuts_shutdown()
    adjust_last_close()
    command_palette.shutdown()
    keymap.shutdown()
    delete(keymap.overrides_path)
    window_chrome_shutdown()
    window_locks_shutdown()
    maximize_shutdown()
    workspace_window_shutdown()
    log.info("Editor Shutdown")
    log.shutdown()
}

// Creates a prefab variant of the currently-selected scene asset, written
// alongside it as "<name>_Variant.scene". Registered into the same menu system
// as "Create/Scene", so it appears in the project panel's right-click menu and
// the top Assets menu. Acts on projectWindowData.selectedFile (the asset the user
// last clicked); no-op with a console note if no .scene is selected.
@(menu_item={path="Assets/Create/Scene Variant", order=-10, shortcut="", help="Creates a variant of the selected scene next to it"})
scene_create_variant_menu :: proc() {
	if !strings.has_suffix(projectWindowData.selectedFile, ".scene") {
		fmt.println("[Editor] Create Scene Variant: select a .scene asset first")
		return
	}
	// selectedFile holds the FULL path (search results span folders).
	create_scene_variant(projectWindowData.selectedFile)
}

@(menu_separator={path="Assets/Create", order=-9})
scene_create_variant_separator :: proc() {}

// True on a frame where an edit may have just finished: a widget was let go, a
// mouse button went up, or a key was pressed. Only then can a document differ
// from its last recorded state, so the import settings check runs on those
// frames alone and idle frames cost nothing (comparing a model with 40 clips
// takes about a quarter of a millisecond).
@(private = "file")
_frame_may_finish_edit :: proc() -> bool {
	@(static) was_active: bool
	active := im.IsAnyItemActive()
	defer was_active = active
	if active do return false
	if was_active do return true
	for released in im.GetIO().MouseReleased do if released do return true
	for k in int(im.Key.NamedKey_BEGIN) ..< int(im.Key.NamedKey_END) {
		if im.IsKeyPressed(im.Key(k), false) do return true
	}
	return false
}

