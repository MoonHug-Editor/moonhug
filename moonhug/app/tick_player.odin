package app

import "../engine"
import gfx "../engine/gfx"
import "core:encoding/uuid"
import "core:math/rand"

@(fixed_update={order=0})
tick_player :: proc(dt: f32) {
    w := engine.ctx_world()
    for i in 0..<len(w.players.slots) {
        slot := &w.players.slots[i]
        if !slot.alive do continue
        p := &slot.data
        if !p.enabled do continue

        t := engine.pool_get(&w.transforms, engine.Handle(p.owner))
        if t == nil do continue

        speed := p.speed if p.speed > 0 else 100

        if gfx.input_key_down_fixed(.W) do t.position[1] += speed * dt
        if gfx.input_key_down_fixed(.S) do t.position[1] -= speed * dt
        if gfx.input_key_down_fixed(.A) do t.position[0] -= speed * dt
        if gfx.input_key_down_fixed(.D) do t.position[0] += speed * dt

        // animations
        if gfx.input_key_down_fixed(._1) do engine.tween_run("Anim0", engine.TweenContext{ subject = p.owner })
        if gfx.input_key_down_fixed(._2) do engine.tween_run("Anim1", engine.TweenContext{ subject = p.owner })
        if gfx.input_key_down_fixed(._3) do engine.tween_run("Anim2", engine.TweenContext{ subject = p.owner })
        if gfx.input_key_down_fixed(._4) do engine.tween_run("Anim3", engine.TweenContext{ subject = p.owner })
        if gfx.input_key_down_fixed(._5) do engine.tween_run("Anim4", engine.TweenContext{ subject = p.owner })
        if gfx.input_key_down_fixed(._6) do engine.tween_run("Anim5", engine.TweenContext{ subject = p.owner })
        if gfx.input_key_down_fixed(._7) do engine.tween_run("Anim6", engine.TweenContext{ subject = p.owner })
        if gfx.input_key_down_fixed(._8) do engine.tween_run("Anim7", engine.TweenContext{ subject = p.owner })
        if gfx.input_key_down_fixed(._9) do engine.tween_run("Anim8", engine.TweenContext{ subject = p.owner })
        if gfx.input_key_down_fixed(._0) do engine.tween_run("Anim9", engine.TweenContext{ subject = p.owner })

        if gfx.input_key_pressed_fixed(.SPACE) && len(p.colors) > 0 {
            _, sr := engine.transform_get_comp(p.owner, engine.SpriteRenderer)
            if sr != nil {
                idx := rand.int_max(len(p.colors))
                sr.color = p.colors[idx]
            }
        }

        if gfx.input_key_pressed_fixed(.SPACE) {
            bullet_guid, guid_ok := uuid.read(BULLET_SCENE_GUID)
            if guid_ok == nil {
                bullet_tH := engine.scene_instantiate_guid(engine.Asset_GUID(bullet_guid), p.owner)
                bt := engine.pool_get(&w.transforms, engine.Handle(bullet_tH))
                if bt != nil {
                    spread :: f32(5)
                    bt.position[0] = rand.float32_range(-spread, spread)
                    bt.position[1] = rand.float32_range(-spread, spread)
                }
            }
        }
    }
}
