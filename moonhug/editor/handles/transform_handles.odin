package handles

// Move, rotate and scale handles (docs/Handles.md): the transform tool's
// parts, for any code that edits a point, a rotation or a scale in the scene.
// Each edits the value it is given while one of its parts drags and returns
// one Drag for all of its parts, like the bounds handles.
//
// - `pos` and the values are in the current gizmos space, as for every
//   handle. Rotate and scale treat that space as rigid (no scale in it).
// - `rotation` turns the axes: identity keeps them on the space's axes.
// - `size` is the length of an arrow, the radius of a ring, in world units.
// - `prio` is the pointer priority of the parts. Squares and the center cube
//   sit one above the arrows, so they win where they overlap one. The
//   transform tool passes PRIO_TOOL.
// - Every frame of a drag rebuilds the value from the grab-time value, so
//   snapping works on the whole move and nothing drifts.
// - During a move, the parts that are not moving draw faint.

import "core:math"
import "core:math/linalg"
import "moonhug:engine"
import "moonhug:engine/gizmos"

// Axis colors: X red, Y green, Z blue.
COLOR_AXES :: [3][4]f32{
	{219.0 / 255, 62.0 / 255, 29.0 / 255, 0.93},
	{154.0 / 255, 243.0 / 255, 72.0 / 255, 0.93},
	{58.0 / 255, 122.0 / 255, 248.0 / 255, 0.93},
}
// The scale handle's center cube, the rotate handle's grab line.
COLOR_CENTER :: [4]f32{0.8, 0.8, 0.8, 0.93}
// The parts a move drag does not use.
COLOR_DIM :: [4]f32{0.5, 0.5, 0.5, 0.2}

// The scale step while snapping is on.
SNAP_SCALE_STEP :: f32(0.1)

@(private = "file")
_RING_SEGMENTS :: 48
// The move handle's squares: from the origin out to this fraction of `size`.
@(private = "file")
_SQUARE_SIDE :: f32(0.2)

// What the dragged part saw at grab. One drag at a time, so one snapshot
// serves every transform handle.
@(private = "file")
_Grab :: struct {
	part:   u64,
	origin: [3]f32,    // world
	dirs:   [3][3]f32, // world axes
	signs:  [3][2]f32, // move squares' quadrant
	s:      f32,       // arrow line parameter
	axis:   [3]f32,    // ring axis, world
	vec:    [3]f32,    // ring plane direction
	px:     [2]f32,    // pointer
	pos:    [3]f32,    // the edited values
	rot:    quaternion128,
	scale:  [3]f32,
}

@(private = "file")
_grab: _Grab

// Each composite salts its part ids differently, so a mode switch mid-drag
// never hands the active part to another composite.
@(private = "file")
_part :: proc(id: u64, slot: int) -> u64 {
	return id_of(id, u64(slot))
}

// The axes `rotation` gives in the current space, as world directions.
@(private = "file")
_axes_world :: proc(s: _Space, rotation: quaternion128) -> [3][3]f32 {
	dirs: [3][3]f32
	for i in 0 ..< 3 {
		e: [3]f32
		e[i] = 1
		dirs[i] = linalg.normalize0(_vec_to_world(s, linalg.quaternion128_mul_vector3(rotation, e)))
	}
	return dirs
}

// A plane holding the line through `o` along `dir` and turned to the camera,
// for an arrow's drag bookkeeping.
@(private = "file")
_facing_normal :: proc(o, dir: [3]f32) -> [3]f32 {
	return linalg.normalize0(linalg.cross(dir, linalg.cross(_to_camera(o), dir)))
}

// --- Move ----------------------------------------------------------------------------

// Three arrows and three squares that move `pos`: an arrow along its axis,
// a square in its plane. The squares sit in the quadrant turned to the
// camera. Snapping works per axis.
position_handle :: proc(id: u64, pos: ^[3]f32, rotation := quaternion128(1), size: f32 = 1, prio := 1) -> Drag {
	s := _space()
	o := _to_world(s, pos^)
	dirs := _axes_world(s, rotation)
	to_cam := linalg.normalize0(_frame.view.cam_pos - o)
	signs: [3][2]f32
	for i in 0 ..< 3 {
		signs[i] = {
			1 if linalg.dot(dirs[(i + 1) % 3], to_cam) >= 0 else -1,
			1 if linalg.dot(dirs[(i + 2) % 3], to_cam) >= 0 else -1,
		}
	}

	parts: [6]Drag
	for i in 0 ..< 3 {
		dist := _mouse_dist_segment(o, o + dirs[i] * size)
		parts[i] = _interact(_part(id, 1 + i), dist <= DOT_HOVER_PX, dist, prio, o, _facing_normal(o, dirs[i]))
	}
	// Inside a square, the nearest along the ray. Squares win over arrows.
	side := size * _SQUARE_SIDE
	for i in 0 ..< 3 {
		inside := false
		t: f32
		if hit, ht, ok := _ray_plane_ahead(_frame.ray, o, dirs[i]); ok {
			su := linalg.dot(hit - o, dirs[(i + 1) % 3]) * signs[i][0]
			sv := linalg.dot(hit - o, dirs[(i + 2) % 3]) * signs[i][1]
			inside = su >= 0 && su <= side && sv >= 0 && sv <= side
			t = ht
		}
		parts[3 + i] = _interact(_part(id, 4 + i), inside, t, prio + 1, o, dirs[i])
	}

	out: Drag
	active := -1
	for p, k in parts {
		if p.started {
			_grab = {part = _part(id, 1 + k), origin = o, dirs = dirs, signs = signs, pos = pos^}
			if k < 3 do _grab.s = _closest_axis_param(o, dirs[k], _frame.ray)
		}
		if p.dragging || p.released do active = k
		_merge_part(&out, p)
	}
	if active >= 0 {
		g := _grab
		delta: [3]f32
		if active < 3 {
			delta = g.dirs[active] * snap(_closest_axis_param(g.origin, g.dirs[active], _frame.ray) - g.s)
		} else {
			n := active - 3
			u, v := g.dirs[(n + 1) % 3], g.dirs[(n + 2) % 3]
			d := parts[active].delta
			delta = u * snap(linalg.dot(d, u)) + v * snap(linalg.dot(d, v))
		}
		out.delta = _vec_from_world(s, delta)
		pos^ = g.pos + out.delta
		out.point = pos^
	}

	// Drawn at the moved position. During a drag the squares keep their
	// grab-time quadrant, and a square drag lights its square and its two
	// arrows.
	gizmos.in_world_space()
	gizmos.with_depth_test(false)
	axis_colors := COLOR_AXES
	now := _to_world(s, pos^)
	moving := active >= 0
	draw_signs := _grab.signs if moving else signs
	plane := active - 3 if active >= 3 else -1
	for i in 0 ..< 3 {
		u := dirs[(i + 1) % 3] * draw_signs[i][0]
		v := dirs[(i + 2) % 3] * draw_signs[i][1]
		col := COLOR_HOT if parts[3 + i].hot else axis_colors[i]
		fill := f32(0.6) if parts[3 + i].hot else f32(0.35)
		if moving && i != plane {
			col = COLOR_DIM
			fill = 0.05
		}
		c := [4][3]f32{now, now + u * side, now + u * side + v * side, now + v * side}
		{
			gizmos.with_color({col.r, col.g, col.b, fill})
			gizmos.solid_quad(c)
		}
		gizmos.with_color(col)
		gizmos.wire_quad(c)
	}
	for i in 0 ..< 3 {
		col := COLOR_HOT if parts[i].hot else axis_colors[i]
		if moving {
			lit := i != plane if plane >= 0 else i == active
			col = COLOR_HOT if lit else COLOR_DIM
		}
		tip := now + dirs[i] * size
		base := tip - dirs[i] * size * 0.18
		gizmos.with_color(col)
		gizmos.line(now, base)
		gizmos.solid_cone(base, tip, size * 0.06, segments = 16)
	}
	return out
}

// --- Rotate --------------------------------------------------------------------------

// Three rings around `pos` that turn `rot`. With `local` the rings follow
// `rot` itself, else they sit on the space's axes. The turn is the signed
// angle on the ring's plane between the grab and the pointer, around the
// grab-time axis, and snaps to the rotate step.
rotation_handle :: proc(id: u64, rot: ^quaternion128, pos: [3]f32, size: f32 = 1, local := true, prio := 1) -> Drag {
	s := _space()
	o := _to_world(s, pos)
	dirs := _axes_world(s, rot^ if local else quaternion128(1))

	parts: [3]Drag
	for i in 0 ..< 3 {
		u, v := dirs[(i + 1) % 3], dirs[(i + 2) % 3]
		dist: f32 = math.F32_MAX
		prev := o + u * size
		for k in 1 ..= _RING_SEGMENTS {
			a := f32(k) * math.TAU / _RING_SEGMENTS
			p := o + (u * math.cos(a) + v * math.sin(a)) * size
			dist = min(dist, _mouse_dist_segment(prev, p))
			prev = p
		}
		parts[i] = _interact(_part(id, 11 + i), dist <= DOT_HOVER_PX, dist, prio, o, dirs[i])
	}

	out: Drag
	active := -1
	for p, k in parts {
		if p.started {
			vec, ok := _ray_plane_dir(_frame.ray, o, dirs[k])
			if !ok do vec = dirs[(k + 1) % 3]
			_grab = {part = _part(id, 11 + k), origin = o, axis = dirs[k], vec = vec, rot = rot^}
		}
		if p.dragging || p.released do active = k
		_merge_part(&out, p)
	}
	cur: [3]f32
	cur_ok := false
	if active >= 0 {
		g := _grab
		cur, cur_ok = _ray_plane_dir(_frame.ray, g.origin, g.axis)
		if cur_ok {
			angle := snap_angle(math.atan2(linalg.dot(linalg.cross(g.vec, cur), g.axis), linalg.dot(g.vec, cur)))
			axis := linalg.normalize0(_vec_from_world(s, g.axis))
			rot^ = linalg.quaternion_angle_axis_f32(angle, axis) * g.rot
		}
	}

	gizmos.in_world_space()
	gizmos.with_depth_test(false)
	axis_colors := COLOR_AXES
	for i in 0 ..< 3 {
		gizmos.with_color(COLOR_HOT if parts[i].hot else axis_colors[i])
		gizmos.wire_circle(o, dirs[i], size, segments = _RING_SEGMENTS)
	}
	// During a drag: the grab direction and the pointer's, in the grab-time
	// plane.
	if active >= 0 {
		{
			gizmos.with_color(COLOR_CENTER)
			gizmos.line(o, o + _grab.vec * size)
		}
		if cur_ok {
			gizmos.with_color(COLOR_HOT)
			gizmos.line(o, o + cur * size)
		}
	}
	return out
}

// --- Scale ---------------------------------------------------------------------------

// Three arrows with cube tips that scale `scale` along the axes `rotation`
// gives, and a center cube that scales every axis (drag right or up to grow).
// An arrow's factor is how far along it the pointer moved, over `size`. The
// factor snaps to SNAP_SCALE_STEP and never goes below 0.01.
scale_handle :: proc(id: u64, scale: ^[3]f32, pos: [3]f32, rotation := quaternion128(1), size: f32 = 1, prio := 1) -> Drag {
	s := _space()
	o := _to_world(s, pos)
	dirs := _axes_world(s, rotation)

	parts: [4]Drag
	for i in 0 ..< 3 {
		dist := _mouse_dist_segment(o, o + dirs[i] * size)
		parts[i] = _interact(_part(id, 21 + i), dist <= DOT_HOVER_PX, dist, prio, o, _facing_normal(o, dirs[i]))
	}
	center_dist := _mouse_dist(o)
	parts[3] = _interact(_part(id, 24), center_dist < DOT_HOVER_PX * 1.5, center_dist, prio + 1, o, _to_camera(o))

	out: Drag
	active := -1
	for p, k in parts {
		if p.started {
			_grab = {part = _part(id, 21 + k), origin = o, dirs = dirs, px = _frame.input.mouse, scale = scale^}
			if k < 3 do _grab.s = _closest_axis_param(o, dirs[k], _frame.ray)
		}
		if p.dragging || p.released do active = k
		_merge_part(&out, p)
	}
	if active >= 0 {
		g := _grab
		factor: f32
		if active == 3 {
			m := _frame.input.mouse
			factor = max(1 + ((m.x - g.px.x) - (m.y - g.px.y)) * 0.005, 0.01)
		} else {
			factor = max(1 + (_closest_axis_param(g.origin, g.dirs[active], _frame.ray) - g.s) / size, 0.01)
		}
		if _snap_on && _frame.input.snap > 0 do factor = max(math.round(factor / SNAP_SCALE_STEP) * SNAP_SCALE_STEP, 0.01)
		sc := g.scale
		if active == 3 {
			sc *= factor
		} else {
			sc[active] *= factor
		}
		scale^ = sc
	}

	gizmos.in_world_space()
	gizmos.with_depth_test(false)
	axis_colors := COLOR_AXES
	for i in 0 ..< 3 {
		tip := o + dirs[i] * size
		gizmos.with_color(COLOR_HOT if parts[i].hot else axis_colors[i])
		gizmos.line(o, tip)
		_cube(tip, dirs, size * 0.05)
	}
	gizmos.with_color(COLOR_HOT if parts[3].hot else COLOR_CENTER)
	_cube(o, dirs, size * 0.06)
	return out
}

// A solid cube of half-extent r turned to `axes`.
@(private = "file")
_cube :: proc(center: [3]f32, axes: [3][3]f32, r: f32) {
	gizmos.with_matrix(matrix[4, 4]f32{
		axes[0].x, axes[1].x, axes[2].x, center.x,
		axes[0].y, axes[1].y, axes[2].y, center.y,
		axes[0].z, axes[1].z, axes[2].z, center.z,
		0, 0, 0, 1,
	})
	gizmos.solid_box({}, {2 * r, 2 * r, 2 * r})
}

// --- Shared --------------------------------------------------------------------------

// One summary for a composite: the dragged part's state wins.
@(private = "file")
_merge_part :: proc(out: ^Drag, d: Drag) {
	out.hot = out.hot || d.hot
	out.started = out.started || d.started
	out.dragging = out.dragging || d.dragging
	out.released = out.released || d.released
}

// Parameter of the point on the line (origin + s*axis) nearest to `ray`.
// 0 when the ray runs along the line.
@(private = "file")
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

// Ray against a plane, in front of the ray only: the hit and its ray
// parameter.
@(private = "file")
_ray_plane_ahead :: proc(ray: engine.Ray, origin, n: [3]f32) -> (hit: [3]f32, t: f32, ok: bool) {
	denom := linalg.dot(ray.direction, n)
	if abs(denom) < 1e-6 do return {}, 0, false
	t = linalg.dot(origin - ray.origin, n) / denom
	if t < 0 do return {}, 0, false
	return ray.origin + ray.direction * t, t, true
}

// The unit direction from `origin` to where the ray meets the plane.
@(private = "file")
_ray_plane_dir :: proc(ray: engine.Ray, origin, n: [3]f32) -> ([3]f32, bool) {
	hit, _, ok := _ray_plane_ahead(ray, origin, n)
	if !ok do return {}, false
	v := hit - origin
	if linalg.length(v) < 1e-6 do return {}, false
	return linalg.normalize(v), true
}
