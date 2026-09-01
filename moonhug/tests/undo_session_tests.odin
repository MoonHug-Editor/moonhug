package tests

// Edit sessions (docs/Undo.md). These pin the three properties the
// older entry points failed to hold, each of which was a real reported bug:
//
//   - N targets in one gesture produce ONE undo step, and undoing it reverts
//     every one of them
//   - a field outside the component's own storage (a dynamic-array element) is
//     recorded as the whole component, never as a nonsense offset
//   - a gesture that ends where it started records nothing

import "base:runtime"
import "../editor/inspector"
import "../editor/undo"
import "../engine"

import "core:testing"
import seq "moonhug:packages/sequencer"
import tweens "moonhug:packages/sequencer/tweens"

@(test)
test_session_multi_target_is_one_undo_step :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	a := engine.transform_new("A")
	b := engine.transform_new("B")
	c := engine.transform_new("C")
	w := engine.ctx_world()
	ta := engine.pool_get(&w.transforms, engine.Handle(a))
	tb := engine.pool_get(&w.transforms, engine.Handle(b))
	tc := engine.pool_get(&w.transforms, engine.Handle(c))

	targets := []undo.Edit_Target{
		undo.edit_target_transform(a, &ta.position, typeid_of([3]f32)),
		undo.edit_target_transform(b, &tb.position, typeid_of([3]f32)),
		undo.edit_target_transform(c, &tc.position, typeid_of([3]f32)),
	}
	sess := undo.edit_session_begin(targets, "Position")
	ta.position = {1, 1, 1}
	tb.position = {2, 2, 2}
	tc.position = {3, 3, 3}
	undo.edit_session_end(&sess)

	// ONE undo takes all three back — the property comp_snapshot could not hold,
	// because a second target discarded the first's pending record.
	undo.apply_undo(s)
	testing.expect_value(t, ta.position, [3]f32{0, 0, 0})
	testing.expect_value(t, tb.position, [3]f32{0, 0, 0})
	testing.expect_value(t, tc.position, [3]f32{0, 0, 0})

	// And redo restores all three.
	undo.apply_redo(s)
	testing.expect_value(t, ta.position, [3]f32{1, 1, 1})
	testing.expect_value(t, tb.position, [3]f32{2, 2, 2})
	testing.expect_value(t, tc.position, [3]f32{3, 3, 3})
}

// A dynamic-array element lives in its own allocation, so `field_ptr - base` is
// the distance between two unrelated allocations — measured at ~526KB for a
// 64-byte component. Recording that as an offset and applying it later writes
// far outside the component (the material-assignment crash). The session must
// fall back to recording the whole component.
@(test)
test_session_array_element_records_whole_component :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	a := engine.transform_new("A")
	h := _comp_handle_of(a, .MeshRenderer)
	w := engine.ctx_world()
	_, ptr := engine.transform_add_comp(a, .MeshRenderer)
	h = _comp_handle_of(a, .MeshRenderer)
	mr := cast(^engine.MeshRenderer)ptr
	mr.materials = make([dynamic]engine.Asset_GUID)
	append(&mr.materials, engine.Asset_GUID{})

	// Point at the ELEMENT, which is outside the component.
	targets := []undo.Edit_Target{
		undo.edit_target_pooled(h, &mr.materials[0], typeid_of(engine.Asset_GUID)),
	}
	sess := undo.edit_session_begin(targets, "Material")
	mat := engine.Asset_GUID{9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9}
	mr.materials[0] = mat
	undo.edit_session_end(&sess)

	// Every recorded offset must land inside the component. A nonsense offset
	// is checked rather than "did it crash": the bad write lands wherever the
	// heap happens to be, so it faults in the editor and usually not in a test.
	comp_size := u32(size_of(engine.MeshRenderer))
	for entry in s.items[:s.top] {
		_expect_offsets_in_bounds(t, entry.cmd, comp_size)
	}

	testing.expect_value(t, mr.materials[0], mat)
	undo.apply_undo(s)
	testing.expect_value(t, len(mr.materials), 1)
	testing.expect_value(t, mr.materials[0], engine.Asset_GUID{})
	_ = w
}

@(test)
test_session_no_change_records_nothing :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	a := engine.transform_new("A")
	w := engine.ctx_world()
	ta := engine.pool_get(&w.transforms, engine.Handle(a))
	ta.position = {5, 5, 5}

	before := s.top
	targets := []undo.Edit_Target{
		undo.edit_target_transform(a, &ta.position, typeid_of([3]f32)),
	}
	sess := undo.edit_session_begin(targets, "Position")
	// Nothing written: clicking into a field and tabbing out must not record.
	undo.edit_session_end(&sess)

	testing.expect_value(t, s.top, before)
}

// Only the targets that actually moved are recorded, so a selection where one
// object already held the new value does not gain a no-op entry.
@(test)
test_session_records_only_changed_targets :: proc(t: ^testing.T) {
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
	tb.position = {7, 7, 7} // already at the destination

	targets := []undo.Edit_Target{
		undo.edit_target_transform(a, &ta.position, typeid_of([3]f32)),
		undo.edit_target_transform(b, &tb.position, typeid_of([3]f32)),
	}
	sess := undo.edit_session_begin(targets, "Position")
	ta.position = {7, 7, 7}
	tb.position = {7, 7, 7} // unchanged
	undo.edit_session_end(&sess)

	undo.apply_undo(s)
	testing.expect_value(t, ta.position, [3]f32{0, 0, 0})
	testing.expect_value(t, tb.position, [3]f32{7, 7, 7}) // untouched by the undo
}

@(test)
test_session_abort_records_nothing :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	a := engine.transform_new("A")
	w := engine.ctx_world()
	ta := engine.pool_get(&w.transforms, engine.Handle(a))

	before := s.top
	targets := []undo.Edit_Target{
		undo.edit_target_transform(a, &ta.position, typeid_of([3]f32)),
	}
	sess := undo.edit_session_begin(targets, "Position")
	ta.position = {4, 4, 4}
	undo.edit_session_abort(&sess)

	// The value the caller wrote stays; only the record is dropped.
	testing.expect_value(t, ta.position, [3]f32{4, 4, 4})
	testing.expect_value(t, s.top, before)
}

// A session survives the frames between begin and end, which is the whole point
// — the before-state is captured once and cannot be clobbered by anything that
// happens in between.
@(test)
test_session_spans_intervening_edits :: proc(t: ^testing.T) {
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

	targets := []undo.Edit_Target{
		undo.edit_target_transform(a, &ta.position, typeid_of([3]f32)),
	}
	sess := undo.edit_session_begin(targets, "Position")

	// Several frames of dragging, plus an unrelated recorded edit in between.
	ta.position = {1, 0, 0}
	e := undo.edit_begin(b, &tb.position, typeid_of([3]f32), "Other")
	tb.position = {9, 9, 9}
	undo.edit_end(&e)
	ta.position = {2, 0, 0}
	ta.position = {3, 0, 0}

	undo.edit_session_end(&sess)

	// The session records 0 -> 3, not 2 -> 3: the pre-image was taken at begin.
	undo.apply_undo(s)
	testing.expect_value(t, ta.position, [3]f32{0, 0, 0})
}

@(private)
_comp_handle_of :: proc(tH: engine.Transform_Handle, key: engine.TypeKey) -> engine.Handle {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return {}
	for comp in t.components {
		if comp.handle.type_key == key do return comp.handle
	}
	return {}
}

// Fails on any pooled record whose offset points outside the component it
// names. resolve_target_ptr computes base+offset with no bounds check, so such
// a record is a wild write waiting to happen.
@(private)
_expect_offsets_in_bounds :: proc(t: ^testing.T, command: undo.Command, comp_size: u32) {
	#partial switch cmd in command {
	case undo.Value_Command:
		if cmd.target.kind != .Pooled do return
		if cmd.target.handle.type_key == .Transform do return
		testing.expectf(
			t, cmd.target.offset < comp_size,
			"undo record points %v bytes into a %v-byte component",
			cmd.target.offset, comp_size,
		)
	case undo.Group_Command:
		for sub in cmd.subs {
			_expect_offsets_in_bounds(t, sub, comp_size)
		}
	}
}

// Undoing a multi-edit of an array ELEMENT must restore each object's own
// value, not the active object's.
//
// An element is recorded as the WHOLE component (its storage is a separate
// allocation no offset can name). A "before" payload captured at FIELD
// granularity and written into such an entry is the wrong shape: undo then
// applies the active object's whole component to its peer. That is what emptied
// DamagedHelmet's materials when undoing a material set across a selection.
@(test)
test_session_array_element_undo_restores_each_own_value :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	a := engine.transform_new("A")
	b := engine.transform_new("B")
	_, a_ptr := engine.transform_add_comp(a, .MeshRenderer)
	_, b_ptr := engine.transform_add_comp(b, .MeshRenderer)
	mr_a := cast(^engine.MeshRenderer)a_ptr
	mr_b := cast(^engine.MeshRenderer)b_ptr

	mat_a := engine.Asset_GUID{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1}
	mat_b := engine.Asset_GUID{2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2}
	mr_a.materials = make([dynamic]engine.Asset_GUID)
	mr_b.materials = make([dynamic]engine.Asset_GUID)
	append(&mr_a.materials, mat_a)
	append(&mr_b.materials, mat_b)

	// A material assigned across both, as the inspector's element row does.
	picked := engine.Asset_GUID{9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9}
	targets := []undo.Edit_Target{
		undo.edit_target_pooled(_comp_handle_of(a, .MeshRenderer), &mr_a.materials[0], typeid_of(engine.Asset_GUID)),
		undo.edit_target_pooled(_comp_handle_of(b, .MeshRenderer), &mr_b.materials[0], typeid_of(engine.Asset_GUID)),
	}
	sess := undo.edit_session_begin(targets, "Material")
	mr_a.materials[0] = picked
	mr_b.materials[0] = picked
	undo.edit_session_end(&sess)

	testing.expect_value(t, mr_a.materials[0], picked)
	testing.expect_value(t, mr_b.materials[0], picked)

	// Each object goes back to ITS OWN material, and neither array is emptied.
	undo.apply_undo(s)
	testing.expect_value(t, len(mr_a.materials), 1)
	testing.expect_value(t, len(mr_b.materials), 1)
	testing.expect_value(t, mr_a.materials[0], mat_a)
	testing.expect_value(t, mr_b.materials[0], mat_b)
}

// A SINGLE selected object's picker change must record an undo step.
//
// Pickers are bracketed retroactively: the row snapshots the value, draws, and
// opens the transaction only if it moved. Taking that snapshot only when there
// are multi-edit peers left a lone object's mesh assignment with nothing to
// record against, so changing a mesh produced no undo step at all.
@(test)
test_session_single_target_records_step :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	a := engine.transform_new("A")
	_, ptr := engine.transform_add_comp(a, .MeshFilter)
	mf := cast(^engine.MeshFilter)ptr
	original := engine.PPtr{guid = engine.Asset_GUID{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1}}
	mf.mesh = original

	before := s.top
	targets := []undo.Edit_Target{
		undo.edit_target_pooled(_comp_handle_of(a, .MeshFilter), &mf.mesh, typeid_of(engine.PPtr)),
	}
	sess := undo.edit_session_begin(targets, "mesh")
	picked := engine.PPtr{guid = engine.Asset_GUID{7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7}}
	mf.mesh = picked
	undo.edit_session_end(&sess)

	// One entry, and it reverts.
	testing.expect(t, s.top > before, "a single-object edit is recorded")
	undo.apply_undo(s)
	testing.expect_value(t, mf.mesh, original)
}

// A structural op (inspector button, union variant switch, decorator) applies to
// the whole selection as ONE undo step.
//
// These were the last callers of the single global pending edit, which held one
// record at a time: a second object's snapshot discarded the first's, so undo
// reverted the active object and left every peer where the click had put it.
@(test)
test_structural_edit_covers_selection_in_one_step :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	a := engine.transform_new("A")
	b := engine.transform_new("B")
	_, a_ptr := engine.transform_add_comp(a, .Light)
	_, b_ptr := engine.transform_add_comp(b, .Light)
	light_a := cast(^engine.Light)a_ptr
	light_b := cast(^engine.Light)b_ptr
	light_a.intensity = 1
	light_b.intensity = 1

	peers := []inspector.Multi_Peer{
		{base = b_ptr, handle = _comp_handle_of(b, .Light), scene = _scene_of(b)},
	}
	prev := inspector.multi_set_peers(peers)
	defer inspector.multi_set_peers(prev)

	before := s.top
	undo.push_component_owner(_comp_handle_of(a, .Light))
	sess := inspector.structural_edit_begin("Invoke")
	// What a button's `invoke` does: mutate every selected object's component.
	light_a.intensity = 4
	light_b.intensity = 4
	inspector.structural_edit_end(&sess)
	undo.pop_owner()

	testing.expect_value(t, s.top, before + 1)

	// One undo takes BOTH back, not just the active object.
	undo.apply_undo(s)
	testing.expect_value(t, light_a.intensity, f32(1))
	testing.expect_value(t, light_b.intensity, f32(1))
}

// An inspector button runs on EVERY selected object, in one undo step.
//
// The click path is only reachable by a real mouse press, so the mutation is
// extracted into `inspector_button_invoke` and driven here. Running `invoke` on
// the active object alone left the session recording peers that never changed,
// so the button silently did nothing to the rest of the selection.
@(test)
test_inspector_button_invokes_across_selection :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	a := engine.transform_new("A")
	b := engine.transform_new("B")
	_, a_ptr := engine.transform_add_comp(a, .Light)
	_, b_ptr := engine.transform_add_comp(b, .Light)
	light_a := cast(^engine.Light)a_ptr
	light_b := cast(^engine.Light)b_ptr
	light_a.intensity = 1
	light_b.intensity = 1

	peers := []inspector.Multi_Peer{
		{base = b_ptr, handle = _comp_handle_of(b, .Light), scene = _scene_of(b)},
	}
	prev := inspector.multi_set_peers(peers)
	defer inspector.multi_set_peers(prev)

	btn := inspector.Inspector_Button{label = "Double Intensity", invoke = _btn_double_intensity}

	before := s.top
	undo.push_component_owner(_comp_handle_of(a, .Light))
	inspector.inspector_button_invoke(btn, a_ptr)
	undo.pop_owner()

	// Both ran, and it is ONE step.
	testing.expect_value(t, light_a.intensity, f32(2))
	testing.expect_value(t, light_b.intensity, f32(2))
	testing.expect_value(t, s.top, before + 1)

	undo.apply_undo(s)
	testing.expect_value(t, light_a.intensity, f32(1))
	testing.expect_value(t, light_b.intensity, f32(1))
}

@(private)
_btn_double_intensity :: proc(comp: rawptr) {
	light := cast(^engine.Light)comp
	light.intensity *= 2
}

// Switching a union variant zeroes the payload and records one undo step.
//
// The old variant's bytes mean something different under the new tag, so
// carrying them over reads garbage as the new type. No component in the tree
// carries a union field yet, so the shape is declared here.
_Test_Union :: union {
	i64,
	[2]f32,
}

@(test)
test_union_variant_switch_zeroes_payload :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	// Undo writes a value back through its registered pointer type; a type the
	// engine has never seen cannot be restored.
	engine.register_pointer_type(_Test_Union)

	ti := runtime.type_info_base(type_info_of(_Test_Union))
	info, ok := ti.variant.(runtime.Type_Info_Union)
	if !testing.expect(t, ok, "test type is a union") do return

	val: _Test_Union = i64(0x7fff_ffff)
	ptr := rawptr(&val)
	tag_ptr := rawptr(uintptr(ptr) + uintptr(info.tag_offset))

	// A raw target, which is what a union field inside editor-owned state is.
	undo.push_raw_owner(ptr, typeid_of(_Test_Union))
	defer undo.pop_owner()

	before := s.top
	// Variant INDEX 1 is [2]f32. For this nilable union that is stored as tag 2,
	// since tag 0 means nil — the conversion the inspector previously got wrong,
	// selecting the neighbouring variant.
	inspector.union_set_variant(ptr, tag_ptr, info, 1)

	// The i64 payload must not survive into the [2]f32 variant.
	v, is_vec := val.([2]f32)
	testing.expect(t, is_vec, "variant switched to [2]f32")
	testing.expect_value(t, v, [2]f32{0, 0})
	testing.expect_value(t, s.top, before + 1)

	// And it reverts.
	undo.apply_undo(s)
	old, is_int := val.(i64)
	testing.expect(t, is_int, "undo restored the i64 variant")
	testing.expect_value(t, old, i64(0x7fff_ffff))
}

// Union fields round-trip through the generic guid-keyed serializers. The
// unions are #no_nil: their zero value is the FIRST variant, never nil, so
// a freshly added list element is a real variant and always marshals to a
// guid-tagged object. A nilable union would write bare `null`, which
// union_unmarshal cannot read back — the whole owning component then fails
// to parse and the loader preserves it verbatim as an unknown component
// (the object shows "Missing Component" and its list vanishes).
@(test)
test_union_field_round_trips :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	root := engine.transform_new("Stage")
	engine.scene_set_root(tc_mem.scene, root)
	clip := engine.transform_new("clip", root)
	_, raw := engine.transform_add_comp(clip, .ClipTween)
	tclip := cast(^seq.ClipTween)raw
	testing.expect(t, tclip != nil)
	if tclip == nil do return
	// Element 0 is the DEFAULT (what "Add Element" produces before a variant
	// is picked); element 1 is explicitly chosen. Both must survive.
	append(&tclip.tweens, seq.TweenUnion{})
	append(&tclip.tweens, seq.TweenUnion(tweens.TweenMoveLocalTo{to = {5, 0, 0}}))

	bytes, ok := engine.scene_serialize(tc_mem.scene)
	testing.expect(t, ok, "serialize")
	if !ok do return
	defer delete(bytes)
	reloaded := engine.scene_reload_in_place_bytes(tc_mem.scene, bytes)
	testing.expect(t, reloaded != nil, "reload")
	if reloaded == nil do return
	tc_mem.scene = reloaded

	testing.expect_value(t, len(reloaded.unknown_components), 0)

	live: ^seq.ClipTween
	{
		w := &tc_mem.world
		it := engine.pool_iterator(&w.transforms)
		for tr, _ in engine.pool_next(&it) {
			for c in tr.components {
				if c.handle.type_key == .ClipTween {
					live = cast(^seq.ClipTween)engine.world_pool_get(w, c.handle)
				}
			}
		}
	}
	testing.expect(t, live != nil, "the component loaded rather than being stashed")
	if live == nil do return
	testing.expect_value(t, len(live.tweens), 2)
	if len(live.tweens) != 2 do return
	_, is_move := live.tweens[1].(tweens.TweenMoveLocalTo)
	testing.expect(t, is_move, "the picked variant survives beside the default")
}
