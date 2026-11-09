package animation_editor

// The property column of the Animation window: row indents and labels, the
// Object row collapse arrows and path field, and the value fields each
// property row shows at the playhead.

import "base:runtime"
import "core:fmt"
import "core:strings"
import im "moonhug:external/odin-imgui"
import "moonhug:editor/widgets"
import engine "moonhug:packages/engine"
import anim "moonhug:packages/animation"
import "moonhug:editor/inspector"
import "moonhug:editor/undo"

@(private = "file") _ANIM_VAL_W :: f32(42)  // one value field of a row
@(private = "file") _ANIM_VAL_GAP :: f32(2)
@(private = "file") _ANIM_INDENT :: f32(14) // a property row's indent under its Object row

// Collapses or expands `target`'s Object row in the current copy.
@(private)
_pv_collapse_toggle :: proc(target: string) {
	context.allocator = runtime.default_allocator()
	_av.window_gen += 1
	if target in _av.collapsed {
		k, _ := delete_key(&_av.collapsed, target)
		delete(k)
		return
	}
	if _av.collapsed == nil do _av.collapsed = make(map[string]bool)
	_av.collapsed[strings.clone(target)] = true
}

// Shows or hides the Lane rows of the vector row with sheet_channel_key `key`
// in the current copy.
@(private)
_pv_expand_toggle :: proc(key: string) {
	context.allocator = runtime.default_allocator()
	_av.window_gen += 1
	if key in _av.expanded {
		k, _ := delete_key(&_av.expanded, key)
		delete(k)
		return
	}
	if _av.expanded == nil do _av.expanded = make(map[string]bool)
	_av.expanded[strings.clone(key)] = true
}

// Expands `target`'s Object row in the current copy, so a channel just added
// under it shows.
@(private)
_pv_collapse_clear :: proc(target: string) {
	if target in _av.collapsed do _pv_collapse_toggle(target)
}

// The animated object's name, the root Object row's label.
@(private)
_pv_root_name :: proc() -> string {
	w := engine.ctx_world()
	if t := engine.pool_get(&w.transforms, engine.Handle(_pv.owner)); t != nil && t.name != "" do return t.name
	return "(self)"
}

// How far a row indents: an Object row sits at the column's edge whatever its
// path depth (the dimmed parent path says where it is), its property rows one
// step in, a vector row's Lane rows two.
@(private)
_pv_row_indent :: proc(r: Sheet_Row) -> int {
	switch r.kind {
	case .Object:  return 0
	case .Channel: return 1
	case .Lane:    return 2
	}
	unreachable()
}

// Where a row's label starts: after its indent and an arrow's width, so the
// labels of property rows line up whether or not they have an arrow.
@(private)
_pv_row_label_x :: proc(x0: f32, r: Sheet_Row) -> f32 {
	return _pv_obj_name_x(x0, _pv_row_indent(r))
}

// Where an Object row's name starts: its indent, then the arrow.
@(private)
_pv_obj_name_x :: proc(x0: f32, depth: int) -> f32 {
	return x0 + 6 + f32(depth) * _ANIM_INDENT + _ANIM_ARROW_W + 4
}

// An Object row's label from `x` up to `x_max`: the transform's name only.
// The full path is in the tooltip and the path field. Warning colour when the
// target does not resolve under the animated object.
@(private)
_pv_draw_obj_label :: proc(dl: ^im.DrawList, target, root_name: string, x, y, x_max: f32) {
	name := sheet_target_name(target, root_name)
	_, resolved := anim._animation_resolve_target(_pv.owner, target)
	col := resolved ? im.GetColorU32(.Text) : im.GetColorU32ImVec4(_ANIM_WARN_COL)
	im.DrawList_PushClipRect(dl, im.Vec2{x, y}, im.Vec2{max(x_max, x), y + _ANIM_ROW_H}, true)
	defer im.DrawList_PopClipRect(dl)
	im.DrawList_AddText(dl, im.Vec2{x, y + 3}, col, fmt.ctprintf("%s", name))
}

// An Object row's collapse arrow centered on `c`: pointing down when open,
// right when collapsed.
@(private)
_pv_draw_collapse_arrow :: proc(dl: ^im.DrawList, c: im.Vec2, open: bool) {
	r := f32(4)
	col := im.GetColorU32(.Text)
	if open {
		im.DrawList_AddTriangleFilled(dl, c + {-r, -r * 0.6}, c + {r, -r * 0.6}, c + {0, r * 0.6}, col)
	} else {
		im.DrawList_AddTriangleFilled(dl, c + {-r * 0.6, -r}, c + {r * 0.6, 0}, c + {-r * 0.6, r}, col)
	}
}

// --- Object row path field ------------------------------------------------------------
//
// Retargeting: a renamed transform leaves its rows unresolved, so the Object
// row's path is editable. "Edit Path" in its menu opens a field holding the
// full target path at the row's indent. Enter and Escape apply through
// animation_window_retarget, a click elsewhere cancels.

@(private)
_pv_path_edit_begin :: proc(target: string) {
	_pv_view_str_set(&_av.path_target, target)
	_av.path_edit = true
	// A field opened from the menu races the closing popup for focus, so it
	// asks again for a few frames before giving up.
	_av.path_wait = 10
	_av.path_buf = {}
	copy(_av.path_buf[:len(_av.path_buf) - 1], target)
}

@(private)
_pv_draw_path_field :: proc(doc: ^inspector.Asset_Doc, rows: []Sheet_Row, x0, rows_y, left_x1: f32) {
	if !_av.path_edit do return
	row := -1
	for r, i in rows {
		if r.kind == .Object && r.target == _av.path_target {
			row = i
			break
		}
	}
	// The row went away (undo, a clip switch) or the clip is read-only.
	if row < 0 || doc == nil {
		_av.path_edit = false
		return
	}
	// Escape commits the typed path, as in every text field (editor/text_input.odin).
	// A click elsewhere cancels.
	field_h := _pv_row_field_h()
	x := _pv_obj_name_x(x0, _pv_row_indent(rows[row]))
	im.PushStyleVarImVec2(.FramePadding, im.Vec2{3, _pv_row_pad_y()})
	if _av.path_wait > 0 do im.SetKeyboardFocusHere(0)
	im.SetCursorScreenPos(im.Vec2{x, rows_y + f32(row) * _ANIM_ROW_H + (_ANIM_ROW_H - field_h) * 0.5})
	im.SetNextItemWidth(max(left_x1 - 4 - x, 40))
	entered := im.InputText("##anim_path", cstring(raw_data(_av.path_buf[:])), uint(len(_av.path_buf)), {.EnterReturnsTrue, .AutoSelectAll})
	active := im.IsItemActive()
	im.PopStyleVar(1)

	if entered {
		_av.path_edit = false
		animation_window_retarget(_av.path_target, string(cstring(raw_data(_av.path_buf[:]))))
		return
	}
	if _av.path_wait > 0 {
		if active {
			_av.path_wait = 0
		} else {
			_av.path_wait -= 1
			if _av.path_wait == 0 do _av.path_edit = false
		}
	} else if !active {
		_av.path_edit = false // clicked elsewhere: cancel
	}
}

// Sets the target of every channel of `old_target` in the shown clip to
// `new_target` (spaces trimmed, otherwise as typed), as one undo step. The
// collapsed state follows the row. False with nothing to change: no
// document (a clip inside a model), no channel on `old_target`, or the same
// path. The Object row path field applies through this.
animation_window_retarget :: proc(old_target, new_target: string) -> bool {
	doc, clip := _pv_doc()
	if doc == nil || clip == nil do return false
	// Copies: `old_target` may be a channel's own string, freed below.
	old := strings.clone(old_target, context.temp_allocator)
	new := strings.clone(strings.trim_space(new_target), context.temp_allocator)
	if new == old do return false
	found := false
	for &c in clip.channels do if c.target == old do found = true
	if !found do return false
	// A property the new path already animates on a lane a moved row animates
	// would give that lane two rows (anim.animation_clip_validate): refused.
	for &c in clip.channels {
		if c.target != old do continue
		probe := c
		probe.target = new
		for &o in clip.channels {
			if o.target != new || !anim.animation_channel_same_property(&probe, &o) do continue
			width := anim.animation_channel_mask_width(&c)
			if width == 0 do return false
			for l in 0 ..< width do if l not_in c.lanes_off && l not_in o.lanes_off do return false
		}
	}

	_pv_edit_begin(doc)
	// Channel strings live in the document.
	a := inspector.doc_alloc()
	for &c in clip.channels {
		if c.target != old do continue
		delete(c.target, a)
		c.target = strings.clone(new, a)
	}
	_pv_edit_commit(doc)

	// The row state follows the rows: the Object row's collapse, and the
	// expanded vector rows, whose keys start with the target
	// (sheet_channel_key).
	if old in _av.collapsed {
		_pv_collapse_toggle(old)
		if new not_in _av.collapsed do _pv_collapse_toggle(new)
	}
	prefix := strings.concatenate({old, "\x1f"}, context.temp_allocator)
	moved := make([dynamic]string, context.temp_allocator)
	for k in _av.expanded do if strings.has_prefix(k, prefix) do append(&moved, strings.clone(k, context.temp_allocator))
	for k in moved {
		_pv_expand_toggle(k)
		renamed := strings.concatenate({new, k[len(old):]}, context.temp_allocator)
		if renamed not_in _av.expanded do _pv_expand_toggle(renamed)
	}
	return true
}

// --- Row values -----------------------------------------------------------------------
//
// Each property row shows its value at the playhead after its name: one small
// field per lane (a vec3 three, a bool a checkbox, an int or enum an int
// field, a string a text field committed by Enter, a reference the asset
// picker the inspector uses). A Rotation row shows three euler angles in
// degrees, converted from the sampled
// quaternion as the inspector's Rotation row converts, and an edit keys the
// normalized quaternion built from them. Editing a field keys the row at the
// playhead with the edited value. A clip inside a model shows them read-only.

// The field of a string or reference value, `w` wide at the cursor. A string
// shows a text field: Enter returns the typed text (temp-allocated), a click
// elsewhere drops it. A reference shows the inspector's asset picker on a
// copy, filtered by the field's tags: a pick or a drop returns the new value.
@(private)
_pv_discrete_field :: proc(ch: ^anim.Animation_Channel, kind: anim.Prop_Kind, value: anim.Channel_Value, w: f32) -> (edited: anim.Channel_Value, ok: bool) {
	#partial switch kind {
	case .Text:
		buf: [256]u8
		if s, is_str := value.(string); is_str do copy(buf[:len(buf) - 1], s)
		im.SetNextItemWidth(w)
		// The field shows the value until it is typed into, then keeps its own
		// text until Enter (or Escape, editor/text_input.odin) commits it.
		if im.InputText("##anim_str", cstring(raw_data(buf[:])), uint(len(buf)), {.EnterReturnsTrue}) {
			return strings.clone(string(cstring(raw_data(buf[:]))), context.temp_allocator), true
		}
	case .Ref:
		orig, _ := value.(engine.PPtr)
		picked := orig
		prev_tags := inspector.field_tags_set(_pv_field_tag(ch))
		defer inspector.field_tags_restore(prev_tags)
		// The picker sizes its value button to the remaining width, so the
		// width past this field counts as trailing.
		prev_trailing := inspector.current_field_trailing_w
		inspector.current_field_trailing_w = max(im.GetContentRegionAvail().x - w, 0)
		defer inspector.current_field_trailing_w = prev_trailing
		// This draw is off the inspector's rows, so no row edit marks the
		// flag for it. The flag belongs to those rows: left as it was found.
		prev_changed := inspector.consume_inspector_changed()
		inspector.draw_value(&picked, typeid_of(engine.PPtr), "##anim_ref")
		inspector.consume_inspector_changed()
		if prev_changed do inspector.mark_inspector_changed()
		if picked != orig do return picked, true
	}
	return {}, false
}

// The width a row's value fields take at the column's right edge.
@(private)
_pv_row_values_w :: proc(ch: ^anim.Animation_Channel) -> f32 {
	kind, ok := _pv_row_kind(ch)
	if !ok do return 0
	if kind == .Bool do return _pv_row_field_h()
	if kind == .Ref || kind == .Text do return 3 * _ANIM_VAL_W + 2 * _ANIM_VAL_GAP
	n := f32(anim.prop_kind_lanes(kind))
	return n * _ANIM_VAL_W + (n - 1) * _ANIM_VAL_GAP
}

// Frame padding that fits a field inside one row.
@(private = "file")
_pv_row_pad_y :: proc() -> f32 {
	return max((_ANIM_ROW_H - 2 - im.GetFontSize()) * 0.5, 0)
}

@(private = "file")
_pv_row_field_h :: proc() -> f32 {
	return im.GetFontSize() + 2 * _pv_row_pad_y()
}

// A drag on a row value spans frames: the document session stays open from the
// first change until no item is active, so the drag is one undo step.
@(private)
_pv_row_gesture: bool

@(private)
_pv_row_gesture_end :: proc() {
	_pv_row_gesture = false
	_pv_edit_release()
	doc, clip := _pv_doc()
	if doc == nil || clip == nil {
		undo.edit_session_end(&_pv_session)
		return
	}
	// A rotation key renormalizes at commit, as the key footer does.
	if _pv_sel_valid(clip) {
		ch := &clip.channels[_av.sel_ch]
		if !anim.animation_channel_is_property(ch) && ch.path == .Rotation do _pv_normalize_rot_key(ch, _av.sel_key)
	}
	_pv_edit_commit(doc)
}

// The value fields, right-aligned in the property column. Submitted after the
// mode handlers, which read the sheet button as the last item. The sheet
// button allows overlap, so a field under the pointer takes the hover and the
// press: the sheet's press logic (row selection, box select) does not run for
// a click on a field, and typing into it is not interrupted.
@(private)
_pv_draw_row_values :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, rows: []Sheet_Row, rows_y, left_x1: f32) {
	field_h := _pv_row_field_h()
	im.PushStyleVarImVec2(.FramePadding, im.Vec2{3, _pv_row_pad_y()})
	defer im.PopStyleVar(1)
	im.BeginDisabled(doc == nil)
	defer im.EndDisabled()

	for r, row in rows {
		if r.kind != .Channel do continue
		i := r.ch
		ch := &clip.channels[i]
		kind, ok := _pv_row_kind(ch)
		if !ok do continue
		n := anim.prop_kind_lanes(kind)
		ry := rows_y + f32(row) * _ANIM_ROW_H + (_ANIM_ROW_H - field_h) * 0.5
		x := left_x1 - _pv_row_values_w(ch) - 4
		sampled := anim._animation_channel_sample_value(ch, _pv.time)
		if kind == .Ref || kind == .Text {
			im.PushIDInt(i32(i))
			im.SetCursorScreenPos(im.Vec2{x, ry})
			edited, ok := _pv_discrete_field(ch, kind, sampled, _pv_row_values_w(ch))
			im.PopID()
			if ok do _pv_row_key(doc, clip, i, edited)
			continue
		}
		v := _pv_value_floats(sampled)
		iv := _pv_value_int(sampled)
		rot := _pv_ch_is_rotation(ch)
		speed, format := _pv_ch_drag_style(ch)
		// A rotation row's angles hold across a gesture (_pv_euler_get).
		euler: [3]f32
		if rot do euler = _pv_euler_get(i, -1, v)
		off := _pv_lanes_off(ch)
		// A split row: each lane reads the channel that animates it, a lane
		// none animates is off.
		lane_ch := [4]int{i, i, i, i}
		if r.split {
			group := _pv_group(clip, i)
			off = {}
			for c in 0 ..< n {
				lane_ch[c] = sheet_lane_channel(clip, group, c)
				if lane_ch[c] < 0 {
					off += {c}
					continue
				}
				v[c] = anim._animation_channel_sample(&clip.channels[lane_ch[c]], _pv.time)[c]
			}
		}
		changed := false
		changed_lane := -1
		im.PushIDInt(i32(i))
		for c in 0 ..< n {
			fx := x + f32(c) * (_ANIM_VAL_W + _ANIM_VAL_GAP)
			if c in off {
				// A lane the row leaves alone keeps its column, as a dimmed dash.
				im.DrawList_AddText(im.GetWindowDrawList(), im.Vec2{fx + _ANIM_VAL_W * 0.5 - 3, ry + _pv_row_pad_y()}, im.GetColorU32(.TextDisabled), "-")
				continue
			}
			im.PushIDInt(i32(c))
			im.SetCursorScreenPos(im.Vec2{fx, ry})
			im.SetNextItemWidth(_ANIM_VAL_W)
			#partial switch kind {
			case .Bool:
				b := iv != 0
				if im.Checkbox("##v", &b) {
					iv = b ? 1 : 0
					changed = true
				}
			case .Int:
				i32v := i32(clamp(iv, i64(min(i32)), i64(max(i32))))
				if im.DragInt("##v", &i32v, 0.1) {
					iv = i64(i32v)
					changed = true
				}
			case:
				// A vector's fields carry their axis stripe (widgets/axis_markers.odin).
				if n >= 2 do widgets.axis_marker_next(c)
				if rot {
					if im.DragFloat("##v", &euler[c], speed, 0, 0, format) do changed = true
					_pv_euler_hold(i, -1, euler)
				} else if im.DragFloat("##v", &v[c], speed, 0, 0, format) {
					changed = true
					changed_lane = c
				}
			}
			im.PopID()
		}
		im.PopID()
		if changed && rot do v = _pv_rot_from_euler(euler)
		edited: anim.Channel_Value = v
		if kind == .Bool || kind == .Int do edited = iv
		key_ch := i
		if changed && r.split && changed_lane >= 0 {
			// Keys the lane's own channel: its sampled value with the lane replaced.
			key_ch = lane_ch[changed_lane]
			lv := anim._animation_channel_sample(&clip.channels[key_ch], _pv.time)
			lv[changed_lane] = v[changed_lane]
			edited = lv
		}
		if changed {
			if !_pv_row_gesture {
				_pv_row_gesture = true
				_pv_edit_hold()
			}
			_pv_row_key(doc, clip, key_ch, edited)
		}
	}
	// A typed value lands on the frame its field lets go, a drag ends on
	// release: either way nothing is active any more.
	if _pv_row_gesture && !im.IsAnyItemActive() do _pv_row_gesture_end()
}
