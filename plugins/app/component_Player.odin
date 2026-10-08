package app

// The demo's player pawn (WASD movement in fixed_update_Player, number-key tween
// animations wired by setup_player_animations). App-level: scene records live
// in ext_components keyed by the type guid below — never change it.

import "moonhug:packages/engine"
import tween "moonhug:packages/tween"
import sprites "moonhug:packages/sprites"
import audio "moonhug:packages/audio"
import input "moonhug:host/input"
import "core:encoding/uuid"
import "core:math/rand"

@(component={max=10, menu="Demo/Player"})
@(typ_guid={guid = "d3f1a2b4-7e8c-4d5f-9a0b-1c2e3f4a5b6c"})
Player :: struct {
    using base: engine.CompData `inspect:"-"`,
    speed:  f32,
    colors: [dynamic][4]f32,
    animations: [dynamic]tween.Authored,
    sprite: engine.Ref_Local `ref:"SpriteRenderer"`,
}

reset_Player :: proc(p: ^Player) {
    cleanup_Player(p)
    p.speed = 5

    p.colors = make([dynamic][4]f32)
    append(&p.colors, [4]f32{1, 0, 0, 1})
    append(&p.colors, [4]f32{0, 1, 0, 1})
    append(&p.colors, [4]f32{0, 0, 1, 1})
}


cleanup_Player :: proc(p: ^Player) {
	if p.colors != nil do delete(p.colors)
	if p.animations != nil {
		for &anim in p.animations do tween.authored_destroy(&anim)
		delete(p.animations)
	}
	engine.comp_zero(p)
}

@(fixed_update={component=Player})
fixed_update_Player :: proc(dt: f32, p: ^Player) {
    w := engine.ctx_world()

    t := engine.pool_get(&w.transforms, engine.Handle(p.owner))
    if t == nil do return

    speed := p.speed if p.speed > 0 else 100

    if input.key_down_fixed(.W) do t.position[1] += speed * dt
    if input.key_down_fixed(.S) do t.position[1] -= speed * dt
    if input.key_down_fixed(.A) do t.position[0] -= speed * dt
    if input.key_down_fixed(.D) do t.position[0] += speed * dt

    // animations
    if input.key_pressed_fixed(._1) do tween.tween_run("Anim0", tween.TweenContext{ subject = p.owner })
    if input.key_pressed_fixed(._2) do tween.tween_run("Anim1", tween.TweenContext{ subject = p.owner })
    if input.key_pressed_fixed(._3) do tween.tween_run("Anim2", tween.TweenContext{ subject = p.owner })
    if input.key_pressed_fixed(._4) do tween.tween_run("Anim3", tween.TweenContext{ subject = p.owner })
    if input.key_pressed_fixed(._5) do tween.tween_run("Anim4", tween.TweenContext{ subject = p.owner })
    if input.key_pressed_fixed(._6) do tween.tween_run("Anim5", tween.TweenContext{ subject = p.owner })
    if input.key_pressed_fixed(._7) do tween.tween_run("Anim6", tween.TweenContext{ subject = p.owner })
    if input.key_pressed_fixed(._8) do tween.tween_run("Anim7", tween.TweenContext{ subject = p.owner })
    if input.key_pressed_fixed(._9) do tween.tween_run("Anim8", tween.TweenContext{ subject = p.owner })
    if input.key_pressed_fixed(._0) do tween.tween_run("Anim9", tween.TweenContext{ subject = p.owner })

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
