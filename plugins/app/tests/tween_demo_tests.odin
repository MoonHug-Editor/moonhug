package app_tests

// The tween demo scene (assets/demo_tweens/demo_tweens.scene) is generated
// JSON. This is its guard: the scene loads, the demo component's references
// and settings survive, and awake starts tweens that move the cubes,
// including the authored tree's node that names its own subject.

import app "moonhug:packages/app"
import "moonhug:packages/engine"
import tween "moonhug:packages/tween"
import common "moonhug:tests/common"
import "core:testing"

@(test)
test_tween_demo_scene_loads_and_moves :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	tween.tween_init()
	defer tween.stop_all()

	s := engine.scene_load("plugins/app/assets/demo_tweens/demo_tweens.scene")
	testing.expect(t, s != nil, "the demo scene parses and loads")
	if s == nil do return
	tc.scene = s

	demo: ^app.TweenDemo
	it := engine.pool_iterator(app.tween_demos(engine.ctx_world()))
	for d, _ in engine.pool_next(&it) do demo = d
	testing.expect(t, demo != nil, "the scene carries the TweenDemo component")
	if demo == nil do return

	testing.expect_value(t, len(demo.ease_cubes), len(app.TWEEN_DEMO_EASES))
	testing.expect_value(t, demo.hop.cycle_mode, tween.Cycle_Mode.Yoyo)
	testing.expect_value(t, demo.spin.cycle_mode, tween.Cycle_Mode.Incremental)
	testing.expect(t, demo.tree.value != nil, "the authored tree is in the scene")

	// Every cube the demo names is a live object.
	w := engine.ctx_world()
	refs := [?]engine.Ref_Local{demo.spin_cube, demo.pulse_cube, demo.punch_cube, demo.shake_cube, demo.sequence_cube, demo.orbit_cube, demo.speed_cube, demo.unscaled_cube, demo.tree_actor}
	for r in refs do testing.expect(t, engine.pool_valid(&w.transforms, r.handle), "a cube reference is bound")
	for r in demo.ease_cubes do testing.expect(t, engine.pool_valid(&w.transforms, r.handle), "an ease cube reference is bound")

	position :: proc(r: engine.Ref_Local) -> [3]f32 {
		return engine.pool_get(&engine.ctx_world().transforms, r.handle).position
	}
	hop_before := position(demo.ease_cubes[0])
	tree_other: engine.Transform_Handle
	oit := engine.pool_iterator(&w.transforms)
	for tr, h in engine.pool_next(&oit) do if tr.name == "Tree Other" do tree_other = engine.Transform_Handle(h)
	testing.expect(t, tree_other != {}, "the cube the tree's own subject names is in the scene")
	other_before := engine.pool_get(&w.transforms, engine.Handle(tree_other)).position

	app.comp_awake_TweenDemo(demo)
	testing.expect(t, tween.run_count() >= 12, "awake starts every example")

	// 1.5 s: the hop is on its way back, the tree has reached its pinned node.
	for _ in 0 ..< 96 do tween.tick_all(1.0 / 64.0)
	testing.expect(t, position(demo.ease_cubes[0]).y > hop_before.y + 0.5, "the Linear cube hops")
	testing.expect(t, engine.pool_get(&w.transforms, engine.Handle(tree_other)).position.y > other_before.y + 0.5, "the node with its own subject moves that cube")
}
