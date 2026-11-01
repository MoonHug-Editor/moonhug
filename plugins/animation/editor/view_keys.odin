package animation_editor

// Keyframe operations of the Animation window: adding, deleting and setting
// keys, frame snapping, lane masks and lane split and join, key modes and
// tangent presets, and the channel and key value helpers they share. Each
// operation is one undo step on the clip's document.

import "base:runtime"
import "core:encoding/uuid"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:reflect"
import "core:slice"
import "core:strings"
import im "moonhug:external/odin-imgui"
import engine "moonhug:packages/engine"
import anim "moonhug:packages/animation"
import "moonhug:editor/inspector"
import "moonhug:editor/widgets"

// --- Frame snapping --------------------------------------------------------------------
//
// Keys and the playhead land on frame boundaries, so a clip authored here
// plays the same at any sample rate. Imported keys are left where they are:
// only what the user moves or creates snaps. Alt places freely, for matching
// an imported time exactly.

@(private)
_pv_snap_time :: proc(clip: ^anim.AnimationClip, t: f32) -> f32 {
	if im.GetIO().KeyAlt do return t
	return anim.animation_snap_to_frame(clip, t)
}

@(private)
_pv_normalize_rot_key :: proc(ch: ^anim.Animation_Channel, k: int) {
	vals := anim.animation_channel_floats(ch)
	v := vals[k]
	if l := linalg.length(v); l > 0.0001 do vals[k] = (1.0 / l) * v
}

// Value lanes a channel edits: transform channels by path, property channels
// by the LIVE field kind (clip_property.odin). An unresolved property channel
// edits one lane, painted yellow in the row list.
@(private)
_pv_ch_ncomp :: proc(ch: ^anim.Animation_Channel) -> int {
	if anim.animation_channel_is_property(ch) {
		if loc, ok := anim._prop_meta(ch.component, ch.field); ok {
			#partial switch loc.kind {
			case .Vec2: return 2
			case .Vec3: return 3
			case .Vec4: return 4
			}
			return 1
		}
		return 1
	}
	return ch.path == .Rotation ? 4 : 3
}

// Row label + resolved flag: transform channels are always resolved,
// property channels resolve their component guid and field path. The target
// is the Object row's label above, so the label leaves it out.
@(private)
_pv_ch_label :: proc(ch: ^anim.Animation_Channel) -> (label: cstring, resolved: bool) {
	m := _pv_meta(ch)
	return m.label, m.resolved
}

// --- Keyframe operations --------------------------------------------------------------

// Insert a key at `t` sampling the curve's current value there, so adding a
// key never changes the curve's shape. With `value` given (recording) the key
// holds that value instead, and a key already at `t` takes it. A string value
// is cloned into the row.
@(private)
_pv_add_key :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, ch_idx: int, t: f32, value: Maybe(anim.Channel_Value) = nil) {
	if doc == nil do return // read-only clip
	if ch_idx < 0 || ch_idx >= len(clip.channels) do return
	ch := &clip.channels[ch_idx]
	t := clamp(t, 0, clip.length)
	given, has_value := value.?
	for kt, i in ch.times {
		if abs(kt - t) >= 0.0005 do continue
		if !has_value do return
		_pv_edit_begin(doc)
		anim.animation_channel_set_value(ch, i, given)
		_pv_sel_set(ch_idx, i)
		_pv_edit_commit(doc)
		return
	}
	v := has_value ? given : anim._animation_channel_sample_value(ch, t)
	idx := len(ch.times)
	for kt, i in ch.times {
		if kt > t {
			idx = i
			break
		}
	}
	_pv_edit_begin(doc)
	anim.animation_channel_insert_key(ch, idx, t, v)
	_pv_sel_set(ch_idx, idx)
	_pv_edit_commit(doc)
}

// The last key of a channel stays — an empty channel samples to zero, which
// is never what a delete meant.
@(private)
// Deletes every selected key in one undo step. A channel left with no keys
// goes with them: a keyless channel animates nothing, so the property row
// disappears rather than lingering empty.
_pv_delete_key :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip) {
	if doc == nil || !_pv_sel_valid(clip) do return
	_pv_sel_prune(clip)
	if len(_av.sel) == 0 do return

	// Highest key index first, so each removal cannot shift the next one.
	refs := make([dynamic]_Key_Ref, 0, len(_av.sel), context.temp_allocator)
	append(&refs, .._av.sel[:])
	slice.sort_by(refs[:], proc(a, b: _Key_Ref) -> bool {
		return a.ch != b.ch ? a.ch > b.ch : a.key > b.key
	})

	_pv_edit_begin(doc)
	for r in refs {
		anim.animation_channel_remove_key(&clip.channels[r.ch], r.key)
	}
	// Emptied channels, highest index first for the same reason.
	for i := len(clip.channels) - 1; i >= 0; i -= 1 {
		if len(clip.channels[i].times) > 0 do continue
		_pv_channel_remove(clip, i)
	}
	_pv_edit_commit(doc)
}

// Frees a channel's own allocations and drops it from the clip.
_pv_channel_remove :: proc(clip: ^anim.AnimationClip, i: int) {
	sheet_channel_free(clip, i)
}

// --- Lanes ------------------------------------------------------------------------------
//
// A vector row animates only its enabled lanes (anim.animation_channel_lanes_off).
// The Lanes group of its context menu turns them on and off. Only enabled
// lanes get Lane rows. A disabled lane's value field is a dimmed dash.

// The lanes row `ch` leaves alone, by the field's live kind. Empty for a row
// with no mask, or a property row that does not resolve.
@(private)
_pv_lanes_off :: proc(ch: ^anim.Animation_Channel) -> anim.Lane_Set {
	kind, ok := _pv_row_kind(ch)
	if !ok do return {}
	return anim.animation_channel_lanes_off(ch, kind)
}

// Enables or disables lane `lane` of row `ch_idx`, one undo step. Disabling
// the last enabled lane removes the row in the same step. False with nothing
// to change: no document, no such row or lane, or the lane already so.
@(private)
_pv_lane_set :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, ch_idx, lane: int, on: bool) -> bool {
	if doc == nil || ch_idx < 0 || ch_idx >= len(clip.channels) do return false
	ch := &clip.channels[ch_idx]
	width := anim.animation_channel_mask_width(ch)
	if lane < 0 || lane >= width do return false
	if (lane not_in ch.lanes_off) == on do return false
	_pv_edit_begin(doc)
	if on {
		ch.lanes_off -= {lane}
	} else {
		ch.lanes_off += {lane}
		last := true
		for l in 0 ..< width do if l not_in ch.lanes_off {
			last = false
			break
		}
		if last {
			// The row's strings and arrays live in the document.
			context.allocator = inspector.doc_alloc()
			_pv_channel_remove(clip, ch_idx)
		}
	}
	_pv_edit_commit(doc)
	return true
}

// Turns lane `lane` of the split row `group` on or off, one undo step. `lc`
// is the channel that animates the lane, -1 for none: checking adds a
// channel for the lane, unchecking frees `lc` (or masks the lane off when
// `lc` animates other lanes too). Freeing the group's last channel removes
// the property.
@(private)
_pv_split_lane_set :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, group: []int, lane, lc: int) {
	if doc == nil do return
	if lc >= 0 {
		c := &clip.channels[lc]
		width := anim.animation_channel_mask_width(c)
		on := 0
		for l in 0 ..< width do if l not_in c.lanes_off do on += 1
		if on > 1 {
			_pv_lane_set(doc, clip, lc, lane, false)
			return
		}
	}
	_pv_edit_begin(doc)
	{
		context.allocator = inspector.doc_alloc()
		if lc >= 0 {
			_pv_channel_remove(clip, lc)
		} else {
			sheet_lane_add(clip, group, lane)
		}
	}
	_pv_edit_commit(doc)
}

// Joins the channels `group` of one property, one undo step.
@(private)
_pv_join_group :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, group: []int) {
	_pv_edit_begin(doc)
	{
		context.allocator = inspector.doc_alloc()
		sheet_join_lanes(clip, group)
	}
	_pv_edit_commit(doc)
}

// A join that changes the animation (a lane holds where another
// interpolates, sheet_join_mixed_step) asks first. The dialog answers on a
// later frame, when channel indices may have moved, so the row is kept by
// its stable key (sheet_channel_key) and found again on Join.
@(private = "file")
_pv_join_key: string // default allocator, "" = no join waiting

@(private)
_pv_join_ask :: proc(clip: ^anim.AnimationClip, ch: int) {
	context.allocator = runtime.default_allocator()
	delete(_pv_join_key)
	_pv_join_key = sheet_channel_key(&clip.channels[ch])
	widgets.dialog_open({
		title       = "Join Lane Keys",
		description = "A lane holds between keys where another lane interpolates. A joined key has one mode for every lane, so that hold becomes a ramp.\nJoin anyway?",
		buttons     = {
			{label = "Join", action = _pv_join_confirmed, is_default = true},
			{label = "Cancel", is_cancel = true},
		},
	})
}

@(private = "file")
_pv_join_confirmed :: proc() {
	doc, clip := _pv_doc()
	if doc == nil || clip == nil || _pv_join_key == "" do return
	for &c, i in clip.channels {
		if sheet_channel_key(&c, context.temp_allocator) != _pv_join_key do continue
		group := _pv_group(clip, i)
		if sheet_can_join(clip, group) do _pv_join_group(doc, clip, group)
		break
	}
}

// --- Key interpolation ------------------------------------------------------------------
//
// The key context menu and the footer set the selected keys' modes and apply
// tangent presets (curve_tools.odin). Each action is one undo step over every
// selected key. Keys of int, reference and string rows always hold, so the
// actions skip them.

// The modes every selected float key's row allows, and whether the selection
// holds a float key at all.
@(private = "file")
_pv_sel_modes :: proc(clip: ^anim.AnimationClip) -> (allowed: Key_Modes, floats: bool) {
	allowed = {.Linear, .Smooth, .Step, .Free}
	for r in _av.sel {
		if r.ch < 0 || r.ch >= len(clip.channels) do continue
		ch := &clip.channels[r.ch]
		if r.key < 0 || r.key >= len(ch.times) || !anim.animation_channel_is_float(ch) do continue
		floats = true
		allowed &= channel_modes_allowed(ch)
	}
	if !floats do allowed = {}
	return
}

// Whether every selected float key has `mode`.
@(private = "file")
_pv_sel_mode_all :: proc(clip: ^anim.AnimationClip, mode: anim.Key_Mode) -> bool {
	found := false
	for r in _av.sel {
		if r.ch < 0 || r.ch >= len(clip.channels) do continue
		ch := &clip.channels[r.ch]
		if r.key < 0 || r.key >= len(ch.times) || !anim.animation_channel_is_float(ch) do continue
		found = true
		if anim._animation_key_mode(ch, r.key) != mode do return false
	}
	return found
}

// Sets `mode` on every selected float key, one undo step. A key turning Free
// keeps the tangents it had. Nothing happens when a selected row does not
// allow the mode.
@(private)
_pv_keys_set_mode :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, mode: anim.Key_Mode) {
	if doc == nil do return
	_pv_sel_prune(clip)
	allowed, floats := _pv_sel_modes(clip)
	if !floats || mode not_in allowed do return
	_pv_edit_begin(doc)
	{
		// `modes` and `tangents` may be created here, and they live in the
		// document.
		context.allocator = inspector.doc_alloc()
		for r in _av.sel {
			ch := &clip.channels[r.ch]
			if anim.animation_channel_is_float(ch) do channel_set_key_mode(ch, r.key, mode)
		}
	}
	_pv_edit_commit(doc)
}

// Applies `preset` to every selected float key, one undo step: each becomes a
// Free key with the preset's tangents. Nothing happens when a selected row
// does not allow Free keys.
@(private)
_pv_keys_apply_preset :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, preset: Key_Preset) {
	if doc == nil do return
	_pv_sel_prune(clip)
	allowed, floats := _pv_sel_modes(clip)
	if !floats || .Free not_in allowed do return
	_pv_edit_begin(doc)
	{
		context.allocator = inspector.doc_alloc()
		for r in _av.sel {
			ch := &clip.channels[r.ch]
			if anim.animation_channel_is_float(ch) do channel_apply_preset(ch, r.key, preset)
		}
	}
	_pv_edit_commit(doc)
}

@(private = "file")
_pv_preset_label :: proc(p: Key_Preset) -> cstring {
	switch p {
	case .Flat:     return "Flat"
	case .Ease_In:  return "Ease In"
	case .Ease_Out: return "Ease Out"
	case .Auto:     return "Auto"
	}
	unreachable()
}

// The Mode group and the presets of the key context menu. A selection of
// discrete keys shows Step, disabled: those keys always hold.
@(private)
_pv_draw_mode_items :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip) {
	allowed, floats := _pv_sel_modes(clip)
	im.SeparatorText("Mode")
	if !floats {
		im.MenuItem("Step", nil, true, false)
		return
	}
	for mode in anim.Key_Mode {
		if mode not_in allowed do continue
		if im.MenuItem(fmt.ctprintf("%v", mode), nil, _pv_sel_mode_all(clip, mode), doc != nil) {
			_pv_keys_set_mode(doc, clip, mode)
		}
	}
	if .Free not_in allowed do return
	im.SeparatorText("Tangents")
	for p in Key_Preset {
		if im.MenuItem(_pv_preset_label(p), nil, false, doc != nil) do _pv_keys_apply_preset(doc, clip, p)
	}
}

// The footer's mode combo: the primary key's mode, and the modes the
// selection allows to pick from. A pick applies to every selected key, as
// the context menu does. A discrete key shows Step, disabled.
@(private)
_pv_draw_mode_combo :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, ch: ^anim.Animation_Channel, k: int) {
	im.SetNextItemWidth(80)
	if channel_modes_allowed(ch) == {} {
		im.BeginDisabled()
		if im.BeginCombo("##anim_key_mode", "Step") do im.EndCombo()
		im.EndDisabled()
		return
	}
	cur := anim._animation_key_mode(ch, k)
	if im.BeginCombo("##anim_key_mode", fmt.ctprintf("%v", cur)) {
		allowed, _ := _pv_sel_modes(clip)
		for mode in anim.Key_Mode {
			if mode not_in allowed do continue
			if im.Selectable(fmt.ctprintf("%v", mode), mode == cur) do _pv_keys_set_mode(doc, clip, mode)
		}
		im.EndCombo()
	}
}

// Sets key `k` of row `ch_idx` to `v`, one undo step. A string is cloned into
// the row.
@(private)
_pv_set_key_value :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, ch_idx, k: int, v: anim.Channel_Value) {
	if doc == nil do return
	_pv_edit_begin(doc)
	{
		context.allocator = inspector.doc_alloc()
		anim.animation_channel_set_value(&clip.channels[ch_idx], k, v)
	}
	_pv_edit_commit(doc)
}

// The kind a row's fields edit, false for a property row that no longer
// resolves (it has no live type to show). A Rotation row edits three euler
// angles.
@(private)
_pv_row_kind :: proc(ch: ^anim.Animation_Channel) -> (kind: anim.Prop_Kind, ok: bool) {
	m := _pv_meta(ch)
	return m.kind, m.kind_ok
}

// Whether a channel is a transform Rotation row, whose fields show euler
// angles of the stored quaternion.
@(private)
_pv_ch_is_rotation :: proc(ch: ^anim.Animation_Channel) -> bool {
	return !anim.animation_channel_is_property(ch) && ch.path == .Rotation
}

// The euler angles (degrees) a Rotation row or key shows for quaternion `q`.
@(private)
_pv_rot_to_euler :: proc(q: [4]f32) -> [3]f32 {
	return engine.quat_to_euler_xyz(q)
}

// The normalized quaternion a Rotation row or key keys for euler angles `e`.
@(private)
_pv_rot_from_euler :: proc(e: [3]f32) -> [4]f32 {
	q := engine.quat_from_euler_xyz(e.x, e.y, e.z)
	if l := linalg.length(q); l > 0.0001 do q = (1.0 / l) * q
	return q
}

// A key value as float lanes, an int in the first lane. A reference or string
// has none.
@(private)
_pv_value_floats :: proc(v: anim.Channel_Value) -> [4]f32 {
	#partial switch x in v {
	case [4]f32: return x
	case i64:    return {f32(x), 0, 0, 0}
	}
	return {}
}

// A key value as an int: the first lane rounded for floats.
@(private)
_pv_value_int :: proc(v: anim.Channel_Value) -> i64 {
	#partial switch x in v {
	case i64:    return x
	case [4]f32: return i64(math.round(x.x))
	}
	return 0
}

// A key value as read-only text, for a key of an int row in the footer: an int
// in decimal, a reference as its guid's first 8 digits (":local id" for a
// sub-asset, "None" when empty), a string as it is. Temp-allocated.
@(private)
_pv_value_text :: proc(v: anim.Channel_Value) -> string {
	switch x in v {
	case [4]f32: return fmt.tprintf("%.2f", x.x)
	case i64:    return fmt.tprintf("%d", x)
	case engine.PPtr:
		if engine.asset_guid_is_empty(x.guid) do return "None"
		g := uuid.to_string(uuid.Identifier(x.guid), context.temp_allocator)[:8]
		if x.local_id != 0 do return fmt.tprintf("%s:%d", g, x.local_id)
		return g
	case string: return x
	}
	unreachable()
}

// The struct tag of the field a property row animates, "" when the row does
// not resolve. A reference row's picker reads its `ext:` and `ref:` tags.
@(private)
_pv_field_tag :: proc(ch: ^anim.Animation_Channel) -> reflect.Struct_Tag {
	guid, gerr := uuid.read(ch.component)
	if gerr != nil do return ""
	cur, ok := engine.get_typeid_by_guid_ok(guid)
	if !ok do return ""
	tag: reflect.Struct_Tag
	rest := ch.field
	for len(rest) > 0 {
		key := rest
		if dot := strings.index_byte(rest, '.'); dot >= 0 {
			key = rest[:dot]
			rest = rest[dot + 1:]
		} else {
			rest = ""
		}
		names := reflect.struct_field_names(cur)
		types := reflect.struct_field_types(cur)
		tags := reflect.struct_field_tags(cur)
		found := false
		for name, i in names {
			if name != key do continue
			cur = types[i].id
			tag = tags[i]
			found = true
			break
		}
		if !found do return ""
	}
	return tag
}

// Keys row `row` at the playhead with `value`: the key already at the playhead
// takes it, else a key is added there. One undo step, or part of the open row
// value gesture.
@(private)
_pv_row_key :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, row: int, value: anim.Channel_Value) {
	_pv_add_key(doc, clip, row, _pv.time, value)
}
