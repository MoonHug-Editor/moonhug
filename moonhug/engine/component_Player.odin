package engine

@(component={max=10})
@(typ_guid={guid = "d3f1a2b4-7e8c-4d5f-9a0b-1c2e3f4a5b6c"})
Player :: struct {
    using base: CompData `inspect:"-"`,
    speed:  f32,
    colors: [dynamic][4]f32,
    animations: [dynamic]TweenUnion,
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
		for &anim in p.animations do tween_free(&anim)
		delete(p.animations)
	}
	comp_zero(p)
}
