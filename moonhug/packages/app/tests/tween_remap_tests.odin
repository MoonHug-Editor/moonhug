package app_tests

// Tween subject Refs must remap on subtree copy/paste (engine machinery,
// exercised through Player — the demo's TweenUnion carrier, which is why the
// test ships with the app package).

import app ".."
import "moonhug:engine"
import common "moonhug:tests/common"
import "core:testing"

@(test)
test_instantiate_remaps_tween_subject_ref :: proc(t: ^testing.T) {
	tc_mem := new(common.TestCtx)
	defer free(tc_mem)
	common.setup(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer common.teardown(tc_mem)

	parentH := engine.transform_new("Parent")
	target1H := engine.transform_new("Target1", parentH)
	target2H := engine.transform_new("Target2", parentH)

	t1 := engine.pool_get(&tc_mem.world.transforms, engine.Handle(target1H))
	t2 := engine.pool_get(&tc_mem.world.transforms, engine.Handle(target2H))
	if t1 == nil || t2 == nil do return
	t1_lid := t1.local_id
	t2_lid := t2.local_id

	_, player := engine.transform_get_or_add_comp(parentH, app.Player)
	if player == nil do return

	move := engine.TweenMoveToLocal{ position = {10, 20, 30}, duration = 1.0 }
	move.subject = engine.Ref{ pptr = engine.PPtr{local_id = t1_lid}, handle = engine.Handle(target1H) }

	scale := engine.TweenScaleToLocal{ scale = {2, 2, 2}, duration = 0.5 }
	scale.subject = engine.Ref{ pptr = engine.PPtr{local_id = t2_lid}, handle = engine.Handle(target2H) }

	seq := engine.Sequence{}
	append(&seq.children, engine.TweenUnion(move))
	append(&seq.children, engine.TweenUnion(scale))
	append(&player.animations, engine.TweenUnion(seq))
	seq.children = {}

	data := engine.scene_copy_subtree(parentH)
	defer delete(data)
	if len(data) == 0 do return

	rootH := engine.Transform_Handle(tc_mem.scene.root.handle)
	inst := engine.scene_paste_subtree(data, rootH)
	testing.expect(t, inst != {}, "paste should succeed")
	if inst == {} do return

	inst_t := engine.pool_get(&tc_mem.world.transforms, engine.Handle(inst))
	if inst_t == nil do return
	testing.expect_value(t, len(inst_t.children), 2)
	if len(inst_t.children) < 2 do return

	inst_t1 := engine.pool_get(&tc_mem.world.transforms, inst_t.children[0].handle)
	inst_t2 := engine.pool_get(&tc_mem.world.transforms, inst_t.children[1].handle)
	if inst_t1 == nil || inst_t2 == nil do return
	inst_t1_lid := inst_t1.local_id
	inst_t2_lid := inst_t2.local_id

	_, inst_player := engine.transform_get_comp(inst, app.Player)
	if inst_player == nil do return
	testing.expect_value(t, len(inst_player.animations), 1)
	if len(inst_player.animations) < 1 do return

	inst_seq := &inst_player.animations[0].(engine.Sequence)
	testing.expect_value(t, len(inst_seq.children), 2)
	if len(inst_seq.children) < 2 do return

	child0 := engine.tween_base(&inst_seq.children[0])
	child1 := engine.tween_base(&inst_seq.children[1])

	testing.expect(t, child0.subject.pptr.local_id != t1_lid,
		"child0 subject should differ from original")
	testing.expect(t, child0.subject.pptr.local_id == inst_t1_lid,
		"child0 subject should be remapped to instantiated Target1")

	testing.expect(t, child1.subject.pptr.local_id != t2_lid,
		"child1 subject should differ from original")
	testing.expect(t, child1.subject.pptr.local_id == inst_t2_lid,
		"child1 subject should be remapped to instantiated Target2")
}
