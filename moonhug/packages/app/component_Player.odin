package app

// The demo's player pawn (WASD movement in tick_player, number-key tween
// animations wired by setup_player_animations). App-level: scene records live
// in ext_components keyed by the type guid below — never change it.

import "moonhug:engine"

@(component={max=10})
@(typ_guid={guid = "d3f1a2b4-7e8c-4d5f-9a0b-1c2e3f4a5b6c"})
Player :: struct {
    using base: engine.CompData `inspect:"-"`,
    speed:  f32,
    colors: [dynamic][4]f32,
    animations: [dynamic]engine.TweenUnion,
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

on_destroy_Player :: proc(p: ^Player) {
	cleanup_Player(p)
}

cleanup_Player :: proc(p: ^Player) {
	if p.colors != nil do delete(p.colors)
	if p.animations != nil {
		for &anim in p.animations do engine.tween_free(&anim)
		delete(p.animations)
	}
	engine.comp_zero(p)
}
