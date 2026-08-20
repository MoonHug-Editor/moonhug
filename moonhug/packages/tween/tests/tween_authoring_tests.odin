package tween_tests

// The structural authoring API the editor's node picker and add/delete
// buttons call: build a node from a registered typeid, attach and remove
// children, and run the result.

import "moonhug:engine"
import tween "moonhug:packages/tween"
import common "moonhug:tests/common"
import "core:testing"

@(test)
test_authored_make_and_child_ops :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	tween.tween_init()

	// Every registered type is offerable, and composites are distinguishable
	// — that pair is exactly what the editor's picker shows.
	types := tween.registered_node_types()
	testing.expect(t, len(types) > 0, "stock nodes should be registered")
	saw_composite, saw_leaf := false, false
	for ty in types {
		if tween.node_type_has_children(ty) do saw_composite = true
		else do saw_leaf = true
	}
	testing.expect(t, saw_composite && saw_leaf, "picker needs both composites and leaves")

	// Build a tree the way the editor does: by typeid, then attach children.
	seq, sok := tween.authored_make(typeid_of(tween.Sequence))
	testing.expect(t, sok, "authored_make on a registered type")
	defer tween.authored_destroy(&seq)

	move, mok := tween.authored_make(typeid_of(tween.TweenMoveToLocal))
	testing.expect(t, mok)
	testing.expect(t, tween.authored_add_child(seq.value, move), "add child to a composite")

	scale, cok := tween.authored_make(typeid_of(tween.TweenScaleToLocal))
	testing.expect(t, cok)
	testing.expect(t, tween.authored_add_child(seq.value, scale))

	kids, kok := tween.authored_children(seq.value)
	testing.expect(t, kok && len(kids) == 2, "both children attached")

	// A leaf rejects children (the editor hides the button, the API guards).
	leaf, lok := tween.authored_make(typeid_of(tween.TweenMoveToLocal))
	testing.expect(t, lok)
	defer tween.authored_destroy(&leaf)
	orphan, ook := tween.authored_make(typeid_of(tween.TweenMoveToLocal))
	testing.expect(t, ook)
	defer tween.authored_destroy(&orphan)
	testing.expect(t, !tween.authored_add_child(leaf.value, orphan), "leaves take no children")

	// Unregistered types are not offerable.
	_, bad := tween.authored_make(typeid_of(engine.Transform))
	testing.expect(t, !bad, "unregistered types cannot be authored")

	// Remove by ordinal, then confirm the survivor still runs.
	testing.expect(t, tween.authored_remove_child(seq.value, 0), "remove by ordinal")
	kids2, _ := tween.authored_children(seq.value)
	testing.expect_value(t, len(kids2), 1)

	owner := engine.transform_new("Subject")
	testing.expect(t, tween.tween_run(&seq, tween.TweenContext{subject = owner}),
		"an editor-built tree runs")
	for _ in 0 ..< 30 do tween.tween_tick_running(1.0 / 60.0, {})
}

@(test)
test_authored_retype :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	tween.tween_init()

	// Composite -> composite keeps the children.
	seq, _ := tween.authored_make(typeid_of(tween.Sequence))
	defer tween.authored_destroy(&seq)
	child, _ := tween.authored_make(typeid_of(tween.TweenMoveToLocal))
	testing.expect(t, tween.authored_add_child(seq.value, child))

	testing.expect(t, tween.authored_retype(seq.value, typeid_of(tween.Parallel)))
	tid, tok := tween.authored_typeid(seq.value)
	testing.expect(t, tok && tid == typeid_of(tween.Parallel), "type tag switched")
	kids, kok := tween.authored_children(seq.value)
	testing.expect(t, kok && len(kids) == 1, "composite -> composite keeps children")

	// Composite -> leaf drops them (a leaf has nowhere to put children).
	testing.expect(t, tween.authored_retype(seq.value, typeid_of(tween.TweenScaleToLocal)))
	tid2, _ := tween.authored_typeid(seq.value)
	testing.expect(t, tid2 == typeid_of(tween.TweenScaleToLocal))
	_, still_has := tween.authored_children(seq.value)
	testing.expect(t, !still_has, "composite -> leaf drops children")

	// The retyped node still instantiates and runs.
	owner := engine.transform_new("Subject")
	testing.expect(t, tween.tween_run(&seq, tween.TweenContext{subject = owner}),
		"a retyped node runs")
	for _ in 0 ..< 10 do tween.tween_tick_running(1.0 / 60.0, {})

	// Unregistered targets are refused, leaving the node intact.
	testing.expect(t, !tween.authored_retype(seq.value, typeid_of(engine.Transform)))
	tid3, _ := tween.authored_typeid(seq.value)
	testing.expect(t, tid3 == typeid_of(tween.TweenScaleToLocal), "failed retype changes nothing")
}
