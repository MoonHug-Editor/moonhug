package animation_tests

// Undo for the States tree (editor/inspector_animation.odin).
//
// The tree draws its own rows, so nothing about them is covered by the
// reflected field loop's tests — and a row that records nothing looks exactly
// like a row that works, right up until Ctrl+Z does nothing. The rows go
// through inspector.field_edit_row for that reason, and these replay the frame
// sequences that path exists to get right:
//
//   - a drag is ONE undo step, taken from the value before the gesture started
//   - a clip assignment comes from a popup with no gesture at all, and is
//     bracketed after the fact
//   - drawing the rows with no gesture records nothing
//
// A blend value and a clip both live inside a dynamic-array element, so each
// step records the WHOLE component — no offset from the component base names
// an entry.

import "core:testing"
import undo "moonhug:editor/undo"
import "moonhug:engine"
import anim "moonhug:packages/animation"
import common "moonhug:tests/common"

@(private = "file")
_comp_handle :: proc(owner: engine.Transform_Handle, key: engine.TypeKey) -> engine.Handle {
	w := engine.ctx_world()
	tr := engine.pool_get(&w.transforms, engine.Handle(owner))
	if tr == nil do return {}
	for c in tr.components {
		if c.handle.type_key == key do return c.handle
	}
	return {}
}

// A component holding one layer with a blend and one clip child, which is the
// smallest tree with every row kind on it.
@(private = "file")
_animation_with_blend :: proc() -> (^anim.Animation, engine.Handle) {
	owner := engine.transform_new("Animated")
	_, ptr := engine.transform_add_comp(owner, .Animation)
	if ptr == nil do return nil, {}
	a := cast(^anim.Animation)ptr

	a.layers = make([dynamic]anim.Animation_Layer)
	append(&a.layers, anim.Animation_Layer{entries = make([dynamic]anim.Animation_Entry)})
	append(&a.layers[0].entries, anim.Animation_Entry{
		id   = 1,
		kind = anim.Animation_Entry_Blend1D{value = 0.25},
	})
	append(&a.layers[0].entries, anim.Animation_Entry{
		id     = 2,
		parent = 1,
		kind   = anim.Animation_Entry_Clip{},
	})
	return a, _comp_handle(owner, .Animation)
}

@(private = "file")
_blend :: proc(a: ^anim.Animation) -> ^anim.Animation_Entry_Blend1D {
	b, _ := &a.layers[0].entries[0].kind.(anim.Animation_Entry_Blend1D)
	return b
}

@(private = "file")
_child_clip :: proc(a: ^anim.Animation) -> ^anim.Animation_Entry_Clip {
	c, _ := &a.layers[0].entries[1].kind.(anim.Animation_Entry_Clip)
	return c
}

@(private = "file")
_write_blend_value :: proc(field_ptr: rawptr) {
	(cast(^f32)field_ptr)^ = 0.75
}

@(private = "file")
_write_clip :: proc(field_ptr: rawptr) {
	g := cast(^engine.Asset_GUID)field_ptr
	g[0], g[1] = 0xAB, 0xCD
}

// The blend slider's gesture. The step's before-state is the value from before
// the drag began, not the value the first drawn frame already wrote.
@(test)
test_blend_value_drag_is_one_undo_step :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	s := new(undo.Undo_Stack)
	undo.init(s)
	undo.install(s)
	defer {undo.destroy(s);free(s)}

	a, h := _animation_with_blend()
	testing.expect(t, a != nil && h.type_key == .Animation, "Animation component built")
	if a == nil do return

	undo.push_component_owner(h)
	defer undo.pop_owner()

	before := s.top
	harness := common.Row_Harness{
		field_ptr = &_blend(a).value,
		field_tid = typeid_of(f32),
		label     = "Blend Value",
	}
	finished := common.row_replay(&harness, []common.Frame{
		common.frame_press(_write_blend_value),
		common.frame_drag(_write_blend_value),
		common.frame_release(),
	})

	testing.expect_value(t, finished, 1)
	testing.expect_value(t, s.top, before + 1)
	testing.expect_value(t, _blend(a).value, 0.75)

	testing.expect(t, undo.apply_undo(s), "undo applies")
	testing.expect_value(t, _blend(a).value, 0.25)

	testing.expect(t, undo.apply_redo(s), "redo applies")
	testing.expect_value(t, _blend(a).value, 0.75)
}

// The clip picker writes from inside a popup: no activation, no active widget.
// The row is what notices the value moved and brackets it with the snapshot it
// took before the draw.
@(test)
test_clip_assign_records_undo_step :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	s := new(undo.Undo_Stack)
	undo.init(s)
	undo.install(s)
	defer {undo.destroy(s);free(s)}

	a, h := _animation_with_blend()
	if a == nil do return

	undo.push_component_owner(h)
	defer undo.pop_owner()

	before := s.top
	harness := common.Row_Harness{
		field_ptr = &_child_clip(a).clip,
		field_tid = typeid_of(engine.Asset_GUID),
		label     = "Clip",
	}
	common.row_replay(&harness, []common.Frame{
		common.frame_idle(),
		common.frame_popup_write(_write_clip),
	})

	testing.expect_value(t, s.top, before + 1)
	testing.expect(t, _child_clip(a).clip != engine.Asset_GUID{}, "clip assigned")

	testing.expect(t, undo.apply_undo(s), "undo applies")
	testing.expect_value(t, _child_clip(a).clip, engine.Asset_GUID{})
}

// Merely drawing the tree is not an edit. Rows redraw every frame, so a row
// that records on draw fills the undo stack with steps nobody made.
@(test)
test_drawing_rows_records_nothing :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	s := new(undo.Undo_Stack)
	undo.init(s)
	undo.install(s)
	defer {undo.destroy(s);free(s)}

	a, h := _animation_with_blend()
	if a == nil do return

	undo.push_component_owner(h)
	defer undo.pop_owner()

	before := s.top
	value_row := common.Row_Harness{
		field_ptr = &_blend(a).value,
		field_tid = typeid_of(f32),
		label     = "Blend Value",
	}
	clip_row := common.Row_Harness{
		field_ptr = &_child_clip(a).clip,
		field_tid = typeid_of(engine.Asset_GUID),
		label     = "Clip",
	}
	idle := []common.Frame{common.frame_idle(), common.frame_idle(), common.frame_idle()}
	common.row_replay(&value_row, idle)
	common.row_replay(&clip_row, idle)

	testing.expect_value(t, s.top, before)
}
