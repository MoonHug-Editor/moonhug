package tween_sample_tests

// The tween demo scene (assets/tween_demo.scene) is generated
// JSON. This is its guard: the scene loads, every cube carries its script
// with its own data, and awake starts tweens that move the cubes, including
// the authored tree's node that names another cube as its subject.

import sample "moonhug:packages/tween_sample"
import "moonhug:packages/engine"
import tween "moonhug:packages/tween"
import common "moonhug:tests/common"
import "core:testing"

@(private = "file")
_named :: proc(name: string) -> engine.Transform_Handle {
	it := engine.pool_iterator(&engine.ctx_world().transforms)
	for tr, h in engine.pool_next(&it) do if tr.name == name do return engine.Transform_Handle(h)
	return {}
}

@(private = "file")
_position :: proc(tH: engine.Transform_Handle) -> [3]f32 {
	return engine.pool_get(&engine.ctx_world().transforms, engine.Handle(tH)).position
}

@(test)
test_tween_demo_scene_loads_and_moves :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	tween.tween_init()
	defer tween.stop_all()

	s := engine.scene_load("plugins/tween/samples/tween_sample/assets/tween_demo.scene")
	testing.expect(t, s != nil, "the demo scene parses and loads")
	if s == nil do return
	tc.scene = s
	w := engine.ctx_world()

	// The red row: the same script on six cubes, only the ease differs.
	eases := [?]struct{name: string, ease: tween.Ease}{
		{"Hop Linear", .Linear}, {"Hop Quad In Out", .Quad_In_Out}, {"Hop Back In Out", .Back_In_Out},
		{"Hop Bounce Out", .Bounce_Out}, {"Hop Elastic Out", .Elastic_Out}, {"Hop Expo In Out", .Expo_In_Out},
	}
	for e in eases {
		_, hop := sample.get_comp(_named(e.name), sample.DemoTween)
		testing.expectf(t, hop != nil, "%s carries the DemoTween script", e.name)
		if hop == nil do continue
		testing.expect_value(t, hop.part, sample.Demo_Tween_Part.Position_Offset)
		testing.expect_value(t, hop.settings.ease, e.ease)
		testing.expect_value(t, hop.settings.cycle_mode, tween.Cycle_Mode.Yoyo)
	}

	// The same script with other data on four more cubes.
	others := [?]struct{name: string, part: sample.Demo_Tween_Part}{
		{"Spin", .Euler_Angles}, {"Pulse", .Scale}, {"Patrol", .World_Offset}, {"Hop Unscaled", .Position_Offset},
	}
	for o in others {
		_, d := sample.get_comp(_named(o.name), sample.DemoTween)
		testing.expectf(t, d != nil, "%s carries the DemoTween script", o.name)
		if d != nil do testing.expect_value(t, d.part, o.part)
	}
	_, unscaled := sample.get_comp(_named("Hop Unscaled"), sample.DemoTween)
	testing.expect(t, unscaled != nil && unscaled.clock == .Unscaled, "the clock is saved by name and read back")
	_, patrol := sample.get_comp(_named("Patrol"), sample.DemoTween)
	testing.expect(t, patrol != nil && patrol.speed == 2)

	// One shake script, twice: a punch of the scale and a shake of the position.
	_, punch := sample.get_comp(_named("Punch"), sample.DemoTweenShake)
	_, shake := sample.get_comp(_named("Shake"), sample.DemoTweenShake)
	testing.expect(t, punch != nil && punch.punch && punch.part == .Scale)
	testing.expect(t, shake != nil && !shake.punch && shake.part == .Position)

	// A script of its own where data cannot say it.
	_, orbit := sample.get_comp(_named("Orbit"), sample.DemoTweenOrbit)
	_, sequence := sample.get_comp(_named("Sequence"), sample.DemoTweenSequence)
	_, tree := sample.get_comp(_named("Tree"), sample.DemoTweenTree)
	testing.expect(t, punch != nil && shake != nil && orbit != nil && sequence != nil && tree != nil, "every example cube carries its script")
	if punch == nil || shake == nil || orbit == nil || sequence == nil || tree == nil do return
	testing.expect(t, tree.tree.value != nil, "the authored tree is in the scene")
	other := _named("Tree Other")
	testing.expect(t, other != {}, "the cube the tree's own subject names is in the scene")

	hop_cube, tree_cube := _named("Hop Linear"), _named("Tree")
	hop_before, tree_before, other_before := _position(hop_cube), _position(tree_cube), _position(other)

	// Play start: every script awakes.
	it := engine.pool_iterator(sample.demo_tweens(w))
	for d, _ in engine.pool_next(&it) do sample.comp_awake_DemoTween(d)
	sample.comp_awake_DemoTweenShake(punch)
	sample.comp_awake_DemoTweenShake(shake)
	sample.comp_awake_DemoTweenOrbit(orbit)
	sample.comp_awake_DemoTweenSequence(sequence)
	sample.comp_awake_DemoTweenTree(tree)
	testing.expect(t, tween.run_count() >= 15, "every script started its tween")

	// 0.5 s: the hop is half way up.
	for _ in 0 ..< 32 do tween.tick_all(1.0 / 64.0)
	testing.expect(t, abs(_position(hop_cube).y - (hop_before.y + 1)) < 0.05, "the Linear cube is half way up its hop")
	// A script's run is bound to its cube: the cube going ends it. Nothing
	// else starts or ends a run on this tick.
	before := tween.run_count()
	engine.transform_destroy(_named("Orbit"))
	tween.tick_all(1.0 / 64.0)
	testing.expect_value(t, tween.run_count(), before - 1)

	// 1.5 s: the tree has moved its own cube and reached the node that names the other one.
	for _ in 0 ..< 63 do tween.tick_all(1.0 / 64.0)
	testing.expect(t, _position(tree_cube).y > tree_before.y + 1.5, "the tree moves the cube its script is on")
	testing.expect(t, _position(other).y > other_before.y + 0.5, "the node with its own subject moves that cube")

}
