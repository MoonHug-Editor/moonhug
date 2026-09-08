package app

import "moonhug:engine"
import sprites "moonhug:packages/sprites"
import audio "moonhug:packages/audio"
import tween "moonhug:packages/tween"
import input "moonhug:engine/input"
import "core:encoding/uuid"
import "core:math/rand"

@(fixed_update={order=0})
tick_player :: proc(dt: f32) {
    w := engine.ctx_world()
    it := engine.pool_iterator(players(w))
    for p, _ in engine.pool_next(&it) {
        if !p.enabled do continue

        t := engine.pool_get(&w.transforms, engine.Handle(p.owner))
        if t == nil do continue

        speed := p.speed if p.speed > 0 else 100

        if input.key_down_fixed(.W) do t.position[1] += speed * dt
        if input.key_down_fixed(.S) do t.position[1] -= speed * dt
        if input.key_down_fixed(.A) do t.position[0] -= speed * dt
        if input.key_down_fixed(.D) do t.position[0] += speed * dt

        // animations
        if input.key_down_fixed(._1) do tween.tween_run("Anim0", tween.TweenContext{ subject = p.owner })
        if input.key_down_fixed(._2) do tween.tween_run("Anim1", tween.TweenContext{ subject = p.owner })
        if input.key_down_fixed(._3) do tween.tween_run("Anim2", tween.TweenContext{ subject = p.owner })
        if input.key_down_fixed(._4) do tween.tween_run("Anim3", tween.TweenContext{ subject = p.owner })
        if input.key_down_fixed(._5) do tween.tween_run("Anim4", tween.TweenContext{ subject = p.owner })
        if input.key_down_fixed(._6) do tween.tween_run("Anim5", tween.TweenContext{ subject = p.owner })
        if input.key_down_fixed(._7) do tween.tween_run("Anim6", tween.TweenContext{ subject = p.owner })
        if input.key_down_fixed(._8) do tween.tween_run("Anim7", tween.TweenContext{ subject = p.owner })
        if input.key_down_fixed(._9) do tween.tween_run("Anim8", tween.TweenContext{ subject = p.owner })
        if input.key_down_fixed(._0) do tween.tween_run("Anim9", tween.TweenContext{ subject = p.owner })

        if input.key_pressed_fixed(.SPACE) && len(p.colors) > 0 {
            _, sr := engine.transform_get_comp(p.owner, sprites.SpriteRenderer)
            if sr != nil {
                idx := rand.int_max(len(p.colors))
                sr.color = p.colors[idx]
            }
        }

        if input.key_pressed_fixed(.SPACE) {
            if _, src := audio.get_comp(p.owner, audio.AudioSource); src != nil {
                audio.audio_play(src)
            }
        }

        if input.key_pressed_fixed(.SPACE) {
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
