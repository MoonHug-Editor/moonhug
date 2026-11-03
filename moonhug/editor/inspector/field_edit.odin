package inspector

// The inspector's field-edit transaction.
//
// One row's edit is a gesture: it starts when the widget is activated, runs for
// however many frames the user drags or types, and ends on release. This wraps
// that gesture in an undo session (docs/core/Undo.md) covering the active
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
import core "moonhug:libs/core"
import undo "moonhug:editor/undo"

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
		if undo.write_json_value(rawptr(&scratch), field_tid, before_json, {}) {
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
	undo.write_json_value(_rollback.field_ptr, _rollback.field_tid, _rollback.before, {})
}

@(private = "file")
_rollback_to_after :: proc(user: rawptr) {
	if _rollback.field_ptr == nil || _rollback.after == nil do return
	undo.write_json_value(_rollback.field_ptr, _rollback.field_tid, _rollback.after, {})
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
	_driven_edit_frame_begin(any_item_active)
}

// Whether the row's widget is mid-gesture. The drawer ran inside a group, so
// imgui's item state here describes the whole row: a multi-component row
// (drag_float3) draws N separate items, and EndGroup forwards whichever one
// had the gesture.
//
// A substituted state is AUTHORITATIVE. Otherwise imgui's item state is read,
// which after the drawer's group describes the whole row.
field_edit_row_started :: proc() -> bool {
	if _widget_state_override != nil do return _widget_state_override.activated
	return im.IsItemActivated()
}

field_edit_row_finished :: proc() -> bool {
	if _widget_state_override != nil do return _widget_state_override.deactivated_after_edit
	return im.IsItemDeactivatedAfterEdit()
}

@(private)
_widget_active :: proc() -> bool {
	if _widget_state_override != nil do return _widget_state_override.active
	return im.IsItemActive()
}

// The mouse is over the row: a right click or a wheel turn writes with no
// activation. Under the test override the row is driven by the state alone.
@(private)
_widget_hovered :: proc() -> bool {
	if _widget_state_override != nil do return false
	return im.IsItemHovered()
}

// A row whose value widget opens a popup (the color swatch's picker) reports
// the popup as open through this latch, from inside its drawer. Consumed by
// the row, so it cannot leak into the next one.
@(private = "file")
_row_hold: bool

// The row clicked on the frame a popup opened owns that popup, the gradient
// and curve editors: the row is held while any popup stays open, and the
// popup's writes record like the latch above. A drawer calls nothing for it.
// Cleared by the row once no popup is open.
@(private = "file")
_popup_owner: rawptr

@(private)
_any_popup_open :: proc() -> bool {
	if _widget_state_override != nil do return _widget_state_override.popup
	return im.IsPopupOpen("", im.PopupFlags_AnyPopup)
}

field_edit_row_hold :: proc() {
	_row_hold = true
}

@(private)
field_edit_row_held :: proc() -> bool {
	if _widget_state_override != nil {
		_row_hold = false
		return _widget_state_override.held
	}
	v := _row_hold
	_row_hold = false
	return v
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
	held:                   bool, // a popup owned by the row is open this frame
	popup:                  bool, // any popup is open this frame (see _popup_owner)
}

@(private)
_widget_state_override: ^Widget_State

// Installs a substitute item state for the rows drawn until it is cleared.
// Test-only: nothing in the editor calls this.
field_edit_set_widget_state :: proc(ws: ^Widget_State) {
	_widget_state_override = ws
}

// One edit of a value as one row: the value is snapshotted before the
// widgets draw and compared after, the change becomes one undo step and lands
// on every selected object, and the prefab override is recorded.
//
// The inspector opens it for every row (Ctx._row, a field or an array
// element), around the row's chain (_draw_row), and a drawer calls nothing:
// - a leaf value (is_row_kind) gets a real edit
// - a container with steps gets a provisional edit: it does not enclose the
//   rows drawn inside it, so each of them opens its own edit. When one opens
//   during the chain, or an undo step lands (an array's add button), the
//   provisional edit is dropped and records nothing. Otherwise the drawer
//   drew the value as one widget and the edit records it like a real one,
//   with its session opened on the first frame the value changed
// - a container without steps opens nothing: its rows open their own
// A driven row's edit is always real: the driven value is one value, drawn
// on a buffer, and rows inside it are nested.
//
// edit_as_one_begin and edit_as_one_end open a real edit by hand. Only a
// drawer that draws sub-rows (field_edit_row, the default drawing) and wants
// all of it recorded as one step needs them: the sub-rows nest into it.
// Off a row, a bare draw_value from custom code, the pair does nothing: that
// code runs its own edits or none. A custom row passes its widgets to
// field_edit_row.
//
// Nested edits of one row collapse into the outer one: a custom row that
// wraps a registered drawer with field_edit_row, or a drawer that draws
// another drawer, records once.
Edit :: struct {
	ptr:        rawptr, // the live value
	tid:        typeid,
	offset:     uintptr,
	label:      string,
	draw_label: cstring,
	// The pointer the widgets draw on: the live value, or a driven row's
	// buffer (driven.odin). edit_begin redirects ctx.ptr to it, edit_end
	// puts ctx.ptr back.
	cur:        rawptr,
	nested:     bool, // inside another edit of a row: this one does nothing
	// A container's edit that encloses nothing (see above). edits_before and
	// mutations_before tell whether a row inside opened an edit or an undo
	// step landed, which drops it.
	provisional: bool,
	dropped:    bool,
	edits_before: int,
	mutations_before: u64,
	bare:       bool, // off a row (a bare draw_value): no edit at all
	driven:     bool, // the row is driven: _driven_edit holds its value
	grouped:    bool,
	picker:     bool,
	before:     []byte,
	owns_before: bool,
	prev_changed: bool, // driven rows: the changed flag before the widgets
	prev_path:  string,
	path:       string, // the property path, for the override record
	finished:   bool,
}

@(private = "file")
_edit_depth: int
// Real edits opened so far, and provisional edits that recorded: a
// provisional edit compares it around its chain.
@(private)
_edit_count: int

// The driven value of the row being edited. Not a field of Edit: an Edit is
// returned by value, and the widgets draw on a pointer into this, which has
// to stay put. One at a time: a nested edit never queries the driver, and a
// driven edit is real, so every edit inside it is nested.
@(private = "file")
_driven_edit: Driven_Value

// Opens a real edit of the value `ctx` draws as one row, with `ctx.offset`,
// `ctx.name` and `ctx.path` from the field loop. For a drawer that draws
// sub-rows and wants them recorded as one step (see above). Does nothing off
// a row (ctx._row false). Redirects ctx.ptr for a driven row, so the widgets
// read ctx.ptr AFTER this call.
edit_as_one_begin :: proc(ctx: ^Ctx) -> Edit {
	return _edit_value_begin(ctx, provisional = false)
}

// The row's edit, real or provisional, opened by _draw_row or by the pair.
@(private)
_edit_value_begin :: proc(ctx: ^Ctx, provisional: bool) -> Edit {
	if !ctx._row do return Edit{ptr = ctx.ptr, cur = ctx.ptr, tid = ctx.tid, bare = true}
	e := _edit_begin(ctx.ptr, ctx.tid, ctx.offset, ctx.name, ctx.label, nil, provisional = provisional)
	e.path = ctx.path
	if !e.nested && ctx.path != "" do e.prev_path = field_edit_set_path(ctx.path)
	ctx.ptr = e.cur
	return e
}

// Closes it: compares, records, applies to the peers, records the override.
// A dropped provisional edit only puts ctx.ptr and the path back.
edit_as_one_end :: proc(ctx: ^Ctx, e: ^Edit) -> (finished: bool) {
	if e.bare do return false
	ctx.ptr = e.ptr
	finished = _edit_end(e)
	if !e.nested && e.path != "" {
		field_edit_set_path(e.prev_path)
		record_nested_override(e.ptr, e.tid, e.path, finished)
	}
	return finished
}

// Draws one field through `drawer` as one row. A nil drawer means a decorator
// drew the row already and only the edit tracking is wanted. `pre_before`
// hands in a snapshot taken earlier (a caller that drew before calling).
// Returns whether an edit of the row ended this frame.
field_edit_row :: proc(
	field_ptr: rawptr,
	field_tid: typeid,
	offset: uintptr,
	label: string,
	drawer: proc(ptr: rawptr, tid: typeid, label: cstring),
	draw_label: cstring,
	pre_before: []byte = nil,
) -> (finished: bool) {
	e := _edit_begin(field_ptr, field_tid, offset, label, draw_label, pre_before, has_drawer = drawer != nil)
	if drawer != nil do drawer(e.cur, field_tid, draw_label)
	return _edit_end(&e)
}

@(private = "file")
_edit_begin :: proc(field_ptr: rawptr, field_tid: typeid, offset: uintptr, label: string, draw_label: cstring, pre_before: []byte, has_drawer := true, provisional := false) -> (e: Edit) {
	e.ptr, e.cur, e.tid, e.offset, e.label, e.draw_label = field_ptr, field_ptr, field_tid, offset, label, draw_label
	// Inside another row's edit: the outer one records.
	if _edit_depth > 0 {
		e.nested = true
		_edit_depth += 1
		return
	}
	// A driven field (driven.odin) shows the driven value. Asked for the active
	// object only: peers are not queried. A row drawn by a decorator (no
	// drawer) is handled by the field loop, which redirects the decorator.
	// No drawer: a decorator drew the row before this edit, so an empty group
	// here would hide its items' gesture. The item state is the decorator's.
	e.grouped = _widget_state_override == nil && has_drawer
	if has_drawer do _driven_edit = driven_query_field(field_ptr, field_tid)
	driven := has_drawer && _driven_edit.state != .None
	// A provisional edit encloses nothing: the rows inside see depth 0 and
	// open their own edits. A driven one is real (see Edit).
	if provisional && !driven {
		e.provisional = true
		e.edits_before = _edit_count
		e.mutations_before = undo.mutation_count()
	} else {
		_edit_depth += 1
		_edit_count += 1
	}
	if driven {
		// The widgets draw on a buffer, never on the live field, and the
		// driven lanes reach neither the object, the scene undo stack, the
		// prefab overrides nor the peers (see _edit_end).
		e.driven = true
		multi_clear_mixed()
		e.prev_changed = consume_inspector_changed()
		e.cur = rawptr(&_driven_edit.value)
		if _driven_edit.state == .Editable do e.cur = driven_edit_buffer(field_ptr, &_driven_edit.value)
		if e.grouped do driven_draw_begin(_driven_edit.state, _driven_edit.own)
		return
	}

	// A picker writes from inside a popup: no drag, no focus, so its gesture has
	// no observable start. Its value is snapshotted before the draw and compared
	// after, and the transaction opened RETROACTIVELY only if it moved.
	//
	// Opening it up front instead is a data-loss bug — the row redraws every
	// frame, so the edit would be permanently in flight and the apply below would
	// copy the active object's value onto every peer continuously.
	// The value BEFORE the widgets run, for every row.
	//
	// imgui reports a widget's activation only after it has drawn, so on the
	// frame a drag begins the widgets have ALREADY written the first frame's
	// value. Opening the session at that point captures the moved value as the
	// "before" state, and undoing the drag leaves its first frame applied.
	// Holding a pre-draw snapshot lets a session opened late still record the
	// value the gesture actually started from.
	//
	// Pickers need it for a related reason: their value lands from a popup with
	// no gesture at all, so this is the only "before" that exists.
	e.picker = _is_picker_type(field_tid)
	e.owns_before = pre_before == nil
	e.before = e.owns_before ? undo.capture_json(field_ptr, field_tid) : pre_before
	// Mixed-value display for the selection, read by the widgets.
	multi_probe_field(field_ptr, field_tid, offset)
	// The widgets run inside a group. imgui's EndGroup forwards the active
	// item, its deactivation and its edited flag to the group, so the item
	// state read in _edit_end describes EVERY item the row emitted, not the
	// last one. A row is one gesture no matter how many items draw it: a
	// three-component drag, a slider's track plus value box, a picker's button
	// and clear. Without this, a gesture on any item but the last was
	// invisible, and each such row needed its own patch.
	//
	// Under the widget-state override (the test harness) there is no imgui
	// context and the override IS the row's item state, so no group.
	if e.grouped do im.BeginGroup()
	return
}

@(private = "file")
_edit_end :: proc(e: ^Edit) -> (finished: bool) {
	if !e.provisional do _edit_depth -= 1
	if e.nested do return false
	if e.driven {
		// read-only: the buffer is the driven value, reseeded every frame, and
		// an edit of a driven lane is dropped; an edit of a lane the driver
		// leaves to the object (dv.own) is an ordinary edit of it
		// (driven_own_lanes_edit). editable: the buffer lives across the frames
		// of one gesture, and when the gesture ends the edited value goes to
		// driven_commit. The widgets' changed flag is dropped too, unless an
		// own lane changed the object.
		if e.grouped do driven_draw_end(_driven_edit.state, _driven_edit.keyed)
		consume_inspector_changed()
		defer if e.prev_changed do mark_inspector_changed()
		if _driven_edit.state == .Editable {
			driven_edit_finish(e.ptr, e.cur, &_driven_edit)
			return false
		}
		active, ended := driven_gesture_state()
		return driven_own_lanes_edit(e.ptr, e.cur, &_driven_edit, e.offset, e.label, active, ended)
	}
	defer if e.owns_before && e.before != nil do delete(e.before)
	// A row inside opened its edit, or an undo step landed: the value is
	// rows of its own, or a structural edit recorded it already.
	if e.provisional {
		e.dropped = _edit_count != e.edits_before || undo.mutation_count() != e.mutations_before
	}
	// A field with a row in the shown clip gets its mark beside the group.
	if e.grouped {
		im.EndGroup()
		if !e.dropped do driven_mark_field(e.ptr, e.tid)
	}
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
	held := field_edit_row_held()
	// The row that opened the popup now open is held (see _popup_owner). A
	// picker brackets its popup's write on its own below.
	if !e.picker {
		open := _any_popup_open()
		if !open && _popup_owner == e.ptr do _popup_owner = nil
		if open && started do _popup_owner = e.ptr
		if open && _popup_owner == e.ptr do held = true
	}
	// The row's value moved this frame: the inspector marks it, a drawer
	// calls nothing for that (mark_inspector_changed is for a change outside
	// the value). Compared on a frame the row is touched, active or under the
	// mouse, so idle rows cost nothing, and every frame for a picker and a
	// provisional edit, whose change lands without a gesture. A dropped
	// provisional edit compares too: a step's own widget above the rows
	// inside.
	touched := started || finished || held || _widget_active() || _widget_hovered() || field_edit_in_flight(e.ptr) || e.picker || e.provisional
	moved := touched && _changed_since(e.ptr, e.tid, e.before)
	if moved do mark_inspector_changed()
	if e.dropped do return false
	// Recorded like a real edit: it counts for a provisional edit around it.
	if e.provisional do _edit_count += 1

	// Opened with the pre-draw snapshot, because the widgets have already
	// written this frame's value by now.
	if !e.picker && !e.provisional && started {
		field_edit_begin(e.ptr, e.tid, e.offset, e.label, e.before)
	}
	editing := field_edit_in_flight(e.ptr)
	// A provisional edit cannot tell an activation on the value from one on
	// a foldout or a button inside the chain, so its session opens on the
	// first frame the value changed, with that frame's pre-draw snapshot. A
	// click that changes nothing then copies nothing onto the peers.
	if e.provisional && !e.picker && !editing && moved {
		field_edit_begin(e.ptr, e.tid, e.offset, e.label, e.before)
		editing = true
	}
	if editing {
		field_edit_apply_to_peers(e.ptr, e.tid, e.offset)
	}

	// A popup owned by the row is open (the color picker). Its writes come
	// with no activation on the row, so a change opens the session
	// retroactively with the pre-draw value, and the session then rides the
	// popup's own drag: field_edit_frame_begin ends it on the frame no item
	// is active any more, which is the mouse release inside the popup. Each
	// drag in the popup is one undo step. The blur rule below must not see
	// these frames: the row's own widget is never active while the popup has
	// the mouse, and it would end the session every frame.
	if held {
		if !editing && moved {
			field_edit_begin(e.ptr, e.tid, e.offset, e.label, e.before)
			editing = true
		}
		if editing do field_edit_apply_to_peers(e.ptr, e.tid, e.offset)
		return false
	}

	// The picker's value changed: bracket the change that already happened,
	// handing the session the value from before it.
	if e.picker && !editing && moved {
		field_edit_begin(e.ptr, e.tid, e.offset, e.label, e.before)
		field_edit_apply_to_peers(e.ptr, e.tid, e.offset)
		field_edit_end()
		return true
	}

	// A typed value committed on blur also ends the gesture.
	if !finished && editing && inspector_changed && !_widget_active() {
		finished = true
	}
	if finished && editing {
		field_edit_apply_to_peers(e.ptr, e.tid, e.offset)
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
	prev_host := core.inspector_set_nested_host(peer.nested_host)
	prev_lid := core.inspector_set_nested_local_id(peer.nested_lid)
	record_nested_override(ptr, tid, property_path, true)
	core.inspector_set_nested_local_id(prev_lid)
	core.inspector_set_nested_host(prev_host)
}

// For rows that write their peers themselves (the RectTransform inspector's
// derived rows): records the override on the peer's own instance.
record_peer_override :: proc(peer: Multi_Peer, ptr: rawptr, tid: typeid, property_path: string) {
	_peer_record_override(peer, ptr, tid, property_path)
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
_write_value :: proc(dst, src: rawptr, tid: typeid, scene: core.Scene_Ref) {
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
