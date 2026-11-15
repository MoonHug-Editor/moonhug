package tween_sample_tests

// The tween sample's scripts on cubes made here: awake starts each one's
// tween, the tweens move their cubes, a script's run ends with its cube, and
// a tree node that names another cube moves that cube.

import sample "moonhug:packages/tween_sample"
import "moonhug:packages/engine"
import tween "moonhug:packages/tween"
import common "moonhug:tests/common"
import "core:testing"

@(private = "file")
_cube :: proc(name: string, position: [3]f32) -> engine.Transform_Handle {
	tH := engine.transform_new(name)
	engine.pool_get(&engine.ctx_world().transforms, engine.Handle(tH)).position = position
	return tH
}

@(private = "file")
_position :: proc(tH: engine.Transform_Handle) -> [3]f32 {
	return engine.pool_get(&engine.ctx_world().transforms, engine.Handle(tH)).position
}

@(private = "file")
_add :: proc(t: ^testing.T, tH: engine.Transform_Handle, key: engine.TypeKey, $T: typeid) -> ^T {
	_, raw := engine.transform_add_comp(tH, key)
	testing.expectf(t, raw != nil, "%v can be added", key)
	return cast(^T)raw
}

@(private = "file")
_tick :: proc(frames: int) {
	for _ in 0 ..< frames do tween.tick_all(1.0 / 64.0)
}

@(test)
test_tween_sample_scripts_start_and_move :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	tween.tween_init()
	defer tween.stop_all()

	// One transform tween: up by 2 and back, linear, a second each way.
	hop_cube := _cube("Hop", {0, 0, 0})
	hop := _add(t, hop_cube, .DemoTween, sample.DemoTween)
	punch := _add(t, _cube("Punch", {2, 0, 0}), .DemoTweenShake, sample.DemoTweenShake)
	orbit_cube := _cube("Orbit", {4, 0, 0})
	orbit := _add(t, orbit_cube, .DemoTweenOrbit, sample.DemoTweenOrbit)
	sequence_cube := _cube("Sequence", {6, 0, 0})
	sequence := _add(t, sequence_cube, .DemoTweenSequence, sample.DemoTweenSequence)
	tree_cube := _cube("Tree", {8, 0, 0})
	tree := _add(t, tree_cube, .DemoTweenTree, sample.DemoTweenTree)
	other := _cube("Tree Other", {10, 0, 0})
	if hop == nil || punch == nil || orbit == nil || sequence == nil || tree == nil do return
	hop.settings.ease = .Linear
	punch.punch = true
	punch.part = .Scale

	// The tree moves its own cube, and a node naming the other cube moves that one.
	own := tween.TweenMoveToLocal{position = {8, 2, 0}, duration = 1}
	pinned := tween.TweenMoveToLocal{position = {10, 1, 0}, duration = 1}
	pinned.subject = engine.Ref{pptr = engine.PPtr{local_id = engine.pool_get(&tc.world.transforms, engine.Handle(other)).local_id}}
	tree.tree = tween.authored(tween.Parallel{}, {tween.authored(own), tween.authored(pinned)})

	// Play start: every script awakes and starts its tween.
	sample.comp_awake_DemoTween(hop)
	sample.comp_awake_DemoTweenShake(punch)
	sample.comp_awake_DemoTweenOrbit(orbit)
	sample.comp_awake_DemoTweenSequence(sequence)
	sample.comp_awake_DemoTweenTree(tree)
	testing.expect(t, tween.run_count() >= 5, "every script started its tween")

	// 0.5 s: the hop is half way up, the orbit has left its centre, the
	// sequence has gone up.
	_tick(32)
	testing.expect(t, abs(_position(hop_cube).y - 1) < 0.05, "the hop is half way up")
	testing.expect(t, _position(orbit_cube) != {4, 0, 0}, "the orbit moves its cube")
	testing.expect(t, _position(sequence_cube).y > 1, "the sequence's first step lifts its cube")

	// A script's run is bound to its cube: the cube going ends it. Nothing
	// else starts or ends a run on this tick.
	before := tween.run_count()
	engine.transform_destroy(orbit_cube)
	_tick(1)
	testing.expect_value(t, tween.run_count(), before - 1)

	// 0.75 s: the tree has moved both cubes most of the way.
	_tick(15)
	testing.expect(t, _position(tree_cube).y > 1, "the tree moves the cube its script is on")
	testing.expect(t, _position(other).y > 0.5, "the node with its own subject moves that cube")
}
