package handles

// Bounds handles: slider dots on the faces of a box, sphere or capsule that
// resize it (docs/Handles.md). Each proc edits the values it is given while
// one of its dots drags, and reports the drag: the caller opens an undo
// session on `started`, writes the values back while `dragging` or on
// `released`, and closes the session on `released`.
//
// - Dragging a face moves it and keeps the opposite face in place: the center
//   moves by half the change.
// - Alt moves the opposite face too: the center stays.
// - Shift (box only) scales the other axes by the same ratio.
// - Sizes never go below zero. A capsule's height never goes below its
//   diameter.
// - Values are in the current gizmos space, so a collider calls these inside
//   the same in_local_space as its wires.
// - Dots on faces turned away from the camera draw faint and lose the pointer
//   to front dots at the same spot.
// - The procs draw only the dots: the shape itself is the caller's gizmo.

import "core:math/linalg"

Axis :: enum {
	X,
	Y,
	Z,
}

Axes :: bit_set[Axis]

ALL_AXES :: Axes{.X, .Y, .Z}

// Alpha multiplier for dots on faces turned away from the camera.
BACK_FACE_ALPHA :: f32(0.3)

// The values when the drag started: every frame rebuilds from them plus the
// drag, so snapping works on the whole distance and nothing drifts. One drag
// at a time, so one snapshot serves every bounds handle.
@(private = "file")
_Bounds_Grab :: struct {
	center:         [3]f32,
	size:           [3]f32,
	radius, height: f32,
}

@(private = "file")
_grab_bounds: _Bounds_Grab

// Six face dots that resize a box around `center` with `size` (full extents).
// `axes` limits the dots: 2D shapes pass {.X, .Y}.
box_bounds :: proc(id: u64, center, size: ^[3]f32, axes := ALL_AXES, color := COLOR_HANDLE) -> Drag {
	out: Drag
	for axis in axes {
		i := int(axis)
		for side in ([2]f32{-1, 1}) {
			dir := _axis_dir(i, side)
			d := _face_dot(_face_id(id, i, side), center^ + dir * (size^[i] * 0.5), dir, color)
			if d.started do _grab_bounds = {center = center^, size = size^}
			if d.dragging || d.released {
				g := _grab_bounds
				a := linalg.dot(d.delta, dir)
				c, s := g.center, g.size
				if _frame.input.alt {
					s[i] = max(g.size[i] + 2 * a, 0)
				} else {
					s[i] = max(g.size[i] + a, 0)
					c[i] = g.center[i] + side * (s[i] - g.size[i]) * 0.5
				}
				if _frame.input.shift && g.size[i] > 0 {
					ratio := s[i] / g.size[i]
					for other in axes do if other != axis do s[int(other)] = g.size[int(other)] * ratio
				}
				center^, size^ = c, s
			}
			_merge(&out, d)
		}
	}
	return out
}

// A dot at each end of every axis in `axes` that resizes a sphere.
sphere_bounds :: proc(id: u64, center: ^[3]f32, radius: ^f32, axes := ALL_AXES, color := COLOR_HANDLE) -> Drag {
	out: Drag
	for axis in axes {
		i := int(axis)
		for side in ([2]f32{-1, 1}) {
			dir := _axis_dir(i, side)
			d := _face_dot(_face_id(id, i, side), center^ + dir * radius^, dir, color)
			if d.started do _grab_bounds = {center = center^, radius = radius^}
			if d.dragging || d.released {
				g := _grab_bounds
				a := linalg.dot(d.delta, dir)
				c, r := g.center, g.radius
				if _frame.input.alt {
					r = max(g.radius + a, 0)
				} else {
					r = max(g.radius + a * 0.5, 0)
					c[i] = g.center[i] + side * (r - g.radius)
				}
				center^, radius^ = c, r
			}
			_merge(&out, d)
		}
	}
	return out
}

// Dots that resize a capsule along `axis`, its long axis: the two on that axis
// change `height` (the full length, caps included), the others `radius`.
// A radius past half the height pushes the height out with it.
capsule_bounds :: proc(id: u64, center: ^[3]f32, radius, height: ^f32, axis: Axis, axes := ALL_AXES, color := COLOR_HANDLE) -> Drag {
	out: Drag
	for ax in axes {
		i := int(ax)
		along := ax == axis
		for side in ([2]f32{-1, 1}) {
			dir := _axis_dir(i, side)
			extent := height^ * 0.5 if along else radius^
			d := _face_dot(_face_id(id, i, side), center^ + dir * extent, dir, color)
			if d.started do _grab_bounds = {center = center^, radius = radius^, height = height^}
			if d.dragging || d.released {
				g := _grab_bounds
				a := linalg.dot(d.delta, dir)
				c, r, h := g.center, g.radius, g.height
				if along {
					if _frame.input.alt {
						h = max(g.height + 2 * a, 2 * g.radius)
					} else {
						h = max(g.height + a, 2 * g.radius)
						c[i] = g.center[i] + side * (h - g.height) * 0.5
					}
				} else {
					if _frame.input.alt {
						r = max(g.radius + a, 0)
					} else {
						r = max(g.radius + a * 0.5, 0)
						c[i] = g.center[i] + side * (r - g.radius)
					}
					h = max(g.height, 2 * r)
				}
				center^, radius^, height^ = c, r, h
			}
			_merge(&out, d)
		}
	}
	return out
}

@(private = "file")
_axis_dir :: proc(i: int, side: f32) -> [3]f32 {
	dir: [3]f32
	dir[i] = side
	return dir
}

@(private = "file")
_face_id :: proc(id: u64, i: int, side: f32) -> u64 {
	return id_of(id, u64(i * 2 + (1 if side > 0 else 0)) + 1)
}

// A slider on a face, faint when the face is turned away from the camera.
@(private = "file")
_face_dot :: proc(id: u64, pos, dir: [3]f32, color: [4]f32) -> Drag {
	s := _space()
	front := linalg.dot(_normal_to_world(s, dir), _to_camera(_to_world(s, pos))) >= 0
	col := color
	if !front do col.a *= BACK_FACE_ALPHA
	return slider(id, pos, dir, color = col, prio = 1 if front else 0)
}

// One summary for a composite: the dragged dot's state wins.
@(private = "file")
_merge :: proc(out: ^Drag, d: Drag) {
	out.hot = out.hot || d.hot
	out.started = out.started || d.started
	out.released = out.released || d.released
	if d.dragging || d.released {
		out.dragging = out.dragging || d.dragging
		out.delta = d.delta
		out.point = d.point
	}
}
