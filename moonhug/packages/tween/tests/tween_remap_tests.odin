package tween_tests

// Tween subject Refs inside authored blobs must remap on subtree copy/paste.
// The typed remap walk cannot see into json.Value — the registered ref-remap
// hook handles it, and this test pins that path.

import "core:encoding/json"
import "moonhug:engine"
import tween "moonhug:packages/tween"
import common "moonhug:tests/common"
import "core:testing"

@(private)
_subject_lid :: proc(node: json.Value) -> i64 {
	obj := node.(json.Object) or_else nil
	if obj == nil do return 0
	base, bok := obj["base"].(json.Object)
	if !bok do return 0
	subj, sok := base["subject"].(json.Object)
	if !sok do return 0
	pptr, pok := subj["pptr"].(json.Object)
	if !pok do return 0
	lid, lok := pptr["local_id"].(json.Integer)
	if !lok do return 0
	return i64(lid)
}

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

	_, player := engine.transform_get_or_add_comp(parentH, tween.TweenPlayer)
	if player == nil do return

	move := tween.TweenMoveToLocal{ position = {10, 20, 30}, duration = 1.0 }
	move.subject = engine.Ref{ pptr = engine.PPtr{local_id = t1_lid}, handle = engine.Handle(target1H) }

	scale := tween.TweenScaleToLocal{ scale = {2, 2, 2}, duration = 0.5 }
	scale.subject = engine.Ref{ pptr = engine.PPtr{local_id = t2_lid}, handle = engine.Handle(target2H) }

	append(&player.animations, tween.authored(tween.Sequence{}, {
		tween.authored(move),
		tween.authored(scale),
	}))

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

	_, inst_player := engine.transform_get_comp(inst, tween.TweenPlayer)
	if inst_player == nil do return
	testing.expect_value(t, len(inst_player.animations), 1)
	if len(inst_player.animations) < 1 do return

	kids, kok := tween.authored_children(inst_player.animations[0].value)
	testing.expect(t, kok, "pasted sequence should keep its children")
	if !kok do return
	testing.expect_value(t, len(kids), 2)
	if len(kids) < 2 do return

	child0_lid := _subject_lid(kids[0])
	child1_lid := _subject_lid(kids[1])

	testing.expect(t, child0_lid != i64(t1_lid),
		"child0 subject should differ from original")
	testing.expect(t, child0_lid == i64(inst_t1_lid),
		"child0 subject should be remapped to instantiated Target1")

	testing.expect(t, child1_lid != i64(t2_lid),
		"child1 subject should differ from original")
	testing.expect(t, child1_lid == i64(inst_t2_lid),
		"child1 subject should be remapped to instantiated Target2")
}
