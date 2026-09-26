package gizmos

// The shapes. Coordinates are in the current space (with_matrix,
// in_local_space), colors come from with_color. Families:
// - line_*: straight strokes
// - curve_*: curved strokes
// - wire_* / solid_*: areas and volumes, always as a pair. Solids are unlit
//   color, alpha allowed. A solid volume drawn without depth test shows only
//   its camera-facing faces, shaded by how much each faces the camera, so it
//   reads as 3D over everything (the transform gizmo's arrowheads). That needs
//   the current view (set_view), so draw those from a view's hooks.
// Angles are radians. rect and grid lie in the local XY plane: rotate them
// with with_matrix.

import "core:math"
import "core:math/linalg"
import "moonhug:engine"

// --- line_* -----------------------------------------------------------------------

line :: proc(a, b: [3]f32) {
	bt := _batch()
	_seg(bt, a, b)
}

// From `origin` to `origin + direction`.
line_ray :: proc(origin, direction: [3]f32) {
	bt := _batch()
	_seg(bt, origin, origin + direction)
}

// A line with a four-stroke head at `to`. `head` is the head length, 0 picks a
// fifth of the arrow.
line_arrow :: proc(from, to: [3]f32, head: f32 = 0) {
	bt := _batch()
	_seg(bt, from, to)
	d := to - from
	length := linalg.length(d)
	if length < 1e-6 do return
	dir := d / length
	h := head > 0 ? head : length * 0.2
	u, v := _basis(dir)
	back := to - dir * h
	for side in ([4][3]f32{u, -u, v, -v}) do _seg(bt, to, back + side * h * 0.4)
}

// Through `points` in order, back to the first when `closed`.
line_poly :: proc(points: [][3]f32, closed := false) {
	if len(points) < 2 do return
	bt := _batch()
	for i in 0 ..< len(points) - 1 do _seg(bt, points[i], points[i + 1])
	if closed do _seg(bt, points[len(points) - 1], points[0])
}

// Dashes of length `dash` with equal gaps, starting with a dash at `a`.
line_dashed :: proc(a, b: [3]f32, dash: f32) {
	bt := _batch()
	d := b - a
	length := linalg.length(d)
	if length < 1e-6 || dash <= 0 do return
	dir := d / length
	for t: f32 = 0; t < length; t += dash * 2 {
		_seg(bt, a + dir * t, a + dir * min(t + dash, length))
	}
}

// Three axis-aligned strokes through `center`, each `size` long.
line_cross :: proc(center: [3]f32, size: f32) {
	bt := _batch()
	h := size * 0.5
	_seg(bt, center - {h, 0, 0}, center + {h, 0, 0})
	_seg(bt, center - {0, h, 0}, center + {0, h, 0})
	_seg(bt, center - {0, 0, h}, center + {0, 0, h})
}

// X, Y, Z from `center`, `size` long, in red, green and blue (the scope color
// does not apply).
line_axes :: proc(center: [3]f32, size: f32) {
	axes := [3][4]f32{{1, 0.25, 0.25, 1}, {0.3, 1, 0.3, 1}, {0.3, 0.55, 1, 1}}
	bt := _batch()
	for axis in 0 ..< 3 {
		tip := center
		tip[axis] += size
		append(&bt.prims, _prim_line(_xf(center), _xf(tip), axes[axis]))
	}
}

// A grid of `cells` in the local XY plane, `size` across, centered on `center`.
line_grid :: proc(center: [3]f32, size: [2]f32, cells: [2]int) {
	if cells.x < 1 || cells.y < 1 do return
	bt := _batch()
	lo := center - {size.x * 0.5, size.y * 0.5, 0}
	for i in 0 ..= cells.x {
		x := lo.x + size.x * f32(i) / f32(cells.x)
		_seg(bt, {x, lo.y, center.z}, {x, lo.y + size.y, center.z})
	}
	for j in 0 ..= cells.y {
		y := lo.y + size.y * f32(j) / f32(cells.y)
		_seg(bt, {lo.x, y, center.z}, {lo.x + size.x, y, center.z})
	}
}

// --- curve_* ----------------------------------------------------------------------

// Cubic bezier from p0 to p3 with control points p1 and p2.
curve_bezier :: proc(p0, p1, p2, p3: [3]f32, segments := 24) {
	bt := _batch()
	prev := p0
	for i in 1 ..= max(segments, 1) {
		t := f32(i) / f32(max(segments, 1))
		u := 1 - t
		p := u * u * u * p0 + 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t * p3
		_seg(bt, prev, p)
		prev = p
	}
}

// --- wire_* / solid_*: areas --------------------------------------------------------

wire_circle :: proc(center, normal: [3]f32, radius: f32, segments := 32) {
	bt := _batch()
	u, v := _basis(normal)
	_ring(bt, center, u, v, radius, 0, math.TAU, segments)
}

solid_circle :: proc(center, normal: [3]f32, radius: f32, segments := 32) {
	bt := _batch()
	u, v := _basis(normal)
	_fan(bt, center, u, v, radius, 0, math.TAU, segments)
}

// Part of a circle around `normal`, starting at direction `from` (projected
// onto the circle's plane) and turning `angle` radians.
wire_arc :: proc(center, normal, from: [3]f32, angle, radius: f32, segments := 24) {
	bt := _batch()
	u, v := _arc_basis(normal, from)
	_ring(bt, center, u, v, radius, 0, angle, segments)
}

// A pie slice: the area of wire_arc.
solid_arc :: proc(center, normal, from: [3]f32, angle, radius: f32, segments := 24) {
	bt := _batch()
	u, v := _arc_basis(normal, from)
	_fan(bt, center, u, v, radius, 0, angle, segments)
}

// Axis-aligned in the local XY plane.
wire_rect :: proc(center: [3]f32, size: [2]f32) {
	wire_quad(_rect_corners(center, size))
}

solid_rect :: proc(center: [3]f32, size: [2]f32) {
	solid_quad(_rect_corners(center, size))
}

// Any four corners, in order around the edge.
wire_quad :: proc(corners: [4][3]f32) {
	bt := _batch()
	for i in 0 ..< 4 do _seg(bt, corners[i], corners[(i + 1) % 4])
}

solid_quad :: proc(corners: [4][3]f32) {
	bt := _batch()
	_tri(bt, corners[0], corners[1], corners[2])
	_tri(bt, corners[0], corners[2], corners[3])
}

wire_triangle :: proc(a, b, c: [3]f32) {
	bt := _batch()
	_seg(bt, a, b)
	_seg(bt, b, c)
	_seg(bt, c, a)
}

solid_triangle :: proc(a, b, c: [3]f32) {
	bt := _batch()
	_tri(bt, a, b, c)
}

// Closed outline through `points`.
wire_polygon :: proc(points: [][3]f32) {
	line_poly(points, closed = true)
}

// Filled as a fan from the first point: exact for convex polygons.
solid_polygon :: proc(points: [][3]f32) {
	if len(points) < 3 do return
	bt := _batch()
	for i in 1 ..< len(points) - 1 do _tri(bt, points[0], points[i], points[i + 1])
}

// --- wire_* / solid_*: volumes ------------------------------------------------------

// Axis-aligned in the current space.
wire_box :: proc(center, size: [3]f32) {
	bt := _batch()
	c := _box_corners(center, size)
	for i in 0 ..< 4 {
		_seg(bt, c[i], c[(i + 1) % 4])         // bottom
		_seg(bt, c[i + 4], c[(i + 1) % 4 + 4]) // top
		_seg(bt, c[i], c[i + 4])               // sides
	}
}

solid_box :: proc(center, size: [3]f32) {
	bt := _batch()
	wc := _xf(center)
	c := _box_corners(center, size)
	faces := [6][4]int{{0, 1, 2, 3}, {4, 5, 6, 7}, {0, 1, 5, 4}, {1, 2, 6, 5}, {2, 3, 7, 6}, {3, 0, 4, 7}}
	for f in faces {
		_vtri(bt, wc, c[f[0]], c[f[1]], c[f[2]])
		_vtri(bt, wc, c[f[0]], c[f[2]], c[f[3]])
	}
}

// Three great circles, one per axis plane.
wire_sphere :: proc(center: [3]f32, radius: f32, segments := 32) {
	bt := _batch()
	_ring(bt, center, {1, 0, 0}, {0, 1, 0}, radius, 0, math.TAU, segments)
	_ring(bt, center, {1, 0, 0}, {0, 0, 1}, radius, 0, math.TAU, segments)
	_ring(bt, center, {0, 1, 0}, {0, 0, 1}, radius, 0, math.TAU, segments)
}

solid_sphere :: proc(center: [3]f32, radius: f32, segments := 16) {
	bt := _batch()
	wc := _xf(center)
	n := max(segments, 4)
	rings := max(n / 2, 2)
	for r in 0 ..< rings {
		t0 := math.PI * f32(r) / f32(rings)
		t1 := math.PI * f32(r + 1) / f32(rings)
		for s in 0 ..< n {
			p0 := math.TAU * f32(s) / f32(n)
			p1 := math.TAU * f32(s + 1) / f32(n)
			a := center + _sphere_point(t0, p0) * radius
			b := center + _sphere_point(t0, p1) * radius
			c := center + _sphere_point(t1, p1) * radius
			d := center + _sphere_point(t1, p0) * radius
			_vtri(bt, wc, a, b, c)
			_vtri(bt, wc, a, c, d)
		}
	}
}

// Between the centers of its two end caps, `a` and `b`.
wire_capsule :: proc(a, b: [3]f32, radius: f32, segments := 24) {
	axis := b - a
	length := linalg.length(axis)
	if length < 1e-6 {
		wire_sphere(a, radius, segments)
		return
	}
	dir := axis / length
	u, v := _basis(dir)
	bt := _batch()
	_ring(bt, a, u, v, radius, 0, math.TAU, segments)
	_ring(bt, b, u, v, radius, 0, math.TAU, segments)
	for side in ([4][3]f32{u, -u, v, -v}) do _seg(bt, a + side * radius, b + side * radius)
	half := max(segments / 2, 2)
	_ring(bt, b, u, dir, radius, 0, math.PI, half)
	_ring(bt, b, v, dir, radius, 0, math.PI, half)
	_ring(bt, a, u, -dir, radius, 0, math.PI, half)
	_ring(bt, a, v, -dir, radius, 0, math.PI, half)
}

solid_capsule :: proc(a, b: [3]f32, radius: f32, segments := 16) {
	axis := b - a
	length := linalg.length(axis)
	if length < 1e-6 {
		solid_sphere(a, radius, segments)
		return
	}
	dir := axis / length
	u, v := _basis(dir)
	bt := _batch()
	wc := _xf((a + b) * 0.5)
	n := max(segments, 4)
	rings := max(n / 4, 2) // per hemisphere
	// Latitude rows from the `b` pole (+dir) to the `a` pole (-dir); the rows
	// on the equator repeat once per cap, which draws the side between them.
	row :: proc(center, u, v, dir: [3]f32, radius, lat, lon: f32) -> [3]f32 {
		return center + (dir * math.sin(lat) + (u * math.cos(lon) + v * math.sin(lon)) * math.cos(lat)) * radius
	}
	for cap in 0 ..< 2 {
		center := cap == 0 ? b : a
		sgn: f32 = cap == 0 ? 1 : -1
		for r in 0 ..< rings {
			l0 := sgn * math.PI * 0.5 * f32(r) / f32(rings)
			l1 := sgn * math.PI * 0.5 * f32(r + 1) / f32(rings)
			for s in 0 ..< n {
				o0 := math.TAU * f32(s) / f32(n)
				o1 := math.TAU * f32(s + 1) / f32(n)
				p0 := row(center, u, v, dir, radius, l0, o0)
				p1 := row(center, u, v, dir, radius, l0, o1)
				p2 := row(center, u, v, dir, radius, l1, o1)
				p3 := row(center, u, v, dir, radius, l1, o0)
				_vtri(bt, wc, p0, p1, p2)
				_vtri(bt, wc, p0, p2, p3)
			}
		}
	}
	for s in 0 ..< n {
		o0 := math.TAU * f32(s) / f32(n)
		o1 := math.TAU * f32(s + 1) / f32(n)
		e0 := (u * math.cos(o0) + v * math.sin(o0)) * radius
		e1 := (u * math.cos(o1) + v * math.sin(o1)) * radius
		_vtri(bt, wc, a + e0, a + e1, b + e1)
		_vtri(bt, wc, a + e0, b + e1, b + e0)
	}
}

// Between the centers of its two end faces, `a` and `b`.
wire_cylinder :: proc(a, b: [3]f32, radius: f32, segments := 24) {
	dir := linalg.normalize0(b - a)
	if dir == {} do dir = {0, 1, 0}
	u, v := _basis(dir)
	bt := _batch()
	_ring(bt, a, u, v, radius, 0, math.TAU, segments)
	_ring(bt, b, u, v, radius, 0, math.TAU, segments)
	for side in ([4][3]f32{u, -u, v, -v}) do _seg(bt, a + side * radius, b + side * radius)
}

solid_cylinder :: proc(a, b: [3]f32, radius: f32, segments := 24) {
	dir := linalg.normalize0(b - a)
	if dir == {} do dir = {0, 1, 0}
	u, v := _basis(dir)
	bt := _batch()
	wc := _xf((a + b) * 0.5)
	n := max(segments, 3)
	for s in 0 ..< n {
		o0 := math.TAU * f32(s) / f32(n)
		o1 := math.TAU * f32(s + 1) / f32(n)
		e0 := (u * math.cos(o0) + v * math.sin(o0)) * radius
		e1 := (u * math.cos(o1) + v * math.sin(o1)) * radius
		_vtri(bt, wc, a, a + e0, a + e1)
		_vtri(bt, wc, b, b + e0, b + e1)
		_vtri(bt, wc, a + e0, a + e1, b + e1)
		_vtri(bt, wc, a + e0, b + e1, b + e0)
	}
}

// Base circle at `base`, point at `tip`.
wire_cone :: proc(base, tip: [3]f32, radius: f32, segments := 24) {
	dir := linalg.normalize0(tip - base)
	if dir == {} do dir = {0, 1, 0}
	u, v := _basis(dir)
	bt := _batch()
	_ring(bt, base, u, v, radius, 0, math.TAU, segments)
	for side in ([4][3]f32{u, -u, v, -v}) do _seg(bt, base + side * radius, tip)
}

solid_cone :: proc(base, tip: [3]f32, radius: f32, segments := 24) {
	dir := linalg.normalize0(tip - base)
	if dir == {} do dir = {0, 1, 0}
	u, v := _basis(dir)
	bt := _batch()
	wc := _xf(base + (tip - base) * 0.25) // inside the cone, for face orientation
	n := max(segments, 3)
	for s in 0 ..< n {
		o0 := math.TAU * f32(s) / f32(n)
		o1 := math.TAU * f32(s + 1) / f32(n)
		e0 := base + (u * math.cos(o0) + v * math.sin(o0)) * radius
		e1 := base + (u * math.cos(o1) + v * math.sin(o1)) * radius
		_vtri(bt, wc, base, e0, e1)
		_vtri(bt, wc, e0, e1, tip)
	}
}

// Near and far rectangles, each four corners in the same order around the edge.
wire_frustum :: proc(near, far: [4][3]f32) {
	bt := _batch()
	for i in 0 ..< 4 {
		_seg(bt, near[i], near[(i + 1) % 4])
		_seg(bt, far[i], far[(i + 1) % 4])
		_seg(bt, near[i], far[i])
	}
}

solid_frustum :: proc(near, far: [4][3]f32) {
	bt := _batch()
	center: [3]f32
	for i in 0 ..< 4 do center += near[i] + far[i]
	wc := _xf(center / 8)
	quad :: proc(bt: ^_Batch, wc: [3]f32, q: [4][3]f32) {
		_vtri(bt, wc, q[0], q[1], q[2])
		_vtri(bt, wc, q[0], q[2], q[3])
	}
	quad(bt, wc, near)
	quad(bt, wc, far)
	for i in 0 ..< 4 {
		j := (i + 1) % 4
		quad(bt, wc, {near[i], near[j], far[j], far[i]})
	}
}

// --- Internals ----------------------------------------------------------------------

// A local-space triangle of a convex solid whose world-space center is `wc`.
// Without depth test and with a view set, a face turned away from the camera
// is skipped (it would paint over the front faces) and the rest are shaded by
// how much they face the camera. Otherwise every face is drawn flat.
@(private)
_vtri :: proc(bt: ^_Batch, wc, a, b, c: [3]f32) {
	wa, wb, w3 := _xf(a), _xf(b), _xf(c)
	color := _s.color
	if !_s.depth_test && _s.has_view {
		n := linalg.cross(wb - wa, w3 - wa)
		mid := (wa + wb + w3) / 3
		if linalg.dot(n, mid - wc) < 0 do n = -n
		facing := linalg.dot(linalg.normalize0(n), linalg.normalize0(_s.view.cam_pos - mid))
		if facing <= 0 do return
		shade := 0.55 + 0.45 * facing
		color = {color.r * shade, color.g * shade, color.b * shade, color.a}
	}
	append(&bt.prims, engine.Gizmo_Prim{p = {wa, wb, w3}, color = color, kind = .Triangle})
}

// Two unit vectors perpendicular to `n` and to each other.
@(private)
_basis :: proc(n: [3]f32) -> (u, v: [3]f32) {
	nn := linalg.normalize0(n)
	if nn == {} do nn = {0, 0, 1}
	helper := abs(nn.y) < 0.99 ? [3]f32{0, 1, 0} : [3]f32{1, 0, 0}
	u = linalg.normalize(linalg.cross(helper, nn))
	v = linalg.cross(nn, u)
	return
}

// u along `from` in the plane of `normal`, v a quarter turn further.
@(private)
_arc_basis :: proc(normal, from: [3]f32) -> (u, v: [3]f32) {
	n := linalg.normalize0(normal)
	if n == {} do n = {0, 0, 1}
	u = linalg.normalize0(from - n * linalg.dot(from, n))
	if u == {} {
		u, v = _basis(n)
		return
	}
	v = linalg.cross(n, u)
	return
}

// Points center + radius*(u cos t + v sin t) for t in [t0, t1], as segments.
@(private)
_ring :: proc(bt: ^_Batch, center, u, v: [3]f32, radius, t0, t1: f32, segments: int) {
	n := max(segments, 1)
	prev := center + u * (radius * math.cos(t0)) + v * (radius * math.sin(t0))
	for i in 1 ..= n {
		t := t0 + (t1 - t0) * f32(i) / f32(n)
		p := center + u * (radius * math.cos(t)) + v * (radius * math.sin(t))
		_seg(bt, prev, p)
		prev = p
	}
}

// The area of _ring, as triangles from the center.
@(private)
_fan :: proc(bt: ^_Batch, center, u, v: [3]f32, radius, t0, t1: f32, segments: int) {
	n := max(segments, 1)
	prev := center + u * (radius * math.cos(t0)) + v * (radius * math.sin(t0))
	for i in 1 ..= n {
		t := t0 + (t1 - t0) * f32(i) / f32(n)
		p := center + u * (radius * math.cos(t)) + v * (radius * math.sin(t))
		_tri(bt, center, prev, p)
		prev = p
	}
}

@(private)
_rect_corners :: proc(center: [3]f32, size: [2]f32) -> [4][3]f32 {
	h := size * 0.5
	return {center + {-h.x, -h.y, 0}, center + {h.x, -h.y, 0}, center + {h.x, h.y, 0}, center + {-h.x, h.y, 0}}
}

// Bottom four (z low) then top four, each in the same order around the edge.
@(private)
_box_corners :: proc(center, size: [3]f32) -> [8][3]f32 {
	h := size * 0.5
	return {
		center + {-h.x, -h.y, -h.z}, center + {h.x, -h.y, -h.z}, center + {h.x, h.y, -h.z}, center + {-h.x, h.y, -h.z},
		center + {-h.x, -h.y, h.z}, center + {h.x, -h.y, h.z}, center + {h.x, h.y, h.z}, center + {-h.x, h.y, h.z},
	}
}

// Unit sphere point: theta from +Z (0) to -Z (pi), phi around Z.
@(private)
_sphere_point :: proc(theta, phi: f32) -> [3]f32 {
	return {math.sin(theta) * math.cos(phi), math.sin(theta) * math.sin(phi), math.cos(theta)}
}
