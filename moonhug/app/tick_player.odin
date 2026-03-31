package app

import "../engine"
import rl "vendor:raylib"
import "core:encoding/uuid"
import "core:math/rand"

@(update={order=0})
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

        if rl.IsKeyDown(.W) do t.position[1] += speed * dt
        if rl.IsKeyDown(.S) do t.position[1] -= speed * dt
        if rl.IsKeyDown(.A) do t.position[0] -= speed * dt
        if rl.IsKeyDown(.D) do t.position[0] += speed * dt

        // animations
        if rl.IsKeyDown(.ONE) do engine.tween_run("Anim0", engine.TweenContext{ subject = p.owner })
        if rl.IsKeyDown(.TWO) do engine.tween_run("Anim1", engine.TweenContext{ subject = p.owner })
        if rl.IsKeyDown(.THREE) do engine.tween_run("Anim2", engine.TweenContext{ subject = p.owner })
        if rl.IsKeyDown(.FOUR) do engine.tween_run("Anim3", engine.TweenContext{ subject = p.owner })
        if rl.IsKeyDown(.FIVE) do engine.tween_run("Anim4", engine.TweenContext{ subject = p.owner })
        if rl.IsKeyDown(.SIX) do engine.tween_run("Anim5", engine.TweenContext{ subject = p.owner })
        if rl.IsKeyDown(.SEVEN) do engine.tween_run("Anim6", engine.TweenContext{ subject = p.owner })
        if rl.IsKeyDown(.EIGHT) do engine.tween_run("Anim7", engine.TweenContext{ subject = p.owner })
        if rl.IsKeyDown(.NINE) do engine.tween_run("Anim8", engine.TweenContext{ subject = p.owner })
        if rl.IsKeyDown(.ZERO) do engine.tween_run("Anim9", engine.TweenContext{ subject = p.owner })

        if rl.IsKeyPressed(.SPACE) && len(p.colors) > 0 {
            _, sr := engine.transform_get_comp(p.owner, engine.SpriteRenderer)
            if sr != nil {
                idx := rl.GetRandomValue(0, i32(len(p.colors)) - 1)
                sr.color = p.colors[idx]
            }
        }

        if rl.IsKeyPressed(.SPACE) {
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
