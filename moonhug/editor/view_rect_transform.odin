package editor

// The RectTransform inspector, Unity's layout. Replaces the generic rows for
// UI nodes (RectTransforms under a canvas):
//
//   [anchor preset]   Pos X    Pos Y    Pos Z        or   Left     Top      Pos Z
//   [   button    ]   Width    Height         [R]         Right    Bottom         [R]
//   > Anchors  (Min, Max)
//   Pivot
//   Rotation, Scale  (the Transform's rows; the Transform section is hidden)
//
// Per axis the fields follow the active object's anchors: coinciding anchors
// give a position and a size, separated anchors give the two edge offsets.
// The preset button opens the 4x4 anchor grid; Shift also sets the pivot,
// Alt also moves the rect onto the anchors. Anchor and pivot edits keep the
// rect where it is unless raw edit mode ([R]) is on, in which case only the
// values change.
//
// Multi-selection: every row shows the active object's value, a dash where
// the other selected objects disagree, and an edit writes the edited value
// into each object through its own anchors, pivot and parent (Left on one
// object and Left on another are the same edge, whatever their pivots). One
// gesture is one undo step over every object's changed fields. A selection
// with a node that has no parent rect (a canvas root) draws the generic rows.

import "core:fmt"
import "core:math"
import im "moonhug:external/odin-imgui"
import engine "../engine"
import "handles"
import "inspector"
import "undo"

@(phase={key=engine.Phase.EditorInit, order=1, mode=Editor})
rect_transform_inspector_install :: proc() {
	inspector.add_component_wrapper(typeid_of(engine.RectTransform), _rect_transform_inspector)
}


// One selected RectTransform with what its rows need. The first entry is
// the active object, the rows' displayed value.
@(private = "file")
_Rt_Target :: struct {
	rt:     ^engine.RectTransform,
	handle: engine.Handle,
	parent: engine.Rect,
	peer:   inspector.Multi_Peer, // zero for the active object
	start:  engine.RectTransform,  // values when the session opened, for override recording
}

@(private = "file") _rt_targets: [dynamic]_Rt_Target // rebuilt every frame
@(private = "file") _rt_edit: undo.Edit_Session
@(private = "file") _rt_edit_targets: [dynamic]_Rt_Target // the session's objects and their start values
@(private = "file") _rt_path_prefix: string

@(private = "file")
_rect_transform_inspector :: proc(ctx: ^inspector.Component_Ctx) {
	rt := cast(^engine.RectTransform)ctx.ptr
	if !_rt_collect(rt) {
		inspector.draw(ctx)
		return
	}
	// A gesture that ended without the row noticing (selection change).
	if _rt_edit.active && !im.IsAnyItemActive() do _rt_session_end()
	_rt_path_prefix = ctx.path_prefix

	// A LayoutGroup owns a laid-out child's position and size: Unity greys
	// them and says so.
	driven := false
	for t in _rt_targets do if engine.rect_transform_driven(t.rt.owner) do driven = true
	if driven do im.TextDisabled("Some values driven by LayoutGroup")
	_rt_draw_position_block(driven)
	_rt_draw_anchor_presets_popup()
	_rt_draw_anchors()
	_rt_draw_pivot()
	_rt_draw_transform_rows(rt.owner)
}

// The active object and its peers, each with its parent rect. false when one
// of them has none.
@(private = "file")
_rt_collect :: proc(active: ^engine.RectTransform) -> bool {
	clear(&_rt_targets)
	frame, ok := engine.rect_frame(active.owner)
	if !ok do return false
	owned, _ := engine.transform_get_comp(active.owner, engine.RectTransform)
	append(&_rt_targets, _Rt_Target{rt = active, handle = owned.handle, parent = frame.parent})
	for peer in inspector.multi_peers() {
		prt := cast(^engine.RectTransform)peer.base
		pframe, pok := engine.rect_frame(prt.owner)
		if !pok do return false
		append(&_rt_targets, _Rt_Target{rt = prt, handle = peer.handle, parent = pframe.parent, peer = peer})
	}
	return true
}

@(private = "file")
_rt_multi :: proc() -> bool {
	return len(_rt_targets) > 1
}

// --- Undo session --------------------------------------------------------------------

@(private = "file")
_rt_session_begin :: proc(label: string) {
	if _rt_edit.active do return
	targets := make([dynamic]undo.Edit_Target, 0, len(_rt_targets) * 5, context.temp_allocator)
	clear(&_rt_edit_targets)
	for &t in _rt_targets {
		append(&targets, undo.edit_target_pooled(t.handle, &t.rt.anchor_min, typeid_of([2]f32)))
		append(&targets, undo.edit_target_pooled(t.handle, &t.rt.anchor_max, typeid_of([2]f32)))
		append(&targets, undo.edit_target_pooled(t.handle, &t.rt.pivot, typeid_of([2]f32)))
		append(&targets, undo.edit_target_pooled(t.handle, &t.rt.anchored_position, typeid_of([3]f32)))
		append(&targets, undo.edit_target_pooled(t.handle, &t.rt.size_delta, typeid_of([2]f32)))
		t.start = t.rt^
		append(&_rt_edit_targets, t)
	}
	_rt_edit = undo.edit_session_begin(targets[:], label)
}

@(private = "file")
_rt_session_end :: proc() {
	if !_rt_edit.active do return
	undo.edit_session_end(&_rt_edit)
	// Prefab overrides for the fields the gesture changed, on each object's
	// own instance.
	for t in _rt_edit_targets {
		_rt_record(t, &t.rt.anchor_min, typeid_of([2]f32), "anchor_min", t.rt.anchor_min != t.start.anchor_min)
		_rt_record(t, &t.rt.anchor_max, typeid_of([2]f32), "anchor_max", t.rt.anchor_max != t.start.anchor_max)
		_rt_record(t, &t.rt.pivot, typeid_of([2]f32), "pivot", t.rt.pivot != t.start.pivot)
		_rt_record(t, &t.rt.anchored_position, typeid_of([3]f32), "anchored_position", t.rt.anchored_position != t.start.anchored_position)
		_rt_record(t, &t.rt.size_delta, typeid_of([2]f32), "size_delta", t.rt.size_delta != t.start.size_delta)
	}
	clear(&_rt_edit_targets)
}

@(private = "file")
_rt_record :: proc(t: _Rt_Target, ptr: rawptr, tid: typeid, name: string, changed: bool) {
	if !changed do return
	path := fmt.tprintf("%s%s", _rt_path_prefix, name)
	if t.peer.base == nil {
		inspector.record_nested_override(ptr, tid, path, true)
	} else {
		inspector.record_peer_override(t.peer, ptr, tid, path)
	}
}

// A block of drag fields drew inside an imgui group and the group just
// ended: open the session on the frame a drag or a typed edit began, close it
// on release. imgui forwards any field's gesture to the group, so a gesture
// on any field in the block counts.
@(private = "file")
_rt_gesture :: proc(label: string) {
	if im.IsItemActivated() do _rt_session_begin(label)
	if im.IsItemDeactivatedAfterEdit() do _rt_session_end()
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

_rt_keep_rect :: engine.rect_transform_keep_rect

@(private = "file")
_rt_set_anchors :: proc(t: _Rt_Target, amin, amax: [2]f32, keep_rect: bool) {
	rect := engine.rect_resolve(t.parent, t.rt)
	t.rt.anchor_min = amin
	t.rt.anchor_max = amax
	if keep_rect do _rt_keep_rect(t.rt, t.parent, rect)
}

@(private = "file")
_rt_set_pivot :: proc(t: _Rt_Target, pivot: [2]f32, keep_rect: bool) {
	rect := engine.rect_resolve(t.parent, t.rt)
	t.rt.pivot = pivot
	if keep_rect do _rt_keep_rect(t.rt, t.parent, rect)
}

// --- Position block ------------------------------------------------------------------

@(private = "file") _RT_COLUMNS :: 3

// The cell values of one object: row 0 then row 1, three columns, following
// the ACTIVE object's stretch modes so peers are compared on the same
// quantity.
@(private = "file")
_rt_cells :: proc(rt: ^engine.RectTransform, stretch_x, stretch_y: bool) -> (cells: [2][_RT_COLUMNS]f32) {
	offset_min, offset_max := _rt_offsets(rt)
	cells[0][0] = offset_min.x if stretch_x else rt.anchored_position.x
	cells[1][0] = -offset_max.x if stretch_x else rt.size_delta.x
	cells[0][1] = -offset_max.y if stretch_y else rt.anchored_position.y
	cells[1][1] = offset_min.y if stretch_y else rt.size_delta.y
	cells[0][2] = rt.anchored_position.z
	return
}

// Writes one cell's value into an object.
@(private = "file")
_rt_apply_cell :: proc(rt: ^engine.RectTransform, row, col: int, value: f32, stretch_x, stretch_y: bool) {
	offset_min, offset_max := _rt_offsets(rt)
	switch {
	case col == 0 && stretch_x:
		if row == 0 { offset_min.x = value } else { offset_max.x = -value }
		_rt_set_offsets(rt, 0, offset_min.x, offset_max.x)
	case col == 0:
		if row == 0 { rt.anchored_position.x = value } else { rt.size_delta.x = value }
	case col == 1 && stretch_y:
		if row == 0 { offset_max.y = -value } else { offset_min.y = value }
		_rt_set_offsets(rt, 1, offset_min.y, offset_max.y)
	case col == 1:
		if row == 0 { rt.anchored_position.y = value } else { rt.size_delta.y = value }
	case col == 2:
		if row == 0 do rt.anchored_position.z = value
	}
}

@(private = "file")
_rt_mixed :: proc(a, b: f32) -> bool {
	return math.abs(a - b) > 1e-5
}

@(private = "file")
_rt_draw_position_block :: proc(driven: bool) {
	active := _rt_targets[0]
	rt := active.rt
	stretch_x := rt.anchor_min.x != rt.anchor_max.x
	stretch_y := rt.anchor_min.y != rt.anchor_max.y
	cells := _rt_cells(rt, stretch_x, stretch_y)
	mixed: [2][_RT_COLUMNS]bool
	for t in _rt_targets[1:] {
		pc := _rt_cells(t.rt, stretch_x, stretch_y)
		for row in 0 ..< 2 do for col in 0 ..< _RT_COLUMNS do if _rt_mixed(pc[row][col], cells[row][col]) do mixed[row][col] = true
	}
	labels: [2][_RT_COLUMNS]cstring
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
	window_x := im.GetWindowPos().x - im.GetScrollX()

	// The anchor preset button fills the label column's height for the block.
	// Mixed anchors across the selection draw no anchor mark.
	btn := min(block_h, inspector.field_label_width() - style.ItemSpacing.x)
	btn_pos := im.GetCursorScreenPos()
	btn_pos.y += (block_h - btn) * 0.5
	im.SetCursorScreenPos(btn_pos)
	if im.InvisibleButton("##rt_anchor_preset", {btn, btn}) do im.OpenPopup("##rt_anchor_presets")
	if im.IsItemHovered() do im.SetTooltip("Anchor presets")
	anchors_mixed := false
	for t in _rt_targets[1:] do if t.rt.anchor_min != rt.anchor_min || t.rt.anchor_max != rt.anchor_max do anchors_mixed = true
	_rt_anchor_icon(im.GetWindowDrawList(), btn_pos, btn, rt.anchor_min, rt.anchor_max, im.IsItemHovered() || im.IsItemActive(), false, anchors_mixed)
	block_top := btn_pos.y - (block_h - btn) * 0.5

	// Three columns of label-over-field, right of the label column. Grouped so
	// _rt_gesture below sees a drag on any cell as the block's gesture.
	im.BeginGroup()
	im.SetCursorPosX(field_x)
	avail := im.GetContentRegionAvail().x
	col_w := (avail - f32(_RT_COLUMNS - 1) * style.ItemSpacing.x) / f32(_RT_COLUMNS)
	for row in 0 ..< 2 {
		y := block_top + f32(row) * (line_h + frame_h + style.ItemSpacing.y)
		for i in 0 ..< _RT_COLUMNS {
			if labels[row][i] == nil do continue
			im.SetCursorScreenPos({window_x + field_x + f32(i) * (col_w + style.ItemSpacing.x), y})
			im.TextUnformatted(labels[row][i])
		}
		for i in 0 ..< _RT_COLUMNS {
			im.SetCursorScreenPos({window_x + field_x + f32(i) * (col_w + style.ItemSpacing.x), y + line_h})
			if labels[row][i] == nil {
				// The raw edit toggle sits in the empty cell.
				if row == 1 do _rt_draw_raw_toggle(frame_h)
				continue
			}
			im.SetNextItemWidth(col_w)
			inspector.current_field_mixed = mixed[row][i]
			cell_driven := driven && i < 2 // position and size; depth stays the node's
			im.BeginDisabled(cell_driven)
			inspector.drag_float(fmt.ctprintf("##rt_cell_%d_%d", row, i), &shown[row][i], 0.1)
			im.EndDisabled()
			inspector.multi_clear_mixed()
		}
	}
	// Leave the cursor below the block.
	im.SetCursorScreenPos({window_x + x0, block_top + block_h})
	im.Dummy({0, 0})
	im.EndGroup()

	_rt_gesture("Rect Transform")
	if shown == cells do return
	if !_rt_edit.active do _rt_session_begin("Rect Transform") // a typed value landing without a latch
	for row in 0 ..< 2 do for col in 0 ..< _RT_COLUMNS {
		if shown[row][col] == cells[row][col] do continue
		for t in _rt_targets do _rt_apply_cell(t.rt, row, col, shown[row][col], stretch_x, stretch_y)
	}
	inspector.mark_inspector_changed()
}

@(private = "file")
_rt_draw_raw_toggle :: proc(size: f32) {
	on := handles.rect_raw_edit // the click below flips the flag; the pop must match the push
	if on do im.PushStyleColorImVec4(.Button, im.GetStyleColorVec4(.ButtonActive)^)
	if im.Button("R", {size, size}) do handles.rect_raw_edit = !handles.rect_raw_edit
	if on do im.PopStyleColor()
	if im.IsItemHovered() do im.SetTooltip("Raw edit mode: anchor and pivot edits leave position and size as they are, so the rect moves")
}

// --- Anchors and pivot ---------------------------------------------------------------

// Mixed flags for a [2]f32 field across the selection, for a drag_float2 row.
@(private = "file")
_rt_mixed2 :: proc(get: proc(rt: ^engine.RectTransform) -> [2]f32) {
	inspector.multi_clear_mixed()
	a := get(_rt_targets[0].rt)
	for t in _rt_targets[1:] {
		b := get(t.rt)
		for i in 0 ..< 2 do if _rt_mixed(a[i], b[i]) {
			inspector.current_field_mixed = true
			inspector.current_field_mixed_comps[i] = true
		}
	}
}

@(private = "file")
_rt_draw_anchors :: proc() {
	if !im.TreeNodeEx("Anchors", {.SpanAvailWidth}) do return
	defer im.TreePop()
	rt := _rt_targets[0].rt
	amin := rt.anchor_min
	amax := rt.anchor_max
	im.BeginGroup()
	_rt_mixed2(proc(rt: ^engine.RectTransform) -> [2]f32 { return rt.anchor_min })
	changed_min := inspector.drag_float2(inspector.field_row("Min"), &amin, 0.01, 0, 1)
	_rt_mixed2(proc(rt: ^engine.RectTransform) -> [2]f32 { return rt.anchor_max })
	changed_max := inspector.drag_float2(inspector.field_row("Max"), &amax, 0.01, 0, 1)
	im.EndGroup()
	inspector.multi_clear_mixed()
	_rt_gesture("Anchors")
	if !changed_min && !changed_max do return
	if !_rt_edit.active do _rt_session_begin("Anchors")
	// Only the moved components reach the objects, the active one included;
	// the moved anchor pushes the other one along rather than crossing it.
	// Decided before the loop: the active object is the first one written.
	moved_min, moved_max: [2]bool
	for i in 0 ..< 2 {
		moved_min[i] = amin[i] != rt.anchor_min[i]
		moved_max[i] = amax[i] != rt.anchor_max[i]
	}
	for t in _rt_targets {
		nmin := t.rt.anchor_min
		nmax := t.rt.anchor_max
		for i in 0 ..< 2 {
			if moved_min[i] {
				nmin[i] = amin[i]
				nmax[i] = max(nmax[i], nmin[i])
			}
			if moved_max[i] {
				nmax[i] = amax[i]
				nmin[i] = min(nmin[i], nmax[i])
			}
		}
		_rt_set_anchors(t, nmin, nmax, !handles.rect_raw_edit)
	}
	inspector.mark_inspector_changed()
}

@(private = "file")
_rt_draw_pivot :: proc() {
	rt := _rt_targets[0].rt
	pivot := rt.pivot
	im.BeginGroup()
	_rt_mixed2(proc(rt: ^engine.RectTransform) -> [2]f32 { return rt.pivot })
	changed := inspector.drag_float2(inspector.field_row("Pivot"), &pivot, 0.01)
	im.EndGroup()
	inspector.multi_clear_mixed()
	_rt_gesture("Pivot")
	if !changed do return
	if !_rt_edit.active do _rt_session_begin("Pivot")
	moved: [2]bool
	for i in 0 ..< 2 do moved[i] = pivot[i] != rt.pivot[i] // before the loop: the active is written first
	for t in _rt_targets {
		np := t.rt.pivot
		for i in 0 ..< 2 do if moved[i] do np[i] = pivot[i]
		_rt_set_pivot(t, np, !handles.rect_raw_edit)
	}
	inspector.mark_inspector_changed()
}

// The Transform's rotation and scale, drawn here so the node shows one
// transform block like Unity. The rows record against the transforms, so the
// transform owner and the transform peers replace the component's for them.
@(private = "file")
_rt_draw_transform_rows :: proc(tH: engine.Transform_Handle) {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return
	undo.push_transform_owner(tH)
	defer undo.pop_owner()
	peers: []inspector.Multi_Peer
	if _rt_multi() do peers = multi_transform_peers(tH, sel_scene_items())
	prev_peers := inspector.multi_set_peers(peers)
	defer inspector.multi_set_peers(prev_peers)
	drawer := inspector.resolve_property_drawer(typeid_of(^[3]f32))
	_wrap_transform_rotation_override(tH, t, drawer)
	_wrap_transform_field_override(tH, t, &t.scale, "scale", typeid_of([3]f32), drawer, typeid_of(^[3]f32), "Scale")
}

// Whether the Transform section stays hidden for `sel`: every selected node
// is a UI node the RectTransform inspector covers.
rect_transform_covers_selection :: proc(active: engine.Transform_Handle, sel: []engine.Transform_Handle) -> bool {
	if _, ok := engine.rect_frame(active); !ok do return false
	for h in sel {
		if _, ok := engine.rect_frame(h); !ok do return false
	}
	return true
}

// --- Anchor presets ------------------------------------------------------------------

// Column c: left, center, right, stretch. Row r: top, middle, bottom, stretch.
@(private = "file") _RT_PRESET_H := [4][2]f32{{0, 0}, {0.5, 0.5}, {1, 1}, {0, 1}}
@(private = "file") _RT_PRESET_V := [4][2]f32{{1, 1}, {0.5, 0.5}, {0, 0}, {0, 1}}
@(private = "file") _RT_PRESET_H_NAMES := [4]cstring{"left", "center", "right", "stretch"}
@(private = "file") _RT_PRESET_V_NAMES := [4]cstring{"top", "middle", "bottom", "stretch"}
@(private = "file") _RT_PRESET_CELL :: f32(40)

@(private = "file")
_rt_draw_anchor_presets_popup :: proc() {
	if !im.BeginPopup("##rt_anchor_presets") do return
	defer im.EndPopup()
	rt := _rt_targets[0].rt
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
			_rt_anchor_icon(dl, p, cell, amin, amax, im.IsItemHovered(), current, false)
			if clicked {
				_rt_apply_preset(amin, amax, c == 3, r == 3, io.KeyShift, io.KeyAlt)
				im.CloseCurrentPopup()
			}
		}
	}
	im.SetCursorScreenPos({origin.x, grid_top + 4 * (cell + style.ItemSpacing.y)})
	im.TextDisabled("Shift: also set pivot   Alt: also set position")
}

// Alt (also set position) puts the rect onto the anchors: position zero, and
// on a stretched axis a size equal to the anchor span. Otherwise the rect
// stays where it is unless raw edit mode is on. Every selected object.
@(private = "file")
_rt_apply_preset :: proc(amin, amax: [2]f32, stretch_x, stretch_y, set_pivot, set_position: bool) {
	_rt_session_begin("Anchor Preset")
	keep := !handles.rect_raw_edit && !set_position
	for t in _rt_targets {
		if set_pivot {
			pivot := [2]f32{0.5 if stretch_x else amin.x, 0.5 if stretch_y else amin.y}
			_rt_set_pivot(t, pivot, keep)
		}
		_rt_set_anchors(t, amin, amax, keep)
		if set_position {
			t.rt.anchored_position.xy = 0
			if stretch_x do t.rt.size_delta.x = 0
			if stretch_y do t.rt.size_delta.y = 0
		}
	}
	inspector.mark_inspector_changed()
	_rt_session_end()
}

// The anchor icon: the parent as an outline, the anchors as a filled mark
// inside it. A coinciding pair on an axis is a short mark at that fraction,
// a separated pair a bar between the two. `mixed` draws the outline only.
@(private = "file")
_rt_anchor_icon :: proc(dl: ^im.DrawList, p: im.Vec2, size: f32, amin, amax: [2]f32, hot, current, mixed: bool) {
	inset := size * 0.18
	inner := size - 2 * inset
	q0 := im.Vec2{p.x + inset, p.y + inset}
	q1 := im.Vec2{q0.x + inner, q0.y + inner}
	outline := im.GetColorU32(.Text, 0.35 if !hot else 0.7)
	fill := im.GetColorU32(.Text, 0.75 if !hot else 1.0)
	if current do im.DrawList_AddRect(dl, p, {p.x + size, p.y + size}, im.GetColorU32(.ButtonActive), 3)
	im.DrawList_AddRect(dl, q0, q1, outline)
	if mixed do return

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
