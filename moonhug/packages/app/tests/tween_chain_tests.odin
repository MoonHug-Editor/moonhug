package app_tests

// The 1-N tween chain end to end: demo scene load -> Player ext record with
// animations -> setup_player_animations -> tween_run("Anim0") -> tick moves
// the subject. The temp free_all + scribble between register and run guards
// the regression where tween_lib stored TEMP-allocated keys (tprintf) — the
// app's per-frame free_all dangled them and number keys stopped running.

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

	engine.asset_db_init("moonhug/assets")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()
	engine.tween_init()

	s := engine.scene_load_single_path("moonhug/assets/demo_prefabs/demo_prefabs.scene")
	testing.expect(t, s != nil, "demo scene should load")
	if s == nil do return

	// The Player ext component exists and carries its animations.
	w := engine.ctx_world()
	pool := app.players(w)
	testing.expect(t, pool != nil, "players pool should exist")
	if pool == nil do return
	found: ^app.Player
	for i in 0 ..< len(pool.slots) {
		if pool.slots[i].alive {
			found = &pool.slots[i].data
			break
		}
	}
	testing.expect(t, found != nil, "a Player should be loaded")
	if found == nil do return
	testing.expect(t, len(found.animations) > 0, "Player.animations should have entries")
	if len(found.animations) == 0 do return

	// scene_loaded registers AnimN keys (via tprintf — temp allocator).
	app.scene_loaded()
	testing.expect(t, len(engine.tween_lib) > 0, "tween_lib should have AnimN entries")

	// The app loop frees the temp allocator every frame and later frames
	// reuse the bytes — simulate both so temp-allocated map keys would dangle.
	free_all(context.temp_allocator)
	for i in 0 ..< 64 {
		_ = fmt.tprintf("scribble over freed temp memory %d", i)
	}

	// Running Anim0 (a position tween) still resolves and moves the player.
	before := engine.pool_get(&w.transforms, engine.Handle(found.owner)).position
	ok := engine.tween_run("Anim0", engine.TweenContext{subject = found.owner})
	testing.expect(t, ok, "tween_run(Anim0) should start after a temp free_all")
	for _ in 0 ..< 60 {
		engine.tween_tick_running(1.0 / 60.0, {})
	}
	after := engine.pool_get(&w.transforms, engine.Handle(found.owner)).position
	testing.expect(t, before != after, "Anim0 should move the player")
}
