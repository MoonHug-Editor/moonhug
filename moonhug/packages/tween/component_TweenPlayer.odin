package tween

// The package's own TweenUnion carrier: a component holding authored tweens,
// shaped like Unity's legacy Animation component (a list on the object).
// Also what the package's tests exercise — they never depend on a runnable
// package's components. Scene records live in ext_components keyed by the
// type guid below — never change it.

import engine "moonhug:engine"

@(component={max=64})
@(typ_guid={guid = "a66f5292-813a-493f-91c4-05eb5e4e4d97"})
TweenPlayer :: struct {
    using base: engine.CompData `inspect:"-"`,
    animations: [dynamic]Authored,
}

on_destroy_TweenPlayer :: proc(p: ^TweenPlayer) {
	cleanup_TweenPlayer(p)
}

cleanup_TweenPlayer :: proc(p: ^TweenPlayer) {
	if p.animations != nil {
		for &anim in p.animations do authored_destroy(&anim)
		delete(p.animations)
	}
	engine.comp_zero(p)
}
