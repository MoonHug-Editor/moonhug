#+feature dynamic-literals
package app

import "moonhug:packages/engine"
import tween "moonhug:packages/tween"
import "core:fmt"
import "moonhug:host/log"

main :: proc() {
    __standalone_run()
}

Phase_Extra :: enum {
    Test,
}

BULLET_SCENE_GUID :: "7db918ca-bee2-4f8a-92de-dc4bec1b7cb9"

@(phase={key=Phase.Init})
app_init :: proc() {
    log.info("App Init")
}

setup_player_animations :: proc()
{
    it := engine.pool_iterator(players(engine.ctx_world()))
    for p, _ in engine.pool_next(&it) {
        for &ht, i in p.animations{
        	anim_key := fmt.tprintf("Anim%d", i)
         	tween.tween_register(anim_key, &ht)
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
    tween.tween_tick_running(dt, {})
}

