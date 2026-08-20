package inspector

// The inspector's field-edit transaction.
//
// One row's edit is a gesture: it starts when the widget is activated, runs for
// however many frames the user drags or types, and ends on release. This wraps
// that gesture in an undo session (docs/Undo.md) covering the active
// object AND every multi-selected peer, so the whole thing is one Ctrl+Z and
// every object's before-state is captured at the same instant.
//
// It replaces the arrangement that produced most of this week's bugs: a
// per-frame pre-image that could be recaptured mid-drag, a preview that had to
// be rewound before recording, a snapshot that only opened on IsItemActivated
// (so picker popups recorded nothing), and an undo group opened after the active
// object had already committed (so undo reverted the peers but not it).
//
// The rule here is narrow: NOTHING in this file inspects widget state to guess
// whether an edit is happening. The caller says when it starts and when it ends.

import "core:slice"
import im "moonhug:external/odin-imgui"
import engine "../../engine"
import "../undo"

// An in-flight row edit. Zero value means "not editing", and every proc below
// tolerates that.
Field_Edit :: struct {
	session:   undo.Edit_Session,
	field_ptr: rawptr, // identifies which row owns this edit
	active:    bool,

	// The row's value when the gesture began, for the fieldwise vector diff.
	// Captured once here rather than re-read per frame — re-reading it is what
	// made the old code lose track of which axis had moved.
	start:     [FIELD_EDIT_START_MAX]byte,
	start_len: int,
}

// Covers the vector rows this applies to ([4]f32 is the widest).
FIELD_EDIT_START_MAX :: 64

@(private)
_field_edit: Field_Edit

// Undo targets a row supplies for itself, when the widget's field is not the
// stored value. nil for ordinary rows.
@(private)
_field_edit_targets: []undo.Edit_Target

field_edit_set_targets :: proc(targets: []undo.Edit_Target) -> []undo.Edit_Target {
	prev := _field_edit_targets
	_field_edit_targets = targets
	return prev
}

// Opens the transaction for the row at `field_ptr`, covering the active object
// and every peer. Idempotent: calling it again for the same row while it is
// already open does nothing, so a drawer can call it on every frame the widget
// is active without tracking state itself.
//
// `owner` is the object the row's field belongs to (a component base or a
// transform); `owner_handle` is its undo identity. Peers come from the ambient
// multi-selection, at the same offset.
// `before_json`, when given, is the ACTIVE object's value from before a change
// the caller ALREADY applied. Pickers need it: their value lands from inside a
// popup with no observable gesture start, so the transaction can only be opened
// after the fact, by which time reading the field would capture the NEW value as
// the old one and undo would do nothing.
//
// It is applied by temporarily writing the old value back while the session
// captures, NOT by handing the payload to the session. An entry records either a
// field or a whole component depending on where the field lives, and a payload
// captured at the wrong granularity corrupts the record — that is what emptied a
// peer's materials array on undo.
field_edit_begin :: proc(
	field_ptr: rawptr,
	field_tid: typeid,
	offset: uintptr,
	label: string,
	before_json: []byte = nil,
) {
	if field_ptr == nil do return
	if _field_edit.active && _field_edit.field_ptr == field_ptr do return
	// A different row's edit was left open — close it rather than lose it.
	if _field_edit.active do field_edit_end()

	// The active object comes from the inspector's owner stack, which already
	// knows whether the row belongs to a pooled component, an asset document or
	// a plain editor struct. Peers are always pooled (a multi-selection is
	// scene objects), and there are none for the other two kinds.
	// A row whose WIDGET edits something other than the stored value supplies
	// its own targets — the Rotation row edits euler caches but must record
	// quaternions. Everything else derives them from the owner stack.
	if _field_edit_targets != nil {
		_field_edit = Field_Edit{
			session   = undo.edit_session_begin(_field_edit_targets, label),
			field_ptr = field_ptr,
			active    = true,
		}
		_field_edit_capture_start(field_ptr, field_tid, before_json)
		return
	}

	targets := make([dynamic]undo.Edit_Target, 0, len(_multi_peers) + 1, context.temp_allocator)
	if o, ok := undo.current_owner(); ok {
		switch o.kind {
		case .None:
		case .Pooled:
			append(&targets, undo.edit_target_pooled(o.handle, field_ptr, field_tid))
		case .Asset:
			append(&targets, undo.edit_target_asset(o.asset_guid, o.asset_tid))
		case .Raw:
			append(&targets, undo.Edit_Target{
				kind = .Raw, raw_ptr = o.base_ptr, raw_tid = o.raw_tid,
				field_ptr = field_ptr, field_tid = field_tid,
			})
		}
	}
	for peer in _multi_peers {
		p := _multi_peer_ptr(peer, offset)
		if p == nil do continue
		append(&targets, undo.edit_target_pooled(peer.handle, p, field_tid))
	}
	if len(targets) == 0 do return

	restore: proc(user: rawptr)
	restore_after: proc(user: rawptr)
	if before_json != nil {
		_rollback = _Rollback{
			field_ptr = field_ptr,
			field_tid = field_tid,
			before    = before_json,
			after     = undo.capture_json(field_ptr, field_tid),
		}
		restore = _rollback_to_before
		restore_after = _rollback_to_after
	}

	_field_edit = Field_Edit{
		session = undo.edit_session_begin(
			targets[:], label,
			restore_before = restore, restore_after = restore_after),
		field_ptr = field_ptr,
		active    = true,
	}
	// The rollback is live only for the duration of edit_session_begin, which has
	// returned. Clearing is unconditional: `before` is the CALLER's buffer and is
	// deleted when the row returns, so leaving it set here leaves a dangling
	// pointer behind a proc that is still callable.
	if _rollback.after != nil do delete(_rollback.after)
	_rollback = {}

	_field_edit_capture_start(field_ptr, field_tid, before_json)
}

// The gesture's starting value, for the fieldwise vector diff.
//
// `before_json` is the row's PRE-DRAWER snapshot and takes precedence: by the
// time a session opens, the drawer has already written this frame's value, so
// reading the field would capture the moved value as the start and every axis
// would compare equal — propagating nothing to the peers.
@(private = "file")
_field_edit_capture_start :: proc(field_ptr: rawptr, field_tid: typeid, before_json: []byte) {
	fti := type_info_of(field_tid)
	if fti == nil || int(fti.size) > FIELD_EDIT_START_MAX do return
	n := int(fti.size)

	if before_json != nil {
		// Decode into a scratch of the field's own type, so the start image is
		// the value as it was before this frame's write.
		scratch: [FIELD_EDIT_START_MAX]byte
		if undo.write_json_value(rawptr(&scratch), field_tid, before_json, nil) {
			copy(_field_edit.start[:n], scratch[:n])
			_field_edit.start_len = n
			return
		}
	}
	copy(_field_edit.start[:n], slice.bytes_from_ptr(field_ptr, n))
	_field_edit.start_len = n
}

// The active object's value on both sides of a picker change, so the session can
// capture the "before" state at each target's own granularity. Lives here rather
// than being passed through because Odin procs are not closures.
@(private = "file")
_Rollback :: struct {
	field_ptr: rawptr,
	field_tid: typeid,
	before:    []byte, // caller-owned
	after:     []byte, // owned here
}

@(private = "file")
_rollback: _Rollback

@(private = "file")
_rollback_to_before :: proc(user: rawptr) {
	if _rollback.field_ptr == nil || _rollback.before == nil do return
	undo.write_json_value(_rollback.field_ptr, _rollback.field_tid, _rollback.before, nil)
}

@(private = "file")
_rollback_to_after :: proc(user: rawptr) {
	if _rollback.field_ptr == nil || _rollback.after == nil do return
	undo.write_json_value(_rollback.field_ptr, _rollback.field_tid, _rollback.after, nil)
}

// Closes the transaction, recording one grouped action for every object whose
// value actually changed. Safe to call when nothing is open.
field_edit_end :: proc() {
	if !_field_edit.active do return
	undo.edit_session_end(&_field_edit.session)
	_field_edit = {}
}

field_edit_in_flight :: proc(field_ptr: rawptr) -> bool {
	return _field_edit.active && _field_edit.field_ptr == field_ptr
}

// Drops an edit whose gesture ended without the row noticing — the panel
// closed, the selection changed, the widget vanished mid-drag. Called once per
// frame before any row draws, with whether ANY imgui widget currently owns
// input: an edit with nothing active is over by definition.
//
// Recording rather than aborting, because the values the user produced are
// already written and should stay undoable.
field_edit_frame_begin :: proc(any_item_active: bool) {
	if _field_edit.active && !any_item_active {
		field_edit_end()
	}
}

// Whether the row's widget is mid-gesture, from the row's own items rather than
// imgui's global item state.
//
// A multi-component row (drag_float3) draws N separate items, so asking imgui
// after the drawer returns only ever describes the LAST component — a drag on X
// or Y looks like nothing happened. drag_row_activated/deactivated latch the
// real answer from inside the row.
//
// A substituted state is AUTHORITATIVE and checked first. Consulting the latched
// flags before it meant a stale latch could both answer the question and be
// consumed, so a harness could not reliably drive a row — the flags are set by
// real drag widgets, which a substituted row never draws.
field_edit_row_started :: proc() -> bool {
	if _widget_state_override != nil {
		drag_row_activated() // consumed, so it cannot leak into the next row
		return _widget_state_override.activated
	}
	if drag_row_activated() do return true
	return im.IsItemActivated()
}

field_edit_row_finished :: proc() -> bool {
	if _widget_state_override != nil {
		drag_row_deactivated()
		return _widget_state_override.deactivated_after_edit
	}
	if drag_row_deactivated() do return true
	return im.IsItemDeactivatedAfterEdit()
}

@(private)
_widget_active :: proc() -> bool {
	if _widget_state_override != nil do return _widget_state_override.active
	return im.IsItemActive()
}

// The imgui item state a row would observe, substitutable so a row can be driven
// without a UI.
//
// Every bug this feature shipped was a MULTI-FRAME sequencing mistake — a value
// copied on a frame with no user gesture, a pre-image recaptured on the commit
// frame, a transaction opened by a button click that changed nothing. None of
// them were reachable from a test that called the procs once, and all of them
// were found by hand in the running editor.
//
// Substituting the three item-state queries is what makes those sequences
// testable: the harness says "frame 2, still dragging", "frame 3, released",
// and the row behaves exactly as it does under imgui. Production leaves this nil
// and calls imgui directly.
Widget_State :: struct {
	activated:              bool, // the gesture began this frame
	active:                 bool, // the widget owns input this frame
	deactivated_after_edit: bool, // the gesture ended this frame
}

@(private)
_widget_state_override: ^Widget_State

// Installs a substitute item state for the rows drawn until it is cleared.
// Test-only: nothing in the editor calls this.
field_edit_set_widget_state :: proc(ws: ^Widget_State) {
	_widget_state_override = ws
}

// Draws one value row and handles its whole edit transaction.
//
// THE single place the begin/apply/end dance lives. It was written twice — once
// in the generic field loop, once for array elements — and the copies drifted:
// the array one kept a picker handling that opened the transaction on every
// frame the row DREW, so merely expanding a materials list copied the active
// object's material onto every selected peer, with no user action. Two call
// sites, one fixed, one not.
//
// Returns whether the edit finished this frame, which callers use to record
// prefab overrides.
// `drawer` and `draw_label` are passed rather than captured: Odin procs are not
// closures, so the row's own values have to travel explicitly.
field_edit_row :: proc(
	field_ptr: rawptr,
	field_tid: typeid,
	offset: uintptr,
	label: string,
	drawer: proc(ptr: rawptr, tid: typeid, label: cstring),
	draw_label: cstring,
) -> (finished: bool) {
	// A picker writes from inside a popup: no drag, no focus, so its gesture has
	// no observable start. Its value is snapshotted before the draw and compared
	// after, and the transaction opened RETROACTIVELY only if it moved.
	//
	// Opening it up front instead is a data-loss bug — the row redraws every
	// frame, so the edit would be permanently in flight and the apply below would
	// copy the active object's value onto every peer continuously.
	// The value BEFORE the drawer runs, for every row.
	//
	// imgui reports a widget's activation only after it has drawn, so on the
	// frame a drag begins the drawer has ALREADY written the first frame's
	// value. Opening the session at that point captures the moved value as the
	// "before" state, and undoing the drag leaves its first frame applied.
	// Holding a pre-drawer snapshot lets a session opened late still record the
	// value the gesture actually started from.
	//
	// Pickers need it for a related reason: their value lands from a popup with
	// no gesture at all, so this is the only "before" that exists.
	picker := _is_picker_type(field_tid)
	before := undo.capture_json(field_ptr, field_tid)
	defer if before != nil do delete(before)

	if drawer != nil do drawer(field_ptr, field_tid, draw_label)
	multi_clear_mixed()

	// Picker rows are excluded from the activation path: they are bracketed
	// retroactively below, and their row contains ordinary buttons (search,
	// clear) whose click is an activation that means nothing about the value.
	// Treating that as an edit opened a transaction and copied the active
	// object's reference onto every peer just for opening the picker.
	//
	// Both are CONSUMED either way: they latch per row, and leaving one set
	// would hand it to whichever row draws next.
	started := field_edit_row_started()
	finished = field_edit_row_finished()

	// Opened with the pre-drawer snapshot, because the drawer has already
	// written this frame's value by now.
	if !picker && started {
		field_edit_begin(field_ptr, field_tid, offset, label, before)
	}
	editing := field_edit_in_flight(field_ptr)
	if editing {
		field_edit_apply_to_peers(field_ptr, field_tid, offset)
	}

	// The picker's value changed: bracket the change that already happened,
	// handing the session the value from before it.
	if picker && !editing && _changed_since(field_ptr, field_tid, before) {
		field_edit_begin(field_ptr, field_tid, offset, label, before)
		field_edit_apply_to_peers(field_ptr, field_tid, offset)
		field_edit_end()
		return true
	}

	// A typed value committed on blur also ends the gesture.
	if !finished && editing && inspector_changed && !_widget_active() {
		finished = true
	}
	if finished && editing {
		field_edit_apply_to_peers(field_ptr, field_tid, offset)
		field_edit_end()
	}
	return finished
}

@(private = "file")
_changed_since :: proc(field_ptr: rawptr, tid: typeid, before: []byte) -> bool {
	if before == nil do return false
	now := undo.capture_json(field_ptr, tid)
	if now == nil do return false
	defer delete(now)
	return !slice.equal(before, now)
}

// Copies the row's current value onto every peer. Called every frame the edit
// is in flight AND on the frame it ends, so the selection tracks the drag live.
//
// It records NOTHING — the session opened at field_edit_begin already holds
// each peer's before-state, so writing here is just writing. That is the whole
// simplification: the previous design had to snapshot peers at commit time,
// which meant rewinding the live preview first so the "old" value was not the
// previewed one.
//
// Fieldwise for vector rows: only components that differ from the value at the
// START of the gesture are copied, so dragging scale.y leaves each peer's own X
// and Z alone. `start` is the row's value when the edit began.
// Records an override for a peer that is prefab-instance content, against ITS
// OWN instance. Plain scene objects have no host and record nothing.
//
// The nested host/local_id pair is ambient (one global set around a draw), so it
// is swapped per peer and put back — writing peers under the active object's
// context would file every override on the wrong instance.
@(private = "file")
_peer_record_override :: proc(peer: Multi_Peer, ptr: rawptr, tid: typeid, property_path: string) {
	if peer.nested_host == {} || peer.nested_lid == 0 do return
	if property_path == "" || ptr == nil do return
	prev_host := engine.inspector_set_nested_host(peer.nested_host)
	prev_lid := engine.inspector_set_nested_local_id(peer.nested_lid)
	record_nested_override(ptr, tid, property_path, true)
	engine.inspector_set_nested_local_id(prev_lid)
	engine.inspector_set_nested_host(prev_host)
}

// The property path of the row currently being applied, so peers can record
// their overrides. Set by the field loop, which is the only place that knows it.
@(private)
_field_edit_path: string

field_edit_set_path :: proc(path: string) -> string {
	prev := _field_edit_path
	_field_edit_path = path
	return prev
}

field_edit_apply_to_peers :: proc(field_ptr: rawptr, field_tid: typeid, offset: uintptr) {
	if field_ptr == nil || len(_multi_peers) == 0 do return
	start := _field_edit.start[:_field_edit.start_len] if _field_edit.field_ptr == field_ptr else nil

	elem_size, elem_count := _scalar_array_shape(field_tid)
	fti := type_info_of(field_tid)
	if fti == nil do return
	total := int(fti.size)

	// Not a vector row, or no usable start image: the value is written whole.
	// Correct for scalars, strings, refs and enums, which drawers replace
	// entirely rather than component-wise.
	if elem_count == 0 || len(start) < total {
		for peer in _multi_peers {
			p := _multi_peer_ptr(peer, offset)
			if p == nil do continue
			_write_value(p, field_ptr, field_tid, peer.scene)
			_peer_record_override(peer, p, field_tid, _field_edit_path)
		}
		mark_inspector_changed()
		return
	}

	for i in 0 ..< elem_count {
		cur := rawptr(uintptr(field_ptr) + uintptr(i * elem_size))
		was := rawptr(uintptr(raw_data(start)) + uintptr(i * elem_size))
		if _bytes_equal(cur, was, elem_size) do continue // axis the user never moved
		for peer in _multi_peers {
			p := _multi_peer_ptr(peer, offset)
			if p == nil do continue
			src := slice.bytes_from_ptr(cur, elem_size)
			dst := slice.bytes_from_ptr(rawptr(uintptr(p) + uintptr(i * elem_size)), elem_size)
			copy(dst, src)
		}
	}
	// Once for the whole field, not per component: an override names the field.
	for peer in _multi_peers {
		p := _multi_peer_ptr(peer, offset)
		if p == nil do continue
		_peer_record_override(peer, p, field_tid, _field_edit_path)
	}
	mark_inspector_changed()
}

// Whole-value write through the serialization path, so a field owning heap
// memory (string, dynamic array, a Ref with a resolved handle) gives each peer
// its OWN copy rather than a shared backing pointer.
@(private = "file")
_write_value :: proc(dst, src: rawptr, tid: typeid, scene: ^engine.Scene) {
	json_bytes := undo.capture_json(src, tid)
	if json_bytes == nil do return
	defer delete(json_bytes)
	undo.write_json_value(dst, tid, json_bytes, scene)
}

// A STRUCTURAL edit: one that changes an object's shape rather than a field's
// value — adding or removing an array element, switching a union variant,
// invoking an inspector button.
//
// These have no gesture to bracket: they happen entirely within one click, and
// what changed cannot be named by a field offset (a union's payload type
// differs, an array's elements move). So the whole owner is recorded, which is
// what comp_snapshot/comp_commit did — but through a session, so the owner and
// every multi-selected peer land in ONE undo step instead of the active object
// alone.
//
// Usage is a bracket around the mutation:
//
//     sess := structural_edit_begin("Add Element")
//     mutate(...)
//     structural_edit_end(&sess)
structural_edit_begin :: proc(label := "Edit") -> undo.Edit_Session {
	targets := make([dynamic]undo.Edit_Target, 0, len(_multi_peers) + 1, context.temp_allocator)

	// The active object, from the inspector's owner stack. field_ptr is nil, so
	// the session records the WHOLE target — see edit_session_begin.
	if o, ok := undo.current_owner(); ok {
		switch o.kind {
		case .None:
		case .Pooled:
			append(&targets, undo.edit_target_whole(o.handle))
		case .Asset:
			append(&targets, undo.edit_target_asset(o.asset_guid, o.asset_tid))
		case .Raw:
			append(&targets, undo.Edit_Target{kind = .Raw, raw_ptr = o.base_ptr, raw_tid = o.raw_tid})
		}
	}
	for peer in _multi_peers {
		if peer.base == nil do continue
		append(&targets, undo.edit_target_whole(peer.handle))
	}
	if len(targets) == 0 do return {}
	return undo.edit_session_begin(targets[:], label)
}

structural_edit_end :: proc(sess: ^undo.Edit_Session) {
	undo.edit_session_end(sess)
	mark_inspector_changed()
}
