package editor

import "core:fmt"
import rl "vendor:raylib"
import strings "core:strings"
import im "../../external/odin-imgui"
import im_gl "../../external/odin-imgui/imgui_impl_opengl3"
import "inspector"
import "menu"
import clip "clipboard"
import "../engine/serialization"
import "../app"
import "../app_editor"
import "core:os"
import "../engine"
import "core:path/filepath"
import "../engine/log"
import "core:encoding/uuid"

main :: proc() {
    cwd, _ := os.get_working_directory(context.temp_allocator)
    if !strings.has_suffix(cwd, "moonhug") {
        moonhug_dir, _ := filepath.join({cwd, "moonhug"}, context.temp_allocator)
        os.set_working_directory(moonhug_dir)
    }

    win_w, win_h, win_x, win_y := load_editor_settings()
    has_saved_settings := win_w > 0 && win_h > 0
    if has_saved_settings {
        rl.InitWindow(win_w, win_h, WINDOW_TITLE)
    } else {
        rl.InitWindow(800, 600, WINDOW_TITLE)
    }
    defer rl.CloseWindow()

    rl.SetWindowState({.WINDOW_RESIZABLE})
    if has_saved_settings && win_x >= 0 && win_y >= 0 {
        rl.SetWindowPosition(win_x, win_y)
    } else if !has_saved_settings {
        apply_default_window_size()
    }
    rl.SetExitKey(.KEY_NULL)
    rl.SetTargetFPS(60)

    // Setup ImGui
    im.CHECKVERSION()
    ctx := im.CreateContext()
    defer im.DestroyContext(ctx)

    // Enable docking (drag window title bars to dock/undock)
    io := im.GetIO()
    io.ConfigFlags += {.DockingEnable}

    // Initialize OpenGL3 backend (Raylib uses OpenGL)
    im_gl.Init("#version 330")
    defer im_gl.Shutdown()

    apply_editor_theme()

    // Init user context and world
    uc := new(engine.UserContext)
    context.user_ptr = uc

    w := new(engine.World)
    engine.w_init(w)
    engine.ctx_get().world = w

    phase_editor_run(.EditorInit)
    defer phase_editor_run(.EditorShutdown)

    for !menu.quit_requested && !rl.WindowShouldClose() {
        // Update ImGui IO
        io := im.GetIO()
        sw := f32(rl.GetScreenWidth())
        sh := f32(rl.GetScreenHeight())
        io.DisplaySize = im.Vec2{sw, sh}
        if menu.scale_ui_for_dpi {
            rw := f32(rl.GetRenderWidth())
            rh := f32(rl.GetRenderHeight())
            io.DisplayFramebufferScale = im.Vec2{
                rw / sw if sw > 0 else 1,
                rh / sh if sh > 0 else 1,
            }
        } else {
            io.DisplayFramebufferScale = im.Vec2{1, 1}
        }
        io.DeltaTime = rl.GetFrameTime()

        // Update mouse
        mouse_pos := rl.GetMousePosition()
        io.MousePos = im.Vec2{mouse_pos.x, mouse_pos.y}
        io.MouseDown[0] = rl.IsMouseButtonDown(.LEFT)
        io.MouseDown[1] = rl.IsMouseButtonDown(.RIGHT)
        io.MouseWheel = rl.GetMouseWheelMove()

        update_imgui_keyboard_input()

        // Start ImGui frame
        im_gl.NewFrame()
        im.NewFrame()

        menu.draw_menu_bar()
        draw_tool_bar()

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

        if menu.show_hierarchy {
            draw_hierarchy_view()
        }

        if menu.show_scene {
            draw_scene_view()
        }

        if menu.show_game {
            draw_game_view()
        }

        if menu.show_output {
            draw_output_view()
        }

        draw_about_popup()
        draw_status_bar()

        // Render
        rl.BeginDrawing()
        rl.ClearBackground(rl.RAYWHITE)

        // Let ImGui render
        im.Render()
        im_gl.RenderDrawData(im.GetDrawData())

        rl.EndDrawing()
    }

    save_editor_settings()
}

@(Phase={key=app.Phase.EditorInit, order=0})
editor_init :: proc() {

	log.info("Editor Init")
	log.error("test error")
	log.warning("test warning")
    app.register_component_serializers()
    inspector.init()
    serialization.init()
    clip.init()
    engine.register_pointer_type(bool)
    engine.register_pointer_type(int)
    engine.register_pointer_type(f32)
    engine.register_pointer_type(f64)
    engine.register_pointer_type(string)
    engine.register_pointer_type(engine.A)
    engine.register_pointer_type(engine.TweenUnion)
    engine.register_pointer_type(engine.UnionTest)
    app.register_type_guids()
    _init_context_menu_registry()
    init_project_view()
    engine.asset_pipeline_init()
    engine.asset_db_init("assets")
    engine.asset_pipeline_import_all()
    engine.texture_cache_init()
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
        top_order["View/Theme"] = -10
        top_order["Assets"] = 2
        top_order["Component"] = 6
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

@(Phase={key=app.Phase.EditorShutdown, order=0})
editor_shutdown :: proc() {
    join_play_thread()
    shutdown_game_view()
    shutdown_scene_view()
    engine.texture_cache_shutdown()
    engine.asset_db_shutdown()
    log.info("Editor Shutdown")
}

@(menu_item={path="Assets/Create/Scene", order=0, shortcut=""})
scene_create_menu :: proc() {
	scene := engine.scene_new()
	save_path, _ := filepath.join({projectViewData.currentPath, "Scene.scene"}, context.temp_allocator)
	engine.scene_save(scene, save_path)
}
