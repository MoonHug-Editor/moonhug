package physics2d

// A polygon collider's path is any simple polygon, and box2d's polygon shape
// is convex with at most MAX_POLYGON_VERTICES (8) vertices. polygon_partition
// turns the one into pieces of the other: ear clipping into triangles, then
// merging neighbours across their shared edge while the union stays convex
// and within the vertex cap (Hertel-Mehlhorn, bounded by the cap). Each
// piece becomes one shape on the collider's body.

import "core:math"
import b2 "vendor:box2d"

// Below this a cross product counts as a straight line.
@(private = "file") POLYGON_EPS :: 1e-6

// The signed area of a closed path: positive counter-clockwise.
polygon_area :: proc(points: [][2]f32) -> f32 {
	area: f32
	for p, i in points {
		q := points[(i + 1) % len(points)]
		area += p.x * q.y - q.x * p.y
	}
	return area * 0.5
}

// The convex pieces of a simple polygon, each at most MAX_POLYGON_VERTICES
// points in the path's own space, allocated on `allocator`. ok=false for a
// path that is not a simple polygon: fewer than three distinct points, all
// on a line, or self-intersecting, which leaves ear clipping no ear.
polygon_partition :: proc(points: [][2]f32, allocator := context.allocator) -> (pieces: [][][2]f32, ok: bool) {
	// Distinct consecutive points, counter-clockwise.
	ring := make([dynamic]int, 0, len(points), context.temp_allocator)
	for p, i in points {
		prev := points[(i + len(points) - 1) % len(points)]
		if p == prev && len(points) > 1 do continue
		append(&ring, i)
	}
	if len(ring) < 3 do return nil, false
	if !_is_simple(points, ring[:]) do return nil, false
	ccw := polygon_area(points) > 0
	if !ccw {
		for i in 0 ..< len(ring) / 2 do ring[i], ring[len(ring) - 1 - i] = ring[len(ring) - 1 - i], ring[i]
	}

	// Ear clipping.
	tris := make([dynamic][dynamic]int, context.temp_allocator)
	for len(ring) > 3 {
		found := false
		for i in 0 ..< len(ring) {
			a, b, c := ring[(i + len(ring) - 1) % len(ring)], ring[i], ring[(i + 1) % len(ring)]
			if _cross(points[a], points[b], points[c]) <= POLYGON_EPS do continue
			ear := true
			for j in 0 ..< len(ring) {
				v := ring[j]
				if v == a || v == b || v == c do continue
				if points[v] == points[a] || points[v] == points[b] || points[v] == points[c] do continue
				if _in_triangle(points[v], points[a], points[b], points[c]) { ear = false; break }
			}
			if !ear do continue
			tri := make([dynamic]int, context.temp_allocator)
			append(&tri, a, b, c)
			append(&tris, tri)
			ordered_remove(&ring, i)
			found = true
			break
		}
		if !found do return nil, false
	}
	if _cross(points[ring[0]], points[ring[1]], points[ring[2]]) > POLYGON_EPS {
		tri := make([dynamic]int, context.temp_allocator)
		append(&tri, ring[0], ring[1], ring[2])
		append(&tris, tri)
	}
	if len(tris) == 0 do return nil, false

	// Merge neighbours while the union is convex and within the cap.
	merged := true
	for merged {
		merged = false
		outer: for i in 0 ..< len(tris) {
			for j in i + 1 ..< len(tris) {
				if u, uok := _merge_convex(points, tris[i][:], tris[j][:]); uok {
					tris[i] = u
					ordered_remove(&tris, j)
					merged = true
					break outer
				}
			}
		}
	}

	pieces = make([][][2]f32, len(tris), allocator)
	for piece, i in tris {
		pieces[i] = make([][2]f32, len(piece), allocator)
		for v, k in piece do pieces[i][k] = points[v]
	}
	return pieces, true
}

// Frees what polygon_partition returned.
polygon_pieces_free :: proc(pieces: [][][2]f32, allocator := context.allocator) {
	for p in pieces do delete(p, allocator)
	delete(pieces, allocator)
}

// The union of two convex pieces that share an edge, when it is convex and
// has at most MAX_POLYGON_VERTICES vertices. `a` holds the edge as (p, q),
// `b` as (q, p): the union walks a from q round to p, then b from after p
// round to before q.
@(private = "file")
_merge_convex :: proc(points: [][2]f32, a, b: []int) -> ([dynamic]int, bool) {
	if len(a) + len(b) - 2 > b2.MAX_POLYGON_VERTICES do return nil, false
	for i in 0 ..< len(a) {
		p, q := a[i], a[(i + 1) % len(a)]
		for j in 0 ..< len(b) {
			if b[j] != q || b[(j + 1) % len(b)] != p do continue
			u := make([dynamic]int, 0, len(a) + len(b) - 2, context.temp_allocator)
			for k in 0 ..< len(a) do append(&u, a[(i + 1 + k) % len(a)])
			for k in 2 ..< len(b) do append(&u, b[(j + k) % len(b)])
			if _is_convex(points, u[:]) do return u, true
			delete(u)
			return nil, false
		}
	}
	return nil, false
}

@(private = "file")
_is_convex :: proc(points: [][2]f32, ring: []int) -> bool {
	for i in 0 ..< len(ring) {
		a, b, c := points[ring[i]], points[ring[(i + 1) % len(ring)]], points[ring[(i + 2) % len(ring)]]
		if _cross(a, b, c) < -POLYGON_EPS do return false
	}
	return true
}

// No two edges cross, the neighbours of an edge excepted. Ear clipping
// cannot tell a crossing path apart on its own: a bow tie still has ears.
@(private = "file")
_is_simple :: proc(points: [][2]f32, ring: []int) -> bool {
	n := len(ring)
	for i in 0 ..< n {
		a, b := points[ring[i]], points[ring[(i + 1) % n]]
		for j in i + 2 ..< n {
			if i == 0 && j == n - 1 do continue
			c, d := points[ring[j]], points[ring[(j + 1) % n]]
			if _segments_cross(a, b, c, d) do return false
		}
	}
	return true
}

// Proper crossing of two segments: each straddles the other's line.
@(private = "file")
_segments_cross :: proc(a, b, c, d: [2]f32) -> bool {
	d1, d2 := _cross(a, b, c), _cross(a, b, d)
	d3, d4 := _cross(c, d, a), _cross(c, d, b)
	return ((d1 > POLYGON_EPS && d2 < -POLYGON_EPS) || (d1 < -POLYGON_EPS && d2 > POLYGON_EPS)) &&
		((d3 > POLYGON_EPS && d4 < -POLYGON_EPS) || (d3 < -POLYGON_EPS && d4 > POLYGON_EPS))
}

@(private = "file")
_cross :: proc(a, b, c: [2]f32) -> f32 {
	return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
}

// Inside or on the counter-clockwise triangle.
@(private = "file")
_in_triangle :: proc(p, a, b, c: [2]f32) -> bool {
	return _cross(a, b, p) >= -POLYGON_EPS && _cross(b, c, p) >= -POLYGON_EPS && _cross(c, a, p) >= -POLYGON_EPS
}

// A regular polygon of `sides` points on a circle: the default path of a
// new polygon collider, Unity's pentagon.
polygon_regular :: proc(points: ^[dynamic][2]f32, sides: int, radius: f32) {
	clear(points)
	for i in 0 ..< sides {
		angle := math.PI * 0.5 + f32(i) * 2 * math.PI / f32(sides)
		append(points, [2]f32{radius * math.cos(angle), radius * math.sin(angle)})
	}
}
