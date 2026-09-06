package editor

// The RectTransform inspector, Unity's layout. Replaces the generic rows for
// a single UI node (a RectTransform under a canvas):
//
//   [anchor preset]   Pos X    Pos Y    Pos Z        or   Left     Top      Pos Z
//   [   button    ]   Width    Height         [R]         Right    Bottom         [R]
//   > Anchors  (Min, Max)
//   Pivot
//   Rotation, Scale  (the Transform's rows; the Transform section is hidden)
//
// Per axis the fields follow the anchors: coinciding anchors give a position
// and a size, separated anchors give the two edge offsets. The preset button
// opens the 4x4 anchor grid; Shift also sets the pivot, Alt also moves the
// rect onto the anchors. Anchor and pivot edits keep the rect where it is
// unless raw edit mode ([R]) is on, in which case only the values change.
//
// Every edit is one undo step over the five RectTransform fields (a session
// that records only what changed). Multi-selection and nodes without a
// parent rect (a canvas root) fall back to the generic rows.

import "core:fmt"
import im "moonhug:external/odin-imgui"
import engine "../engine"
import "inspector"
import "undo"

@(phase={key=engine.Phase.EditorInit, order=1, mode=Editor})
rect_transform_inspector_install :: proc() {
	inspector.add_component_wrapper(typeid_of(engine.RectTransform), _rect_transform_inspector)
}

// Raw edit mode: anchor and pivot changes leave anchored_position and
// size_delta alone, so the rect moves.
@(private = "file") _rt_raw_edit: bool

@(private = "file") _rt_edit: undo.Edit_Session
@(private = "file") _rt_start: engine.RectTransform // values when the session opened, for override recording
@(private = "file") _rt_path_prefix: string

@(private = "file")
_rect_transform_inspector :: proc(ctx: ^inspector.Component_Ctx) {
	rt := cast(^engine.RectTransform)ctx.ptr
	tH := rt.owner
	frame, has_frame := engine.rect_frame(tH)
	if !has_frame || inspector.multi_active() {
		inspector.draw(ctx)
		return
	}
	// A gesture that ended without the row noticing (selection change).
	if _rt_edit.active && !im.IsAnyItemActive() do _rt_session_end(rt)
	_rt_path_prefix = ctx.path_prefix
	owned, _ := engine.transform_get_comp(tH, engine.RectTransform)

	_rt_draw_position_block(owned.handle, rt, frame.parent)
	_rt_draw_anchor_presets_popup(owned.handle, rt, frame.parent)
	_rt_draw_anchors(owned.handle, rt, frame.parent)
	_rt_draw_pivot(owned.handle, rt, frame.parent)
	_rt_draw_transform_rows(tH)
}

// --- Undo session --------------------------------------------------------------------

@(private = "file")
_rt_session_begin :: proc(h: engine.Handle, rt: ^engine.RectTransform, label: string) {
	if _rt_edit.active do return
	targets := [?]undo.Edit_Target{
		undo.edit_target_pooled(h, &rt.anchor_min, typeid_of([2]f32)),
		undo.edit_target_pooled(h, &rt.anchor_max, typeid_of([2]f32)),
		undo.edit_target_pooled(h, &rt.pivot, typeid_of([2]f32)),
		undo.edit_target_pooled(h, &rt.anchored_position, typeid_of([3]f32)),
		undo.edit_target_pooled(h, &rt.size_delta, typeid_of([2]f32)),
	}
	_rt_edit = undo.edit_session_begin(targets[:], label)
	_rt_start = rt^
}

@(private = "file")
_rt_session_end :: proc(rt: ^engine.RectTransform) {
	if !_rt_edit.active do return
	undo.edit_session_end(&_rt_edit)
	// Prefab overrides for the fields the gesture changed.
	record :: proc(ptr: rawptr, tid: typeid, name: string, changed: bool) {
		if !changed do return
		inspector.record_nested_override(ptr, tid, fmt.tprintf("%s%s", _rt_path_prefix, name), true)
	}
	record(&rt.anchor_min, typeid_of([2]f32), "anchor_min", rt.anchor_min != _rt_start.anchor_min)
	record(&rt.anchor_max, typeid_of([2]f32), "anchor_max", rt.anchor_max != _rt_start.anchor_max)
	record(&rt.pivot, typeid_of([2]f32), "pivot", rt.pivot != _rt_start.pivot)
	record(&rt.anchored_position, typeid_of([3]f32), "anchored_position", rt.anchored_position != _rt_start.anchored_position)
	record(&rt.size_delta, typeid_of([2]f32), "size_delta", rt.size_delta != _rt_start.size_delta)
}

// A block of drag fields drew: open the session on the frame a drag or a
// typed edit began, close it on release. The latches come from the drag
// widgets themselves (drag_row_activated), so a gesture on any field in the
// block counts.
@(private = "file")
_rt_gesture :: proc(h: engine.Handle, rt: ^engine.RectTransform, label: string) -> (began: bool) {
	if inspector.drag_row_activated() {
		_rt_session_begin(h, rt, label)
		began = true
	}
	if inspector.drag_row_deactivated() do _rt_session_end(rt)
	return
}

// --- Rect math -----------------------------------------------------------------------

// The edge offsets Unity shows as Left/Right and Bottom/Top: the rect's
// edges relative to the anchor edges. offset_max is positive past the anchor,
// so Right = -offset_max.x and Top = -offset_max.y.
@(private = "file")
_rt_offsets :: proc(rt: ^engine.RectTransform) -> (offset_min, offset_max: [2]f32) {
	offset_min = rt.anchored_position.xy - rt.size_delta * rt.pivot
	offset_max = rt.anchored_position.xy + rt.size_delta * (1 - rt.pivot)
	return
}

@(private = "file")
_rt_set_offsets :: proc(rt: ^engine.RectTransform, axis: int, offset_min, offset_max: f32) {
	size := offset_max - offset_min
	rt.size_delta[axis] = size
	rt.anchored_position[axis] = offset_min + size * rt.pivot[axis]
}

// anchored_position and size_delta that resolve to `rect` with the current
// anchors and pivot.
@(private = "file")
_rt_keep_rect :: proc(rt: ^engine.RectTransform, parent, rect: engine.Rect) {
	lo := parent.pos + parent.size * rt.anchor_min
	hi := parent.pos + parent.size * rt.anchor_max
	rt.size_delta = rect.size - (hi - lo)
	pivot_pos := rect.pos + rect.size * rt.pivot
	rt.anchored_position.xy = pivot_pos - (lo + (hi - lo) * rt.pivot)
}

@(private = "file")
_rt_set_anchors :: proc(rt: ^engine.RectTransform, parent: engine.Rect, amin, amax: [2]f32, keep_rect: bool) {
	rect := engine.rect_resolve(parent, rt)
	rt.anchor_min = amin
	rt.anchor_max = amax
	if keep_rect do _rt_keep_rect(rt, parent, rect)
}

@(private = "file")
_rt_set_pivot :: proc(rt: ^engine.RectTransform, parent: engine.Rect, pivot: [2]f32, keep_rect: bool) {
	rect := engine.rect_resolve(parent, rt)
	rt.pivot = pivot
	if keep_rect do _rt_keep_rect(rt, parent, rect)
}

// --- Position block ------------------------------------------------------------------

@(private = "file") _RT_COLUMNS :: 3

@(private = "file")
_rt_draw_position_block :: proc(h: engine.Handle, rt: ^engine.RectTransform, parent: engine.Rect) {
	stretch_x := rt.anchor_min.x != rt.anchor_max.x
	stretch_y := rt.anchor_min.y != rt.anchor_max.y
	offset_min, offset_max := _rt_offsets(rt)

	// Values shown, one per cell: row 0 then row 1, three columns each.
	cells: [2][_RT_COLUMNS]f32
	labels: [2][_RT_COLUMNS]cstring
	cells[0][0] = offset_min.x if stretch_x else rt.anchored_position.x
	cells[1][0] = -offset_max.x if stretch_x else rt.size_delta.x
	cells[0][1] = -offset_max.y if stretch_y else rt.anchored_position.y
	cells[1][1] = offset_min.y if stretch_y else rt.size_delta.y
	cells[0][2] = rt.anchored_position.z
	labels[0][0] = "Left" if stretch_x else "Pos X"
	labels[1][0] = "Right" if stretch_x else "Width"
	labels[0][1] = "Top" if stretch_y else "Pos Y"
	labels[1][1] = "Bottom" if stretch_y else "Height"
	labels[0][2] = "Pos Z"
	shown := cells

	style := im.GetStyle()
	line_h := im.GetTextLineHeight()
	frame_h := im.GetFrameHeight()
	x0 := im.GetCursorPosX()
	field_x := x0 + inspector.field_label_width() + inspector.PREFIX_PADDING_RIGHT
	block_h := 2 * (line_h + frame_h) + style.ItemSpacing.y

	// The anchor preset button fills the label column's height for the block.
	btn := min(block_h, inspector.field_label_width() - style.ItemSpacing.x)
	btn_pos := im.GetCursorScreenPos()
	btn_pos.y += (block_h - btn) * 0.5
	im.SetCursorScreenPos(btn_pos)
	if im.InvisibleButton("##rt_anchor_preset", {btn, btn}) do im.OpenPopup("##rt_anchor_presets")
	if im.IsItemHovered() do im.SetTooltip("Anchor presets")
	_rt_anchor_icon(im.GetWindowDrawList(), btn_pos, btn, rt.anchor_min, rt.anchor_max, im.IsItemHovered() || im.IsItemActive(), false)
	block_top := btn_pos.y - (block_h - btn) * 0.5

	// Three columns of label-over-field, right of the label column.
	right := x0 + im.GetContentRegionAvail().x + (im.GetCursorPosX() - x0) // window-local right edge
	im.SetCursorPosX(field_x)
	avail := im.GetContentRegionAvail().x
	col_w := (avail - f32(_RT_COLUMNS - 1) * style.ItemSpacing.x) / f32(_RT_COLUMNS)
	col_x :: proc(field_x, col_w, spacing: f32, i: int) -> f32 { return field_x + f32(i) * (col_w + spacing) }
	_ = right
	for row in 0 ..< 2 {
		y := block_top + f32(row) * (line_h + frame_h + style.ItemSpacing.y)
		for i in 0 ..< _RT_COLUMNS {
			if labels[row][i] == nil do continue
			im.SetCursorScreenPos({im.GetWindowPos().x - im.GetScrollX() + col_x(field_x, col_w, style.ItemSpacing.x, i), y})
			im.TextUnformatted(labels[row][i])
		}
		for i in 0 ..< _RT_COLUMNS {
			im.SetCursorScreenPos({im.GetWindowPos().x - im.GetScrollX() + col_x(field_x, col_w, style.ItemSpacing.x, i), y + line_h})
			if labels[row][i] == nil {
				// The raw edit toggle sits in the empty cell.
				if row == 1 do _rt_draw_raw_toggle(frame_h)
				continue
			}
			im.SetNextItemWidth(col_w)
			inspector.drag_float(fmt.ctprintf("##rt_cell_%d_%d", row, i), &shown[row][i], 0.1)
		}
	}
	// Leave the cursor below the block.
	im.SetCursorScreenPos({im.GetWindowPos().x - im.GetScrollX() + x0, block_top + block_h})
	im.Dummy({0, 0})

	_rt_gesture(h, rt, "Rect Transform")
	if shown == cells do return
	if !_rt_edit.active do _rt_session_begin(h, rt, "Rect Transform") // a typed value landing without a latch
	if stretch_x {
		_rt_set_offsets(rt, 0, shown[0][0], -shown[1][0])
	} else {
		rt.anchored_position.x = shown[0][0]
		rt.size_delta.x = shown[1][0]
	}
	if stretch_y {
		_rt_set_offsets(rt, 1, shown[1][1], -shown[0][1])
	} else {
		rt.anchored_position.y = shown[0][1]
		rt.size_delta.y = shown[1][1]
	}
	rt.anchored_position.z = shown[0][2]
	inspector.mark_inspector_changed()
}

@(private = "file")
_rt_draw_raw_toggle :: proc(size: f32) {
	on := _rt_raw_edit // the click below flips the flag; the pop must match the push
	if on do im.PushStyleColorImVec4(.Button, im.GetStyleColorVec4(.ButtonActive)^)
	if im.Button("R", {size, size}) do _rt_raw_edit = !_rt_raw_edit
	if on do im.PopStyleColor()
	if im.IsItemHovered() do im.SetTooltip("Raw edit mode: anchor and pivot edits leave position and size as they are, so the rect moves")
}

// --- Anchors and pivot ---------------------------------------------------------------

@(private = "file")
_rt_draw_anchors :: proc(h: engine.Handle, rt: ^engine.RectTransform, parent: engine.Rect) {
	if !im.TreeNodeEx("Anchors", {.SpanAvailWidth}) do return
	defer im.TreePop()
	amin := rt.anchor_min
	amax := rt.anchor_max
	changed_min := inspector.drag_float2(inspector.field_row("Min"), &amin, 0.01, 0, 1)
	changed_max := inspector.drag_float2(inspector.field_row("Max"), &amax, 0.01, 0, 1)
	_rt_gesture(h, rt, "Anchors")
	if !changed_min && !changed_max do return
	if !_rt_edit.active do _rt_session_begin(h, rt, "Anchors")
	// The moved anchor pushes the other one along rather than crossing it.
	if changed_min do amax = {max(amax.x, amin.x), max(amax.y, amin.y)}
	if changed_max do amin = {min(amin.x, amax.x), min(amin.y, amax.y)}
	_rt_set_anchors(rt, parent, amin, amax, !_rt_raw_edit)
	inspector.mark_inspector_changed()
}

@(private = "file")
_rt_draw_pivot :: proc(h: engine.Handle, rt: ^engine.RectTransform, parent: engine.Rect) {
	pivot := rt.pivot
	changed := inspector.drag_float2(inspector.field_row("Pivot"), &pivot, 0.01)
	_rt_gesture(h, rt, "Pivot")
	if !changed do return
	if !_rt_edit.active do _rt_session_begin(h, rt, "Pivot")
	_rt_set_pivot(rt, parent, pivot, !_rt_raw_edit)
	inspector.mark_inspector_changed()
}

// The Transform's rotation and scale, drawn here so the node shows one
// transform block like Unity. The rows record against the transform, so its
// owner is pushed over the component's.
@(private = "file")
_rt_draw_transform_rows :: proc(tH: engine.Transform_Handle) {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return
	undo.push_transform_owner(tH)
	defer undo.pop_owner()
	prev_peers := inspector.multi_set_peers(nil)
	defer inspector.multi_set_peers(prev_peers)
	drawer := inspector.resolve_property_drawer(typeid_of(^[3]f32))
	_wrap_transform_rotation_override(tH, t, drawer)
	_wrap_transform_field_override(tH, t, &t.scale, "scale", typeid_of([3]f32), drawer, typeid_of(^[3]f32), "Scale")
}

// --- Anchor presets ------------------------------------------------------------------

// Column c: left, center, right, stretch. Row r: top, middle, bottom, stretch.
@(private = "file") _RT_PRESET_H := [4][2]f32{{0, 0}, {0.5, 0.5}, {1, 1}, {0, 1}}
@(private = "file") _RT_PRESET_V := [4][2]f32{{1, 1}, {0.5, 0.5}, {0, 0}, {0, 1}}
@(private = "file") _RT_PRESET_H_NAMES := [4]cstring{"left", "center", "right", "stretch"}
@(private = "file") _RT_PRESET_V_NAMES := [4]cstring{"top", "middle", "bottom", "stretch"}
@(private = "file") _RT_PRESET_CELL :: f32(40)

@(private = "file")
_rt_draw_anchor_presets_popup :: proc(h: engine.Handle, rt: ^engine.RectTransform, parent: engine.Rect) {
	if !im.BeginPopup("##rt_anchor_presets") do return
	defer im.EndPopup()
	io := im.GetIO()
	style := im.GetStyle()
	cell := _RT_PRESET_CELL
	label_w := im.CalcTextSize("stretch").x + style.ItemSpacing.x
	dl := im.GetWindowDrawList()

	// Column names over the grid.
	origin := im.GetCursorScreenPos()
	for c in 0 ..< 4 {
		name := _RT_PRESET_H_NAMES[c]
		tw := im.CalcTextSize(name).x
		im.SetCursorScreenPos({origin.x + label_w + f32(c) * (cell + style.ItemSpacing.x) + (cell - tw) * 0.5, origin.y})
		im.TextDisabled(name)
	}
	grid_top := origin.y + im.GetTextLineHeight() + style.ItemSpacing.y
	for r in 0 ..< 4 {
		y := grid_top + f32(r) * (cell + style.ItemSpacing.y)
		im.SetCursorScreenPos({origin.x, y + (cell - im.GetTextLineHeight()) * 0.5})
		im.TextDisabled(_RT_PRESET_V_NAMES[r])
		for c in 0 ..< 4 {
			p := im.Vec2{origin.x + label_w + f32(c) * (cell + style.ItemSpacing.x), y}
			im.SetCursorScreenPos(p)
			amin := [2]f32{_RT_PRESET_H[c][0], _RT_PRESET_V[r][0]}
			amax := [2]f32{_RT_PRESET_H[c][1], _RT_PRESET_V[r][1]}
			clicked := im.InvisibleButton(fmt.ctprintf("##rt_preset_%d_%d", r, c), {cell, cell})
			current := rt.anchor_min == amin && rt.anchor_max == amax
			_rt_anchor_icon(dl, p, cell, amin, amax, im.IsItemHovered(), current)
			if clicked {
				_rt_apply_preset(h, rt, parent, amin, amax, c == 3, r == 3, io.KeyShift, io.KeyAlt)
				im.CloseCurrentPopup()
			}
		}
	}
	im.SetCursorScreenPos({origin.x, grid_top + 4 * (cell + style.ItemSpacing.y)})
	im.TextDisabled("Shift: also set pivot   Alt: also set position")
}

// Alt (also set position) puts the rect onto the anchors: position zero, and
// on a stretched axis a size equal to the anchor span. Otherwise the rect
// stays where it is unless raw edit mode is on.
@(private = "file")
_rt_apply_preset :: proc(h: engine.Handle, rt: ^engine.RectTransform, parent: engine.Rect, amin, amax: [2]f32, stretch_x, stretch_y, set_pivot, set_position: bool) {
	_rt_session_begin(h, rt, "Anchor Preset")
	keep := !_rt_raw_edit && !set_position
	if set_pivot {
		pivot := [2]f32{0.5 if stretch_x else amin.x, 0.5 if stretch_y else amin.y}
		_rt_set_pivot(rt, parent, pivot, keep)
	}
	_rt_set_anchors(rt, parent, amin, amax, keep)
	if set_position {
		rt.anchored_position.xy = 0
		if stretch_x do rt.size_delta.x = 0
		if stretch_y do rt.size_delta.y = 0
	}
	inspector.mark_inspector_changed()
	_rt_session_end(rt)
}

// The anchor icon: the parent as an outline, the anchors as a filled mark
// inside it. A coinciding pair on an axis is a short mark at that fraction,
// a separated pair a bar between the two.
@(private = "file")
_rt_anchor_icon :: proc(dl: ^im.DrawList, p: im.Vec2, size: f32, amin, amax: [2]f32, hot, current: bool) {
	inset := size * 0.18
	inner := size - 2 * inset
	q0 := im.Vec2{p.x + inset, p.y + inset}
	q1 := im.Vec2{q0.x + inner, q0.y + inner}
	outline := im.GetColorU32(.Text, 0.35 if !hot else 0.7)
	fill := im.GetColorU32(.Text, 0.75 if !hot else 1.0)
	if current do im.DrawList_AddRect(dl, p, {p.x + size, p.y + size}, im.GetColorU32(.ButtonActive), 3)
	im.DrawList_AddRect(dl, q0, q1, outline)

	span :: proc(a, b, inner: f32) -> (lo, hi: f32) {
		if a == b {
			m := a * inner
			return m - 3, m + 3
		}
		return a * inner + 2, b * inner - 2
	}
	x0, x1 := span(amin.x, amax.x, inner)
	// Canvas y is up, screen y is down.
	yb, yt := span(amin.y, amax.y, inner)
	y0 := inner - yt
	y1 := inner - yb
	im.DrawList_AddRectFilled(dl, {q0.x + x0, q0.y + y0}, {q0.x + x1, q0.y + y1}, fill)
}
