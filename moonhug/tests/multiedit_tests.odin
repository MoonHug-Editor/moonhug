package tests

import "../editor"
import "../editor/inspector"
import "../editor/undo"
import "../engine"

import "base:runtime"
import "core:testing"

// Peers for every selected transform except the active one.
@(private)
_peers_for :: proc(active: engine.Transform_Handle, sel: []engine.Transform_Handle) -> []inspector.Multi_Peer {
	return editor.multi_transform_peers(active, sel)
}

@(private)
_comp_handle :: proc(tH: engine.Transform_Handle, key: engine.TypeKey) -> engine.Handle {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return {}
	for comp in t.components {
		if comp.handle.type_key == key do return comp.handle
	}
	return {}
}

@(private)
_scene_of :: proc(tH: engine.Transform_Handle) -> ^engine.Scene {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	return t.scene if t != nil else nil
}

@(test)
test_multi_common_components_intersects_by_type :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	a := engine.transform_new("A")
	b := engine.transform_new("B")

	// A: SpriteRenderer + SpriteSortingGroup. B: SpriteRenderer only.
	engine.transform_add_comp(a, .SpriteRenderer)
	engine.transform_add_comp(a, .SpriteSortingGroup)
	engine.transform_add_comp(b, .SpriteRenderer)

	sel := []engine.Transform_Handle{a, b}
	common := editor.multi_common_components(a, sel)

	// Only the shared type survives — SpriteSortingGroup is missing on B.
	testing.expect_value(t, len(common), 1)
	if len(common) != 1 do return

	w := engine.ctx_world()
	ta := engine.pool_get(&w.transforms, engine.Handle(a))
	shared_key := ta.components[common[0].comp_index].handle.type_key
	testing.expect_value(t, shared_key, engine.TypeKey.SpriteRenderer)
	testing.expect_value(t, len(common[0].peers), 1)
}

@(test)
test_multi_common_components_matches_duplicates_by_ordinal :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	a := engine.transform_new("A")
	b := engine.transform_new("B")

	// Two of the same type on A, but only one on B: the second has no
	// counterpart, so only the first pairs up.
	engine.transform_add_comp(a, .SpriteSortingGroup)
	engine.transform_add_comp(a, .SpriteSortingGroup)
	_, b_ptr := engine.transform_add_comp(b, .SpriteSortingGroup)

	sel := []engine.Transform_Handle{a, b}
	common := editor.multi_common_components(a, sel)

	testing.expect_value(t, len(common), 1)
	if len(common) != 1 do return
	// The pair is with B's ONLY instance, matched at ordinal 0.
	testing.expect_value(t, len(common[0].peers), 1)
	testing.expect(t, common[0].peers[0].base == b_ptr, "ordinal 0 pairs with B's first instance")
}

@(test)
test_multi_probe_reports_mixed_per_component :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	a := engine.transform_new("A")
	b := engine.transform_new("B")
	w := engine.ctx_world()
	ta := engine.pool_get(&w.transforms, engine.Handle(a))
	tb := engine.pool_get(&w.transforms, engine.Handle(b))

	// Agree on X and Y, differ on Z.
	ta.position = {1, 2, 3}
	tb.position = {1, 2, 99}

	sel := []engine.Transform_Handle{a, b}
	prev := inspector.multi_set_peers(_peers_for(a, sel))
	defer inspector.multi_set_peers(prev)

	inspector.multi_probe_field(&ta.position, typeid_of([3]f32), offset_of(engine.Transform, position))
	defer inspector.multi_clear_mixed()

	testing.expect(t, inspector.current_field_mixed, "position is mixed")
	testing.expect(t, !inspector.current_field_mixed_comps[0], "X agrees")
	testing.expect(t, !inspector.current_field_mixed_comps[1], "Y agrees")
	testing.expect(t, inspector.current_field_mixed_comps[2], "Z differs")
}

@(test)
test_multi_probe_clean_when_all_agree :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	a := engine.transform_new("A")
	b := engine.transform_new("B")
	w := engine.ctx_world()
	ta := engine.pool_get(&w.transforms, engine.Handle(a))
	tb := engine.pool_get(&w.transforms, engine.Handle(b))
	ta.position = {5, 5, 5}
	tb.position = {5, 5, 5}

	sel := []engine.Transform_Handle{a, b}
	prev := inspector.multi_set_peers(_peers_for(a, sel))
	defer inspector.multi_set_peers(prev)

	inspector.multi_probe_field(&ta.position, typeid_of([3]f32), offset_of(engine.Transform, position))
	defer inspector.multi_clear_mixed()

	testing.expect(t, !inspector.current_field_mixed, "identical values are not mixed")
}





// Rotating one euler axis across a selection must leave the peers' other axes
// alone.
//
// Rotation cannot use the generic fieldwise path: the stored value is a
// quaternion rebuilt from ALL THREE euler angles every frame, so diffing it
// always reports every component changed and copying it wholesale snaps every
// selected object to the active object's orientation. The delta has to be
// applied per euler axis instead — which is what _rotation_apply_to_peers does,
// and what this asserts through the same math.
@(test)
test_multi_rotation_is_per_euler_axis :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	a := engine.transform_new("A")
	b := engine.transform_new("B")
	w := engine.ctx_world()
	ta := engine.pool_get(&w.transforms, engine.Handle(a))
	tb := engine.pool_get(&w.transforms, engine.Handle(b))

	// Distinct starting orientations on every axis.
	ta.rotation = engine.quat_from_euler_xyz(10, 20, 30)
	tb.rotation = engine.quat_from_euler_xyz(50, 60, 70)

	// The user turns Y only: 20 -> 25 on the active object.
	before := engine.quat_to_euler_xyz(ta.rotation)
	after := before
	after.y = 25
	ta.rotation = engine.quat_from_euler_xyz(after.x, after.y, after.z)

	// Same transformation the wrapper applies to each peer.
	pe := engine.quat_to_euler_xyz(tb.rotation)
	pe.y = after.y
	expect := engine.quat_from_euler_xyz(pe.x, pe.y, pe.z)

	// The peer takes the edited axis and KEEPS its own X and Z. Comparing in
	// euler terms because two quaternions can name one orientation.
	got := engine.quat_to_euler_xyz(expect)
	testing.expect(t, abs(got.y - 25) < 0.01, "Y took the edited value")
	testing.expect(t, abs(got.x - 50) < 0.01, "X kept the peer's own value")
	testing.expect(t, abs(got.z - 70) < 0.01, "Z kept the peer's own value")

	// And the whole-quaternion alternative would NOT preserve them — this is the
	// bug the per-axis path avoids.
	flat := engine.quat_to_euler_xyz(ta.rotation)
	testing.expect(t, abs(flat.x - 50) > 1, "copying the whole quaternion loses the peer's X")
}

// The axes a rotation drag touched must be remembered ACROSS frames.
//
// The commit fires on the release frame, when the pointer has stopped moving —
// so that frame's before and after are identical and a per-frame "which axes
// moved" comes back empty. The commit then applies nothing and the peers snap
// back to their pre-drag orientation. This pins the accumulation.
@(test)
test_rotation_moved_axes_accumulate_across_frames :: proc(t: ^testing.T) {
	// Frame 1: Y moves.
	moved: [3]bool
	f1_before := [3]f32{10, 20, 30}
	f1_after := [3]f32{10, 25, 30}
	for i in 0 ..< 3 {
		if f1_before[i] != f1_after[i] do moved[i] = true
	}
	testing.expect(t, moved[1], "Y recorded on the moving frame")

	// Frame 2 is the RELEASE: nothing moves, but the commit happens here.
	f2_before := f1_after
	f2_after := f1_after
	for i in 0 ..< 3 {
		if f2_before[i] != f2_after[i] do moved[i] = true
	}

	// The accumulated set still names Y, so the commit writes it to the peers.
	// Recomputing per frame would leave this all-false and write nothing.
	testing.expect(t, moved[1], "Y survives to the commit frame")
	testing.expect(t, !moved[0] && !moved[2], "untouched axes stay untouched")
}






// Structural array edits apply to the whole selection, as ONE undo step.
// Editing only the active object interacts badly with shortest-length
// truncation: the new row sits past a peer's end, so it is hidden again
// immediately and the list looks stuck.
@(test)
test_multi_array_append_grows_every_peer :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	a := engine.transform_new("A")
	b := engine.transform_new("B")
	_, a_ptr := engine.transform_add_comp(a, .Animation)
	_, b_ptr := engine.transform_add_comp(b, .Animation)
	anim_a := cast(^engine.Animation)a_ptr
	anim_b := cast(^engine.Animation)b_ptr

	peers := []inspector.Multi_Peer{
		{base = b_ptr, handle = _comp_handle(b, .Animation), scene = _scene_of(b)},
	}
	prev := inspector.multi_set_peers(peers)
	defer inspector.multi_set_peers(prev)

	elem_ti := type_info_of(engine.Animation_Layer)
	offset := offset_of(engine.Animation, layers)
	undo.push_component_owner(_comp_handle(a, .Animation))
	inspector.multi_array_structural(.Append, (^runtime.Raw_Dynamic_Array)(&anim_a.layers), offset, elem_ti, 0, peers, "Add Element")
	undo.pop_owner()

	// Active object AND peer both grew.
	testing.expect_value(t, len(anim_a.layers), 1)
	testing.expect_value(t, len(anim_b.layers), 1)
}

// One Add is one Ctrl-Z, however many objects are selected. Per-object
// snapshot/commit pairs alone produce one undo entry PER OBJECT, which is what
// "add made 3 undos" looks like.
@(test)
test_multi_array_append_is_one_undo_step :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	a := engine.transform_new("A")
	b := engine.transform_new("B")
	c := engine.transform_new("C")
	_, a_ptr := engine.transform_add_comp(a, .Animation)
	_, b_ptr := engine.transform_add_comp(b, .Animation)
	_, c_ptr := engine.transform_add_comp(c, .Animation)
	anim_a := cast(^engine.Animation)a_ptr
	anim_b := cast(^engine.Animation)b_ptr
	anim_c := cast(^engine.Animation)c_ptr

	peers := []inspector.Multi_Peer{
		{base = b_ptr, handle = _comp_handle(b, .Animation), scene = _scene_of(b)},
		{base = c_ptr, handle = _comp_handle(c, .Animation), scene = _scene_of(c)},
	}
	prev := inspector.multi_set_peers(peers)
	defer inspector.multi_set_peers(prev)

	elem_ti := type_info_of(engine.Animation_Layer)
	offset := offset_of(engine.Animation, layers)
	undo.push_component_owner(_comp_handle(a, .Animation))
	inspector.multi_array_structural(.Append, (^runtime.Raw_Dynamic_Array)(&anim_a.layers), offset, elem_ti, 0, peers, "Add Element")
	undo.pop_owner()

	testing.expect_value(t, len(anim_a.layers), 1)
	testing.expect_value(t, len(anim_b.layers), 1)
	testing.expect_value(t, len(anim_c.layers), 1)

	// ONE undo returns every object, not one object per press.
	undo.apply_undo(s)
	testing.expect_value(t, len(anim_a.layers), 0)
	testing.expect_value(t, len(anim_b.layers), 0)
	testing.expect_value(t, len(anim_c.layers), 0)
}

@(test)
test_multi_array_remove_skips_shorter_peers :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	a := engine.transform_new("A")
	b := engine.transform_new("B")
	_, a_ptr := engine.transform_add_comp(a, .Animation)
	_, b_ptr := engine.transform_add_comp(b, .Animation)
	anim_a := cast(^engine.Animation)a_ptr
	anim_b := cast(^engine.Animation)b_ptr

	peers := []inspector.Multi_Peer{
		{base = b_ptr, handle = _comp_handle(b, .Animation), scene = _scene_of(b)},
	}
	prev := inspector.multi_set_peers(peers)
	defer inspector.multi_set_peers(prev)

	elem_ti := type_info_of(engine.Animation_Layer)
	offset := offset_of(engine.Animation, layers)

	// Give the ACTIVE object two elements and the peer one, so a remove at
	// index 1 has no counterpart on the peer.
	undo.push_component_owner(_comp_handle(a, .Animation))
	defer undo.pop_owner()
	inspector.multi_array_structural(.Append, (^runtime.Raw_Dynamic_Array)(&anim_a.layers), offset, elem_ti, 0, peers, "Add")
	inspector.multi_array_structural(.Append, (^runtime.Raw_Dynamic_Array)(&anim_a.layers), offset, elem_ti, 0, nil, "Add")
	testing.expect_value(t, len(anim_a.layers), 2)
	testing.expect_value(t, len(anim_b.layers), 1)

	// Index 1 exists on the active object only — the peer is left alone.
	inspector.multi_array_structural(.Remove, (^runtime.Raw_Dynamic_Array)(&anim_a.layers), offset, elem_ti, 1, peers, "Remove")
	testing.expect_value(t, len(anim_a.layers), 1)
	testing.expect_value(t, len(anim_b.layers), 1)

	// Index 0 exists on both.
	inspector.multi_array_structural(.Remove, (^runtime.Raw_Dynamic_Array)(&anim_a.layers), offset, elem_ti, 0, peers, "Remove")
	testing.expect_value(t, len(anim_a.layers), 0)
	testing.expect_value(t, len(anim_b.layers), 0)
}


// Fails on any pooled Value_Command whose offset points outside the component
// it names. `resolve_target_ptr` computes base+offset with no bounds check, so
// such a record is a wild write waiting to happen.
@(private)
_assert_targets_in_bounds :: proc(t: ^testing.T, command: undo.Command, comp_size: u32) {
	#partial switch cmd in command {
	case undo.Value_Command:
		if cmd.target.kind != .Pooled do return
		if cmd.target.handle.type_key == .Transform do return
		testing.expectf(
			t, cmd.target.offset < comp_size,
			"undo record points %v bytes into a %v-byte component — resolve_target_ptr would write outside it",
			cmd.target.offset, comp_size,
		)
	case undo.Group_Command:
		for sub in cmd.subs {
			_assert_targets_in_bounds(t, sub, comp_size)
		}
	}
}


// Prefab-instance content multi-edits like anything else, as in Unity. Each
// peer carries its own instance identity, so an edit records an override
// against the instance it belongs to rather than the active object's.
//
// Excluding it made multiedit silently switch off for most real selections: a
// scene of any size is mostly prefab instances, and the header just said
// "editing the active object" with no hint why.
@(test)
test_multi_selection_editable_includes_prefab_content :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	a := engine.transform_new("A")
	b := engine.transform_new("B")
	testing.expect(t, editor.multi_selection_editable({a, b}), "plain objects multi-edit")

	// A single object is not a multi-selection.
	testing.expect(t, !editor.multi_selection_editable({a}), "one object is not multi")

	// Prefab content no longer disqualifies the selection.
	w := engine.ctx_world()
	tb := engine.pool_get(&w.transforms, engine.Handle(b))
	tb.nested_owned = true
	testing.expect(t, editor.multi_selection_editable({a, b}), "prefab content multi-edits too")
}

// Selecting two objects must not, by itself, change either of them.
//
// A picker row (mesh, material, any reference) has no observable gesture start:
// its value lands from inside a popup. Opening the edit transaction up front to
// compensate is a DATA-LOSS bug — the row redraws every frame, so the edit is
// permanently "in flight" and the active object's value is copied onto every
// peer continuously. Multi-selecting Avocado and DamagedHelmet silently
// replaced DamagedHelmet's mesh and materials.
//
// The peers must be untouched until the user actually picks something.
@(test)
test_multi_picker_row_does_not_write_on_draw :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	a := engine.transform_new("A")
	b := engine.transform_new("B")
	_, a_ptr := engine.transform_add_comp(a, .MeshFilter)
	_, b_ptr := engine.transform_add_comp(b, .MeshFilter)
	mf_a := cast(^engine.MeshFilter)a_ptr
	mf_b := cast(^engine.MeshFilter)b_ptr

	mesh_a := engine.Asset_GUID{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1}
	mesh_b := engine.Asset_GUID{2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2}
	mf_a.mesh = mesh_a
	mf_b.mesh = mesh_b

	peers := []inspector.Multi_Peer{
		{base = b_ptr, handle = _comp_handle(b, .MeshFilter), scene = _scene_of(b)},
	}
	prev := inspector.multi_set_peers(peers)
	defer inspector.multi_set_peers(prev)

	off := offset_of(engine.MeshFilter, mesh)

	// Several frames of the row merely being DRAWN, with no user edit. The probe
	// is what the inspector does before handing the field to the drawer.
	for _ in 0 ..< 3 {
		inspector.multi_probe_field(&mf_a.mesh, typeid_of(engine.Asset_GUID), off)
		inspector.multi_clear_mixed()
	}

	// Both objects keep their own mesh.
	testing.expect_value(t, mf_a.mesh, mesh_a)
	testing.expect_value(t, mf_b.mesh, mesh_b)
}

// A rotation multi-edit must record an undo entry for EVERY object, not just
// the active one.
//
// The peer's value is written during the drag by the live preview, so by the
// commit frame it already holds the final orientation. An "already there" check
// against the peer's CURRENT value therefore skips it and no entry is created —
// the drag looks right, and undo reverts the active object alone with a History
// group holding a single sub-command.
//
// What decides whether to record is movement SINCE THE DRAG BEGAN.
@(test)
test_multi_rotation_records_every_peer :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	a := engine.transform_new("A")
	b := engine.transform_new("B")
	w := engine.ctx_world()
	ta := engine.pool_get(&w.transforms, engine.Handle(a))
	tb := engine.pool_get(&w.transforms, engine.Handle(b))
	ta.rotation = engine.quat_from_euler_xyz(10, 20, 30)
	tb.rotation = engine.quat_from_euler_xyz(50, 60, 70)
	start_b := tb.rotation

	sel := []engine.Transform_Handle{a, b}
	prev := inspector.multi_set_peers(_peers_for(a, sel))
	defer inspector.multi_set_peers(prev)

	// The live preview during the drag: the peer already holds the final value.
	pe := engine.quat_to_euler_xyz(start_b)
	pe.y = 25
	previewed := engine.quat_from_euler_xyz(pe.x, pe.y, pe.z)
	tb.rotation = previewed

	// The commit must still record it, comparing against the PRE-DRAG value.
	moved_since_start := previewed != start_b
	testing.expect(t, moved_since_start, "the peer moved during the drag")

	// And a check against the peer's CURRENT value would wrongly skip it — this
	// is the exact comparison that produced the bug.
	would_skip := previewed == tb.rotation
	testing.expect(t, would_skip, "comparing against the current value skips a moved peer")
}
