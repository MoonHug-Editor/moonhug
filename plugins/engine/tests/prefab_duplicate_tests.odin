package engine_tests

// Duplicating and deleting a prefab instance (fixture chain: host.scene holds
// a bullet_Variant instance). A duplicate is an instance too, with the
// prefab's content, and undo brings a deleted instance back once, not with
// its content twice.

import "core:testing"
import "moonhug:packages/engine"
import undo "moonhug:packages/engine/editor/undo"

// Every transform in the world: a count that does not depend on which scene
// prefab content belongs to.
@(private = "file")
_transform_count :: proc(w: ^engine.World) -> int {
	n := 0
	it := engine.pool_iterator(&w.transforms)
	for _ in engine.pool_next(&it) do n += 1
	return n
}

@(test)
test_prefab_instance_duplicate_and_delete_undo :: proc(t: ^testing.T) {
	fx: Fixture_Chain
	defer fixture_chain_destroy(&fx)
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	fx_ok: bool
	fx, fx_ok = fixture_chain_author(t, tc_mem, "moonhug/tests/_fx_prefab_duplicate")
	if !fx_ok do return
	w := &tc_mem.world
	root := engine.pool_get(&w.transforms, tc_mem.scene.root.handle)
	testing.expect(t, root != nil && len(root.children) == 1, "the host holds one instance")
	if root == nil || len(root.children) != 1 do return
	inst := engine.Transform_Handle(root.children[0].handle)
	it := engine.pool_get(&w.transforms, engine.Handle(inst))
	if it == nil do return
	content, comps := len(it.children), len(it.components)
	testing.expect(t, content > 0, "the instance has the prefab's content")
	before := _transform_count(w)

	// A duplicate is an instance too: the prefab's content and the host's
	// components, not an empty object.
	dup := engine.scene_duplicate_subtree(inst)
	dt := engine.pool_get(&w.transforms, engine.Handle(dup))
	testing.expect(t, dt != nil, "duplicated")
	if dt == nil do return
	testing.expect_value(t, len(dt.children), content)
	testing.expect_value(t, len(dt.components), comps)
	testing.expect_value(t, _transform_count(w) - before, _subtree_size(w, inst))
	engine.transform_destroy(dup)
	testing.expect_value(t, _transform_count(w), before)

	// Delete, undo: the instance comes back once. Redo and undo again too.
	pre, ok := undo.record_delete_pre(inst)
	testing.expect(t, ok, "delete captured")
	defer if ok do undo.record_cleanup(&pre)
	engine.transform_destroy(inst)
	undo.record_commit(&pre)
	undo.apply_undo(s)
	testing.expect_value(t, _transform_count(w), before)
	undo.apply_redo(s)
	undo.apply_undo(s)
	testing.expect_value(t, _transform_count(w), before)
}

// `tH` and every transform under it.
@(private = "file")
_subtree_size :: proc(w: ^engine.World, tH: engine.Transform_Handle) -> int {
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return 0
	n := 1
	for c in t.children do n += _subtree_size(w, engine.Transform_Handle(c.handle))
	return n
}

// A prefab's content can hold another prefab's instance (bullet holds a
// c_Variant instance). Undo of deleting that inner instance brings back the
// content it had, once: the restore does not load the inner prefab again on
// top of it.
@(test)
test_prefab_inner_instance_delete_undo :: proc(t: ^testing.T) {
	fx: Fixture_Chain
	defer fixture_chain_destroy(&fx)
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	fx_ok: bool
	fx, fx_ok = fixture_chain_author(t, tc_mem, "moonhug/tests/_fx_prefab_inner_delete")
	if !fx_ok do return
	w := &tc_mem.world
	root := engine.pool_get(&w.transforms, tc_mem.scene.root.handle)
	if root == nil || len(root.children) != 1 do return
	it := engine.pool_get(&w.transforms, root.children[0].handle)
	if it == nil do return
	// The inner instance: the content object that has content of its own.
	inner: engine.Transform_Handle
	for c in it.children {
		if ct := engine.pool_get(&w.transforms, c.handle); ct != nil && len(ct.children) > 0 {
			inner = engine.Transform_Handle(c.handle)
		}
	}
	testing.expect(t, inner != {} && engine.transform_is_nested_owned(inner), "the outer instance's content holds an inner instance")
	if inner == {} do return
	before := _transform_count(w)
	inner_size := _subtree_size(w, inner)

	pre, ok := undo.record_delete_pre(inner)
	testing.expect(t, ok, "delete captured")
	defer if ok do undo.record_cleanup(&pre)
	engine.transform_destroy(inner)
	undo.record_commit(&pre)
	testing.expect_value(t, _transform_count(w), before - inner_size)
	undo.apply_undo(s)
	testing.expect_value(t, _transform_count(w), before)
	undo.apply_redo(s)
	testing.expect_value(t, _transform_count(w), before - inner_size)
	undo.apply_undo(s)
	testing.expect_value(t, _transform_count(w), before)

	// Restored as prefab content, not as objects the host scene adds.
	inner = {}
	if it = engine.pool_get(&w.transforms, root.children[0].handle); it != nil {
		for c in it.children {
			if ct := engine.pool_get(&w.transforms, c.handle); ct != nil && len(ct.children) > 0 {
				inner = engine.Transform_Handle(c.handle)
			}
		}
	}
	testing.expect(t, inner != {} && engine.transform_is_nested_owned(inner), "the inner instance is prefab content again")
	if ip := engine.pool_get(&w.transforms, engine.Handle(inner)); ip != nil && len(ip.children) > 0 {
		testing.expect(t, engine.transform_is_nested_owned(engine.Transform_Handle(ip.children[0].handle)), "its content is prefab content again")
	}
}
