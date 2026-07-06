#+feature dynamic-literals
package app

import "../engine"
import "../engine/serialization"
import rl "vendor:raylib"
import "core:os"
import "core:fmt"
import "core:encoding/json"
import "core:encoding/uuid"
import "../engine/log"

MENU_SCENE_GUID :: "b794d34b-3067-4b7e-ac2d-5cd46c16c5c1"

main :: proc() {
    rl.InitWindow(800, 600, "App")
    defer rl.CloseWindow()

    rl.SetWindowState({.WINDOW_RESIZABLE})
    rl.SetExitKey(.KEY_NULL) // ESC is used by the demo menu, not for quitting
    rl.SetTargetFPS(60)

    uc := new(engine.UserContext)
    uc.is_playmode = true
    context.user_ptr = uc

    w := new(engine.World)
    engine.w_init(w)
    engine.ctx_get().world = w

    phase_run(Phase.Init)

    // Scene selection: explicit path via first program arg (the editor's Play
    // button passes its active scene), falling back to the menu scene resolved
    // by GUID so the asset can move freely.
    scene_path: string
    if len(os.args) > 1 && len(os.args[1]) > 0 {
        scene_path = os.args[1]
    } else if guid, gerr := uuid.read(MENU_SCENE_GUID); gerr == nil {
        scene_path, _ = engine.asset_db_get_path(guid)
    }
    if os.exists(scene_path) {
        engine.scene_load_single_path(scene_path)
        scene_loaded()
    } else {
        log.errorf("scene not found: %s", scene_path)
    }

    for !rl.WindowShouldClose() {
        dt := rl.GetFrameTime()
        __update(dt)

        rl.BeginDrawing()
        rl.ClearBackground(rl.BLACK)
        engine.render_world_cameras()
        demo_menu_draw()
        rl.EndDrawing()
    }

    phase_run(Phase.Shutdown)
}

Phase_Extra :: enum {
    Test,
}

BULLET_SCENE_GUID :: "7db918ca-bee2-4f8a-92de-dc4bec1b7cb9"

@(phase={key=Phase.Init})
app_init :: proc() {
    log.info("App Init")
    register_type_guids()
    register_component_serializers()
    serialization.init()
    engine.asset_db_init("assets")
    engine.texture_cache_init()
    engine.tween_init()

    log.info("App Init done")
}

setup_player_animations :: proc()
{
    w := engine.ctx_world()
    for i in 0..<len(w.players.slots) {
        slot := &w.players.slots[i]
        if !slot.alive do continue
        p :^engine.Player= &slot.data;
        for &ht, i in p.animations{
        	anim_key := fmt.tprintf("Anim%d", i)
         	engine.tween_register(anim_key, &ht)
        }
        break
    }
}

@(phase={key=Phase.Shutdown})
app_shutdown :: proc() {
    log.info("App Shutdown")
}

@(update={order=1})
tween_tick :: proc(dt: f32) {
    engine.tween_tick_running(dt, {})
}
