package tests

// The Text component's custom rows (text area, style toggles) through the
// real field row: a string and a bit_set field must record undo steps like
// any generic row.

import "core:strings"
import "../editor/inspector"
import "core:testing"
import "../editor/undo"
import "../engine"
import text "moonhug:packages/text"

@(private = "file")
_write_hello :: proc(field_ptr: rawptr) {
	s := cast(^string)field_ptr
	delete(s^)
	s^ = strings.clone("hello")
}

@(private = "file")
_write_bold :: proc(field_ptr: rawptr) {
	(cast(^text.Font_Style)field_ptr)^ += {.Bold}
}

@(test)
test_text_rows_record_undo_steps :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	a := engine.transform_new("A")
	_, ptr := engine.transform_add_comp(a, .Text)
	tx := cast(^text.Text)ptr
	tx.text = strings.clone("")
	defer delete(tx.text)
	undo.push_component_owner(_comp_handle(a, .Text))
	defer undo.pop_owner()

	// Typing into the text area: focus, keystrokes, blur.
	before := s.top
	h := Row_Harness{field_ptr = &tx.text, field_tid = typeid_of(string), offset = offset_of(text.Text, text), label = "text"}
	frames := []Frame{frame_press(), frame_drag(_write_hello), frame_drag(), frame_release()}
	finishes := row_replay(&h, frames)
	testing.expect_value(t, finishes, 1)
	testing.expect_value(t, tx.text, "hello")
	testing.expect_value(t, s.top, before + 1)

	// A style toggle: one click is a whole gesture.
	before = s.top
	hs := Row_Harness{field_ptr = &tx.font_style, field_tid = typeid_of(text.Font_Style), offset = offset_of(text.Text, font_style), label = "font_style"}
	finishes = row_replay(&hs, []Frame{Frame{activated = true, deactivated = true, write = _write_bold}})
	testing.expect_value(t, finishes, 1)
	testing.expect(t, .Bold in tx.font_style)
	testing.expect_value(t, s.top, before + 1)

	// A generic bool row (auto_size): press, release.
	before = s.top
	hb := Row_Harness{field_ptr = &tx.auto_size, field_tid = typeid_of(bool), offset = offset_of(text.Text, auto_size), label = "auto_size"}
	finishes = row_replay(&hb, []Frame{frame_press(), Frame{deactivated = true, write = proc(p: rawptr) { (cast(^bool)p)^ = true }}})
	testing.expect_value(t, finishes, 1)
	testing.expect_value(t, s.top, before + 1)
	undo.apply_undo(s)
	testing.expect_value(t, tx.auto_size, false)

	undo.apply_undo(s)
	testing.expect(t, .Bold not_in tx.font_style, "undo clears the flag")
	undo.apply_undo(s)
	testing.expect_value(t, tx.text, "")
}

@(private = "file")
_idle_drawer :: proc(ptr: rawptr, tid: typeid, label: cstring) {}

@(private = "file")
_set_true :: proc(ptr: rawptr, tid: typeid, label: cstring) {
	(cast(^bool)ptr)^ = true
	inspector.mark_inspector_changed()
}

// The Text inspector's row order every frame: the text area, the style
// toggles, then the generic rows. A click on a generic bool row must still
// record while the two custom rows sit idle above it.
@(test)
test_text_inspector_row_order_keeps_generic_undo :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	a := engine.transform_new("A")
	_, ptr := engine.transform_add_comp(a, .Text)
	tx := cast(^text.Text)ptr
	tx.text = strings.clone("x")
	defer delete(tx.text)
	undo.push_component_owner(_comp_handle(a, .Text))
	defer undo.pop_owner()
	before := s.top

	ws: inspector.Widget_State
	idle := inspector.Widget_State{}
	press := inspector.Widget_State{activated = true, active = true}
	release := inspector.Widget_State{deactivated_after_edit = true}
	for frame in 0 ..< 3 {
		inspector.consume_inspector_changed()
		inspector.field_edit_frame_begin(frame == 2 || frame == 1) // the checkbox is held between press and release
		inspector.field_edit_set_widget_state(&ws)
		ws = idle
		inspector.field_edit_row(&tx.text, typeid_of(string), offset_of(text.Text, text), "text", _idle_drawer, "Text")
		ws = idle
		inspector.field_edit_row(&tx.font_style, typeid_of(text.Font_Style), offset_of(text.Text, font_style), "font_style", _idle_drawer, "Font Style")
		switch frame {
		case 0: ws = idle
		case 1: ws = press
		case 2: ws = release
		}
		drawer := _set_true if frame == 2 else _idle_drawer
		inspector.field_edit_row(&tx.auto_size, typeid_of(bool), offset_of(text.Text, auto_size), "auto_size", drawer, "auto_size")
		inspector.field_edit_set_widget_state(nil)
	}
	testing.expect_value(t, tx.auto_size, true)
	testing.expect_value(t, s.top, before + 1)
}

@(private = "file")
_pick_center :: proc(field_ptr: rawptr) {
	(cast(^text.Horizontal_Alignment)field_ptr)^ = .Center
}

// An enum combo lands its value from a popup with no gesture on the row, so
// the row records it retroactively (inspector._is_picker_type), and idle
// frames of the row open no session that could cut another row's gesture.
@(test)
test_enum_row_records_popup_write_and_stays_idle :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	a := engine.transform_new("A")
	_, ptr := engine.transform_add_comp(a, .Text)
	tx := cast(^text.Text)ptr
	undo.push_component_owner(_comp_handle(a, .Text))
	defer undo.pop_owner()
	before := s.top

	h := Row_Harness{field_ptr = &tx.horizontal_alignment, field_tid = typeid_of(text.Horizontal_Alignment), offset = offset_of(text.Text, horizontal_alignment), label = "horizontal_alignment"}
	finishes := row_replay(&h, []Frame{frame_idle(), frame_idle(), frame_popup_write(_pick_center), frame_idle()})
	testing.expect_value(t, finishes, 1)
	testing.expect_value(t, tx.horizontal_alignment, text.Horizontal_Alignment.Center)
	testing.expect_value(t, s.top, before + 1)
	undo.apply_undo(s)
	testing.expect_value(t, tx.horizontal_alignment, text.Horizontal_Alignment.Left)
}
