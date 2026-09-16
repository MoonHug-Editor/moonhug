package animation_tests

// Undo for the TimelineAnimator's States tree
// (editor/inspector_timeline_animator.odin).
//
// Same three frame sequences the Animation tree's rows are pinned against
// (inspector_undo_tests.odin), because the rows go through the same
// inspector.field_edit_row and the failure mode is the same: a row that records
// nothing looks exactly like a row that works until Ctrl+Z.
//
// The timeline row is the one worth having twice: it is assigned from a picker
// popup with no gesture, so the row can only bracket it retroactively, against
// the snapshot it took before the draw.
//
// A state lives in a dynamic array, so each step records the WHOLE component:
// no offset from the component base names one.

import "core:testing"
import undo "moonhug:editor/undo"
import "moonhug:engine"
import anim "moonhug:packages/animation"
import seq "moonhug:packages/sequencer"
import common "moonhug:tests/common"

@(private = "file")
_ta_handle :: proc(owner: engine.Transform_Handle) -> engine.Handle {
	w := engine.ctx_world()
	tr := engine.pool_get(&w.transforms, engine.Handle(owner))
	if tr == nil do return {}
	for c in tr.components {
		if c.handle.type_key == .TimelineAnimator do return c.handle
	}
	return {}
}

// One layer holding one state, the smallest tree with every row kind on it.
@(private = "file")
_animator_with_state :: proc() -> (^anim.TimelineAnimator, engine.Handle) {
	owner := engine.transform_new("Animator")
	_, ptr := engine.transform_add_comp(owner, .TimelineAnimator)
	if ptr == nil do return nil, {}
	a := cast(^anim.TimelineAnimator)ptr

	a.layers = make([dynamic]anim.Animator_Layer)
	append(&a.layers, anim.Animator_Layer{weight = 1, states = make([dynamic]anim.Timeline_State)})
	append(&a.layers[0].states, anim.Timeline_State{
		id    = 1,
		speed = 1,
		fade  = 0.25,
		wrap  = .Once,
	})
	return a, _ta_handle(owner)
}

@(private = "file")
_state :: proc(a: ^anim.TimelineAnimator) -> ^anim.Timeline_State {
	return &a.layers[0].states[0]
}

@(private = "file")
_write_fade :: proc(field_ptr: rawptr) {
	(cast(^f32)field_ptr)^ = 0.75
}

@(private = "file")
_write_timeline :: proc(field_ptr: rawptr) {
	r := cast(^engine.Ref_Local)field_ptr
	r.local_id = 42
}

// The fade drag: one step, taken from the value before the gesture began rather
// than the one the first drawn frame already wrote.
@(test)
test_animator_fade_drag_is_one_undo_step :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	s := new(undo.Undo_Stack)
	undo.init(s)
	undo.install(s)
	defer {undo.destroy(s);free(s)}

	a, h := _animator_with_state()
	testing.expect(t, a != nil && h.type_key == .TimelineAnimator, "TimelineAnimator built")
	if a == nil do return

	undo.push_component_owner(h)
	defer undo.pop_owner()

	before := s.top
	harness := common.Row_Harness{
		field_ptr = &_state(a).fade,
		field_tid = typeid_of(f32),
		label     = "Fade",
	}
	finished := common.row_replay(&harness, []common.Frame{
		common.frame_press(_write_fade),
		common.frame_drag(_write_fade),
		common.frame_release(),
	})

	testing.expect_value(t, finished, 1)
	testing.expect_value(t, s.top, before + 1)
	testing.expect_value(t, _state(a).fade, 0.75)

	testing.expect(t, undo.apply_undo(s), "undo applies")
	testing.expect_value(t, _state(a).fade, 0.25)

	testing.expect(t, undo.apply_redo(s), "redo applies")
	testing.expect_value(t, _state(a).fade, 0.75)
}

// The timeline picker writes from a popup: no activation, no active widget. The
// row notices the reference moved and brackets it with its pre-draw snapshot.
@(test)
test_animator_timeline_assign_records_undo_step :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	s := new(undo.Undo_Stack)
	undo.init(s)
	undo.install(s)
	defer {undo.destroy(s);free(s)}

	a, h := _animator_with_state()
	if a == nil do return

	undo.push_component_owner(h)
	defer undo.pop_owner()

	before := s.top
	harness := common.Row_Harness{
		field_ptr = &_state(a).timeline,
		field_tid = typeid_of(engine.Ref_Local),
		label     = "Timeline",
	}
	common.row_replay(&harness, []common.Frame{
		common.frame_idle(),
		common.frame_popup_write(_write_timeline),
	})

	testing.expect_value(t, s.top, before + 1)
	testing.expect_value(t, _state(a).timeline.local_id, engine.Local_ID(42))

	testing.expect(t, undo.apply_undo(s), "undo applies")
	testing.expect_value(t, _state(a).timeline.local_id, engine.Local_ID(0))
}

// Merely drawing the tree is not an edit. These rows redraw every frame.
@(test)
test_animator_drawing_rows_records_nothing :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	s := new(undo.Undo_Stack)
	undo.init(s)
	undo.install(s)
	defer {undo.destroy(s);free(s)}

	a, h := _animator_with_state()
	if a == nil do return

	undo.push_component_owner(h)
	defer undo.pop_owner()

	before := s.top
	idle := []common.Frame{common.frame_idle(), common.frame_idle(), common.frame_idle()}

	fade_row := common.Row_Harness{field_ptr = &_state(a).fade, field_tid = typeid_of(f32), label = "Fade"}
	timeline_row := common.Row_Harness{
		field_ptr = &_state(a).timeline,
		field_tid = typeid_of(engine.Ref_Local),
		label     = "Timeline",
	}
	wrap_row := common.Row_Harness{
		field_ptr = &_state(a).wrap,
		field_tid = typeid_of(seq.Timeline_Wrap),
		label     = "Wrap",
	}
	common.row_replay(&fade_row, idle)
	common.row_replay(&timeline_row, idle)
	common.row_replay(&wrap_row, idle)

	testing.expect_value(t, s.top, before)
}

// A state added through the tree gets an id immediately, so two new rows never
// share one. _ta_ensure_ids mints at build time, which is too late for a row
// that has to key a widget the moment it appears.
@(test)
test_animator_state_ids_are_unique_on_add :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	a, _ := _animator_with_state()
	if a == nil do return

	first := anim.animator_state_next_id(a)
	append(&a.layers[0].states, anim.Timeline_State{id = first})
	second := anim.animator_state_next_id(a)

	testing.expect(t, first != second, "a second added state takes a different id")
	testing.expect_value(t, second, first + 1)
}
