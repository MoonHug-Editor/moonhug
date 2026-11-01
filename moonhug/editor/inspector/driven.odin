package inspector

// Driven values: a field whose shown value comes from some system other than
// the object itself (the Animation window's preview pose). The inspector shows
// that value instead of the field's own value.
//
// Five seams, nil by default, plus three tooltip texts. A plugin installs
// them at EditorInit:
//   - driven_provider answers whether a field is driven, with its value
//   - driven_commit takes an edit of a driven field (Record keys the clip)
//   - driven_row_state answers whether the field has a row in the shown
//     clip, whether a key can be added for it, and whether the playhead's
//     frame has a key
//   - driven_add_key keys a value of the field ("Add Key" in its menu)
//   - driven_delete_key deletes the key on the playhead's frame ("Delete Key")
//
// field_edit_row, the transform rows and decorator-drawn rows ask the provider
// for the active object's field before they draw:
//   - not driven: the row draws the field as usual
//   - driven, read-only: the row draws the driven value, tinted, and ignores
//     edits. The buffer is reseeded every frame, so an edit cannot stick. No
//     edit session, no undo, no override record, no multi-edit
//   - driven, editable: the row draws the driven value, tinted red, and hands
//     the edited value to driven_commit when the gesture ends. The live field
//     is never written and no scene edit session runs: "before" for such a
//     session would be the object's own value, so an edit back to that value
//     would record nothing
//
// The live field holds the object's own value while the inspector draws, so a
// driven row never reads it.
//
// A vector field can be driven in some lanes only (a clip row with disabled
// lanes): the provider names the lanes it leaves to the object (`own`), and
// fills them with the object's own value. The row draws those lanes in the
// normal colors. On a read-only row an edit of one of them changes the object
// as an ordinary row does: one undoable edit of the live field, which the
// driver leaves alone (driven_own_lanes_edit). On an editable row an edit of
// any lane goes to driven_commit, as every edit does while recording.
//
// A field that is not driven but has a row (driven_row_state) gets a mark: the
// driven bar in the gutter (gutter.odin), in a quieter color. A driven row also shows a
// filled diamond when the playhead's frame has a key for it. The field's
// context menu shows "Add Key" or "Delete Key" while the field can be keyed,
// which is while recording. Add Key keys the value the row shows: the driven
// value on a driven row, the live value on any other.

import "core:fmt"
import "core:mem"
import im "moonhug:external/odin-imgui"
import core "moonhug:libs/core"
import undo "moonhug:editor/undo"
import "moonhug:editor/widgets"

// For the field at `field_offset` bytes from the pooled `owner`'s base (a
// component or a transform handle) of type `field_tid`: when something drives
// the field now, writes the driven value into `out` (size_of(field_tid) bytes,
// the field's own type) and returns driven=true. `editable` says an edit of
// the field goes somewhere. Called per field per frame, so it must be cheap.
// `own` names the lanes of a vector field the driver leaves to the object:
// `out` holds the object's own value in them. Empty for a field driven whole.
driven_provider: proc(owner: core.Handle, field_offset: uintptr, field_tid: typeid, out: rawptr) -> (driven: bool, editable: bool, own: Driven_Lanes)

// Lanes of a vector field, 0 x to 3 w.
Driven_Lanes :: bit_set[0 ..< 4; u8]

// Takes an edit of a driven, editable field: `value` holds the edited value in
// the field's own type. Called once per gesture, when it ends. Returns false
// when the edit went nowhere. Without it every driven field is read-only.
driven_commit: proc(owner: core.Handle, field_offset: uintptr, field_tid: typeid, value: rawptr) -> bool

// For the same field: whether the clip the plugin shows has a row for it
// (`has_row`), and whether a key can be added for it now (`keyable`). Called
// per field per frame for the mark and the context menu, so it must be cheap
// and allocate nothing beyond temp.
driven_row_state: proc(owner: core.Handle, field_offset: uintptr, field_tid: typeid) -> (has_row, keyable, keyed: bool)

// Deletes the row's key on the playhead's frame (a row left without keys
// goes with it). One undo step. False when there is no such key.
driven_delete_key: proc(owner: core.Handle, field_offset: uintptr, field_tid: typeid) -> bool

// Keys `value` (the field's own type) at the playhead, creating the row when
// it is missing, as one undo step. Returns false when the field is not
// keyable. Unlike driven_commit it needs no recording gesture.
driven_add_key: proc(owner: core.Handle, field_offset: uintptr, field_tid: typeid, value: rawptr) -> bool

// Tooltips the provider's owner sets for driven rows and the "Add Key" menu
// item, "" for none.
driven_tooltip_read_only: cstring
driven_tooltip_editable: cstring
driven_tooltip_add_key: cstring

// Text colors of a driven field, full alpha: green while the preview drives
// it, red while recording. The green has a darker shade for light themes,
// where a bright green is hard to read on a bright background.
DRIVEN_READ_ONLY_TEXT_COLOR_DARK_THEME :: im.Vec4{0.35, 0.80, 0.45, 1.0}
DRIVEN_READ_ONLY_TEXT_COLOR_LIGHT_THEME :: im.Vec4{0.08, 0.50, 0.22, 1.0}
DRIVEN_EDITABLE_TEXT_COLOR :: im.Vec4{0.95, 0.35, 0.35, 1.0}

// How far a driven field's frame background moves toward the tint.
DRIVEN_FRAME_BLEND :: f32(0.3)

// How far the mark of a field with a row moves from the theme's disabled text
// color toward the read-only tint: a dimmed green.
DRIVEN_MARK_BLEND :: f32(0.5)

Driven_State :: enum u8 {
	None,
	Read_Only,
	Editable,
}

// Covers every animatable field ([4]f32 is the widest).
DRIVEN_VALUE_MAX :: 64

// One driven field's answer. `value` is the buffer a row's widget draws on,
// `start` the driven value as the provider gave it. `owner`, `offset` and
// `tid` name the field for driven_commit.
Driven_Value :: struct {
	state:  Driven_State,
	keyed:  bool,         // the row has a key on the playhead's frame
	own:    Driven_Lanes, // lanes left to the object (driven_provider)
	owner:  core.Handle,
	offset: uintptr,
	tid:    typeid,
	value:  [DRIVEN_VALUE_MAX / 8]u64, // u64 lanes keep any field type aligned
	start:  [DRIVEN_VALUE_MAX / 8]u64,
}

// Asks the provider about the field at `field_offset` of `owner`.
driven_query :: proc(owner: core.Handle, field_offset: uintptr, field_tid: typeid) -> (dv: Driven_Value) {
	if driven_provider == nil || field_tid == nil do return
	ti := type_info_of(field_tid)
	if ti == nil || ti.size > DRIVEN_VALUE_MAX do return
	driven, editable, own := driven_provider(owner, field_offset, field_tid, &dv.value)
	if !driven do return {}
	dv.own = own
	dv.state = editable && driven_commit != nil ? .Editable : .Read_Only
	_, _, dv.keyed = driven_row_query(owner, field_offset, field_tid)
	dv.owner = owner
	dv.offset = field_offset
	dv.tid = field_tid
	dv.start = dv.value
	return
}

// Asks the provider about the row at `field_ptr`, with the owner from the
// inspector's owner stack.
driven_query_field :: proc(field_ptr: rawptr, field_tid: typeid) -> Driven_Value {
	if driven_provider == nil do return {}
	owner, offset, ok := _driven_field_owner(field_ptr)
	if !ok do return {}
	return driven_query(owner, offset, field_tid)
}

// The owner and offset of the row at `field_ptr`, from the inspector's owner
// stack. Only a pooled owner can be driven, and only a field inside the
// owner's own memory: a dynamic-array element lives elsewhere. A field inside
// a fixed array is left to the plugin, which resolves no path into an array.
@(private = "file")
_driven_field_owner :: proc(field_ptr: rawptr) -> (owner: core.Handle, offset: uintptr, ok: bool) {
	if field_ptr == nil do return
	o, has := undo.current_owner()
	if !has || o.kind != .Pooled || o.base_ptr == nil do return
	// The owner's memory is [base, base + size of the owner's type). A field
	// pointer outside it (a heap array element) has no offset in the owner.
	owner_tid := core.get_typeid_by_type_key(o.handle.type_key)
	if owner_tid == nil do return
	base := uintptr(o.base_ptr)
	if uintptr(field_ptr) < base || uintptr(field_ptr) >= base + uintptr(type_info_of(owner_tid).size) do return
	return o.handle, uintptr(field_ptr) - base, true
}

// Asks driven_row_state about the field at `field_offset` of `owner`.
driven_row_query :: proc(owner: core.Handle, field_offset: uintptr, field_tid: typeid) -> (has_row, keyable, keyed: bool) {
	if driven_row_state == nil || field_tid == nil do return
	return driven_row_state(owner, field_offset, field_tid)
}

// --- Drawing -------------------------------------------------------------------------
//
// The tint is drawn at full alpha: green for a read-only driven field, red for
// a recording one, the same in every theme.
// The text (label and value) takes the tint, the frame background is blended
// toward it, and a bar in the gutter marks the row at a glance. No
// BeginDisabled: it multiplies alpha, which some themes fade to nothing.

// The tint color of a driven row.
driven_tint :: proc(state: Driven_State) -> im.Vec4 {
	if state == .Editable do return DRIVEN_EDITABLE_TEXT_COLOR
	// A light theme has a bright window background: its luminance tells the
	// two apart. Not the text color, which a row may have pushed (the override
	// blue), so one theme gets one green on every row and in the gutter.
	b := im.GetStyleColorVec4(.WindowBg)^
	if 0.299 * b.x + 0.587 * b.y + 0.114 * b.z > 0.5 do return DRIVEN_READ_ONLY_TEXT_COLOR_LIGHT_THEME
	return DRIVEN_READ_ONLY_TEXT_COLOR_DARK_THEME
}

// The mark color of a field with a row that is not driven now.
driven_mark_color :: proc() -> im.Vec4 {
	return _driven_blend(im.GetStyleColorVec4(.TextDisabled)^, driven_tint(.Read_Only), DRIVEN_MARK_BLEND)
}

@(private = "file")
_driven_blend :: proc(base, tint: im.Vec4, t := DRIVEN_FRAME_BLEND) -> im.Vec4 {
	c := base + (tint - base) * t
	c.w = 1
	return c
}

// The row's bar in the gutter (gutter.odin), from the row's top-left corner
// `rmin` down to `rmax`.
@(private = "file")
_driven_bar :: proc(rmin, rmax: im.Vec2, color: im.Vec4) {
	gutter_bar(.Animation, rmin, rmax, color)
}

// The lanes of the row being drawn that the driver leaves to the object, and
// the colors before the tint, so a vector widget draws those lanes plain
// (driven_lane_style_begin). Set from driven_draw_begin to driven_draw_end.
@(private = "file")
_driven_row_own: Driven_Lanes

@(private = "file")
_driven_row_plain: [4]im.Vec4

// Opens a driven row: pushes the tint and opens the group the row's widgets
// draw in. `own` names the lanes the row draws in the plain colors. Pair with
// driven_draw_end.
driven_draw_begin :: proc(state: Driven_State, own := Driven_Lanes{}) {
	if state == .None do return
	_driven_row_own = own
	_driven_row_plain = {
		im.GetStyleColorVec4(.Text)^,
		im.GetStyleColorVec4(.FrameBg)^,
		im.GetStyleColorVec4(.FrameBgHovered)^,
		im.GetStyleColorVec4(.FrameBgActive)^,
	}
	tint := driven_tint(state)
	im.PushStyleColorImVec4(.Text, tint)
	im.PushStyleColorImVec4(.FrameBg, _driven_blend(im.GetStyleColorVec4(.FrameBg)^, tint))
	im.PushStyleColorImVec4(.FrameBgHovered, _driven_blend(im.GetStyleColorVec4(.FrameBgHovered)^, tint))
	im.PushStyleColorImVec4(.FrameBgActive, _driven_blend(im.GetStyleColorVec4(.FrameBgActive)^, tint))
	im.BeginGroup()
}

// Closes the group, pops the tint, marks the row and sets its tooltip. The
// group stays the last item, so imgui's item state describes the whole row.
// A filled diamond in the gutter marks a row whose playhead frame has a
// key. No key, no mark. With `marks` false it only closes the
// group and pops the tint: the group drew no field (a decorator that draws a
// header alone).
driven_draw_end :: proc(state: Driven_State, keyed := false, marks := true) {
	if state == .None do return
	_driven_row_own = {}
	im.EndGroup()
	im.PopStyleColor(4)
	if !marks do return
	rmin, rmax := im.GetItemRectMin(), im.GetItemRectMax()
	tint := driven_tint(state)
	_driven_bar(rmin, rmax, tint)
	_driven_diamond(rmin, rmax, tint, keyed)
	text := state == .Editable ? driven_tooltip_editable : driven_tooltip_read_only
	if text != "" do widgets.tooltip(text)
}

// Called by a vector widget around lane `lane` of the row being drawn: a
// lane the driver leaves to the object draws in the colors from before the
// tint. Returns whether colors were pushed, for driven_lane_style_end.
driven_lane_style_begin :: proc(lane: int) -> bool {
	if lane < 0 || lane >= 4 || lane not_in _driven_row_own do return false
	im.PushStyleColorImVec4(.Text, _driven_row_plain[0])
	im.PushStyleColorImVec4(.FrameBg, _driven_row_plain[1])
	im.PushStyleColorImVec4(.FrameBgHovered, _driven_row_plain[2])
	im.PushStyleColorImVec4(.FrameBgActive, _driven_row_plain[3])
	return true
}

driven_lane_style_end :: proc(pushed: bool) {
	if pushed do im.PopStyleColor(4)
}

// After a read-only driven row drew on `buf` (seeded with the driven value,
// the object's own value in the lanes dv.own): an edit of one of those lanes
// is an ordinary edit of the object. The first changed frame opens the row's
// undo session (field_edit_begin, as an ordinary row does), the changed lanes
// are written to the live field, and the session ends with the gesture. The
// driven lanes of `buf` are never written: the driver owns them. `active`
// and `finished` are the row's gesture state (driven_gesture_state). Returns
// whether the edit ended this frame, the moment a caller records a prefab
// override. The field's lanes are f32 (a vector field).
driven_own_lanes_edit :: proc(field_ptr, buf: rawptr, dv: ^Driven_Value, offset: uintptr, label: string, active, finished: bool) -> (ended: bool) {
	if dv.state != .Read_Only || dv.own == {} || field_ptr == nil do return false
	src := cast([^]f32)buf
	dst := cast([^]f32)field_ptr
	lanes := type_info_of(dv.tid).size / size_of(f32)
	moved := false
	for l in dv.own {
		assert(l < lanes, "driven: an own lane lies inside the field")
		if src[l] != dst[l] do moved = true
	}
	if moved {
		if !field_edit_in_flight(field_ptr) do field_edit_begin(field_ptr, dv.tid, offset, label)
		for l in dv.own do dst[l] = src[l]
		mark_inspector_changed()
	}
	if field_edit_in_flight(field_ptr) && (finished || !active) {
		field_edit_end()
		return true
	}
	return false
}

// The key diamond of a driven row whose playhead frame has a key, at its spot
// in the gutter, centred on the row's height.
@(private = "file")
_driven_diamond :: proc(rmin, rmax: im.Vec2, color: im.Vec4, keyed: bool) {
	if !keyed do return
	gutter_diamond(rmin, rmax, color)
}

// Marks a row that is not driven when its field has a row in the shown clip:
// the bar a driven row draws, in the mark color. `row_min` is the row's
// top-left corner, the last item's bottom is the row's bottom. A driven row
// draws its own bar instead, so callers mark only rows that are not driven.
driven_mark :: proc(owner: core.Handle, field_offset: uintptr, field_tid: typeid, row_min: im.Vec2) {
	if driven_row_state == nil do return
	if has_row, _, _ := driven_row_query(owner, field_offset, field_tid); !has_row do return
	_driven_bar(row_min, im.GetItemRectMax(), driven_mark_color())
}

// driven_mark for the row at `field_ptr` that is the last item (a group), with
// the owner from the inspector's owner stack.
driven_mark_field :: proc(field_ptr: rawptr, field_tid: typeid) {
	if driven_row_state == nil do return
	owner, offset, ok := _driven_field_owner(field_ptr)
	if !ok do return
	driven_mark(owner, offset, field_tid, im.GetItemRectMin())
}

// --- Add Key -------------------------------------------------------------------------

// The key item of a field's context menu, drawn inside the open popup: shown
// only while the field can be keyed, which the provider's owner limits to
// recording. "Add Key" when the playhead's frame has no key for the row,
// keying `value` (the value the row shows, in the field's own type), else
// "Delete Key", removing that key. Returns whether an item was drawn.
driven_add_key_item :: proc(owner: core.Handle, field_offset: uintptr, field_tid: typeid, value: rawptr) -> bool {
	if driven_add_key == nil do return false
	_, keyable, keyed := driven_row_query(owner, field_offset, field_tid)
	if !keyable do return false
	if keyed && driven_delete_key != nil {
		if im.MenuItem("Delete Key") {
			ok := driven_delete_key(owner, field_offset, field_tid)
			assert(ok, "driven: a keyed field loses its key")
		}
		return true
	}
	if im.MenuItem("Add Key") {
		ok := driven_add_key(owner, field_offset, field_tid, value)
		assert(ok, "driven: a keyable field takes a key")
	}
	if driven_tooltip_add_key != "" do widgets.tooltip(driven_tooltip_add_key, im.HoveredFlags_AllowWhenDisabled)
	return true
}

// driven_add_key_item for the row at `field_ptr`, with the owner from the
// inspector's owner stack. Keys the value the row shows: the driven value
// when the field is driven, else the live value.
driven_add_key_item_field :: proc(field_ptr: rawptr, field_tid: typeid) -> bool {
	if driven_add_key == nil do return false
	owner, offset, ok := _driven_field_owner(field_ptr)
	if !ok do return false
	dv := driven_query(owner, offset, field_tid)
	value := dv.state != .None ? rawptr(&dv.start) : field_ptr
	return driven_add_key_item(owner, offset, field_tid, value)
}

// The context menu of a driven row that draws no other menu (the transform
// rows, a row drawn by a decorator): "Add Key" alone, keying the driven value.
// Opens on a right-click on the last item, the row's group. The popup id is
// the one draw_field_context_menu uses for the same field.
driven_context_menu :: proc(field_ptr: rawptr, dv: ^Driven_Value) {
	if driven_add_key == nil || dv.state == .None do return
	popup_id := fmt.ctprintf("##vcp_%x", uintptr(field_ptr))
	im.OpenPopupOnItemClick(popup_id, im.PopupFlags_MouseButtonRight)
	if im.BeginPopup(popup_id) {
		if !driven_add_key_item(dv.owner, dv.offset, dv.tid, &dv.start) do im.TextDisabled("No actions")
		im.EndPopup()
	}
}

// --- Editable rows -------------------------------------------------------------------
//
// An editable driven row's widget draws on a buffer seeded with the driven
// value, never on the live field. A gesture spans frames, so while one row's
// edit is in flight its buffer lives here and is not reseeded (a drag
// continues from where it is, a typed value is not overwritten). When the
// gesture ends the buffer goes to driven_commit. One row edits at a time, so
// one slot is enough. A row names its slot by a key (its field pointer) and
// may draw a buffer of another type than the field (the Rotation row draws
// euler angles).

// One slot: a field's gesture runs in one row at a time. The slot is keyed
// by the field AND the imgui ID scope the row draws in, so a second
// inspector showing the same object draws its own seed and never commits
// the first inspector's gesture.
@(private = "file")
_Driven_Edit :: struct {
	key:   rawptr,
	scope: im.ID,
	value: [DRIVEN_VALUE_MAX / 8]u64,
	start: [DRIVEN_VALUE_MAX / 8]u64,
}

@(private = "file")
_driven_edit: _Driven_Edit

// The ID scope the calling row draws in: the window and the ids pushed
// around the row, the same before and after its widgets draw. A test that
// substitutes the widget state draws no window, so every row there shares
// one scope.
@(private = "file")
_driven_scope :: proc() -> im.ID {
	if _widget_state_override != nil || im.GetCurrentContext() == nil do return 0
	return im.GetID("##driven_slot")
}

@(private = "file")
_driven_owned :: proc(key: rawptr) -> bool {
	return key != nil && _driven_edit.key == key && _driven_edit.scope == _driven_scope()
}

// The buffer the row `key` draws on this frame: the slot while that row's
// gesture is in flight, else `seed`, which the caller filled this frame.
driven_edit_buffer :: proc(key: rawptr, seed: rawptr) -> rawptr {
	if _driven_owned(key) do return &_driven_edit.value
	return seed
}

// The row's gesture state after its widgets drew (the group they drew in is
// the last item): whether it is mid-gesture, and whether the gesture ended
// this frame with an edit. A row whose popup is open (the color picker) is
// mid-gesture while any item in the popup is active. Consumes the row latches.
driven_gesture_state :: proc() -> (active, finished: bool) {
	finished = field_edit_row_finished()
	held := field_edit_row_held()
	active = _widget_active()
	if held && _widget_state_override == nil do active = active || im.IsAnyItemActive()
	return
}

// After the row `key` drew on `buf` (from driven_edit_buffer), with `start`
// the value `seed` was seeded with this frame and `n` the buffer's size.
// Returns true when the gesture ended with a changed value, which is then in
// `seed` for the caller to commit. Otherwise keeps the slot while the gesture
// is in flight and lets it go once it is over.
//
// The gesture ends when imgui reports it (released, or a typed value landed),
// or retroactively when the value moved with nothing active: a picker writes
// from a popup with no gesture of its own.
driven_edit_end :: proc(key, buf, seed, start: rawptr, n: int, active, finished: bool) -> (commit: bool) {
	assert(n <= DRIVEN_VALUE_MAX, "driven: a row's buffer fits the slot")
	owned := _driven_owned(key)
	from := owned ? rawptr(&_driven_edit.start) : start
	changed := mem.compare_ptrs(buf, from, n) != 0
	if changed && (finished || !active) {
		if buf != seed do mem.copy(seed, buf, n)
		if owned do _driven_edit = {}
		return true
	}
	switch {
	case active && !owned:
		_driven_edit = {key = key, scope = _driven_scope()}
		mem.copy(&_driven_edit.value, buf, n)
		mem.copy(&_driven_edit.start, start, n)
	case !active && owned:
		_driven_edit = {}
	}
	return false
}

// driven_edit_end for a row whose buffer is the field's own type: commits the
// edited value through driven_commit. Returns whether an edit was committed.
driven_edit_finish :: proc(key, buf: rawptr, dv: ^Driven_Value) -> bool {
	active, finished := driven_gesture_state()
	n := type_info_of(dv.tid).size
	if !driven_edit_end(key, buf, &dv.value, &dv.start, n, active, finished) do return false
	return driven_commit != nil && driven_commit(dv.owner, dv.offset, dv.tid, &dv.value)
}

// Lets go of a slot whose row stopped drawing mid-gesture (the panel closed,
// the selection changed). Called from field_edit_frame_begin.
@(private)
_driven_edit_frame_begin :: proc(any_item_active: bool) {
	if !any_item_active do _driven_edit = {}
}
