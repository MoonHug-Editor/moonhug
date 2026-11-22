package mhgui

// UiPolygon: a graphic whose outline is a list of points, drawn as a mesh:
// an arrow, a speech bubble's tail, a chart's area, a line through points.
// The node also needs a CanvasRenderer.
//
// - `points` are in the node's rect, 0 to 1 across and up: (0, 0) is the
//   bottom left corner, (1, 1) the top right. The shape follows the rect.
// - `fill` fills the outline, which may be concave and must not cross itself.
// - `line_width` draws a line through the points, closed back to the first
//   one with `closed`. With `fill` off that is a line chart or a frame.
// - `antialias` fades the edges over one canvas unit, by a strip of
//   triangles whose outer points have no alpha.
//
// A UiShape draws rectangles, ellipses, polygons with equal sides and stars
// in a shader, with borders and shadows. A UiPolygon is for the outlines
// those do not cover.

import "core:math/linalg"
import "moonhug:packages/engine"

@(component={menu="UI/UiPolygon"})
@(typ_guid={guid = "71c4e9a2-0b5d-4f83-a6e1-3d8f2c7b5094"})
UiPolygon :: struct {
	using base:    engine.CompData `inspect:"-"`,
	using graphic: engine.Graphic `inline:""`,
	points:        [dynamic][2]f32 `decor:tooltip(desc="The outline, in the node's rect: 0 to 1 across and up.")`,
	fill:          bool `decor:tooltip(desc="Fill the outline. It may be concave and must not cross itself.")`,
	line_width:    f32 `decor:min(0) decor:tooltip(desc="The width of a line through the points, in canvas units. 0 draws none.")`,
	line_color:    [4]f32 `decor:color() decor:tooltip(desc="The line's colour. Its alpha is multiplied by the graphic's.")`,
	closed:        bool `decor:tooltip(desc="The line goes back from the last point to the first.")`,
	antialias:     bool `decor:tooltip(desc="Fade the edges over one canvas unit.")`,
}

// How wide the fade of an antialiased edge is, in canvas units.
POLYGON_FEATHER :: f32(1)

type_reset_UiPolygon :: proc(p: ^UiPolygon) {
	type_cleanup_UiPolygon(p)
	p.color = {1, 1, 1, 1}
	p.raycast_target = true
	p.fill = true
	p.closed = true
	p.antialias = true
	p.line_color = {1, 1, 1, 1}
}

type_cleanup_UiPolygon :: proc(p: ^UiPolygon) {
	delete(p.points)
	p.points = nil
}

// Twice the area the points go round, positive counter-clockwise.
polygon_area2 :: proc(points: [][2]f32) -> f32 {
	sum := f32(0)
	for p, i in points {
		q := points[(i + 1) % len(points)]
		sum += p.x * q.y - q.x * p.y
	}
	return sum
}

// The triangles of a polygon that does not cross itself, by cutting ears:
// three indices into `points` per triangle, temp-allocated. Either winding.
polygon_triangulate :: proc(points: [][2]f32) -> []int {
	n := len(points)
	if n < 3 do return nil
	out := make([dynamic]int, 0, (n - 2) * 3, context.temp_allocator)
	left := make([dynamic]int, 0, n, context.temp_allocator)
	// Walked counter-clockwise.
	if polygon_area2(points) >= 0 {
		for i in 0 ..< n do append(&left, i)
	} else {
		for i := n - 1; i >= 0; i -= 1 do append(&left, i)
	}
	cross :: proc(a, b, c: [2]f32) -> f32 {
		return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
	}
	for len(left) > 3 {
		cut := false
		for i in 0 ..< len(left) {
			ia, ib, ic := left[(i + len(left) - 1) % len(left)], left[i], left[(i + 1) % len(left)]
			a, b, c := points[ia], points[ib], points[ic]
			// A corner that turns in is no ear.
			if cross(a, b, c) <= 0 do continue
			inside := false
			for other in left {
				if other == ia || other == ib || other == ic do continue
				p := points[other]
				if cross(a, b, p) >= 0 && cross(b, c, p) >= 0 && cross(c, a, p) >= 0 {
					inside = true
					break
				}
			}
			if inside do continue
			append(&out, ia, ib, ic)
			ordered_remove(&left, i)
			cut = true
			break
		}
		// Points on one line, or an outline that crosses itself: the rest
		// goes as a fan, so something draws.
		if !cut {
			for i in 1 ..< len(left) - 1 do append(&out, left[0], left[i], left[i + 1])
			return out[:]
		}
	}
	append(&out, left[0], left[1], left[2])
	return out[:]
}

// The points moved `distance` to the right of the line through them, corners
// kept sharp (a miter, cut at three times the distance). Temp-allocated.
polygon_offset :: proc(points: [][2]f32, closed: bool, distance: f32) -> [][2]f32 {
	n := len(points)
	out := make([][2]f32, n, context.temp_allocator)
	if n < 2 {
		copy(out, points)
		return out
	}
	right :: proc(a, b: [2]f32) -> [2]f32 {
		d := linalg.normalize0(b - a)
		return {d.y, -d.x}
	}
	for p, i in points {
		has_in := closed || i > 0
		has_out := closed || i < n - 1
		n_in := right(points[(i + n - 1) % n], p) if has_in else right(p, points[(i + 1) % n])
		n_out := right(p, points[(i + 1) % n]) if has_out else n_in
		m := linalg.normalize0(n_in + n_out)
		if m == {} do m = n_in
		out[i] = p + m * (distance / max(linalg.dot(m, n_in), 1.0 / 3))
	}
	return out
}

@(canvas_graphic)
canvas_populate_UiPolygon :: proc(s: ^UiPolygon, rect: engine.Rect, out: ^[dynamic]engine.Graphic_Quad) {
	n := len(s.points)
	if n < 2 || rect.size.x <= 0 || rect.size.y <= 0 do return
	tex := white_texture_guid()
	uv := [2]f32{0.5, 0.5}
	points := make([][2]f32, n, context.temp_allocator)
	for p, i in s.points do points[i] = rect.pos + p * rect.size
	// Outward is to the right of a counter-clockwise outline.
	outward := f32(1) if polygon_area2(points) >= 0 else -1
	feather := POLYGON_FEATHER if s.antialias else 0
	WHITE :: [4]f32{1, 1, 1, 1}
	CLEAR :: [4]f32{1, 1, 1, 0}

	// A band between two lines of points, a colour per line.
	band :: proc(out: ^[dynamic]engine.Graphic_Quad, tex: engine.Asset_GUID, a, b: [][2]f32, closed: bool, color_a, color_b: [4]f32, absolute: bool) {
		n := len(a)
		for i in 0 ..< (n if closed else n - 1) {
			j := (i + 1) % n
			append(out, engine.Graphic_Quad{
				free     = true,
				corners  = {a[i], a[j], b[j], b[i]},
				colors   = {color_a, color_a, color_b, color_b},
				colored  = true,
				absolute = absolute,
				uvs      = {{0.5, 0.5}, {0.5, 0.5}, {0.5, 0.5}, {0.5, 0.5}},
				texture  = tex,
			})
		}
	}

	if s.fill && n >= 3 {
		// With a fade the solid part ends half the fade inside the outline.
		solid := polygon_offset(points, true, -outward * feather * 0.5) if feather > 0 else points
		tris := polygon_triangulate(solid)
		for i := 0; i + 2 < len(tris); i += 3 {
			engine.graphic_triangle(out, {solid[tris[i]], solid[tris[i + 1]], solid[tris[i + 2]]}, {uv, uv, uv}, tex)
		}
		if feather > 0 {
			band(out, tex, solid, polygon_offset(points, true, outward * feather * 0.5), true, WHITE, CLEAR, false)
		}
	}
	if s.line_width > 0 && s.line_color.a > 0 {
		half := s.line_width * 0.5
		closed := s.closed && n >= 3
		c := s.line_color
		clear_c := [4]f32{c.r, c.g, c.b, 0}
		inner := max(half - feather * 0.5, 0)
		l := polygon_offset(points, closed, -inner)
		r := polygon_offset(points, closed, inner)
		band(out, tex, l, r, closed, c, c, true)
		if feather > 0 {
			band(out, tex, l, polygon_offset(points, closed, -(half + feather * 0.5)), closed, c, clear_c, true)
			band(out, tex, r, polygon_offset(points, closed, half + feather * 0.5), closed, c, clear_c, true)
		}
	}
}

// The pointer hits a UiPolygon on its fill and on its line, not in the rest
// of its rect.
@(canvas_hit)
canvas_hit_UiPolygon :: proc(s: ^UiPolygon, rect: engine.Rect, point: [2]f32) -> bool {
	n := len(s.points)
	if n < 2 || rect.size.x <= 0 || rect.size.y <= 0 do return false
	points := make([][2]f32, n, context.temp_allocator)
	for p, i in s.points do points[i] = rect.pos + p * rect.size
	if s.fill && n >= 3 {
		// A ray to the right crosses the outline an odd number of times.
		inside := false
		for a, i in points {
			b := points[(i + 1) % n]
			if (a.y > point.y) != (b.y > point.y) && point.x < a.x + (point.y - a.y) / (b.y - a.y) * (b.x - a.x) do inside = !inside
		}
		if inside do return true
	}
	if s.line_width > 0 {
		reach := s.line_width * 0.5
		for i in 0 ..< (n if s.closed && n >= 3 else n - 1) {
			a, b := points[i], points[(i + 1) % n]
			e := b - a
			t := clamp(linalg.dot(point - a, e) / max(linalg.dot(e, e), 1e-6), 0, 1)
			if linalg.length(point - (a + e * t)) <= reach do return true
		}
	}
	return false
}
