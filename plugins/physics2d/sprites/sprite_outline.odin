package physics2d_sprites

// The outline of a sprite's opaque pixels, for a polygon collider added to
// a sprite: Unity's physics shape. The opaque pixels of the sprite's rect
// are a mask, marching squares traces the mask's boundaries as loops of
// pixel-edge midpoints, the longest loop is kept, and a Douglas-Peucker pass
// drops the points a straight line covers within OUTLINE_TOLERANCE_PX. The
// points come out in the collider's space: pixels over the texture's
// pixels per unit, around the sprite's pivot, y up. The folder compiles only
// with the sprites plugin installed (docs/core/Plugins.md).

import "core:encoding/uuid"
import "core:math"
import stbi "vendor:stb/image"
import "moonhug:packages/engine"
import sprites "moonhug:packages/sprites"

// A pixel counts as opaque above this alpha.
ALPHA_OPAQUE :: 127

// The distance in pixels a dropped point may lie from the line that replaces
// it.
OUTLINE_TOLERANCE_PX :: 2.0

// The outline of the sprite the object shows, in the collider's space.
// false when the object has no SpriteRenderer with a sprite, the texture
// cannot be read, or nothing in the sprite's rect is opaque.
sprite_outline_of_owner :: proc(owner: engine.Transform_Handle, points: ^[dynamic][2]f32) -> bool {
	w := engine.ctx_world()
	if w == nil || !engine.pool_valid(&w.transforms, engine.Handle(owner)) do return false
	_, sr := engine.transform_get_comp(owner, sprites.SpriteRenderer)
	if sr == nil do return false
	return sprite_outline(sr.sprite, points)
}

// The outline of a sprite reference (texture guid, slice id or 0 for the
// whole texture), in the collider's space.
sprite_outline :: proc(sprite: engine.PPtr, points: ^[dynamic][2]f32) -> bool {
	// The texture's artifact holds its image bytes. A slice has no file of
	// its own, so the texture's main artifact is the one to read.
	data, data_ok := engine.artifact_read(sprite.guid)
	if !data_ok do return false
	path, path_ok := engine.asset_db_get_path(uuid.Identifier(sprite.guid))
	if !path_ok do return false
	width, height, channels: i32
	pixels := stbi.load_from_memory(raw_data(data), i32(len(data)), &width, &height, &channels, 4)
	if pixels == nil do return false
	defer stbi.image_free(pixels)

	// The rect, pivot and pixels per unit the renderer sizes the sprite by.
	rect := [4]f32{0, 0, f32(width), f32(height)}
	pivot := [2]f32{0.5, 0.5}
	ppu := f32(engine.PIXELS_PER_UNIT)
	if settings, sok := engine.asset_pipeline_get_settings(path, context.temp_allocator); sok {
		if ts, is_tex := settings.(engine.TextureSettings); is_tex {
			if ts.pixels_per_unit > 0 do ppu = ts.pixels_per_unit
			if sprite.local_id != 0 {
				found := false
				for s in ts.sprites {
					if s.id != sprite.local_id do continue
					rect, pivot, found = s.rect, s.pivot, true
					break
				}
				if !found do return false
			}
		}
	}

	rw, rh := int(rect.z), int(rect.w)
	if rw <= 0 || rh <= 0 do return false
	mask := make([]bool, rw * rh, context.temp_allocator)
	for y in 0 ..< rh {
		py := int(rect.y) + y
		if py < 0 || py >= int(height) do continue
		for x in 0 ..< rw {
			px := int(rect.x) + x
			if px < 0 || px >= int(width) do continue
			mask[y * rw + x] = pixels[(py * int(width) + px) * 4 + 3] > ALPHA_OPAQUE
		}
	}
	outline := mask_outline(mask, rw, rh, context.temp_allocator)
	if len(outline) < 3 do return false

	clear(points)
	for p in outline {
		append(points, [2]f32{(p.x - pivot.x * rect.z) / ppu, (rect.w - p.y - pivot.y * rect.w) / ppu})
	}
	return true
}

// The longest boundary loop of a mask, simplified, in pixel coordinates
// with the origin at the mask's top-left corner and y down. Empty when the
// mask has no opaque pixel. Allocated on `allocator`.
mask_outline :: proc(mask: []bool, w, h: int, allocator := context.allocator) -> [][2]f32 {
	loops := _marching_squares(mask, w, h)
	best := -1
	best_area: f32
	for loop, i in loops {
		area := abs(_area(loop[:]))
		if area > best_area { best, best_area = i, area }
	}
	if best < 0 do return nil
	return _simplify_loop(loops[best][:], OUTLINE_TOLERANCE_PX, allocator)
}

// Every boundary loop of the mask as pixel-edge midpoints. The mask is read
// on a grid with one empty sample around it, so every loop closes. Temp.
@(private = "file")
_marching_squares :: proc(mask: []bool, w, h: int) -> [dynamic][dynamic][2]f32 {
	sample :: proc(mask: []bool, w, h, i, j: int) -> bool {
		x, y := i - 1, j - 1
		if x < 0 || y < 0 || x >= w || y >= h do return false
		return mask[y * w + x]
	}
	// A segment per cell edge pair, and the segments at each endpoint. The
	// endpoint key is the coordinate doubled: midpoints sit on halves.
	Segment :: struct { a, b: [2]f32 }
	segments := make([dynamic]Segment, context.temp_allocator)
	at := make(map[[2]int][dynamic]int, context.temp_allocator)
	key :: proc(p: [2]f32) -> [2]int { return {int(p.x * 2), int(p.y * 2)} }
	add :: proc(segments: ^[dynamic]Segment, at: ^map[[2]int][dynamic]int, a, b: [2]f32) {
		id := len(segments)
		append(segments, Segment{a, b})
		for p in ([2][2]f32{a, b}) {
			k := key(p)
			list, has := &at[k]
			if !has {
				at[k] = make([dynamic]int, context.temp_allocator)
				list = &at[k]
			}
			append(list, id)
		}
	}
	for cy in 0 ..= h {
		for cx in 0 ..= w {
			tl := sample(mask, w, h, cx, cy)
			tr := sample(mask, w, h, cx + 1, cy)
			br := sample(mask, w, h, cx + 1, cy + 1)
			bl := sample(mask, w, h, cx, cy + 1)
			// The cell's corner samples sit on pixel centers at half steps,
			// so its edge midpoints sit on whole and half pixel coordinates.
			fx, fy := f32(cx), f32(cy)
			top    := [2]f32{fx, fy - 0.5}
			right  := [2]f32{fx + 0.5, fy}
			bottom := [2]f32{fx, fy + 0.5}
			left   := [2]f32{fx - 0.5, fy}
			c := 0
			if tl do c |= 8
			if tr do c |= 4
			if br do c |= 2
			if bl do c |= 1
			switch c {
			case 0, 15:
			case 1, 14: add(&segments, &at, left, bottom)
			case 2, 13: add(&segments, &at, bottom, right)
			case 3, 12: add(&segments, &at, left, right)
			case 4, 11: add(&segments, &at, top, right)
			case 6, 9:  add(&segments, &at, top, bottom)
			case 7, 8:  add(&segments, &at, left, top)
			// Saddles: two opposite corners opaque. Keep them apart, so a
			// loop never crosses itself.
			case 5:  add(&segments, &at, left, top); add(&segments, &at, bottom, right)
			case 10: add(&segments, &at, top, right); add(&segments, &at, left, bottom)
			}
		}
	}

	loops := make([dynamic][dynamic][2]f32, context.temp_allocator)
	used := make([]bool, len(segments), context.temp_allocator)
	for start in 0 ..< len(segments) {
		if used[start] do continue
		loop := make([dynamic][2]f32, context.temp_allocator)
		cur := start
		p := segments[start].a
		for {
			used[cur] = true
			append(&loop, p)
			s := segments[cur]
			p = p == s.a ? s.b : s.a
			next := -1
			for id in at[key(p)] do if !used[id] { next = id; break }
			if next < 0 do break
			cur = next
		}
		if len(loop) >= 3 do append(&loops, loop)
	}
	return loops
}

@(private = "file")
_area :: proc(points: [][2]f32) -> f32 {
	area: f32
	for p, i in points {
		q := points[(i + 1) % len(points)]
		area += p.x * q.y - q.x * p.y
	}
	return area * 0.5
}

// Douglas-Peucker on a closed loop: it is cut at its two farthest-apart
// points and each half simplified, so the result keeps both.
@(private = "file")
_simplify_loop :: proc(loop: [][2]f32, tolerance: f32, allocator := context.allocator) -> [][2]f32 {
	n := len(loop)
	if n < 4 {
		out := make([][2]f32, n, allocator)
		copy(out, loop)
		return out
	}
	first := 0
	second := n / 2
	best: f32 = -1
	for i in 0 ..< n {
		d := _dist2(loop[i], loop[(i + n / 2) % n])
		if d > best { best, first, second = d, i, (i + n / 2) % n }
	}
	if first > second do first, second = second, first
	keep := make([]bool, n, context.temp_allocator)
	keep[first], keep[second] = true, true
	_simplify_range(loop, first, second, tolerance, keep)
	// The other half wraps around the end.
	shifted := make([][2]f32, n, context.temp_allocator)
	for i in 0 ..< n do shifted[i] = loop[(second + i) % n]
	keep2 := make([]bool, n, context.temp_allocator)
	wrap_first := (first - second + n) % n
	keep2[0], keep2[wrap_first] = true, true
	_simplify_range(shifted, 0, wrap_first, tolerance, keep2)
	for i in 0 ..< n do if keep2[i] do keep[(second + i) % n] = true

	out := make([dynamic][2]f32, 0, n, allocator)
	for i in 0 ..< n do if keep[i] do append(&out, loop[i])
	return out[:]
}

@(private = "file")
_simplify_range :: proc(points: [][2]f32, lo, hi: int, tolerance: f32, keep: []bool) {
	if hi - lo < 2 do return
	a, b := points[lo], points[hi]
	best_i := -1
	best: f32
	for i in lo + 1 ..< hi {
		d := _point_line_dist(points[i], a, b)
		if d > best { best, best_i = d, i }
	}
	if best_i < 0 || best <= tolerance do return
	keep[best_i] = true
	_simplify_range(points, lo, best_i, tolerance, keep)
	_simplify_range(points, best_i, hi, tolerance, keep)
}

@(private = "file")
_dist2 :: proc(a, b: [2]f32) -> f32 {
	d := a - b
	return d.x * d.x + d.y * d.y
}

@(private = "file")
_point_line_dist :: proc(p, a, b: [2]f32) -> f32 {
	ab := b - a
	l2 := ab.x * ab.x + ab.y * ab.y
	if l2 < 1e-12 do return math.sqrt(_dist2(p, a))
	t := clamp(((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / l2, 0, 1)
	return math.sqrt(_dist2(p, a + ab * t))
}
