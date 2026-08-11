package app_tests

// The 1-N tween chain end to end: a code-built Player ext record with
// animations -> setup_player_animations (via app.scene_loaded) ->
// tween_run("Anim0") -> tick moves the subject. The temp free_all + scribble
// between register and run guards the regression where tween_lib stored
// TEMP-allocated keys (tprintf) — the app's per-frame free_all dangled them
// and number keys stopped running.

import app ".."
import "moonhug:engine"
import common "moonhug:tests/common"
import "core:fmt"
import "core:testing"

@(test)
test_player_tween_chain :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	engine.tween_init()

	// Code-built Player with one position tween — no scene file, no assets.
	owner := engine.transform_new("Player")
	_, p_ptr := engine.transform_add_comp(owner, .Player)
	testing.expect(t, p_ptr != nil, "Player component should be addable")
	if p_ptr == nil do return
	p := cast(^app.Player)p_ptr
	p.enabled = true
	if p.animations == nil do p.animations = make([dynamic]engine.TweenUnion)
	append(&p.animations, engine.TweenMoveToLocal{position = {5, 0, 0}, duration = 0.5})

	// scene_loaded registers AnimN keys (via tprintf — temp allocator).
	app.scene_loaded()
	testing.expect(t, engine.tween_lib_count() > 0, "tween lib should have AnimN entries")

	// The app loop frees the temp allocator every frame and later frames
	// reuse the bytes — simulate both so temp-allocated map keys would dangle.
	free_all(context.temp_allocator)
	for i in 0 ..< 64 {
		_ = fmt.tprintf("scribble over freed temp memory %d", i)
	}

	// Running Anim0 (a position tween) still resolves and moves the player.
	w := engine.ctx_world()
	before := engine.pool_get(&w.transforms, engine.Handle(owner)).position
	ok := engine.tween_run("Anim0", engine.TweenContext{subject = engine.Transform_Handle(p.owner)})
	testing.expect(t, ok, "tween_run(Anim0) should start after a temp free_all")
	for _ in 0 ..< 60 {
		engine.tween_tick_running(1.0 / 60.0, {})
	}
	after := engine.pool_get(&w.transforms, engine.Handle(owner)).position
	testing.expect(t, before != after, "Anim0 should move the player")
}
