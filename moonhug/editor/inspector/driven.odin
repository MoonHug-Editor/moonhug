package inspector

// Driven values: a field whose shown value comes from some system other than
// the object itself (the Animation window's preview pose). The inspector shows
// that value instead of the field's own value.
//
// Two seams, nil by default. A plugin installs both at EditorInit:
//   - driven_provider answers whether a field is driven, with its value
//   - driven_commit takes an edit of a driven field (Record keys the clip)
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
driven_provider: proc(owner: core.Handle, field_offset: uintptr, field_tid: typeid, out: rawptr) -> (driven: bool, editable: bool)

// Takes an edit of a driven, editable field: `value` holds the edited value in
// the field's own type. Called once per gesture, when it ends. Returns false
// when the edit went nowhere. Without it every driven field is read-only.
driven_commit: proc(owner: core.Handle, field_offset: uintptr, field_tid: typeid, value: rawptr) -> bool

// Tooltips the provider's owner sets for driven rows, "" for none.
driven_tooltip_read_only: cstring
driven_tooltip_editable: cstring

// Text colors of a driven field, full alpha: green while the preview drives
// it, red while recording. The green has a darker shade for light themes,
// where a bright green is hard to read on a bright background.
DRIVEN_READ_ONLY_TEXT_COLOR_DARK_THEME :: im.Vec4{0.35, 0.80, 0.45, 1.0}
DRIVEN_READ_ONLY_TEXT_COLOR_LIGHT_THEME :: im.Vec4{0.08, 0.50, 0.22, 1.0}
DRIVEN_EDITABLE_TEXT_COLOR :: im.Vec4{0.95, 0.35, 0.35, 1.0}

// How far a driven field's frame background moves toward the tint.
DRIVEN_FRAME_BLEND :: f32(0.3)

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
	driven, editable := driven_provider(owner, field_offset, field_tid, &dv.value)
	if !driven do return {}
	dv.state = editable && driven_commit != nil ? .Editable : .Read_Only
	dv.owner = owner
	dv.offset = field_offset
	dv.tid = field_tid
	dv.start = dv.value
	return
}

// Asks the provider about the row at `field_ptr`, with the owner from the
// inspector's owner stack. Only a pooled owner can be driven, and only a field
// inside the owner's own memory: a dynamic-array element lives elsewhere.
driven_query_field :: proc(field_ptr: rawptr, field_tid: typeid) -> Driven_Value {
	if driven_provider == nil || field_ptr == nil do return {}
	o, ok := undo.current_owner()
	if !ok || o.kind != .Pooled || o.base_ptr == nil do return {}
	if uintptr(field_ptr) < uintptr(o.base_ptr) do return {}
	return driven_query(o.handle, uintptr(field_ptr) - uintptr(o.base_ptr), field_tid)
}

// --- Drawing -------------------------------------------------------------------------
//
// The tint is drawn at full alpha: green for a read-only driven field, red for
// a recording one, the same in every theme.
// The text (label and value) takes the tint, the frame background is blended
// toward it, and a bar left of the label marks the row at a glance. No
// BeginDisabled: it multiplies alpha, which some themes fade to nothing.

// The tint color of a driven row.
driven_tint :: proc(state: Driven_State) -> im.Vec4 {
	if state == .Editable do return DRIVEN_EDITABLE_TEXT_COLOR
	// A light theme has dark text: its luminance tells the two apart.
	t := im.GetStyleColorVec4(.Text)^
	if 0.299 * t.x + 0.587 * t.y + 0.114 * t.z < 0.5 do return DRIVEN_READ_ONLY_TEXT_COLOR_LIGHT_THEME
	return DRIVEN_READ_ONLY_TEXT_COLOR_DARK_THEME
}

@(private = "file")
_driven_blend :: proc(base, tint: im.Vec4) -> im.Vec4 {
	c := base + (tint - base) * DRIVEN_FRAME_BLEND
	c.w = 1
	return c
}

// Opens a driven row: pushes the tint and opens the group the row's widgets
// draw in. Pair with driven_draw_end.
driven_draw_begin :: proc(state: Driven_State) {
	if state == .None do return
	tint := driven_tint(state)
	im.PushStyleColorImVec4(.Text, tint)
	im.PushStyleColorImVec4(.FrameBg, _driven_blend(im.GetStyleColorVec4(.FrameBg)^, tint))
	im.PushStyleColorImVec4(.FrameBgHovered, _driven_blend(im.GetStyleColorVec4(.FrameBgHovered)^, tint))
	im.PushStyleColorImVec4(.FrameBgActive, _driven_blend(im.GetStyleColorVec4(.FrameBgActive)^, tint))
	im.BeginGroup()
}

// Closes the group, pops the tint, marks the row and sets its tooltip. The
// group stays the last item, so imgui's item state describes the whole row.
driven_draw_end :: proc(state: Driven_State) {
	if state == .None do return
	im.EndGroup()
	im.PopStyleColor(4)
	rmin := im.GetItemRectMin()
	rmax := im.GetItemRectMax()
	if rmax.y > rmin.y {
		col := im.GetColorU32ImVec4(driven_tint(state))
		im.DrawList_AddRectFilled(im.GetWindowDrawList(), {rmin.x - 4, rmin.y}, {rmin.x - 2, rmax.y}, col)
	}
	text := state == .Editable ? driven_tooltip_editable : driven_tooltip_read_only
	if text != "" do widgets.tooltip(text)
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

@(private = "file")
_Driven_Edit :: struct {
	key:   rawptr,
	value: [DRIVEN_VALUE_MAX / 8]u64,
	start: [DRIVEN_VALUE_MAX / 8]u64,
}

@(private = "file")
_driven_edit: _Driven_Edit

// The buffer the row `key` draws on this frame: the slot while that row's
// gesture is in flight, else `seed`, which the caller filled this frame.
driven_edit_buffer :: proc(key: rawptr, seed: rawptr) -> rawptr {
	if key != nil && _driven_edit.key == key do return &_driven_edit.value
	return seed
}

// The row's gesture state after its widgets drew (the group they drew in is
// the last item): whether it is mid-gesture, and whether the gesture ended
// this frame with an edit. A row whose popup is open (the color picker) is
// mid-gesture while any item in the popup is active. Consumes the row latches.
driven_row_state :: proc() -> (active, finished: bool) {
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
	owned := key != nil && _driven_edit.key == key
	from := owned ? rawptr(&_driven_edit.start) : start
	changed := mem.compare_ptrs(buf, from, n) != 0
	if changed && (finished || !active) {
		if buf != seed do mem.copy(seed, buf, n)
		if owned do _driven_edit = {}
		return true
	}
	switch {
	case active && !owned:
		_driven_edit = {key = key}
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
	active, finished := driven_row_state()
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
