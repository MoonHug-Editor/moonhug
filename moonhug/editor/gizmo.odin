package editor

// Scene-view transform gizmos (docs/SDL3Renderer.md #8 + follow-up).
// Drags apply to EVERY selected top-level object (Unity): translate offsets
// them all, rotate orbits positions around the gizmo and spins orientations,
// scale scales offsets + local scales. One undo GROUP per drag (edit scopes
// captured at grab, pushed at release). The gizmo anchors at the active
// object's pivot or the selection centroid (gizmo_pivot toggle).
// - Translate: world-space axis arrows (drag = closest-point-on-axis delta)
//              + Unity-style plane quads (drag = ray<->plane hit delta,
//              movement constrained to the plane).
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
	Picker, // selection only, no gizmo (Unity's Q hand/view slot)
	Translate,
	Rotate,
	Scale,
}

gizmo_mode: Gizmo_Mode = .Translate

// Gizmo axis orientation (Unity's Global/Local pivot switch): Global = world
// axes; Local = the object's rotated axes. Scale IGNORES this — it always
// composes in local space.
Gizmo_Space :: enum {
	Global,
	Local,
}

gizmo_space: Gizmo_Space = .Global

// Gizmo position (Unity's Pivot/Center toggle): the active object's pivot vs
// the centroid of the selected top-level objects (Unity uses the combined
// bounds center; the pivot average is our approximation).
Gizmo_Pivot :: enum {
	Pivot,
	Center,
}

gizmo_pivot: Gizmo_Pivot = .Pivot

gizmo_origin :: proc(tH: engine.Transform_Handle) -> [3]f32 {
	if gizmo_pivot == .Center {
		sum: [3]f32
		n := 0
		for h in sel_scene_top_level() {
			sum += engine.transform_world_position(h)
			n += 1
		}
		if n > 0 do return sum / f32(n)
	}
	return engine.transform_world_position(tH)
}

_GIZMO_SNAP_SCALE :: f32(0.1)

// Snap is the Snap popup's Enabled XOR the snap modifier: it temporarily
// snaps when the toggle is off and frees the drag when it's on. io.KeyCtrl
// follows Unity's convention — Ctrl on Windows/Linux, Cmd on macOS (imgui's
// ConfigMacOSXBehaviors remaps it there).
_gizmo_snap_active :: proc() -> bool {
	return snap_settings.enabled != im.GetIO().KeyCtrl
}

_gizmo_snap_angle :: proc() -> f32 {
	return math.to_radians(max(snap_settings.angle, 1))
}

_snap :: proc(value, step: f32) -> f32 {
	if step <= 0 do return value
	return math.round(value / step) * step
}

// Gizmo screen presence: fraction of the camera distance, so it stays a
// constant apparent size while zooming (Unity-like).
_GIZMO_SIZE_FACTOR :: f32(0.15)
_GIZMO_HOVER_PX :: f32(8)
_GIZMO_CIRCLE_SEGMENTS :: 48
_GIZMO_UNIFORM_AXIS :: 3 // scale mode's center handle "axis" index
// Translate plane handles: hot-axis 4/5/6 = drag on the plane whose NORMAL is
// X/Y/Z (Unity: the YZ quad is red, XZ green, XY blue — the normal's color).
_GIZMO_PLANE_AXIS_BASE :: 4
// Quad extents along both in-plane axes, as fractions of the gizmo size.
_GIZMO_PLANE_OFFSET :: f32(0)
_GIZMO_PLANE_SIDE :: f32(0.2)

_gizmo_hot_axis: int = -1 // -1 none, 0/1/2 = X/Y/Z, 3 = uniform (scale), 4/5/6 = plane
_gizmo_dragging: bool
_gizmo_drag_axis: int
_gizmo_drag_dirs: [3][3]f32 // axis dirs captured at grab (local axes move mid-drag)
_gizmo_grab_s: f32          // axis-line parameter at grab (translate/scale)
_gizmo_grab_vec: [3]f32     // plane vector at grab (rotate)
_gizmo_grab_px: [2]f32      // mouse pixels at grab (scale uniform)
_gizmo_drag_signs: [3][2]f32 // plane-quad quadrant signs frozen at grab
_gizmo_start_world: [3]f32 // gizmo origin (pivot point) at grab

// One drag applies to every selected top-level object. Start states are
// captured at grab; the per-frame apply is absolute (start + delta), and the
// edit scopes become ONE undo group at release.
_Gizmo_Target :: struct {
	tH:          engine.Transform_Handle,
	start_pos:   [3]f32, // world
	start_rot:   [4]f32, // world
	start_scale: [3]f32, // local
	edit_a:      undo.Edit_Scope, // mode's field: position / rotation / scale
	edit_b:      undo.Edit_Scope, // position, for rotate/scale orbit offsets
}
_gizmo_targets: [dynamic]_Gizmo_Target

_GIZMO_AXIS_DIRS :: [3][3]f32{{1, 0, 0}, {0, 1, 0}, {0, 0, 1}}
// Unity's exact handle palette (UnityCsReference Handles.cs): axis colors
// s_X/Y/ZAxisColor, selected s_SelectedColor, center s_CenterColor.
_GIZMO_AXIS_COLORS :: [3][4]f32{
	{219.0 / 255, 62.0 / 255, 29.0 / 255, 0.93},
	{154.0 / 255, 243.0 / 255, 72.0 / 255, 0.93},
	{58.0 / 255, 122.0 / 255, 248.0 / 255, 0.93},
}
_GIZMO_HOT_COLOR :: [4]f32{246.0 / 255, 242.0 / 255, 50.0 / 255, 0.89}
_GIZMO_UNIFORM_COLOR :: [4]f32{0.8, 0.8, 0.8, 0.93}
// Unity's Handles.secondaryColor — what non-participating parts get during a
// drag (UnityCsReference Handles.cs: Color(.5, .5, .5, .2)).
_GIZMO_DIM_COLOR :: [4]f32{0.5, 0.5, 0.5, 0.2}

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
	origin := gizmo_origin(tH)
	size := linalg.length(scene_cam_pos - origin) * _GIZMO_SIZE_FACTOR
	if size <= 0 do return
	mouse_ray := engine.render_view_screen_ray(view, mouse_px, mouse_py)

	switch gizmo_mode {
	case .Picker:
		// Selection only: no handles, never consumes the mouse. Close out any
		// drag left open by a mid-drag mode switch (Q shortcut).
		gizmo_end_drag_if_any()
		_gizmo_hot_axis = -1
	case .Translate:
		_gizmo_translate(tH, view, origin, size, mouse_ray)
	case .Rotate:
		_gizmo_rotate(tH, view, origin, size, mouse_ray)
	case .Scale:
		_gizmo_scale(tH, view, origin, size, mouse_ray, {mouse_px, mouse_py})
	}
}

// Axis directions for translate/rotate honoring gizmo_space: world axes in
// Global, the object's rotated basis in Local (same column extraction as the
// scale gizmo, which is always local).
_gizmo_axes :: proc(tH: engine.Transform_Handle) -> [3][3]f32 {
	if gizmo_space == .Global do return _GIZMO_AXIS_DIRS
	rot := engine.quat_to_matrix3(engine.transform_world_rotation(tH))
	dirs: [3][3]f32
	for axis in 0 ..< 3 {
		dirs[axis] = linalg.normalize0([3]f32{rot[0, axis], rot[1, axis], rot[2, axis]})
	}
	return dirs
}

@(private)
_gizmo_collect_targets :: proc() -> bool {
	clear(&_gizmo_targets)
	w := engine.ctx_world()
	for h in sel_scene_top_level() {
		t := engine.pool_get(&w.transforms, engine.Handle(h))
		if t == nil do continue
		tgt := _Gizmo_Target{
			tH          = h,
			start_pos   = engine.transform_world_position(h),
			start_rot   = engine.transform_world_rotation(h),
			start_scale = t.scale,
		}
		switch gizmo_mode {
		case .Picker:
		case .Translate:
			tgt.edit_a = undo.edit_begin(h, &t.position, typeid_of([3]f32), "Gizmo Move")
		case .Rotate:
			tgt.edit_a = undo.edit_begin(h, &t.rotation, typeid_of([4]f32), "Gizmo Rotate")
			tgt.edit_b = undo.edit_begin(h, &t.position, typeid_of([3]f32), "Gizmo Rotate")
		case .Scale:
			tgt.edit_a = undo.edit_begin(h, &t.scale, typeid_of([3]f32), "Gizmo Scale")
			tgt.edit_b = undo.edit_begin(h, &t.position, typeid_of([3]f32), "Gizmo Scale")
		}
		append(&_gizmo_targets, tgt)
	}
	return len(_gizmo_targets) > 0
}

@(private)
_gizmo_end_drag :: proc() {
	label: string
	switch gizmo_mode {
	case .Picker:    label = "Gizmo"
	case .Translate: label = "Gizmo Move"
	case .Rotate:    label = "Gizmo Rotate"
	case .Scale:     label = "Gizmo Scale"
	}
	g := undo.group_begin(label)
	for &tgt in _gizmo_targets {
		undo.edit_end(&tgt.edit_a)
		undo.edit_end(&tgt.edit_b)
	}
	undo.group_commit(&g)
	undo.group_end(&g) // no-changes group is dropped by end_group_command
	clear(&_gizmo_targets)
}

// Finalize an in-flight drag (mode switch, selection loss) — commits what
// happened so far as the drag's undo group.
gizmo_end_drag_if_any :: proc() {
	if !_gizmo_dragging do return
	_gizmo_dragging = false
	_gizmo_end_drag()
}

gizmo_shutdown :: proc() {
	delete(_gizmo_targets)
	_gizmo_targets = nil
}

_gizmo_release_if_needed :: proc() -> bool {
	if _gizmo_dragging && !im.IsMouseDown(.Left) {
		_gizmo_dragging = false
		_gizmo_end_drag()
	}
	return _gizmo_dragging
}

// ---------------------------------------------------------------- Translate

_gizmo_translate :: proc(tH: engine.Transform_Handle, view: engine.Render_View, origin: [3]f32, size: f32, mouse_ray: engine.Ray) {
	dirs := _gizmo_axes(tH)
	colors := _GIZMO_AXIS_COLORS

	// Plane quads sit in the camera-facing quadrant of each plane (Unity):
	// flip each in-plane axis toward the viewer so the handles never hide
	// behind the origin.
	view_dir := linalg.normalize0(scene_cam_pos - origin)
	plane_signs: [3][2]f32
	for axis in 0 ..< 3 {
		u := dirs[(axis + 1) % 3]
		v := dirs[(axis + 2) % 3]
		plane_signs[axis] = {
			linalg.dot(u, view_dir) >= 0 ? 1 : -1,
			linalg.dot(v, view_dir) >= 0 ? 1 : -1,
		}
	}

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
		// Inside a quad beats a nearby axis line (Unity). Two quads can
		// overlap on screen — take the one whose plane the ray hits first.
		best_t := max(f32)
		for axis in 0 ..< 3 {
			hit, t, ok := _ray_plane_point(mouse_ray, origin, dirs[axis])
			if !ok || t >= best_t do continue
			su := linalg.dot(hit - origin, dirs[(axis + 1) % 3]) * plane_signs[axis][0]
			sv := linalg.dot(hit - origin, dirs[(axis + 2) % 3]) * plane_signs[axis][1]
			lo := size * _GIZMO_PLANE_OFFSET
			hi := size * (_GIZMO_PLANE_OFFSET + _GIZMO_PLANE_SIDE)
			if su >= lo && su <= hi && sv >= lo && sv <= hi {
				best_t = t
				hover_axis = _GIZMO_PLANE_AXIS_BASE + axis
			}
		}
	}

	if !_gizmo_dragging && hover_axis >= 0 && im.IsMouseClicked(.Left) {
		grab_ok := true
		if hover_axis >= _GIZMO_PLANE_AXIS_BASE {
			hit, _, ok := _ray_plane_point(mouse_ray, origin, dirs[hover_axis - _GIZMO_PLANE_AXIS_BASE])
			grab_ok = ok
			_gizmo_grab_vec = hit
		} else {
			_gizmo_grab_s = _closest_axis_param(origin, dirs[hover_axis], mouse_ray)
		}
		if grab_ok && _gizmo_collect_targets() {
			_gizmo_dragging = true
			_gizmo_drag_axis = hover_axis
			_gizmo_drag_dirs = dirs
			_gizmo_drag_signs = plane_signs
			_gizmo_start_world = origin
		}
	}
	if _gizmo_release_if_needed() {
		// Drag math uses the grab-time axes (dirs would be stable for
		// translate, but keep the same convention as rotate).
		delta: [3]f32
		have_delta := false
		if _gizmo_drag_axis >= _GIZMO_PLANE_AXIS_BASE {
			normal_axis := _gizmo_drag_axis - _GIZMO_PLANE_AXIS_BASE
			n := _gizmo_drag_dirs[normal_axis]
			if hit, _, ok := _ray_plane_point(mouse_ray, _gizmo_start_world, n); ok {
				delta = hit - _gizmo_grab_vec
				if _gizmo_snap_active() {
					// Per-axis snap on the plane's two spanning directions.
					u := _gizmo_drag_dirs[(normal_axis + 1) % 3]
					v := _gizmo_drag_dirs[(normal_axis + 2) % 3]
					step := snap_translate_step()
					delta = u * _snap(linalg.dot(delta, u), step) + v * _snap(linalg.dot(delta, v), step)
				}
				have_delta = true
			}
		} else {
			s := _closest_axis_param(_gizmo_start_world, _gizmo_drag_dirs[_gizmo_drag_axis], mouse_ray)
			move := s - _gizmo_grab_s
			if _gizmo_snap_active() do move = _snap(move, snap_translate_step())
			delta = _gizmo_drag_dirs[_gizmo_drag_axis] * move
			have_delta = true
		}
		if have_delta {
			for &tgt in _gizmo_targets {
				engine.transform_set_world_position(tgt.tH, tgt.start_pos + delta)
			}
		}
	}
	_gizmo_hot_axis = _gizmo_dragging ? _gizmo_drag_axis : hover_axis

	origin_now := gizmo_origin(tH)
	// During a drag: participating parts yellow, everything else faint white
	// (Unity). A plane drag highlights the quad AND its two spanning axes.
	// The quads also keep their grab-time quadrant placement until release.
	dragging := _gizmo_dragging
	drag_plane_normal := dragging && _gizmo_drag_axis >= _GIZMO_PLANE_AXIS_BASE \
		? _gizmo_drag_axis - _GIZMO_PLANE_AXIS_BASE : -1
	draw_signs := dragging ? _gizmo_drag_signs : plane_signs

	// Quads first: axis lines and arrowheads draw over them.
	for axis in 0 ..< 3 {
		u := dirs[(axis + 1) % 3] * draw_signs[axis][0]
		v := dirs[(axis + 2) % 3] * draw_signs[axis][1]
		lo := size * _GIZMO_PLANE_OFFSET
		hi := size * (_GIZMO_PLANE_OFFSET + _GIZMO_PLANE_SIDE)
		hot := _gizmo_hot_axis == _GIZMO_PLANE_AXIS_BASE + axis
		col := hot ? _GIZMO_HOT_COLOR : colors[axis]
		fill_a := hot ? f32(0.6) : f32(0.35)
		if dragging && axis != drag_plane_normal {
			col = _GIZMO_DIM_COLOR
			fill_a = 0.05
		}
		p00 := origin_now + u * lo + v * lo
		p10 := origin_now + u * hi + v * lo
		p11 := origin_now + u * hi + v * hi
		p01 := origin_now + u * lo + v * hi
		fill := [4]f32{col.r, col.g, col.b, fill_a}
		gfx.draw_triangle(p00, p10, p11, fill, depth_test = false)
		gfx.draw_triangle(p00, p11, p01, fill, depth_test = false)
		gfx.draw_line(p00, p10, col, depth_test = false)
		gfx.draw_line(p10, p11, col, depth_test = false)
		gfx.draw_line(p11, p01, col, depth_test = false)
		gfx.draw_line(p01, p00, col, depth_test = false)
	}
	for axis in 0 ..< 3 {
		dir := dirs[axis]
		col := _gizmo_hot_axis == axis ? _GIZMO_HOT_COLOR : colors[axis]
		if dragging {
			active := drag_plane_normal >= 0 ? axis != drag_plane_normal : axis == _gizmo_drag_axis
			col = active ? _GIZMO_HOT_COLOR : _GIZMO_DIM_COLOR
		}
		tip := origin_now + dir * size
		// Line stops where the arrowhead begins.
		gfx.draw_line(origin_now, tip - dir * size * 0.18, col, depth_test = false)

		// Arrowhead: solid cone (Unity-like), base pulled back along the axis.
		_draw_cone(tip - dir * size * 0.18, dir, size * 0.18, size * 0.06, col)
	}
}

// Solid overlay cone from base center along dir — the translate arrowhead.
// The overlay pipeline has no depth test and no culling, so only CAMERA-FACING
// facets are drawn (back facets would overdraw front ones); for a convex solid
// their projections never overlap, making draw order irrelevant. The world
// shader is unlit — 3D reads via flat headlight shading per facet.
_draw_cone :: proc(base: [3]f32, dir: [3]f32, height, radius: f32, col: [4]f32) {
	CONE_SEGMENTS :: 16
	tip := base + dir * height
	ref := math.abs(dir.y) < 0.9 ? [3]f32{0, 1, 0} : [3]f32{1, 0, 0}
	u := linalg.normalize0(linalg.cross(ref, dir))
	v := linalg.cross(dir, u)
	view_dir := linalg.normalize0(scene_cam_pos - tip)

	// Base cap faces -dir: visible only from behind the base plane.
	draw_cap := linalg.dot(view_dir, dir) < 0
	cap_col := [4]f32{col.r * 0.5, col.g * 0.5, col.b * 0.5, col.a}

	prev_ang := f32(0)
	prev := base + u * radius
	for i in 1 ..= CONE_SEGMENTS {
		ang := f32(i) * math.TAU / CONE_SEGMENTS
		p := base + (u * math.cos(ang) + v * math.sin(ang)) * radius
		// Outward slant normal at the facet's mid angle: perpendicular to the
		// slant line and the rim tangent = normalize(radial*height + dir*radius).
		mid := (prev_ang + ang) * 0.5
		w := u * math.cos(mid) + v * math.sin(mid)
		n := linalg.normalize0(w * height + dir * radius)
		facing := linalg.dot(n, view_dir)
		if facing > 0 {
			shade := 0.55 + 0.45 * facing
			gfx.draw_triangle(tip, prev, p, {col.r * shade, col.g * shade, col.b * shade, col.a}, depth_test = false)
		}
		if draw_cap {
			gfx.draw_triangle(base, prev, p, cap_col, depth_test = false)
		}
		prev = p
		prev_ang = ang
	}
}

// ------------------------------------------------------------------- Rotate

_gizmo_rotate :: proc(tH: engine.Transform_Handle, view: engine.Render_View, origin: [3]f32, size: f32, mouse_ray: engine.Ray) {
	// Local axes MOVE while a rotate drag changes the rotation — the drag math
	// below must use the grab-time axes (_gizmo_drag_dirs); drawing uses the
	// current ones so the gizmo visibly rotates with the object (Unity-like).
	dirs := _gizmo_axes(tH)
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
		if grab, ok := _ray_plane_vector(mouse_ray, origin, dirs[hover_axis]); ok {
			if _gizmo_collect_targets() {
				_gizmo_dragging = true
				_gizmo_drag_axis = hover_axis
				_gizmo_drag_dirs = dirs
				_gizmo_start_world = origin
				_gizmo_grab_vec = grab
			}
		}
	}
	if _gizmo_release_if_needed() {
		axis := _gizmo_drag_dirs[_gizmo_drag_axis]
		if cur, ok := _ray_plane_vector(mouse_ray, _gizmo_start_world, axis); ok {
			angle := _signed_angle(_gizmo_grab_vec, cur, axis)
			if _gizmo_snap_active() do angle = _snap(angle, _gizmo_snap_angle())
			delta := linalg.quaternion_angle_axis_f32(angle, axis)
			for &tgt in _gizmo_targets {
				world := delta * engine.quat_to_native(tgt.start_rot)
				engine.transform_set_world_rotation(tgt.tH, engine.quat_from_native(world))
				// Orbit the position around the pivot (no-op for the object
				// AT the pivot — single-object Pivot mode keeps its place).
				off := tgt.start_pos - _gizmo_start_world
				if linalg.length(off) > 1e-6 {
					engine.transform_set_world_position(tgt.tH, _gizmo_start_world + linalg.quaternion128_mul_vector3(delta, off))
				}
			}
		}
	}
	_gizmo_hot_axis = _gizmo_dragging ? _gizmo_drag_axis : hover_axis

	origin_now := gizmo_origin(tH)
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
	// During a drag: show the grab and current vectors like Unity's pie hint
	// (in the grab-time plane — the live axes rotate with the object).
	if _gizmo_dragging {
		gfx.draw_line(origin_now, origin_now + _gizmo_grab_vec * size, _GIZMO_UNIFORM_COLOR, depth_test = false)
		if cur, ok := _ray_plane_vector(mouse_ray, _gizmo_start_world, _gizmo_drag_dirs[_gizmo_drag_axis]); ok {
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
		if _gizmo_collect_targets() {
			_gizmo_dragging = true
			_gizmo_drag_axis = hover_axis
			_gizmo_start_world = origin
			_gizmo_grab_px = mouse_px
			if hover_axis < 3 {
				_gizmo_grab_s = _closest_axis_param(origin, local_dirs[hover_axis], mouse_ray)
			}
		}
	}
	if _gizmo_release_if_needed() {
		w := engine.ctx_world()
		factor: f32
		if _gizmo_drag_axis == _GIZMO_UNIFORM_AXIS {
			// Uniform: right/up drag grows, left/down shrinks.
			pixel_delta := (mouse_px.x - _gizmo_grab_px.x) - (mouse_px.y - _gizmo_grab_px.y)
			factor = max(1 + pixel_delta * 0.005, 0.01)
		} else {
			s := _closest_axis_param(_gizmo_start_world, local_dirs[_gizmo_drag_axis], mouse_ray)
			factor = max(1 + (s - _gizmo_grab_s) / size, 0.01)
		}
		if _gizmo_snap_active() do factor = max(_snap(factor, _GIZMO_SNAP_SCALE), 0.01)
		for &tgt in _gizmo_targets {
			t := engine.pool_get(&w.transforms, engine.Handle(tgt.tH))
			if t == nil do continue
			off := tgt.start_pos - _gizmo_start_world
			if _gizmo_drag_axis == _GIZMO_UNIFORM_AXIS {
				t.scale = tgt.start_scale * factor
				if linalg.length(off) > 1e-6 {
					engine.transform_set_world_position(tgt.tH, _gizmo_start_world + off * factor)
				}
			} else {
				// Per-axis: each object's own local component scales; the
				// offset scales along the drag axis only (Unity group scale).
				t.scale[_gizmo_drag_axis] = tgt.start_scale[_gizmo_drag_axis] * factor
				dir := local_dirs[_gizmo_drag_axis]
				amt := linalg.dot(off, dir)
				if abs(amt) > 1e-6 {
					engine.transform_set_world_position(tgt.tH, _gizmo_start_world + off + dir * amt * (factor - 1))
				}
			}
		}
	}
	_gizmo_hot_axis = _gizmo_dragging ? _gizmo_drag_axis : hover_axis

	origin_now := gizmo_origin(tH)
	for axis in 0 ..< 3 {
		dir := local_dirs[axis]
		col := _gizmo_hot_axis == axis ? _GIZMO_HOT_COLOR : colors[axis]
		tip := origin_now + dir * size
		gfx.draw_line(origin_now, tip, col, depth_test = false)
		_draw_cube(tip, local_dirs, size * 0.05, col)
	}
	center_col := _gizmo_hot_axis == _GIZMO_UNIFORM_AXIS ? _GIZMO_HOT_COLOR : _GIZMO_UNIFORM_COLOR
	_draw_cube(origin_now, local_dirs, size * 0.06, center_col)
}

// Solid overlay cube (half-extent r) aligned to the axes basis — the scale
// handle tips, Unity-like. Camera-facing faces only, flat headlight shading;
// same convex-solid reasoning as _draw_cone.
_draw_cube :: proc(center: [3]f32, axes: [3][3]f32, r: f32, col: [4]f32) {
	view_dir := linalg.normalize0(scene_cam_pos - center)
	for axis in 0 ..< 3 {
		for side in 0 ..< 2 {
			n := side == 0 ? axes[axis] : -axes[axis]
			facing := linalg.dot(n, view_dir)
			if facing <= 0 do continue
			a := axes[(axis + 1) % 3] * r
			b := axes[(axis + 2) % 3] * r
			c := center + n * r
			shade := 0.55 + 0.45 * facing
			face_col := [4]f32{col.r * shade, col.g * shade, col.b * shade, col.a}
			gfx.draw_triangle(c - a - b, c + a - b, c + a + b, face_col, depth_test = false)
			gfx.draw_triangle(c - a - b, c + a + b, c - a + b, face_col, depth_test = false)
		}
	}
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

// Ray<->plane intersection point and ray parameter; false when the ray is
// (near-)parallel to the plane or hits it behind the camera.
_ray_plane_point :: proc(ray: engine.Ray, plane_origin, n: [3]f32) -> ([3]f32, f32, bool) {
	denom := linalg.dot(ray.direction, n)
	if abs(denom) < 1e-6 do return {}, 0, false
	t := linalg.dot(plane_origin - ray.origin, n) / denom
	if t < 0 do return {}, 0, false
	return ray.origin + ray.direction * t, t, true
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
