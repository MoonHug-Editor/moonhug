package animation_editor

// The Animation window's sheet: the property column and its header on the
// left, the ruler and the time canvas on the right, the row and key context
// menus, the shared key drag, and the splitter between the two halves.

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:strings"
import im "moonhug:external/odin-imgui"
import engine "moonhug:packages/engine"
import anim "moonhug:packages/animation"
import "moonhug:editor/inspector"
import "moonhug:editor/undo"
import "moonhug:editor/widgets"
import "moonhug:editor/icons"

// The sheet's layout and pointer for one frame, what the dope sheet and the
// curve view both draw and hit-test against: the visible rows and where they
// start, the body height, the canvas edges, the time origin and scale
// (pixels per second), and the pointer with the row under it.
@(private)
_Sheet_Frame :: struct {
	rows:                                 []Sheet_Row,
	rows_y, body_h, x0, x1, tx0, pps:     f32,
	hovered:                              bool,
	mp:                                   im.Vec2,
	row_at:                               int, // -1 off the rows
}

@(private = "file") _ANIM_MIN_LEFT_W :: f32(210) // a vec4 row's value fields plus the start of its name
@(private = "file") _ANIM_MIN_CANVAS_W :: f32(80)
@(private = "file") _ANIM_DRAG_PX :: f32(4) // a press that moves less is a click
@(private = "file") _ANIM_RULER_H :: f32(22) // minimum: the band grows to a frame height

// Header of the property column: the clip picker, stretched to the column
// width, and the key button beside it. Both act on the track list below them
// rather than on the transport, so they sit at its head.
@(private)
_pv_draw_sheet_header :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, clips: []engine.PPtr, left_w: f32) {
	key_w := im.GetFrameHeight()
	combo_w := max(left_w - key_w - im.GetStyle().ItemSpacing.x, 1)

	im.SetNextItemWidth(combo_w)
	cur := strings.clone_to_cstring(_pv_clip_name(_pv.clip), context.temp_allocator)
	if im.BeginCombo("##pv_clip", cur) {
		for c in clips {
			// A clip inside a model has no document to edit. The list marks it,
			// the toolbar marks the open one.
			name := fmt.ctprintf("%s (Read-Only)" if c.local_id != 0 else "%s", _pv_clip_name(c))
			if im.Selectable(name, c == _pv.clip) && c != _pv.clip {
				_pv_teardown()
				_pv_deselect()
				_pv.entry = 0 // the window takes the preview back from the States tree
				_pv.clip = c
				_pv.time = 0
			}
		}
		im.EndCombo()
	}
	widgets.tooltip("Clip to edit")

	im.SameLine()
	im.BeginDisabled(doc == nil || clip == nil || _av.sel_ch < 0 || _av.sel_ch >= len(clip.channels))
	if widgets.icon_button(icons.ICON_MD_KEYFRAME, "##addkey", "Add a keyframe on the selected property") {
		_pv_add_key(doc, clip, _av.sel_ch, _pv.time)
	}
	im.EndDisabled()
}

// The sheet: property rows on the left, the time canvas (ruler + dopesheet
// keys or curves) on the right, one interaction surface each.
@(private)
_pv_draw_sheet :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, clips: []engine.PPtr) {
	dl := im.GetWindowDrawList()
	origin := im.GetCursorScreenPos()
	avail := im.GetContentRegionAvail()
	if avail.x < _ANIM_MIN_LEFT_W + widgets.SPLITTER_SIZE + _ANIM_MIN_CANVAS_W {
		im.TextDisabled("Window too narrow.")
		return
	}

	length := max(clip.length, 0.0001)
	// Property column | splitter gap | time canvas.
	left_w := clamp(_av.left_w, _ANIM_MIN_LEFT_W, avail.x - widgets.SPLITTER_SIZE - _ANIM_MIN_CANVAS_W)
	// The ruler band spans the whole sheet, but only the canvas half of it
	// holds the ruler — the property column's half takes the header controls.
	// It is at least a frame tall so they fit without a row of their own.
	ruler_h := max(_ANIM_RULER_H, im.GetFrameHeight())

	// Header in the property column's half of the band. Drawn before the two
	// interaction surfaces below, which the mode handlers read as the last
	// item, and clear of both in x and y.
	im.SetCursorScreenPos(origin)
	_pv_draw_sheet_header(doc, clip, clips, left_w)

	left_x1 := origin.x + left_w
	x0 := left_x1 + widgets.SPLITTER_SIZE
	x1 := origin.x + avail.x
	// Time axis: pps (pixels per second) is the fit scale times the zoom, so
	// zoom 1 shows the whole clip and no pan is possible.
	if _av.zoom < 1 do _av.zoom = 1
	span_px := max(x1 - x0 - 2 * _ANIM_PAD_X, 1)
	pps_fit := span_px / length
	pps := pps_fit * _av.zoom
	visible := span_px / pps // seconds across the canvas
	_av.pan = clamp(_av.pan, 0, max(length - visible, 0))
	tx0 := x0 + _ANIM_PAD_X - _av.pan * pps // x of t=0

	// The visible rows: an Object row per animated transform, its property
	// rows under it unless collapsed (sheet_rows.odin).
	rows := _pv_sheet(doc, clip).rows[:]
	nrows := len(rows)
	rows_y := origin.y + ruler_h
	body_h: f32
	if _av.mode == .Dopesheet {
		// Fills the pane rather than stopping at the last track: the empty
		// area below the tracks is where a box selection often starts.
		body_h = max(f32(nrows) * _ANIM_ROW_H, max(avail.y - ruler_h, _ANIM_ROW_H))
	} else {
		body_h = max(f32(nrows)*_ANIM_ROW_H, max(avail.y - ruler_h, 140))
	}

	// --- Zoom and pan on the time axis. Zoom keeps the time under the cursor
	// in place, which is what makes wheel zoom feel anchored.
	{
		mp := im.GetMousePos()
		// Resolved every frame so a gesture times out even while the pointer
		// is elsewhere. Only acted on while the canvas is under it.
		wheel_v, wheel_h := widgets.wheel_dominant(&_av.wheel)
		over_canvas := im.IsWindowHovered(im.HoveredFlags_ChildWindows) && mp.x >= x0 && mp.x <= x1
		_av.over_canvas = over_canvas
		if over_canvas {
			if wheel := wheel_v; wheel != 0 {
				t_at := (mp.x - tx0) / pps
				_av.zoom = clamp(_av.zoom * math.pow(f32(1.15), wheel), 1, 200)
				new_pps := pps_fit * _av.zoom
				_av.pan = t_at + (x0 + _ANIM_PAD_X - mp.x) / new_pps
				pps = new_pps
				visible = span_px / pps
				_av.pan = clamp(_av.pan, 0, max(length - visible, 0))
				tx0 = x0 + _ANIM_PAD_X - _av.pan * pps
			}
			// Horizontal wheel (a trackpad's sideways swipe) pans, signed the
			// way imgui scrolls its own windows: positive moves the view
			// toward earlier time.
			if wheel_h != 0 {
				step := span_px * 0.15 / pps // a sixth of the view per notch
				_av.pan = clamp(_av.pan - wheel_h * step, 0, max(length - visible, 0))
				tx0 = x0 + _ANIM_PAD_X - _av.pan * pps
			}
			// Middle-drag pans too, for a mouse without a sideways wheel.
			if im.IsMouseDragging(.Middle, 1) {
				_av.pan = clamp(_av.pan - im.GetIO().MouseDelta.x / pps, 0, max(length - visible, 0))
				tx0 = x0 + _ANIM_PAD_X - _av.pan * pps
			}
		}
	}

	// Canvas drawing is clipped to its own column: zoomed in, keys and ticks
	// fall outside it and would otherwise paint over the property panel.
	canvas_clip_min := im.Vec2{x0, origin.y}
	canvas_clip_max := im.Vec2{x1, rows_y + body_h}

	// --- Ruler: dragging it scrubs (the only scrub surface).
	im.SetCursorScreenPos(im.Vec2{x0, origin.y})
	im.InvisibleButton("##anim_ruler", im.Vec2{max(x1 - x0, 1), ruler_h})
	if im.IsItemActive() {
		_pv.time = clamp(_pv_snap_time(clip, (im.GetMousePos().x - tx0) / pps), 0, clip.length)
		_pv.active = true
	}
	im.DrawList_AddRectFilled(dl, im.Vec2{x0, origin.y}, im.Vec2{x1, origin.y + ruler_h}, im.GetColorU32(.FrameBg, 0.6))
	im.DrawList_PushClipRect(dl, canvas_clip_min, canvas_clip_max, true)
	fps := anim.animation_clip_frame_rate(clip)
	switch _anim_ruler() {
	case .Time:
		_pv_ruler_time(dl, origin.y, ruler_h, tx0, pps, length)
	case .Frames:
		_pv_ruler_frames(dl, origin.y, ruler_h, tx0, pps, length, fps)
	case .Frames_And_Time:
		// Each ruler takes half the band: time above, frames below, next to
		// the keys they count. A divider parts the two.
		half := ruler_h * 0.5
		_pv_ruler_time(dl, origin.y, half, tx0, pps, length)
		im.DrawList_AddLine(dl, im.Vec2{x0, origin.y + half}, im.Vec2{x1, origin.y + half}, im.GetColorU32(.Border), 1)
		_pv_ruler_frames(dl, origin.y + half, half, tx0, pps, length, fps)
	}
	im.DrawList_PopClipRect(dl)

	// --- Rows surface (left panel + canvas share it, hit-tested by x). It
	// spans the splitter gap too: AllowOverlap lets the splitter, submitted
	// last, take the pointer there.
	im.SetCursorScreenPos(im.Vec2{origin.x, rows_y})
	im.SetNextItemAllowOverlap()
	im.InvisibleButton("##anim_sheet", im.Vec2{avail.x, body_h})
	hovered := im.IsItemHovered()
	mp := im.GetMousePos()
	// The sheet row under the pointer, -1 off the rows (below the last one).
	row_at := hovered ? int((mp.y - rows_y) / _ANIM_ROW_H) : -1
	if row_at >= nrows do row_at = -1

	// A press on an Object row's arrow (or the indent left of it) collapses or
	// expands it, in both modes. This frame keeps the rows it built, the next
	// frame shows the change. A click on its name pings the transform in the
	// hierarchy, a double-click selects it (the first click of the pair pings).
	root_name := _pv_root_name()
	if row_at >= 0 && rows[row_at].kind == .Object && mp.x < left_x1 {
		r := rows[row_at]
		name_x := _pv_obj_name_x(origin.x, _pv_row_indent(r))
		if im.IsItemActivated() && mp.x < name_x do _pv_collapse_toggle(r.target)
		if !(_av.path_edit && _av.path_target == r.target) {
			full := r.target == "" ? root_name : r.target
			tH, ok := anim._animation_resolve_target(_pv.owner, r.target)
			if ok {
				widgets.tooltip_unchecked(fmt.ctprintf("%s\nClick: ping\nDouble-click: select", full))
				if mp.x >= name_x {
					if im.IsMouseDoubleClicked(.Left) {
						engine.inspector_request_select(tH)
					} else if im.IsMouseClicked(.Left) {
						engine.inspector_request_ping(tH)
					}
				}
			} else {
				widgets.tooltip_unchecked(fmt.ctprintf("%s\nNot found under %s", full, root_name))
			}
		}
	}
	// A press on a vector row's arrow (or the indent left of it) shows or
	// hides its Lane rows.
	if row_at >= 0 && rows[row_at].kind == .Channel && mp.x < _pv_row_label_x(origin.x, rows[row_at]) && im.IsItemActivated() {
		ch := &clip.channels[rows[row_at].ch]
		if anim.animation_channel_mask_width(ch) >= 2 do _pv_expand_toggle(sheet_channel_key(ch, context.temp_allocator))
	}

	// Left panel rows (both modes: this is where curves pick their channel).
	// An Object row shows its arrow and the transform's name. A property row's
	// value fields sit at the column's right edge and the name is clipped
	// short of them.
	im.DrawList_PushClipRect(dl, im.Vec2{origin.x, rows_y}, im.Vec2{left_x1, rows_y + body_h}, true)
	for r, i in rows {
		ry := rows_y + f32(i) * _ANIM_ROW_H
		if r.kind == .Object {
			im.DrawList_AddRectFilled(dl, im.Vec2{origin.x, ry}, im.Vec2{left_x1, ry + _ANIM_ROW_H}, im.GetColorU32(.FrameBg, 0.6))
			name_x := _pv_obj_name_x(origin.x, _pv_row_indent(r))
			_pv_draw_collapse_arrow(dl, im.Vec2{name_x - 4 - _ANIM_ARROW_W * 0.5, ry + _ANIM_ROW_H * 0.5}, !_av.collapsed[r.target])
			if _av.path_edit && _av.path_target == r.target do continue // the path field covers the name
			_pv_draw_obj_label(dl, r.target, root_name, name_x, ry, left_x1 - 4)
			continue
		}
		ch := &clip.channels[r.ch]
		if r.kind == .Lane {
			// A Lane row: the lane's name in its curve colour.
			if i % 2 == 1 {
				im.DrawList_AddRectFilled(dl, im.Vec2{origin.x, ry}, im.Vec2{left_x1, ry + _ANIM_ROW_H}, im.GetColorU32(.FrameBg, 0.25))
			}
			lane_names := [4]cstring{"x", "y", "z", "w"}
			comp_cols := _ANIM_COMP_COLS
			im.DrawList_AddText(dl, im.Vec2{_pv_row_label_x(origin.x, r), ry + 3}, im.GetColorU32ImVec4(comp_cols[r.lane]), lane_names[r.lane])
			continue
		}
		// A split row is selected when any of its lane channels is.
		row_sel := r.ch == _av.sel_ch
		if r.split && !row_sel {
			row_sel = slice.contains(_pv_group(clip, r.ch), _av.sel_ch)
		}
		if row_sel {
			im.DrawList_AddRectFilled(dl, im.Vec2{origin.x, ry}, im.Vec2{left_x1, ry + _ANIM_ROW_H}, im.GetColorU32(.Header, 0.7))
		} else if i % 2 == 1 {
			im.DrawList_AddRectFilled(dl, im.Vec2{origin.x, ry}, im.Vec2{left_x1, ry + _ANIM_ROW_H}, im.GetColorU32(.FrameBg, 0.25))
		}
		label_x := _pv_row_label_x(origin.x, r)
		if anim.animation_channel_mask_width(ch) >= 2 {
			open := _av.expanded[sheet_channel_key(ch, context.temp_allocator)]
			_pv_draw_collapse_arrow(dl, im.Vec2{label_x - 4 - _ANIM_ARROW_W * 0.5, ry + _ANIM_ROW_H * 0.5}, open)
		}
		label, resolved := _pv_ch_label(ch)
		col := resolved ? im.GetColorU32(.Text) : im.GetColorU32ImVec4(_ANIM_WARN_COL)
		name_x1 := left_x1 - _pv_row_values_w(ch) - 8
		im.DrawList_PushClipRect(dl, im.Vec2{origin.x, ry}, im.Vec2{max(name_x1, origin.x), ry + _ANIM_ROW_H}, true)
		im.DrawList_AddText(dl, im.Vec2{label_x, ry + 3}, col, label)
		im.DrawList_PopClipRect(dl)
	}
	im.DrawList_PopClipRect(dl)

	// Right-click a property row: channel operations. An Object row has none.
	if hovered && mp.x < x0 && row_at >= 0 && rows[row_at].kind == .Channel &&
	   im.IsMouseClicked(.Right) {
		_av.sel_ch = rows[row_at].ch
		_av.sel_key = -1
		im.OpenPopup("##anim_ch_ctx")
	}
	// Right-click an Object row: its path.
	if hovered && mp.x < x0 && row_at >= 0 && rows[row_at].kind == .Object &&
	   im.IsMouseClicked(.Right) {
		_pv_view_str_set(&_av.ctx_target, rows[row_at].target)
		im.OpenPopup("##anim_obj_ctx")
	}
	if im.BeginPopup("##anim_obj_ctx") {
		if im.MenuItem("Edit Path", nil, false, doc != nil) do _pv_path_edit_begin(_av.ctx_target)
		im.EndPopup()
	}
	if im.BeginPopup("##anim_ch_ctx") {
		// A vector row's lanes, checked when enabled. Unchecking the last
		// enabled lane removes the row, as Remove Property does. On a split
		// row a lane is checked when a channel animates it: unchecking frees
		// that channel, checking adds one.
		if _av.sel_ch >= 0 && _av.sel_ch < len(clip.channels) {
			ch := &clip.channels[_av.sel_ch]
			group := _pv_group(clip, _av.sel_ch)
			if width := anim.animation_channel_mask_width(ch); width >= 2 {
				im.SeparatorText("Lanes")
				lane_names := [4]cstring{"x", "y", "z", "w"}
				// A lane change frees or adds channels: `group` and `ch` are
				// stale after it, so the items below wait for the next frame.
				changed := false
				for l in 0 ..< width {
					if len(group) == 1 {
						on := l not_in _pv_lanes_off(ch)
						if im.MenuItem(lane_names[l], nil, on, doc != nil) {
							_pv_lane_set(doc, clip, _av.sel_ch, l, !on)
							changed = true
							break // the row may be gone
						}
						continue
					}
					lc := sheet_lane_channel(clip, group, l)
					if im.MenuItem(lane_names[l], nil, lc >= 0, doc != nil) {
						_pv_split_lane_set(doc, clip, group, l, lc)
						changed = true
						break // channel indices shifted
					}
				}
				im.Separator()
				// Split or join, whichever the row allows: a joined row with
				// two or more enabled lanes splits, a split row joins.
				can_split := doc != nil && !changed && sheet_can_split(clip, _av.sel_ch)
				can_join := doc != nil && !changed && sheet_can_join(clip, group)
				if can_split && im.MenuItem("Split Lane Keys") {
					_pv_edit_begin(doc)
					{
						context.allocator = inspector.doc_alloc()
						sheet_split_lanes(clip, _av.sel_ch)
					}
					_pv_edit_commit(doc)
				}
				if can_join && im.MenuItem("Join Lane Keys") {
					if sheet_join_mixed_step(clip, group) {
						_pv_join_ask(clip, _av.sel_ch)
					} else {
						_pv_join_group(doc, clip, group)
					}
				}
				if can_split || can_join do im.Separator()
			}
		}
		// A quaternion row of an editable clip becomes an Euler row, the
		// authoring form with per-axis keys, masks and splits.
		if _av.sel_ch >= 0 && _av.sel_ch < len(clip.channels) && _pv_ch_is_rotation(&clip.channels[_av.sel_ch]) {
			if im.MenuItem("Convert to Euler", nil, false, doc != nil) {
				_pv_edit_begin(doc)
				{
					context.allocator = inspector.doc_alloc()
					sheet_rotation_to_euler(clip, _av.sel_ch)
				}
				_pv_edit_commit(doc)
			}
			im.Separator()
		}
		if im.MenuItem("Remove Property", nil, false, doc != nil) && _av.sel_ch >= 0 && _av.sel_ch < len(clip.channels) {
			// Every channel of the property, last first so the indices hold.
			group := _pv_group(clip, _av.sel_ch)
			_pv_edit_begin(doc)
			{
				context.allocator = inspector.doc_alloc()
				for i := len(group) - 1; i >= 0; i -= 1 do _pv_channel_remove(clip, group[i])
			}
			_pv_edit_commit(doc)
		}
		im.EndPopup()
	}

	// The menus above may have edited the clip: the rows as they are now.
	rows = _pv_sheet(doc, clip).rows[:]
	nrows = len(rows)
	if row_at >= nrows do row_at = -1

	frame := _Sheet_Frame{
		rows = rows, rows_y = rows_y, body_h = body_h,
		x0 = x0, x1 = x1, tx0 = tx0, pps = pps,
		hovered = hovered, mp = mp, row_at = row_at,
	}
	im.DrawList_PushClipRect(dl, canvas_clip_min, canvas_clip_max, true)
	if _av.mode == .Dopesheet {
		// A tangent drag belongs to the curve view: leaving it ends the drag.
		if _av.drag_tan do _pv_tan_drag_end(doc, true)
		_pv_sheet_dopesheet(doc, clip, dl, frame)
	} else {
		_pv_sheet_curves(doc, clip, dl, frame)
	}
	im.DrawList_PopClipRect(dl)

	// Playhead over everything, inside the canvas column.
	im.DrawList_PushClipRect(dl, canvas_clip_min, canvas_clip_max, true)
	px := tx0 + clamp(_pv.time, 0, length) * pps
	head_col := im.GetColorU32ImVec4(im.Vec4{0.92, 0.28, 0.28, 1})
	im.DrawList_AddLine(dl, im.Vec2{px, origin.y}, im.Vec2{px, rows_y + body_h}, head_col, 1)
	im.DrawList_AddTriangleFilled(dl, im.Vec2{px - 5, origin.y}, im.Vec2{px + 5, origin.y}, im.Vec2{px, origin.y + 8}, head_col)
	im.DrawList_PopClipRect(dl)

	// Shared drag update/commit (a drag started in either mode).
	if _av.drag_key {
		if !_pv_sel_valid(clip) || len(_av.sel) != len(_av.drag_t0) {
			// A key vanished mid-drag, so there is no edit to record.
			_av.drag_key = false
			undo.edit_session_abort(&_pv_session)
		} else if im.IsMouseDown(.Left) && !_av.drag_live && linalg.length(mp - _av.drag_press) < _ANIM_DRAG_PX {
			// A press is a click until the mouse has moved a few pixels: a
			// click selects and must not nudge the key's time or value. The
			// rest of the sheet draws as usual meanwhile.
		} else if im.IsMouseDown(.Left) {
			_av.drag_live = true
			// One delta for the whole selection, snapped, then clamped by the
			// tightest neighbour bound among the dragged keys so none of them
			// can cross another and reorder the channel.
			want := _pv_snap_time(clip, (mp.x - tx0) / pps) - _av.drag_from
			lo_d, hi_d := -max(f32), max(f32)
			for r, i in _av.sel {
				ch := &clip.channels[r.ch]
				mask := _pv_sel_mask(r.ch, len(ch.times))
				lo, hi := anim.animation_key_bounds(ch.times[:], mask, r.key, clip.length)
				lo_d = max(lo_d, lo - _av.drag_t0[i])
				hi_d = min(hi_d, hi - _av.drag_t0[i])
			}
			d := clamp(want, lo_d, hi_d)
			for r, i in _av.sel {
				clip.channels[r.ch].times[r.key] = _av.drag_t0[i] + d
			}
			if _av.drag_comp >= 0 && anim.animation_channel_is_float(&clip.channels[_av.sel_ch]) {
				// Curves: y edits the grabbed component's value on the primary
				// key only — the others have their own values to keep.
				ch := &clip.channels[_av.sel_ch]
				anim.animation_channel_floats(ch)[_av.sel_key][_av.drag_comp] = _pv_curve_y_to_v(mp.y, rows_y, body_h)
			}
			_pv_mark_edited(doc)
		} else if !_av.drag_live {
			// Released without moving: a click, nothing to record.
			undo.edit_session_abort(&_pv_session)
			_av.drag_key = false
		} else {
			ch := &clip.channels[_av.sel_ch]
			if ch.path == .Rotation && _av.drag_comp >= 0 do _pv_normalize_rot_key(ch, _av.sel_key)
			_pv_edit_commit(doc)
			_av.drag_key = false
		}
	}

	// Key context menu (opened by the mode-specific right-click handling).
	if im.BeginPopup("##anim_key_ctx") {
		_pv_draw_mode_items(doc, clip)
		im.Separator()
		can_delete := doc != nil && _pv_sel_valid(clip)
		label: cstring = len(_av.sel) > 1 ? fmt.ctprintf("Delete %d Keys", len(_av.sel)) : "Delete Key"
		if im.MenuItem(label, nil, false, can_delete) do _pv_delete_key(doc, clip)
		im.EndPopup()
	}

	// The sheet may have edited the clip (a key menu's Delete Key): the rows
	// as they are now.
	rows = _pv_sheet(doc, clip).rows[:]
	_pv_draw_row_values(doc, clip, rows, rows_y, left_x1)
	_pv_draw_path_field(doc, rows, origin.x, rows_y, left_x1)

	// Add Property closes the track list, under the last row. Submitted after
	// the mode handlers for the same reason as the splitter below — they read
	// the sheet button as the last item. A press here lands in the property
	// column below every row, so it matches no sheet case either way.
	// Fixed width, centered in the column, as the inspector's Add Component is
	// — narrowed only when the column is too thin to hold it.
	add_w := min(f32(220), max(left_w - 8, 1))
	im.SetCursorScreenPos(im.Vec2{
		origin.x + (left_w - add_w) * 0.5,
		rows_y + f32(nrows) * _ANIM_ROW_H + 4,
	})
	im.BeginDisabled(doc == nil)
	if im.Button("Add Property", im.Vec2{add_w, 0}) do im.OpenPopup("##anim_add_prop")
	im.EndDisabled()
	if im.BeginPopup("##anim_add_prop") {
		_pv_add_prop_object(doc, clip, _pv.owner, "", 0)
		im.EndPopup()
	}

	// Splitter between the property column and the canvas. Submitted LAST:
	// the mode handlers above query the sheet button as the last item, and a
	// later item is what wins the pointer over the AllowOverlap sheet.
	canvas_w := x1 - x0
	im.SetCursorScreenPos(im.Vec2{left_x1, origin.y})
	if widgets.splitter("##anim_split", true, &left_w, &canvas_w, _ANIM_MIN_LEFT_W, _ANIM_MIN_CANVAS_W) {
		_av.left_w = left_w
	}
}
