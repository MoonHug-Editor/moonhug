package physics2d_editor

// Collider outlines in the scene view via the @(comp_on_draw_gizmos) hook — drawn
// only for objects in the selection (a parent selected counts). The outline
// geometry lives in the runtime package (packages/physics2d/gizmos.odin),
// shared with the in-app @(debug_draw) view — here only the selected-only
// policy and the color choice remain.
//
// In the Handles tool (T), bounds handles on the selected colliders resize
// them in their plane (@(comp_on_scene_handles)), one undo step per drag.

import "moonhug:packages/engine"
import "moonhug:libs/gizmos"
import "moonhug:editor/handles"
import "moonhug:editor/undo"
import physics2d "moonhug:packages/physics2d"

@(comp_on_draw_gizmos={component=BoxCollider2D})
comp_on_draw_gizmos_BoxCollider2D :: proc(c: ^physics2d.BoxCollider2D, ctx: handles.Gizmo_Context) {
	if .In_Selection not_in ctx.state do return
	physics2d.draw_box_collider_wires(c, physics2d.COLLIDER_GIZMO_COLOR)
}

@(comp_on_draw_gizmos={component=CircleCollider2D})
comp_on_draw_gizmos_CircleCollider2D :: proc(c: ^physics2d.CircleCollider2D, ctx: handles.Gizmo_Context) {
	if .In_Selection not_in ctx.state do return
	physics2d.draw_circle_collider_wires(c, physics2d.COLLIDER_GIZMO_COLOR)
}

@(comp_on_draw_gizmos={component=CapsuleCollider2D})
comp_on_draw_gizmos_CapsuleCollider2D :: proc(c: ^physics2d.CapsuleCollider2D, ctx: handles.Gizmo_Context) {
	if .In_Selection not_in ctx.state do return
	physics2d.draw_capsule_collider_wires(c, physics2d.COLLIDER_GIZMO_COLOR)
}

@(comp_on_draw_gizmos={component=PolygonCollider2D})
comp_on_draw_gizmos_PolygonCollider2D :: proc(c: ^physics2d.PolygonCollider2D, ctx: handles.Gizmo_Context) {
	if .In_Selection not_in ctx.state do return
	physics2d.draw_polygon_collider_wires(c, physics2d.COLLIDER_GIZMO_COLOR)
}

@(comp_on_draw_gizmos={component=EdgeCollider2D})
comp_on_draw_gizmos_EdgeCollider2D :: proc(c: ^physics2d.EdgeCollider2D, ctx: handles.Gizmo_Context) {
	if .In_Selection not_in ctx.state do return
	physics2d.draw_edge_collider_wires(c, physics2d.COLLIDER_GIZMO_COLOR)
}

// --- Bounds handles --------------------------------------------------------------
// The handles work in the collider's space (collider_space) with scaled
// sizes, as the outlines do, on the X and Y axes only. A field changes only
// on the axes the drag changed, so a click without a move, or the scale
// round trip, never touches the others.

@(private = "file")
_AXES_2D :: handles.Axes{.X, .Y}

@(private = "file")
_edit: undo.Edit_Session

@(private = "file")
_edit_begin :: proc(targets: []undo.Edit_Target, label: string) {
	_edit = undo.edit_session_begin(targets, label)
	handles.on_drag_lost(proc(_: rawptr) { undo.edit_session_end(&_edit) })
}

@(private = "file")
_unscale :: proc(field: ^[2]f32, now, before: [3]f32, s: [2]f32) {
	for i in 0 ..< 2 do _unscale1(&field[i], now[i], before[i], s[i])
}

@(private = "file")
_unscale1 :: proc(field: ^f32, now, before, s: f32) {
	if now != before && s > 1e-6 do field^ = now / s
}

// A box-shaped collider (box, capsule): its size and offset as box bounds.
@(private = "file")
_box_handles :: proc(c: ^engine.CompData, size_field, offset_field: ^[2]f32, size2, offset2, s: [2]f32, label: string) {
	h, ok := engine.comp_handle_of(c)
	if !ok do return
	gizmos.with_matrix(physics2d.collider_space(c.owner))
	size0 := [3]f32{size2.x, size2.y, 0}
	center0 := [3]f32{offset2.x, offset2.y, 0}
	size, center := size0, center0
	d := handles.box_bounds(handles.id_of(h), &center, &size, _AXES_2D, physics2d.COLLIDER_GIZMO_COLOR)
	if d.started {
		targets := [?]undo.Edit_Target{
			undo.edit_target_pooled(h, size_field, typeid_of([2]f32)),
			undo.edit_target_pooled(h, offset_field, typeid_of([2]f32)),
		}
		_edit_begin(targets[:], label)
	}
	if d.dragging || d.released {
		_unscale(size_field, size, size0, s)
		_unscale(offset_field, center, center0, s)
	}
	if d.released do undo.edit_session_end(&_edit)
}

@(comp_on_scene_handles={component=BoxCollider2D})
comp_on_scene_handles_BoxCollider2D :: proc(c: ^physics2d.BoxCollider2D, ctx: handles.Gizmo_Context) {
	if ctx.tool != .Handles do return
	s := physics2d.collider_scale(c.owner)
	size, offset := physics2d.box_scaled(c, s)
	_box_handles(&c.base, &c.size, &c.offset, size, offset, s, "Edit Box Collider 2D")
}

// The capsule's size is its bounding box, so box bounds edit it.
@(comp_on_scene_handles={component=CapsuleCollider2D})
comp_on_scene_handles_CapsuleCollider2D :: proc(c: ^physics2d.CapsuleCollider2D, ctx: handles.Gizmo_Context) {
	if ctx.tool != .Handles do return
	s := physics2d.collider_scale(c.owner)
	size, offset := physics2d.capsule_scaled(c, s)
	_box_handles(&c.base, &c.size, &c.offset, size, offset, s, "Edit Capsule Collider 2D")
}

@(comp_on_scene_handles={component=CircleCollider2D})
comp_on_scene_handles_CircleCollider2D :: proc(c: ^physics2d.CircleCollider2D, ctx: handles.Gizmo_Context) {
	if ctx.tool != .Handles do return
	h, ok := engine.comp_handle_of(&c.base)
	if !ok do return
	s := physics2d.collider_scale(c.owner)
	gizmos.with_matrix(physics2d.collider_space(c.owner))
	radius0, offset2 := physics2d.circle_scaled(c, s)
	center0 := [3]f32{offset2.x, offset2.y, 0}
	radius, center := radius0, center0
	d := handles.sphere_bounds(handles.id_of(h), &center, &radius, _AXES_2D, physics2d.COLLIDER_GIZMO_COLOR)
	if d.started {
		targets := [?]undo.Edit_Target{
			undo.edit_target_pooled(h, &c.radius, typeid_of(f32)),
			undo.edit_target_pooled(h, &c.offset, typeid_of([2]f32)),
		}
		_edit_begin(targets[:], "Edit Circle Collider 2D")
	}
	if d.dragging || d.released {
		_unscale1(&c.radius, radius, radius0, max(s.x, s.y))
		_unscale(&c.offset, center, center0, s)
	}
	if d.released do undo.edit_session_end(&_edit)
}

// --- Path handles ----------------------------------------------------------------
// A polygon's or an edge's points in the Handles tool: a dot per point to
// drag, a press on an edge that inserts a point there and drags it, and
// Alt+click on a point that deletes it, down to the three a polygon or the
// two an edge keeps. Each drag, insert or delete is one undo step of the
// point list. The handles work in the collider's space with scaled points,
// as the outlines do, and write the unscaled points back.

// The point a press on an edge inserted, dragged for as long as the press
// lasts. -1 between inserts.
@(private = "file")
_inserted: int = -1

@(private = "file")
_path_handles :: proc(base: ^engine.CompData, points: ^[dynamic][2]f32, offset: [2]f32, closed: bool, min_points: int, label: string) {
	h, ok := engine.comp_handle_of(base)
	if !ok do return
	s := physics2d.collider_scale(base.owner)
	gizmos.with_matrix(physics2d.collider_space(base.owner))
	normal := [3]f32{0, 0, 1}
	scaled := proc(p, offset, s: [2]f32) -> [3]f32 {
		q := (offset + p) * s
		return {q.x, q.y, 0}
	}
	unscaled := proc(q: [3]f32, offset, s: [2]f32) -> [2]f32 {
		out := [2]f32{q.x, q.y}
		for i in 0 ..< 2 do out[i] = s[i] > 1e-6 ? q[i] / s[i] - offset[i] : 0
		return out
	}
	target := [?]undo.Edit_Target{undo.edit_target_pooled(h, points, typeid_of([dynamic][2]f32))}

	// The edges first: their hit area is a line, and the dots on their ends
	// win the pointer at the same spot.
	n := len(points)
	edges := closed ? n : n - 1
	for i in 0 ..< edges {
		a := scaled(points[i], offset, s)
		b := scaled(points[(i + 1) % n], offset, s)
		d := handles.segment(handles.id_of(h, u64(1000 + i)), a, b, normal, prio = 0)
		if d.hot do gizmos.with_color(handles.COLOR_HOT)
		if d.hot do gizmos.line(a, b)
		// Alt is the delete key on the dots: an Alt press on an edge does
		// nothing, so a miss by a few pixels inserts no point.
		if d.started && !handles.frame().input.alt {
			_edit_begin(target[:], label)
			_inserted = i + 1
			inject_at(points, _inserted, unscaled(d.point, offset, s))
		}
		if (d.dragging || d.released) && _inserted >= 0 && _inserted < len(points) {
			points[_inserted] = unscaled(d.point, offset, s)
		}
		if d.released {
			_inserted = -1
			undo.edit_session_end(&_edit)
		}
	}

	for i := 0; i < len(points); i += 1 {
		p := scaled(points[i], offset, s)
		d := handles.dot(handles.id_of(h, u64(1 + i)), p, normal, color = physics2d.COLLIDER_GIZMO_COLOR)
		if d.started && handles.frame().input.alt {
			// A click, not a drag: the point goes in its own step.
			if len(points) > min_points {
				sess := undo.edit_session_begin(target[:], label)
				ordered_remove(points, i)
				undo.edit_session_end(&sess)
			}
			// The press stays active on this dot's id until the mouse comes
			// up, and the next point now has that id: drop the press, and
			// draw no more dots this frame, or the next point takes the
			// click as its own and goes too. They are back next frame.
			handles.end_drag()
			break
		}
		if d.started do _edit_begin(target[:], label)
		if d.dragging || d.released do points[i] = unscaled(d.point, offset, s)
		if d.released do undo.edit_session_end(&_edit)
	}
}

@(comp_on_scene_handles={component=PolygonCollider2D})
comp_on_scene_handles_PolygonCollider2D :: proc(c: ^physics2d.PolygonCollider2D, ctx: handles.Gizmo_Context) {
	if ctx.tool != .Handles do return
	_path_handles(&c.base, &c.points, c.offset, true, 3, "Edit Polygon Collider 2D")
}

@(comp_on_scene_handles={component=EdgeCollider2D})
comp_on_scene_handles_EdgeCollider2D :: proc(c: ^physics2d.EdgeCollider2D, ctx: handles.Gizmo_Context) {
	if ctx.tool != .Handles do return
	_path_handles(&c.base, &c.points, c.offset, false, 2, "Edit Edge Collider 2D")
}
