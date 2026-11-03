package engine_tests

// The undo edit session keeps the lanes the preview drives (undo_driven.odin):
// a write through any session, the gizmo's, a tool's, lands in the other
// lanes only.

import "core:testing"
import "moonhug:packages/engine"
import "moonhug:editor/inspector"
import undo "moonhug:packages/engine/editor/undo"

@(private = "file")
_ds_owner: engine.Handle

// X of the position is driven, Y and Z are the object's.
@(private = "file")
_ds_provider :: proc(owner: engine.Handle, field_offset: uintptr, field_tid: typeid, out: rawptr) -> (driven: bool, editable: bool, own: inspector.Driven_Lanes) {
	if owner != _ds_owner || field_offset != offset_of(engine.Transform, position) || field_tid != typeid_of([3]f32) do return false, false, {}
	(cast(^[3]f32)out)^ = {0, 0, 0}
	return true, false, {1, 2}
}

@(test)
test_session_keeps_the_driven_lanes :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	s := setup_undo(tc)
	context.user_ptr = &tc.uc
	defer teardown_undo(tc, s)

	a := engine.transform_new("A")
	ta := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(a))
	ta.position = {1, 2, 3}
	_ds_owner = engine.Handle(a)
	prev := inspector.driven_provider
	inspector.driven_provider = _ds_provider
	defer inspector.driven_provider = prev

	steps := s.top
	e := undo.edit_begin(a, &ta.position, typeid_of([3]f32), "write")
	ta.position = {9, 9, 9}
	undo.edit_end(&e)
	testing.expect_value(t, ta.position, [3]f32{1, 9, 9})
	testing.expect_value(t, s.top, steps + 1)
	undo.apply_undo(s)
	testing.expect_value(t, ta.position, [3]f32{1, 2, 3})

	// A write to the driven lane alone records nothing.
	e = undo.edit_begin(a, &ta.position, typeid_of([3]f32), "write")
	ta.position.x = 7
	undo.edit_end(&e)
	testing.expect_value(t, ta.position, [3]f32{1, 2, 3})
	testing.expect_value(t, s.top, steps)
}
