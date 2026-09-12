package animation_tests

// TimelineAnimator (docs/TimelineAnimator.md): the component's graph skeleton —
// one output per bound target, a layer mixer at each output's root, one mixer
// per layer under it.

import "core:strings"
import "core:testing"
import "moonhug:engine"
import anim "moonhug:packages/animation"
import common "moonhug:tests/common"

// Strings on a component are owned by it: cleanup_TimelineAnimator frees them,
// so a test may not hand it a literal.
@(private = "file")
_ta_target :: proc(key: string, h: engine.Handle) -> anim.Target_Binding {
	return {key = strings.clone(key), target = {handle = h}}
}

@(test)
test_timeline_animator_graph_skeleton :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	root := engine.transform_new("Rig")
	engine.scene_set_root(tc.scene, root)
	body := engine.transform_new("Body", root)
	face := engine.transform_new("Face", root)

	b_owned, _ := engine.transform_add_comp(body, .Animation)
	f_owned, _ := engine.transform_add_comp(face, .Animation)

	_, raw := engine.transform_add_comp(root, .TimelineAnimator)
	ta := cast(^anim.TimelineAnimator)raw
	ta.enabled = true
	ta.targets = make([dynamic]anim.Target_Binding)
	append(&ta.targets, _ta_target("Body", b_owned.handle))
	append(&ta.targets, _ta_target("Face", f_owned.handle))
	ta.layers = make([dynamic]anim.Animator_Layer)
	append(&ta.layers, anim.Animator_Layer{name = strings.clone("Base")})
	append(&ta.layers, anim.Animator_Layer{name = strings.clone("Upper"), weight = 0.5})

	anim.timeline_animator_tick(0)

	testing.expect_value(t, len(ta.graph.outputs), 2)
	testing.expect_value(t, anim.timeline_animator_output_for_key(ta, "Body"), 0)
	testing.expect_value(t, anim.timeline_animator_output_for_key(ta, "Face"), 1)
	testing.expect_value(t, anim.timeline_animator_output_for_key(ta, "Missing"), -1)

	for oi in 0 ..< 2 {
		o := anim.graph_output(&ta.graph, oi)
		testing.expect(t, o != nil, "every bound target has an output")
		n := anim.playable_node(&ta.graph, o.root)
		testing.expect(t, n != nil, "the output root is a live node")
		// One mixer per layer, in layer order — input order IS override order.
		testing.expect_value(t, len(n.inputs), 2)
		testing.expect_value(t, n.inputs[0].node, anim.timeline_animator_layer_mixer(ta, 0, oi))
		testing.expect_value(t, n.inputs[1].node, anim.timeline_animator_layer_mixer(ta, 1, oi))
		// Layer weight is zero-neutral: unset is full strength, not silent.
		testing.expect(t, abs(n.inputs[0].weight - 1) < 0.001, "unset layer weight reads as 1")
		testing.expect(t, abs(n.inputs[1].weight - 0.5) < 0.001, "an authored layer weight is used")
	}
}

@(test)
test_timeline_animator_skips_unbound_targets :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	root := engine.transform_new("Rig")
	engine.scene_set_root(tc.scene, root)
	body := engine.transform_new("Body", root)
	b_owned, _ := engine.transform_add_comp(body, .Animation)

	_, raw := engine.transform_add_comp(root, .TimelineAnimator)
	ta := cast(^anim.TimelineAnimator)raw
	ta.enabled = true
	ta.targets = make([dynamic]anim.Target_Binding)
	append(&ta.targets, _ta_target("Nothing", {})) // never bound
	append(&ta.targets, _ta_target("Body", b_owned.handle))

	anim.timeline_animator_tick(0)

	// A key with no component behind it produces no output, and the keys that
	// do resolve are unaffected by its position in the list.
	testing.expect_value(t, len(ta.graph.outputs), 1)
	testing.expect_value(t, anim.timeline_animator_output_for_key(ta, "Nothing"), -1)
	testing.expect_value(t, anim.timeline_animator_output_for_key(ta, "Body"), 0)
}

@(test)
test_timeline_animator_idle_leaves_targets_alone :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	root := engine.transform_new("Rig")
	engine.scene_set_root(tc.scene, root)
	body := engine.transform_new("Body", root)
	b_owned, _ := engine.transform_add_comp(body, .Animation)

	_, raw := engine.transform_add_comp(root, .TimelineAnimator)
	ta := cast(^anim.TimelineAnimator)raw
	ta.enabled = true
	ta.targets = make([dynamic]anim.Target_Binding)
	append(&ta.targets, _ta_target("Body", b_owned.handle))
	ta.layers = make([dynamic]anim.Animator_Layer)
	append(&ta.layers, anim.Animator_Layer{name = strings.clone("Base")})

	bt := engine.pool_get(&tc.world.transforms, engine.Handle(body))
	bt.position = {3, 0, 0}

	// No state is attached to any layer mixer, so the graph would evaluate to
	// an empty pose. Applying that would write bind-time defaults over whatever
	// else poses the object, so an idle animator must not apply at all.
	anim.timeline_animator_tick(0)
	anim.timeline_animator_tick(0)

	testing.expect(t, abs(bt.position.x - 3) < 0.001,
		"an animator with no states does not touch its targets")
}
