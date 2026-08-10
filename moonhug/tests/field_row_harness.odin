package tests

// Drives an inspector field ROW across frames, without a UI.
//
// Every bug the multiedit feature shipped was a multi-frame sequencing mistake:
//
//   - a picker row copied the active object's value onto every peer on every
//     frame it DREW, so merely selecting two objects destroyed one of them
//   - the pre-edit image was recaptured on the commit frame, so the fieldwise
//     diff came back empty and a vector edit flattened the selection
//   - clicking the picker's SEARCH button counted as starting an edit
//   - a single-object picker change recorded no undo step at all
//
// None were reachable from a test that called the row's procs once, and all
// were found by hand in the running editor. What they have in common is a
// SEQUENCE of frames with particular widget state — which is exactly what this
// replays.
//
// The harness is deliberately thin: it substitutes the three imgui item-state
// queries a row observes and calls the real `field_edit_row`. Nothing about the
// transaction, the peer apply or the undo recording is reimplemented here, so a
// test exercises the shipping code path rather than a model of it.

import "../editor"
import "../editor/inspector"
import "../engine"

// One frame of a gesture, as the row would observe it.
Frame :: struct {
	// imgui item state for this frame.
	activated:   bool, // the gesture began (mouse went down on the widget)
	active:      bool, // the widget owns input (still dragging / focused)
	deactivated: bool, // the gesture ended (released, or value committed)

	// What the drawer writes into the field this frame, if anything. nil leaves
	// the value alone — which is the important case: a row that merely DRAWS
	// must not change any object.
	write: proc(field_ptr: rawptr),
}

Row_Harness :: struct {
	field_ptr: rawptr,
	field_tid: typeid,
	offset:    uintptr,
	label:     string,
	ws:        inspector.Widget_State,
}

// The drawer the harness hands to the row. It performs this frame's write, so
// the value changes at the same point in the sequence a real drawer would
// change it — inside the row, between the before-snapshot and the commit checks.
@(private)
_harness_pending_write: proc(field_ptr: rawptr)

@(private)
_harness_drawer :: proc(ptr: rawptr, tid: typeid, label: cstring) {
	if _harness_pending_write != nil {
		_harness_pending_write(ptr)
		inspector.mark_inspector_changed()
	}
}

// Replays `frames` through the real field_edit_row, one frame per entry.
//
// Returns how many frames reported the edit as finished, which is the count of
// undo steps the sequence should have produced.
row_replay :: proc(h: ^Row_Harness, frames: []Frame) -> (finish_count: int) {
	inspector.field_edit_set_widget_state(&h.ws)
	defer inspector.field_edit_set_widget_state(nil)

	for f in frames {
		h.ws = inspector.Widget_State{
			activated              = f.activated,
			active                 = f.active,
			deactivated_after_edit = f.deactivated,
		}
		_harness_pending_write = f.write
		defer _harness_pending_write = nil

		inspector.consume_inspector_changed()
		if inspector.field_edit_row(h.field_ptr, h.field_tid, h.offset, h.label,
		                            _harness_drawer, "##harness") {
			finish_count += 1
		}
	}
	// A gesture the sequence left open is closed the way the editor closes one
	// whose widget vanished — see field_edit_frame_begin.
	inspector.field_edit_frame_begin(false)
	return
}

// A frame where the row is merely drawn: no gesture, no write. The case that
// must never change anything, and the one that shipped a data-loss bug.
frame_idle :: proc() -> Frame {
	return Frame{}
}

// The first frame of a drag.
frame_press :: proc(write: proc(field_ptr: rawptr) = nil) -> Frame {
	return Frame{activated = true, active = true, write = write}
}

// A frame mid-drag.
frame_drag :: proc(write: proc(field_ptr: rawptr) = nil) -> Frame {
	return Frame{active = true, write = write}
}

// The frame the drag releases. Note it reports no movement of its own: the
// pointer has stopped, which is what made per-frame "what changed" logic fail.
frame_release :: proc() -> Frame {
	return Frame{deactivated = true}
}

// A popup write (picker): the value changes with NO activation and NO active
// widget, because the click happened inside a popup rather than on the row.
frame_popup_write :: proc(write: proc(field_ptr: rawptr)) -> Frame {
	return Frame{write = write}
}

// A click on a button inside the row that is not the value widget — the picker's
// search or clear button. It activates an imgui item but changes nothing.
frame_button_click :: proc() -> Frame {
	return Frame{activated = true, deactivated = true}
}

// Sets up peers from a selection, the way the inspector does before drawing.
// Returns the previous peers so the caller can restore them.
row_set_peers :: proc(active: engine.Transform_Handle, sel: []engine.Transform_Handle) -> []inspector.Multi_Peer {
	return inspector.multi_set_peers(editor.multi_transform_peers(active, sel))
}
