package editor

// Scene-view transform gizmos (docs/SDL3Renderer.md #8 + follow-up).
// - Translate: world-space axis arrows; drag = closest-point-on-axis delta.
// - Rotate:    world-space axis circles; drag = signed angle between the
//              grab and current ray↔plane intersections around the axis.
// - Scale:     LOCAL axis handles (scale composes in local space, Unity-like)
//              with square tips + a center handle for uniform scale.
// All drawn as overlay lines (no depth test) into the current scene pass;
// hover is a screen-space point↔segment test; every drag is ONE undo step
// (undo.field_drag_* on t.position / t.rotation / t.scale).

import gfx "../engine/gfx"
import im "../../external/odin-imgui"
import "core:math"
import "core:math/linalg"
import "../engine"
import "undo"

Gizmo_Mode :: enum {
	Translate,
	Rotate,
	Scale,
}

gizmo_mode: Gizmo_Mode = .Translate

// Gizmo screen presence: fraction of the camera distance, so it stays a
// constant apparent size while zooming (Unity-like).
_GIZMO_SIZE_FACTOR :: f32(0.15)
_GIZMO_HOVER_PX :: f32(8)
_GIZMO_CIRCLE_SEGMENTS :: 48
_GIZMO_UNIFORM_AXIS :: 3 // scale mode's center handle "axis" index

_gizmo_hot_axis: int = -1 // -1 none, 0/1/2 = X/Y/Z, 3 = uniform (scale)
_gizmo_dragging: bool
_gizmo_drag_axis: int
_gizmo_grab_s: f32          // axis-line parameter at grab (translate/scale)
_gizmo_grab_vec: [3]f32     // plane vector at grab (rotate)
_gizmo_grab_px: [2]f32      // mouse pixels at grab (scale uniform)
_gizmo_start_world: [3]f32
_gizmo_start_rot: [4]f32
_gizmo_start_scale: [3]f32
_gizmo_drag: undo.Field_Drag

_GIZMO_AXIS_DIRS :: [3][3]f32{{1, 0, 0}, {0, 1, 0}, {0, 0, 1}}
_GIZMO_AXIS_COLORS :: [3][4]f32{{0.9, 0.16, 0.22, 1}, {0, 0.89, 0.19, 1}, {0, 0.47, 0.95, 1}}
_GIZMO_HOT_COLOR :: [4]f32{1, 0.9, 0.1, 1}
_GIZMO_UNIFORM_COLOR :: [4]f32{0.9, 0.9, 0.9, 1}

// True while the gizmo owns the mouse (hot or dragging) — checked by the
// click-picking path so gizmo grabs never select-through.
gizmo_consumes_mouse :: proc() -> bool {
	return _gizmo_dragging || _gizmo_hot_axis >= 0
}

// Draws the active gizmo for tH into the CURRENT gfx pass and handles
// interaction. mouse_px/py are viewport pixels relative to the scene image
// (same space as picking); hover needs the view hovered, an active drag
// keeps tracking even if the cursor leaves the image.
gizmo_draw_and_handle :: proc(tH: engine.Transform_Handle, view: engine.Render_View, mouse_px, mouse_py: f32) {
	origin := engine.transform_world_position(tH)
	size := linalg.length(scene_cam_pos - origin) * _GIZMO_SIZE_FACTOR
	if size <= 0 do return
	mouse_ray := engine.render_view_screen_ray(view, mouse_px, mouse_py)

	switch gizmo_mode {
	case .Translate:
		_gizmo_translate(tH, view, origin, size, mouse_ray)
	case .Rotate:
		_gizmo_rotate(tH, view, origin, size, mouse_ray)
	case .Scale:
		_gizmo_scale(tH, view, origin, size, mouse_ray, {mouse_px, mouse_py})
	}
}

_gizmo_release_if_needed :: proc() -> bool {
	if _gizmo_dragging && !im.IsMouseDown(.Left) {
		_gizmo_dragging = false
		undo.field_drag_end(&_gizmo_drag)
	}
	return _gizmo_dragging
}

// ---------------------------------------------------------------- Translate

_gizmo_translate :: proc(tH: engine.Transform_Handle, view: engine.Render_View, origin: [3]f32, size: f32, mouse_ray: engine.Ray) {
	dirs := _GIZMO_AXIS_DIRS
	colors := _GIZMO_AXIS_COLORS

	hover_axis := -1
	if !_gizmo_dragging && scene_view_hovered {
		best_px := _GIZMO_HOVER_PX
		for axis in 0 ..< 3 {
			d, ok := _segment_screen_distance(view, origin, origin + dirs[axis] * size, mouse_ray)
			if ok && d < best_px {
				best_px = d
				hover_axis = axis
			}
		}
	}

	if !_gizmo_dragging && hover_axis >= 0 && im.IsMouseClicked(.Left) {
		w := engine.ctx_world()
		if t := engine.pool_get(&w.transforms, engine.Handle(tH)); t != nil {
			_gizmo_dragging = true
			_gizmo_drag_axis = hover_axis
			_gizmo_start_world = origin
			_gizmo_grab_s = _closest_axis_param(origin, dirs[hover_axis], mouse_ray)
			_gizmo_drag = undo.field_drag_begin(tH, &t.position, typeid_of([3]f32), "Gizmo Move")
		}
	}
	if _gizmo_release_if_needed() {
		s := _closest_axis_param(_gizmo_start_world, dirs[_gizmo_drag_axis], mouse_ray)
		delta := dirs[_gizmo_drag_axis] * (s - _gizmo_grab_s)
		engine.transform_set_world_position(tH, _gizmo_start_world + delta)
	}
	_gizmo_hot_axis = _gizmo_dragging ? _gizmo_drag_axis : hover_axis

	origin_now := engine.transform_world_position(tH)
	for axis in 0 ..< 3 {
		dir := dirs[axis]
		col := _gizmo_hot_axis == axis ? _GIZMO_HOT_COLOR : colors[axis]
		tip := origin_now + dir * size
		gfx.draw_line(origin_now, tip, col, depth_test = false)

		// Arrowhead: V lines angled back along the other two axes.
		back := tip - dir * size * 0.18
		p1 := dirs[(axis + 1) % 3] * size * 0.06
		p2 := dirs[(axis + 2) % 3] * size * 0.06
		gfx.draw_line(tip, back + p1, col, depth_test = false)
		gfx.draw_line(tip, back - p1, col, depth_test = false)
		gfx.draw_line(tip, back + p2, col, depth_test = false)
		gfx.draw_line(tip, back - p2, col, depth_test = false)
	}
}

// ------------------------------------------------------------------- Rotate

_gizmo_rotate :: proc(tH: engine.Transform_Handle, view: engine.Render_View, origin: [3]f32, size: f32, mouse_ray: engine.Ray) {
	dirs := _GIZMO_AXIS_DIRS
	colors := _GIZMO_AXIS_COLORS

	// Hover: nearest of the three circles, tested segment-by-segment in
	// screen space (robust for any view angle, ~150 projections — trivial).
	hover_axis := -1
	if !_gizmo_dragging && scene_view_hovered {
		best_px := _GIZMO_HOVER_PX
		for axis in 0 ..< 3 {
			u := dirs[(axis + 1) % 3]
			v := dirs[(axis + 2) % 3]
			prev := origin + u * size
			for i in 1 ..= _GIZMO_CIRCLE_SEGMENTS {
				ang := f32(i) * math.TAU / _GIZMO_CIRCLE_SEGMENTS
				p := origin + (u * math.cos(ang) + v * math.sin(ang)) * size
				d, ok := _segment_screen_distance(view, prev, p, mouse_ray)
				if ok && d < best_px {
					best_px = d
					hover_axis = axis
				}
				prev = p
			}
		}
	}

	if !_gizmo_dragging && hover_axis >= 0 && im.IsMouseClicked(.Left) {
		w := engine.ctx_world()
		if t := engine.pool_get(&w.transforms, engine.Handle(tH)); t != nil {
			if grab, ok := _ray_plane_vector(mouse_ray, origin, dirs[hover_axis]); ok {
				_gizmo_dragging = true
				_gizmo_drag_axis = hover_axis
				_gizmo_start_world = origin
				_gizmo_start_rot = engine.transform_world_rotation(tH)
				_gizmo_grab_vec = grab
				_gizmo_drag = undo.field_drag_begin(tH, &t.rotation, typeid_of([4]f32), "Gizmo Rotate")
			}
		}
	}
	if _gizmo_release_if_needed() {
		axis := dirs[_gizmo_drag_axis]
		if cur, ok := _ray_plane_vector(mouse_ray, _gizmo_start_world, axis); ok {
			angle := _signed_angle(_gizmo_grab_vec, cur, axis)
			delta := linalg.quaternion_angle_axis_f32(angle, axis)
			world := delta * engine.quat_to_native(_gizmo_start_rot)
			engine.transform_set_world_rotation(tH, engine.quat_from_native(world))
		}
	}
	_gizmo_hot_axis = _gizmo_dragging ? _gizmo_drag_axis : hover_axis

	origin_now := engine.transform_world_position(tH)
	for axis in 0 ..< 3 {
		col := _gizmo_hot_axis == axis ? _GIZMO_HOT_COLOR : colors[axis]
		u := dirs[(axis + 1) % 3]
		v := dirs[(axis + 2) % 3]
		prev := origin_now + u * size
		for i in 1 ..= _GIZMO_CIRCLE_SEGMENTS {
			ang := f32(i) * math.TAU / _GIZMO_CIRCLE_SEGMENTS
			p := origin_now + (u * math.cos(ang) + v * math.sin(ang)) * size
			gfx.draw_line(prev, p, col, depth_test = false)
			prev = p
		}
	}
	// During a drag: show the grab and current vectors like Unity's pie hint.
	if _gizmo_dragging {
		gfx.draw_line(origin_now, origin_now + _gizmo_grab_vec * size, _GIZMO_UNIFORM_COLOR, depth_test = false)
		if cur, ok := _ray_plane_vector(mouse_ray, _gizmo_start_world, dirs[_gizmo_drag_axis]); ok {
			gfx.draw_line(origin_now, origin_now + cur * size, _GIZMO_HOT_COLOR, depth_test = false)
		}
	}
}

// -------------------------------------------------------------------- Scale

_gizmo_scale :: proc(tH: engine.Transform_Handle, view: engine.Render_View, origin: [3]f32, size: f32, mouse_ray: engine.Ray, mouse_px: [2]f32) {
	colors := _GIZMO_AXIS_COLORS

	// Scale composes in LOCAL space — handles follow the object's rotation.
	rot := engine.quat_to_matrix3(engine.transform_world_rotation(tH))
	local_dirs: [3][3]f32
	for axis in 0 ..< 3 {
		local_dirs[axis] = linalg.normalize0([3]f32{rot[0, axis], rot[1, axis], rot[2, axis]})
	}

	hover_axis := -1
	if !_gizmo_dragging && scene_view_hovered {
		best_px := _GIZMO_HOVER_PX
		for axis in 0 ..< 3 {
			d, ok := _segment_screen_distance(view, origin, origin + local_dirs[axis] * size, mouse_ray)
			if ok && d < best_px {
				best_px = d
				hover_axis = axis
			}
		}
		// Center handle: uniform scale.
		if c, ok := _gizmo_project(view, origin); ok {
			dx := mouse_px.x - c.x
			dy := mouse_px.y - c.y
			if math.sqrt(dx * dx + dy * dy) < _GIZMO_HOVER_PX * 1.5 {
				hover_axis = _GIZMO_UNIFORM_AXIS
			}
		}
	}

	if !_gizmo_dragging && hover_axis >= 0 && im.IsMouseClicked(.Left) {
		w := engine.ctx_world()
		if t := engine.pool_get(&w.transforms, engine.Handle(tH)); t != nil {
			_gizmo_dragging = true
			_gizmo_drag_axis = hover_axis
			_gizmo_start_world = origin
			_gizmo_start_scale = t.scale
			_gizmo_grab_px = mouse_px
			if hover_axis < 3 {
				_gizmo_grab_s = _closest_axis_param(origin, local_dirs[hover_axis], mouse_ray)
			}
			_gizmo_drag = undo.field_drag_begin(tH, &t.scale, typeid_of([3]f32), "Gizmo Scale")
		}
	}
	if _gizmo_release_if_needed() {
		w := engine.ctx_world()
		if t := engine.pool_get(&w.transforms, engine.Handle(tH)); t != nil {
			if _gizmo_drag_axis == _GIZMO_UNIFORM_AXIS {
				// Uniform: right/up drag grows, left/down shrinks.
				pixel_delta := (mouse_px.x - _gizmo_grab_px.x) - (mouse_px.y - _gizmo_grab_px.y)
				factor := max(1 + pixel_delta * 0.005, 0.01)
				t.scale = _gizmo_start_scale * factor
			} else {
				s := _closest_axis_param(_gizmo_start_world, local_dirs[_gizmo_drag_axis], mouse_ray)
				factor := max(1 + (s - _gizmo_grab_s) / size, 0.01)
				t.scale[_gizmo_drag_axis] = _gizmo_start_scale[_gizmo_drag_axis] * factor
			}
		}
	}
	_gizmo_hot_axis = _gizmo_dragging ? _gizmo_drag_axis : hover_axis

	origin_now := engine.transform_world_position(tH)
	for axis in 0 ..< 3 {
		dir := local_dirs[axis]
		col := _gizmo_hot_axis == axis ? _GIZMO_HOT_COLOR : colors[axis]
		tip := origin_now + dir * size
		gfx.draw_line(origin_now, tip, col, depth_test = false)
		_draw_box_tip(tip, size * 0.05, col)
	}
	center_col := _gizmo_hot_axis == _GIZMO_UNIFORM_AXIS ? _GIZMO_HOT_COLOR : _GIZMO_UNIFORM_COLOR
	_draw_box_tip(origin_now, size * 0.06, center_col)
}

// Small wireframe octahedron — reads as a solid handle tip at gizmo sizes.
_draw_box_tip :: proc(center: [3]f32, r: f32, col: [4]f32) {
	x := [3]f32{r, 0, 0}
	y := [3]f32{0, r, 0}
	z := [3]f32{0, 0, r}
	gfx.draw_line(center - x, center + y, col, depth_test = false)
	gfx.draw_line(center + y, center + x, col, depth_test = false)
	gfx.draw_line(center + x, center - y, col, depth_test = false)
	gfx.draw_line(center - y, center - x, col, depth_test = false)
	gfx.draw_line(center - z, center + y, col, depth_test = false)
	gfx.draw_line(center + y, center + z, col, depth_test = false)
	gfx.draw_line(center + z, center - y, col, depth_test = false)
	gfx.draw_line(center - y, center - z, col, depth_test = false)
}

// ------------------------------------------------------------------ shared

// World point -> viewport pixels; false when behind the camera.
_gizmo_project :: proc(view: engine.Render_View, p: [3]f32) -> ([2]f32, bool) {
	clip := view.view_proj * [4]f32{p.x, p.y, p.z, 1}
	if clip.w <= 0 do return {}, false
	ndc := clip.xyz / clip.w
	return {
		(ndc.x * 0.5 + 0.5) * view.width,
		(0.5 - ndc.y * 0.5) * view.height,
	}, true
}

// Screen-space distance from the mouse (encoded in `ray`'s pixel origin via
// the caller) to the world segment a-b. The mouse pixel is recovered by
// projecting the ray origin — cheaper to pass explicitly, but this keeps one
// signature for all handles.
_segment_screen_distance :: proc(view: engine.Render_View, a, b: [3]f32, mouse_ray: engine.Ray) -> (f32, bool) {
	pa, a_ok := _gizmo_project(view, a)
	pb, b_ok := _gizmo_project(view, b)
	if !a_ok || !b_ok do return 0, false
	// Recover the mouse pixel from the ray's near-plane origin.
	pm, m_ok := _gizmo_project(view, mouse_ray.origin)
	if !m_ok do return 0, false
	return _point_segment_distance_2d(pm, pa, pb), true
}

_point_segment_distance_2d :: proc(p, a, b: [2]f32) -> f32 {
	ab := b - a
	len_sq := ab.x * ab.x + ab.y * ab.y
	t := len_sq > 0 ? clamp(((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / len_sq, 0, 1) : 0
	closest := a + ab * t
	d := p - closest
	return math.sqrt(d.x * d.x + d.y * d.y)
}

// Parameter s of the closest point on the infinite line (origin + s*axis) to
// `ray` — standard line-line closest-point solve, degenerate-guarded for a
// ray (near-)parallel to the axis.
_closest_axis_param :: proc(origin, axis: [3]f32, ray: engine.Ray) -> f32 {
	w0 := origin - ray.origin
	a := linalg.dot(axis, axis)
	b := linalg.dot(axis, ray.direction)
	c := linalg.dot(ray.direction, ray.direction)
	d := linalg.dot(axis, w0)
	e := linalg.dot(ray.direction, w0)
	denom := a * c - b * b
	if abs(denom) < 1e-9 do return 0
	return (b * e - c * d) / denom
}

// Normalized vector from `plane_origin` to the ray's intersection with the
// plane (normal n); false when the ray is (near-)parallel to the plane or
// hits it behind the camera.
_ray_plane_vector :: proc(ray: engine.Ray, plane_origin, n: [3]f32) -> ([3]f32, bool) {
	denom := linalg.dot(ray.direction, n)
	if abs(denom) < 1e-6 do return {}, false
	t := linalg.dot(plane_origin - ray.origin, n) / denom
	if t < 0 do return {}, false
	hit := ray.origin + ray.direction * t
	v := hit - plane_origin
	if linalg.length(v) < 1e-6 do return {}, false
	return linalg.normalize(v), true
}

// Signed angle from a to b around axis n (right-hand rule).
_signed_angle :: proc(a, b, n: [3]f32) -> f32 {
	return math.atan2(linalg.dot(linalg.cross(a, b), n), linalg.dot(a, b))
}
