package handles

// Interactive scene-view handles for editor code and package editors
// (docs/Handles.md). Immediate mode, keyed by caller ids like imgui: a handle
// proc draws itself into the open scene pass, reports hover, and when the
// user drags it, reports the drag as a world-space offset on a plane. The
// scene view publishes the frame (view, mouse, hover) before the gizmo hooks
// run, and asks `consumes_mouse` before picking or box-selecting.
//
// Undo is the caller's: open an undo session on `started`, close it on
// `released`, so one drag is one undo step.

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:strings"
import im "moonhug:external/odin-imgui"
import "moonhug:engine"
import gfx "moonhug:engine/gfx"

// Hovered handle color, imgui's Handles yellow (the transform gizmo uses it).
COLOR_HOT :: [4]f32{246.0 / 255, 242.0 / 255, 50.0 / 255, 0.89}
// Handle chrome at rest.
COLOR_HANDLE :: [4]f32{1, 1, 1, 0.9}
COLOR_SHADOW :: [4]f32{0, 0, 0, 0.5} // under white outlines, for light backgrounds

// Pixel radius inside which a dot handle counts as hovered.
DOT_HOVER_PX :: f32(8)

Frame :: struct {
	view:    engine.Render_View,
	mouse:   [2]f32, // viewport pixels, scene image top-left origin
	ray:     engine.Ray,
	hovered: bool, // the scene view has the pointer
	valid:   bool,
}

_frame: Frame

// Hot resolution is one frame late (imgui's HoveredIdPreviousFrame): every
// handle proposes itself during the frame, the nearest highest-priority one
// wins, and handles read the previous frame's winner. Active is the handle
// being dragged; it stays active while the mouse is down, and is dropped
// when its owner stops calling in.
_hot_prev:    u64
_hot:         u64
_hot_prio:    int
_hot_dist:    f32
_active:      u64
_active_seen: bool
_grab:        [3]f32 // plane point at grab
_grab_origin: [3]f32 // drag plane origin
_grab_normal: [3]f32 // drag plane normal

// One handle's state for this frame.
Drag :: struct {
	hot:      bool, // hovered (or being dragged)
	started:  bool, // the mouse went down on it this frame
	dragging: bool, // the mouse is down and it moved with the drag (includes the start frame)
	released: bool, // the mouse came up this frame
	delta:    [3]f32, // world offset of the drag plane point from the grab point
	point:    [3]f32, // current drag plane point
}

// The rect tool's raw edit mode (the inspector's [R]): anchor and pivot
// changes leave anchored position and size alone, so the rect moves. Off,
// they keep the rect where it is. Shared by the inspector and the scene
// handles, so it lives here.
rect_raw_edit: bool

// The scene view calls this once per frame with the pass open, before the
// gizmo hooks. `mouse` in viewport pixels relative to the scene image.
frame_begin :: proc(view: engine.Render_View, mouse: [2]f32, hovered: bool) {
	_frame = Frame{
		view    = view,
		mouse   = mouse,
		ray     = engine.render_view_screen_ray(view, mouse.x, mouse.y),
		hovered = hovered,
		valid   = true,
	}
	_hot_prev = _hot
	_hot = 0
	_hot_prio = -1
	_hot_dist = math.F32_MAX
	if _active != 0 && !_active_seen do _active = 0 // its owner went away mid-drag
	_active_seen = false
	clear(&_labels)
}

// --- Labels -------------------------------------------------------------------------------
// Text next to a world point. Handles draw lines through gfx, but text is
// imgui's: the scene view reads labels() after its image and draws them over
// it, so a label queued here shows on the same frame.

Label :: struct {
	px:      [2]f32, // scene image pixels
	text:    string, // temp-allocated, this frame
	align:   [2]f32, // which point of the text box sits at px: {0, 0} top-left, {0.5, 0} top-center, {1, 0.5} right-center
	rotated: bool,   // drawn turned 90 degrees, reading bottom to top (a vertical line's label)
}

@(private = "file") _labels: [dynamic]Label

// `offset_px` moves the label on screen after projecting, e.g. a few pixels
// below a line.
label :: proc(pos: [3]f32, text: string, align := [2]f32{0, 0}, rotated := false, offset_px := [2]f32{0, 0}) {
	px, ok := project(pos)
	if !ok do return
	if _labels == nil do _labels = make([dynamic]Label, runtime.default_allocator())
	append(&_labels, Label{px = px + offset_px, text = strings.clone(text, context.temp_allocator), align = align, rotated = rotated})
}

labels :: proc() -> []Label {
	return _labels[:]
}

// True while a handle is hovered or dragged: the scene view then neither
// picks nor starts a box select.
consumes_mouse :: proc() -> bool {
	return _hot_prev != 0 || _active != 0
}

frame :: proc() -> Frame {
	return _frame
}

// --- Geometry -----------------------------------------------------------------------

// Ray against the plane through `origin` with `normal`. ok=false when the
// ray runs parallel to the plane.
ray_plane :: proc(ray: engine.Ray, origin, normal: [3]f32) -> (p: [3]f32, ok: bool) {
	denom := linalg.dot(ray.direction, normal)
	if abs(denom) < 1e-6 do return {}, false
	t := linalg.dot(origin - ray.origin, normal) / denom
	return ray.origin + ray.direction * t, true
}

// World point -> viewport pixels. ok=false behind the camera.
project :: proc(p: [3]f32) -> (px: [2]f32, ok: bool) {
	v := _frame.view
	clip := v.view_proj * [4]f32{p.x, p.y, p.z, 1}
	if clip.w <= 1e-6 do return {}, false
	ndc := clip.xy / clip.w
	return {(ndc.x + 1) * 0.5 * v.width, (1 - ndc.y) * 0.5 * v.height}, true
}

// World length that spans `pixels` on screen at `p`: exact for perspective
// and orthographic views alike (two unprojected pixels on the plane facing
// the camera through `p`).
world_per_pixels :: proc(p: [3]f32, pixels: f32) -> f32 {
	v := _frame.view
	sp, ok := project(p)
	if !ok do return 0
	n := linalg.normalize0(v.cam_pos - p)
	if n == {} do n = {0, 0, 1}
	a, aok := ray_plane(engine.render_view_screen_ray(v, sp.x, sp.y), p, n)
	b, bok := ray_plane(engine.render_view_screen_ray(v, sp.x + pixels, sp.y), p, n)
	if !aok || !bok do return 0
	return linalg.length(b - a)
}

// Camera right and up in world space (rows of the view rotation).
_camera_basis :: proc() -> (right, up: [3]f32) {
	m := _frame.view.view
	return {m[0, 0], m[0, 1], m[0, 2]}, {m[1, 0], m[1, 1], m[1, 2]}
}

// --- Drawing (overlay: never depth-tested, like the transform gizmo) --------------

line :: proc(a, b: [3]f32, color: [4]f32) {
	gfx.draw_line(a, b, color, depth_test = false)
}

// bl, br, tr, tl or any closed order.
rect :: proc(c: [4][3]f32, color: [4]f32) {
	for i in 0 ..< 4 do line(c[i], c[(i + 1) % 4], color)
}

// A rect outline with a dark half-transparent line one pixel INSIDE each
// edge, so the outline reads on a white image too (the rect tool). Inside
// rather than shifted, so the outline still marks the exact edge.
rect_outlined :: proc(c: [4][3]f32, color: [4]f32) {
	center := (c[0] + c[1] + c[2] + c[3]) * 0.25
	px := world_per_pixels(center, 1)
	for i in 0 ..< 4 {
		a, b := c[i], c[(i + 1) % 4]
		inward := linalg.normalize0(center - (a + b) * 0.5) * px
		line(a + inward, b + inward, COLOR_SHADOW)
	}
	rect(c, color)
}

circle :: proc(center, normal: [3]f32, radius: f32, color: [4]f32, segments := 32) {
	n := linalg.normalize0(normal)
	u := linalg.cross(n, [3]f32{0, 1, 0})
	if linalg.length(u) < 1e-4 do u = linalg.cross(n, [3]f32{1, 0, 0})
	u = linalg.normalize(u)
	v := linalg.cross(n, u)
	prev := center + u * radius
	for i in 1 ..= segments {
		a := f32(i) / f32(segments) * math.TAU
		p := center + (u * math.cos(a) + v * math.sin(a)) * radius
		line(prev, p, color)
		prev = p
	}
}

// A ring with a dark half-transparent ring one pixel inside it, so it reads
// on any color (the rect tool's pivot).
circle_outlined :: proc(center, normal: [3]f32, radius: f32, color: [4]f32, segments := 32) {
	px := world_per_pixels(center, 1)
	if radius > px do circle(center, normal, radius - px, COLOR_SHADOW, segments)
	circle(center, normal, radius, color, segments)
}

// A filled circle in the plane through `center` with `normal`.
disc :: proc(center, normal: [3]f32, radius: f32, color: [4]f32, segments := 24) {
	n := linalg.normalize0(normal)
	u := linalg.cross(n, [3]f32{0, 1, 0})
	if linalg.length(u) < 1e-4 do u = linalg.cross(n, [3]f32{1, 0, 0})
	u = linalg.normalize(u)
	v := linalg.cross(n, u)
	prev := center + u * radius
	for i in 1 ..= segments {
		a := f32(i) / f32(segments) * math.TAU
		p := center + (u * math.cos(a) + v * math.sin(a)) * radius
		gfx.draw_triangle(center, prev, p, color, depth_test = false)
		prev = p
	}
}

// A filled dot with a dark half-transparent edge one pixel outside it, so it
// reads on any color (the rect tool's corner markers).
dot_outlined :: proc(center, normal: [3]f32, radius: f32, color: [4]f32) {
	px := world_per_pixels(center, 1)
	disc(center, normal, radius + px, COLOR_SHADOW)
	disc(center, normal, radius, color)
}

// A camera-facing filled square, `half` in world units.
square :: proc(center: [3]f32, half: f32, color: [4]f32) {
	r, u := _camera_basis()
	a := center - r * half - u * half
	b := center + r * half - u * half
	c := center + r * half + u * half
	d := center - r * half + u * half
	gfx.draw_triangle(a, b, c, color, depth_test = false)
	gfx.draw_triangle(a, c, d, color, depth_test = false)
}

// A camera-facing square outline, `half` the half side in world units, with
// the one pixel shadow inside (rect_outlined's look, for corner markers).
square_outline :: proc(center: [3]f32, half: f32, color: [4]f32) {
	r, u := _camera_basis()
	c := [4][3]f32{
		center - r * half - u * half,
		center + r * half - u * half,
		center + r * half + u * half,
		center - r * half + u * half,
	}
	rect_outlined(c, color)
}

// A filled triangle facing the camera, apex at `tip` pointing along `dir`
// (in the plane of the screen), `size` in world units.
triangle :: proc(tip, dir: [3]f32, size: f32, color: [4]f32) {
	p, ok := triangle_points(tip, dir, size)
	if !ok do return
	gfx.draw_triangle(p[0], p[1], p[2], color, depth_test = false)
}

// The triangle's edges only, over a dark half-transparent copy shifted one
// pixel right and down, so the outline reads on a white image as well as on
// a dark scene (Unity's anchor handles do the same).
triangle_outline :: proc(tip, dir: [3]f32, size: f32, color: [4]f32) {
	p, ok := triangle_points(tip, dir, size)
	if !ok do return
	r, u := _camera_basis()
	shadow := (r - u) * world_per_pixels(tip, 1) // screen +x, +y (down)
	for i in 0 ..< 3 do line(p[i] + shadow, p[(i + 1) % 3] + shadow, COLOR_SHADOW)
	for i in 0 ..< 3 do line(p[i], p[(i + 1) % 3], color)
}

// The triangle's corners: the tip, then the two base corners `size` behind
// it along -dir. For hit areas that match the drawing.
triangle_points :: proc(tip, dir: [3]f32, size: f32) -> (p: [3][3]f32, ok: bool) {
	d := linalg.normalize0(dir)
	if d == {} do return {}, false
	r, u := _camera_basis()
	// A perpendicular inside the screen plane.
	side := linalg.normalize0(r * linalg.dot(d, u) - u * linalg.dot(d, r))
	if side == {} do side = r
	base := tip - d * size
	return {tip, base + side * size * 0.5, base - side * size * 0.5}, true
}

// --- Handles ------------------------------------------------------------------------

// Shared interaction step. `candidate` says the pointer is over this handle
// this frame at screen distance `dist`; higher `prio` wins over nearer.
_interact :: proc(id: u64, candidate: bool, dist: f32, prio: int, plane_origin, normal: [3]f32) -> Drag {
	d: Drag
	if !_frame.valid || id == 0 do return d

	if _active == id {
		_active_seen = true
		d.hot = true
		if p, ok := ray_plane(_frame.ray, _grab_origin, _grab_normal); ok {
			d.point = p
			d.delta = p - _grab
		} else {
			d.point = _grab
		}
		if im.IsMouseDown(.Left) {
			d.dragging = true
		} else {
			d.released = true
			_active = 0
		}
		return d
	}
	if _active != 0 do return d // another handle owns the drag

	if candidate && _frame.hovered && (prio > _hot_prio || (prio == _hot_prio && dist < _hot_dist)) {
		_hot = id
		_hot_prio = prio
		_hot_dist = dist
	}
	d.hot = _hot_prev == id
	if d.hot && im.IsMouseClicked(.Left) {
		_active = id
		_active_seen = true
		_grab_origin = plane_origin
		_grab_normal = normal
		if p, ok := ray_plane(_frame.ray, plane_origin, normal); ok {
			_grab = p
		} else {
			_grab = plane_origin
		}
		d.point = _grab
		d.started = true
		d.dragging = true
	}
	return d
}

// A draggable point on the plane through `pos` with `normal`, drawn as a
// camera-facing square `size_px` wide. The drag reports offsets in that plane.
dot :: proc(id: u64, pos, normal: [3]f32, size_px: f32 = 7, color := COLOR_HANDLE) -> Drag {
	dist: f32 = math.F32_MAX
	if sp, ok := project(pos); ok do dist = linalg.length(sp - _frame.mouse)
	d := _interact(id, dist <= DOT_HOVER_PX, dist, 1, pos, normal)
	half := world_per_pixels(pos, size_px) * 0.5
	square(pos, half, COLOR_HOT if d.hot else color)
	return d
}

// A draggable point that draws nothing: the caller draws its own marker
// (the rect tool's anchor triangles). Same priority as a dot.
// `prio` above 1 wins over dots and other points at the same spot (the
// rect tool's pivot over a resize spot it sits on).
point :: proc(id: u64, pos, normal: [3]f32, hover_px: f32 = DOT_HOVER_PX, prio := 1) -> Drag {
	dist: f32 = math.F32_MAX
	if sp, ok := project(pos); ok do dist = linalg.length(sp - _frame.mouse)
	return _interact(id, dist <= hover_px, dist, prio, pos, normal)
}

// A draggable line segment that draws nothing: the pointer within `hover_px`
// of the segment on screen takes it (the rect tool's edges). The drag plane
// goes through the segment's middle.
segment :: proc(id: u64, a, b, normal: [3]f32, hover_px: f32 = DOT_HOVER_PX, prio := 1) -> Drag {
	mid := (a + b) * 0.5
	sa, oka := project(a)
	sb, okb := project(b)
	if !oka || !okb do return _interact(id, false, math.F32_MAX, prio, mid, normal)
	ab := sb - sa
	t := f32(0)
	if l2 := linalg.dot(ab, ab); l2 > 0 do t = clamp(linalg.dot(_frame.mouse - sa, ab) / l2, 0, 1)
	dist := linalg.length(_frame.mouse - (sa + ab * t))
	return _interact(id, dist <= hover_px, dist, prio, mid, normal)
}

// A draggable area that draws nothing: the screen box around `pts` (a marker
// the caller draws, the rect tool's anchor triangles) is the hit area, so it
// matches what is seen. The drag plane goes through `plane_pos`.
area :: proc(id: u64, plane_pos, normal: [3]f32, pts: [][3]f32, prio := 1) -> Drag {
	lo := [2]f32{math.F32_MAX, math.F32_MAX}
	hi := [2]f32{-math.F32_MAX, -math.F32_MAX}
	for p in pts {
		sp, ok := project(p)
		if !ok do return _interact(id, false, math.F32_MAX, 1, plane_pos, normal)
		lo = {min(lo.x, sp.x), min(lo.y, sp.y)}
		hi = {max(hi.x, sp.x), max(hi.y, sp.y)}
	}
	m := _frame.mouse
	inside := m.x >= lo.x - 1 && m.x <= hi.x + 1 && m.y >= lo.y - 1 && m.y <= hi.y + 1
	dist := linalg.length(m - (lo + hi) * 0.5)
	return _interact(id, inside, dist, prio, plane_pos, normal)
}

// A dashed line, dashes `dash_px` long on screen.
dashed_line :: proc(a, b: [3]f32, color: [4]f32, dash_px: f32 = 6) {
	length := linalg.length(b - a)
	if length <= 0 do return
	dash := world_per_pixels((a + b) * 0.5, dash_px)
	if dash <= 0 do return
	dir := (b - a) / length
	for t := f32(0); t < length; t += dash * 2 {
		end := min(t + dash, length)
		line(a + dir * t, a + dir * end, color)
	}
}

// An invisible draggable surface: the quad bl, br, tr, tl. Lower priority
// than dots, so dots on its edges win the pointer.
quad :: proc(id: u64, c: [4][3]f32, normal: [3]f32) -> Drag {
	t0, h0 := engine.ray_hit_triangle(_frame.ray, c[0], c[1], c[2])
	t1, h1 := engine.ray_hit_triangle(_frame.ray, c[0], c[2], c[3])
	hit := h0 || h1
	dist := f32(0)
	if hit do dist = min(t0 if h0 else math.F32_MAX, t1 if h1 else math.F32_MAX)
	return _interact(id, hit, dist, 0, c[0], normal)
}

// --- Scene picking providers -----------------------------------------------------------

// A package's clickable shapes for scene-view picking: the nearest hit along
// `ray` as (transform, ray parameter). The editor's pick takes the nearest
// over sprites, meshes and every provider.
Pick_Provider :: proc(view: engine.Render_View, ray: engine.Ray) -> (tH: engine.Transform_Handle, t: f32, ok: bool)

_pick_providers: [dynamic]Pick_Provider

// Process-global registry: never borrows the caller's allocator.
pick_register :: proc(p: Pick_Provider) {
	context.allocator = runtime.default_allocator()
	if _pick_providers == nil do _pick_providers = make([dynamic]Pick_Provider)
	append(&_pick_providers, p)
}

pick_providers :: proc() -> []Pick_Provider {
	return _pick_providers[:]
}
