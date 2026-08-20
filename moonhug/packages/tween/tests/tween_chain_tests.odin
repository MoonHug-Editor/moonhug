package tween_tests

// The tween chain end to end through the package's own carrier: a code-built
// TweenPlayer with authored animations -> tween_register(tprintf key) ->
// tween_run("Anim0") -> tick moves the subject. The temp free_all + scribble
// between register and run guards the regression where tween_lib stored
// TEMP-allocated keys (tprintf) — a per-frame free_all dangled them and
// number keys stopped running.

import "moonhug:engine"
import tween "moonhug:packages/tween"
import common "moonhug:tests/common"
import "core:fmt"
import "core:testing"

@(test)
test_tween_player_chain :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	tween.tween_init()

	owner := engine.transform_new("TweenPlayer")
	_, p_ptr := engine.transform_add_comp(owner, .TweenPlayer)
	testing.expect(t, p_ptr != nil, "TweenPlayer component should be addable")
	if p_ptr == nil do return
	p := cast(^tween.TweenPlayer)p_ptr
	p.enabled = true
	if p.animations == nil do p.animations = make([dynamic]tween.Authored)
	append(&p.animations, tween.authored(tween.TweenMoveToLocal{position = {5, 0, 0}, duration = 0.5}))

	// Register under a TEMP-allocated key, the way game code builds AnimN keys.
	for &anim, i in p.animations {
		tween.tween_register(fmt.tprintf("Anim%d", i), &anim)
	}
	testing.expect(t, tween.tween_lib_count() > 0, "tween lib should have AnimN entries")

	// A frame loop frees the temp allocator every frame and later frames
	// reuse the bytes — simulate both so temp-allocated map keys would dangle.
	free_all(context.temp_allocator)
	for i in 0 ..< 64 {
		_ = fmt.tprintf("scribble over freed temp memory %d", i)
	}

	w := engine.ctx_world()
	before := engine.pool_get(&w.transforms, engine.Handle(owner)).position
	ok := tween.tween_run("Anim0", tween.TweenContext{subject = engine.Transform_Handle(p.owner)})
	testing.expect(t, ok, "tween_run(Anim0) should start after a temp free_all")
	for _ in 0 ..< 60 {
		tween.tween_tick_running(1.0 / 60.0, {})
	}
	after := engine.pool_get(&w.transforms, engine.Handle(owner)).position
	testing.expect(t, before != after, "Anim0 should move the subject")
}
