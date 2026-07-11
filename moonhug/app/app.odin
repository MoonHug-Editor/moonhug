#+feature dynamic-literals
package app

import "../engine"
import gfx "../engine/gfx"
import "../engine/serialization"
import "core:os"
import "core:fmt"
import "core:encoding/json"
import "core:encoding/uuid"
import "../engine/log"

MENU_SCENE_GUID :: "b794d34b-3067-4b7e-ac2d-5cd46c16c5c1"

main :: proc() {
    // Machine-tagged log lines: the editor's play pipe parses them back into
    // its console (standalone runs just see the tagged text in the terminal).
    log.stdout_tagged = true

    if !gfx.init("App", 800, 600) {
        log.error("gfx init failed")
        return
    }
    defer gfx.shutdown()

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

    for !gfx.quit_requested() {
        gfx.poll_events()
        if !gfx.frame_begin() do continue

        __update(gfx.delta_time())

        // World cameras render first (pass stays open), then the demo menu
        // overlays in screen space within the same swapchain pass.
        if engine.render_world_cameras() {
            ws := gfx.window_size()
            gfx.set_view_proj(gfx.matrix4_ortho_pixels(f32(ws.x), f32(ws.y)))
            demo_menu_draw()
            gfx.pass_end()
        }
        gfx.frame_end()
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
    register_app_components()
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
