package handles

// Interactive scene-view handles for editor code and package editors
// (docs/Handles.md). Immediate mode, keyed by caller ids like imgui: a handle
// proc draws itself (through engine/gizmos), reports hover, and when the user
// drags it, reports the drag as an offset on a plane. The editor's gizmo pass
// publishes the scene view's frame (view, pointer, keys) before the handle
// hooks run, and the scene view asks `consumes_mouse` before picking or
// box-selecting.
//
// - Positions and normals are in the current gizmos space (in_local_space,
//   with_matrix), as for shapes, and drags report in it too. Lengths (sizes,
//   radii) are world units: world_per_pixels returns them.
// - Every handle snaps its drag while snapping is on, in the current space:
//   plane handles per axis, sliders along their line. Callers never snap.
//   A handle whose values are not distances turns it off with `with_snap`.
// - Undo is the caller's: open an undo session on `started`, close it on
//   `released`, so one drag is one undo step. A drag can end without a
//   release frame when its handle stops calling in (its object was
//   deselected or destroyed): on_drag_lost closes the session then.

import "base:runtime"
import "core:hash"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "moonhug:engine"
import "moonhug:engine/gizmos"

// The scene view's tool: Q W E R T. The editor's gizmo_mode holds it, and
// gizmo and handles hooks read it from their context.
Tool :: enum {
	Picker,    // Q: selection only
	Translate, // W
	Rotate,    // E
	Scale,     // R
	Handles,   // T: the selection's own handles in place of the transform gizmo
}

Gizmo_State :: enum {
	Selected,     // this object is selected
	Active,       // the active object of the selection
	In_Selection, // it or an ancestor is selected
}

// What an @(on_draw_gizmos) or @(on_scene_handles) proc is told about the
// instance it draws (docs/Gizmos.md, docs/Handles.md).
Gizmo_Context :: struct {
	state: bit_set[Gizmo_State],
	tool:  Tool,
}

// Hovered handle color, imgui's Handles yellow (the transform gizmo uses it).
COLOR_HOT :: [4]f32{246.0 / 255, 242.0 / 255, 50.0 / 255, 0.89}
// Handle chrome at rest.
COLOR_HANDLE :: [4]f32{1, 1, 1, 0.9}
COLOR_SHADOW :: [4]f32{0, 0, 0, 0.5} // under white outlines, for light backgrounds

// Pixel radius inside which a dot handle counts as hovered.
DOT_HOVER_PX :: f32(8)

// The pointer priority of a tool's parts (the move, rotate and scale
// handles of the transform tool): below every other handle, so a
// component's own handle takes the click where the two overlap.
PRIO_TOOL :: -10

// The pointer and keys a frame's handles read. The scene view fills it from
// imgui, tests from a script.
Input :: struct {
	mouse:   [2]f32, // viewport pixels, scene image top-left origin
	hovered: bool,   // the scene view has the pointer
	down:    bool,   // the left button is held
	clicked: bool,   // the left button went down this frame
	alt:     bool,
	shift:   bool,
	// While snapping is on (the Snap popup's toggle, flipped by holding Ctrl
	// or Cmd): the move step in world units and the rotate step in radians.
	// Both are 0 while it is off.
	snap:       f32,
	snap_angle: f32,
}

Frame :: struct {
	view:  engine.Render_View,
	input: Input,
	ray:   engine.Ray,
	valid: bool,
}

_frame: Frame

// The hot handle is picked when a frame begins, before any handle runs: every
// handle records its hit shape (Hit) during a frame, and the next frame_begin
// tests those shapes with the new camera and pointer. The nearest
// highest-priority one wins, so the highlight and a click land on the frame
// the pointer arrives, and handle code runs once per frame. The shapes are
// world space: only a handle that moved since the last frame is a frame
// behind. A hot handle that does not call in again this frame (its object was
// deselected) does not count. Active is the handle being dragged. It stays
// active while the mouse is down, and is dropped when its owner stops calling
// in.
_hot:         u64 // this frame's winner, picked in frame_begin
_hot_seen:    bool // the hot handle called in this frame
_active:      u64
_active_seen: bool
_grab:        [3]f32 // plane point at grab, world
_grab_origin: [3]f32 // drag plane origin, world
_grab_normal: [3]f32 // drag plane normal, world
_lost_cb:     Drag_Lost_Proc // runs when the active drag is dropped (on_drag_lost)
_lost_user:   rawptr

// What a caller does when its drag is dropped without a release: close the
// undo session it opened on `started`.
Drag_Lost_Proc :: proc(user: rawptr)

// One handle's state for this frame.
Drag :: struct {
	hot:      bool, // hovered (or being dragged)
	started:  bool, // the mouse went down on it this frame
	dragging: bool, // the mouse is down and it moved with the drag (includes the start frame)
	released: bool, // the mouse came up this frame
	delta:    [3]f32, // offset of the drag plane point from the grab point
	point:    [3]f32, // current drag plane point
}

// The rect tool's raw edit mode (the inspector's [R]): anchor and pivot
// changes leave anchored position and size alone, so the rect moves. Off,
// they keep the rect where it is. Shared by the inspector and the scene
// handles, so it lives here.
rect_raw_edit: bool

// The editor's gizmo pass calls this once per frame for the scene view,
// before the handle hooks. It picks this frame's hot handle from the shapes
// the handles recorded last frame. Nothing needs a render pass open.
frame_begin :: proc(view: engine.Render_View, input: Input) {
	_frame = Frame{
		view  = view,
		input = input,
		ray   = engine.render_view_screen_ray(view, input.mouse.x, input.mouse.y),
		valid = true,
	}
	if _active != 0 && !_active_seen { // its owner went away mid-drag
		_active = 0
		if cb := _lost_cb; cb != nil {
			_lost_cb = nil
			cb(_lost_user)
		}
	}
	_active_seen = false
	// A drag in progress owns the pointer: nothing else is hot.
	_hot = _pick() if _active == 0 else 0
	_hot_seen = false
	clear(&_shapes)
}

// True while a handle is hovered or dragged: the scene view then neither
// picks nor starts a box select.
consumes_mouse :: proc() -> bool {
	return (_hot != 0 && _hot_seen) || _active != 0
}

frame :: proc() -> Frame {
	return _frame
}

// True while a handle is being dragged.
dragging :: proc() -> bool {
	return _active != 0
}

// Ends the drag in progress now, with no release frame: for a caller whose
// drag lost its target (the transform tool on a mode switch mid-drag). The
// caller ends it, so on_drag_lost does not run.
end_drag :: proc() {
	_active = 0
	_lost_cb = nil
}

// `cb` runs once if the drag started this frame is dropped without a release
// frame: its handle stopped calling in because its object was deselected or
// destroyed, or its caller drew another handle instead. Call it in the
// `started` frame, after opening the undo session, and close the session in
// `cb`. A release or end_drag drops it unrun.
on_drag_lost :: proc(cb: Drag_Lost_Proc, user: rawptr = nil) {
	assert(_active != 0, "handles.on_drag_lost: no drag in progress (call it on `started`)")
	_lost_cb = cb
	_lost_user = user
}

// Handles inside the scope snap (true, the default) or not. A handle whose
// values are not distances (the rect tool's anchors and pivot, fractions of
// the parent rect) turns snapping off around itself.
@(deferred_out = _restore_snap)
with_snap :: proc(enabled: bool) -> bool {
	prev := _snap_on
	_snap_on = enabled
	return prev
}

@(private)
_snap_on := true

@(private)
_restore_snap :: proc(prev: bool) {
	_snap_on = prev
}

// `amount` rounded to the move snap step while snapping is on. Handles snap
// their drags by themselves: this is for a custom handle that measures a
// distance of its own.
snap :: proc(amount: f32) -> f32 {
	step := _frame.input.snap
	if !_snap_on || step <= 0 do return amount
	return math.round(amount / step) * step
}

// `radians` rounded to the rotate snap step while snapping is on, for a
// handle that measures an angle.
snap_angle :: proc(radians: f32) -> f32 {
	step := _frame.input.snap_angle
	if !_snap_on || step <= 0 do return radians
	return math.round(radians / step) * step
}

// A handle id from a value (a component's pool handle) and a slot: the same
// inputs give the same id every frame. Never 0, which means no handle. It
// hashes the value's bytes, so pass a value without padding (handles and
// integers qualify).
id_of :: proc(v: $T, slot: u64 = 0) -> u64 {
	v, slot := v, slot
	h := hash.fnv64a(mem.ptr_to_bytes(&v))
	h = hash.fnv64a(mem.ptr_to_bytes(&slot), h)
	return h if h != 0 else 1
}

// --- Space --------------------------------------------------------------------------
// Public procs take points in the current gizmos space, convert them to world
// space, and do their work there inside gizmos.in_world_space, where the
// current space is identity.

@(private)
_Space :: struct {
	m, inv: matrix[4, 4]f32,
}

@(private)
_space :: proc() -> _Space {
	m := gizmos.helper_matrix()
	return {m, linalg.inverse(m)}
}

@(private)
_to_world :: proc(s: _Space, p: [3]f32) -> [3]f32 {
	v := s.m * [4]f32{p.x, p.y, p.z, 1}
	return v.xyz
}

@(private)
_from_world :: proc(s: _Space, p: [3]f32) -> [3]f32 {
	v := s.inv * [4]f32{p.x, p.y, p.z, 1}
	return v.xyz
}

@(private)
_vec_to_world :: proc(s: _Space, d: [3]f32) -> [3]f32 {
	v := s.m * [4]f32{d.x, d.y, d.z, 0}
	return v.xyz
}

@(private)
_vec_from_world :: proc(s: _Space, d: [3]f32) -> [3]f32 {
	v := s.inv * [4]f32{d.x, d.y, d.z, 0}
	return v.xyz
}

// Normals go through the inverse transpose, so they stay normal to their
// surface under non-uniform scale.
@(private)
_normal_to_world :: proc(s: _Space, n: [3]f32) -> [3]f32 {
	v := linalg.transpose(s.inv) * [4]f32{n.x, n.y, n.z, 0}
	return linalg.normalize0(v.xyz)
}

@(private)
_drag_from_world :: proc(s: _Space, d: Drag) -> Drag {
	out := d
	out.point = _from_world(s, d.point)
	out.delta = _vec_from_world(s, d.delta)
	return out
}

// A plane handle's drag in the current space, snapped per axis while
// snapping is on. `normal` is the plane's normal in that space: a plane
// oblique to the axes gets the snapped point pushed back onto it.
@(private)
_finish_plane :: proc(s: _Space, d: Drag, normal: [3]f32) -> Drag {
	out := _drag_from_world(s, d)
	if !d.dragging && !d.released do return out
	if !_snap_on || _frame.input.snap <= 0 do return out
	grab := out.point - out.delta
	delta := [3]f32{snap(out.delta.x), snap(out.delta.y), snap(out.delta.z)}
	if n := linalg.normalize0(normal); n != {} do delta -= n * linalg.dot(delta, n)
	out.delta = delta
	out.point = grab + delta
	return out
}

// --- Geometry -----------------------------------------------------------------------

// Ray against the plane through `origin` with `normal`. ok=false when the
// ray runs parallel to the plane. Plain math: no space applies.
ray_plane :: proc(ray: engine.Ray, origin, normal: [3]f32) -> (p: [3]f32, ok: bool) {
	denom := linalg.dot(ray.direction, normal)
	if abs(denom) < 1e-6 do return {}, false
	t := linalg.dot(origin - ray.origin, normal) / denom
	return ray.origin + ray.direction * t, true
}

// Point -> viewport pixels. ok=false behind the camera.
project :: proc(p: [3]f32) -> (px: [2]f32, ok: bool) {
	return gizmos.helper_project_in(_frame.view, _to_world(_space(), p))
}

// World length that spans `pixels` on screen at `p`.
world_per_pixels :: proc(p: [3]f32, pixels: f32) -> f32 {
	return gizmos.helper_pixel_in(_frame.view, _to_world(_space(), p), pixels)
}

// Camera right and up in world space (rows of the view rotation).
_camera_basis :: proc() -> (right, up: [3]f32) {
	m := _frame.view.view
	return {m[0, 0], m[0, 1], m[0, 2]}, {m[1, 0], m[1, 1], m[1, 2]}
}

// World direction from `p` toward the camera: the camera's back axis for an
// orthographic view, where every point sees the camera the same way.
@(private)
_to_camera :: proc(p: [3]f32) -> [3]f32 {
	v := _frame.view
	if abs(v.proj[3, 3]) > 0.5 do return {v.view[2, 0], v.view[2, 1], v.view[2, 2]}
	return linalg.normalize0(v.cam_pos - p)
}

// --- Drawing: handle chrome ---------------------------------------------------------
// Handle shapes over everything (no depth test), styled to read on any
// background: a dark half-transparent line one pixel off each edge. Plain
// shapes come from engine/gizmos directly.

// A rect outline with the dark line one pixel INSIDE each edge, so the
// outline still marks the exact edge (the rect tool). bl, br, tr, tl or any
// closed order.
rect_outlined :: proc(c: [4][3]f32, color: [4]f32) {
	s := _space()
	w := [4][3]f32{_to_world(s, c[0]), _to_world(s, c[1]), _to_world(s, c[2]), _to_world(s, c[3])}
	gizmos.in_world_space()
	gizmos.with_depth_test(false)
	center := (w[0] + w[1] + w[2] + w[3]) * 0.25
	px := world_per_pixels(center, 1)
	{
		gizmos.with_color(COLOR_SHADOW)
		for i in 0 ..< 4 {
			a, b := w[i], w[(i + 1) % 4]
			inward := linalg.normalize0(center - (a + b) * 0.5) * px
			gizmos.line(a + inward, b + inward)
		}
	}
	gizmos.with_color(color)
	gizmos.wire_quad(w)
}

// A ring with the dark ring one pixel inside it (the rect tool's pivot).
circle_outlined :: proc(center, normal: [3]f32, radius: f32, color: [4]f32, segments := 32) {
	s := _space()
	c, n := _to_world(s, center), _normal_to_world(s, normal)
	gizmos.in_world_space()
	gizmos.with_depth_test(false)
	px := world_per_pixels(c, 1)
	if radius > px {
		gizmos.with_color(COLOR_SHADOW)
		gizmos.wire_circle(c, n, radius - px, segments)
	}
	gizmos.with_color(color)
	gizmos.wire_circle(c, n, radius, segments)
}

// A filled dot with the dark edge one pixel outside it (the rect tool's
// corner markers).
dot_outlined :: proc(center, normal: [3]f32, radius: f32, color: [4]f32) {
	s := _space()
	c, n := _to_world(s, center), _normal_to_world(s, normal)
	gizmos.in_world_space()
	gizmos.with_depth_test(false)
	px := world_per_pixels(c, 1)
	{
		gizmos.with_color(COLOR_SHADOW)
		gizmos.solid_circle(c, n, radius + px, segments = 24)
	}
	gizmos.with_color(color)
	gizmos.solid_circle(c, n, radius, segments = 24)
}

// The four corners of a camera-facing square, `half` in world units. World
// center in, world corners out.
@(private = "file")
_square_corners :: proc(center: [3]f32, half: f32) -> [4][3]f32 {
	r, u := _camera_basis()
	return {center - r * half - u * half, center + r * half - u * half, center + r * half + u * half, center - r * half + u * half}
}

// A camera-facing filled square, `half` in world units.
square :: proc(center: [3]f32, half: f32, color: [4]f32) {
	c := _to_world(_space(), center)
	gizmos.in_world_space()
	gizmos.with_depth_test(false)
	gizmos.with_color(color)
	gizmos.solid_quad(_square_corners(c, half))
}

// A camera-facing square outline, `half` the half side in world units, with
// the one pixel shadow inside (rect_outlined's look, for corner markers).
square_outline :: proc(center: [3]f32, half: f32, color: [4]f32) {
	c := _to_world(_space(), center)
	gizmos.in_world_space()
	rect_outlined(_square_corners(c, half), color)
}

// A filled triangle facing the camera, apex at `tip` pointing along `dir`
// (in the plane of the screen), `size` in world units.
triangle :: proc(tip, dir: [3]f32, size: f32, color: [4]f32) {
	s := _space()
	p, ok := _triangle_points_world(_to_world(s, tip), _vec_to_world(s, dir), size)
	if !ok do return
	gizmos.in_world_space()
	gizmos.with_depth_test(false)
	gizmos.with_color(color)
	gizmos.solid_triangle(p[0], p[1], p[2])
}

// The triangle's edges only, over a dark copy shifted one pixel right and
// down, so the outline reads on a white image as well as on a dark scene.
triangle_outline :: proc(tip, dir: [3]f32, size: f32, color: [4]f32) {
	s := _space()
	wtip := _to_world(s, tip)
	p, ok := _triangle_points_world(wtip, _vec_to_world(s, dir), size)
	if !ok do return
	gizmos.in_world_space()
	gizmos.with_depth_test(false)
	r, u := _camera_basis()
	shadow := (r - u) * world_per_pixels(wtip, 1) // screen +x, +y (down)
	{
		gizmos.with_color(COLOR_SHADOW)
		gizmos.wire_triangle(p[0] + shadow, p[1] + shadow, p[2] + shadow)
	}
	gizmos.with_color(color)
	gizmos.wire_triangle(p[0], p[1], p[2])
}

// The triangle's corners: the tip, then the two base corners `size` behind
// it along -dir. For hit areas that match the drawing.
triangle_points :: proc(tip, dir: [3]f32, size: f32) -> (p: [3][3]f32, ok: bool) {
	s := _space()
	w: [3][3]f32
	w, ok = _triangle_points_world(_to_world(s, tip), _vec_to_world(s, dir), size)
	if !ok do return {}, false
	return {_from_world(s, w[0]), _from_world(s, w[1]), _from_world(s, w[2])}, true
}

@(private = "file")
_triangle_points_world :: proc(tip, dir: [3]f32, size: f32) -> (p: [3][3]f32, ok: bool) {
	d := linalg.normalize0(dir)
	if d == {} do return {}, false
	r, u := _camera_basis()
	// A perpendicular inside the screen plane.
	side := linalg.normalize0(r * linalg.dot(d, u) - u * linalg.dot(d, r))
	if side == {} do side = r
	base := tip - d * size
	return {tip, base + side * size * 0.5, base - side * size * 0.5}, true
}

// --- Hit shapes -----------------------------------------------------------------------
// Where a handle sits, in world space. A handle records one each frame, and
// the next frame_begin tests it with that frame's camera and pointer.

// Within `px` pixels of `pos` on screen.
Hit_Point :: struct {
	pos: [3]f32,
	px:  f32,
}

// Within `px` pixels of the segment a-b on screen.
Hit_Segment :: struct {
	a, b: [3]f32,
	px:   f32,
}

// Within `px` pixels of the circle around `center` in the plane of the unit
// vectors u and v, drawn with `segments` segments.
Hit_Ring :: struct {
	center, u, v: [3]f32,
	radius, px:   f32,
	segments:     int,
}

// Inside the screen box around the first `count` points, one pixel of slack.
// Nearest by distance to the box center.
Hit_Box :: struct {
	pts:   [4][3]f32,
	count: int,
}

// The ray through the pointer hits the quad bl, br, tr, tl. Nearest by ray
// distance.
Hit_Quad :: struct {
	c: [4][3]f32,
}

// The ray hits the plane through `origin` with `normal` inside the square
// spanned by `side` along the unit vectors u and v. Nearest by ray distance.
Hit_Square :: struct {
	origin, normal, u, v: [3]f32,
	side:                 f32,
}

Hit :: union {
	Hit_Point,
	Hit_Segment,
	Hit_Ring,
	Hit_Box,
	Hit_Quad,
	Hit_Square,
}

@(private)
_Shape :: struct {
	id:   u64,
	prio: int,
	hit:  Hit,
}

// This frame's hit shapes, for the next frame's pick. Cross-frame state:
// never borrows the caller's allocator.
@(private)
_shapes: [dynamic]_Shape

// The recorded shape nearest the pointer, highest priority first. 0 when
// the pointer is over none or outside the view.
@(private)
_pick :: proc() -> u64 {
	if !_frame.input.hovered do return 0
	best: u64
	best_prio := min(int)
	best_dist: f32 = math.F32_MAX
	for sh in _shapes {
		hit, dist := _hit_test(sh.hit)
		if !hit do continue
		if sh.prio > best_prio || (sh.prio == best_prio && dist < best_dist) {
			best, best_prio, best_dist = sh.id, sh.prio, dist
		}
	}
	return best
}

// Whether the pointer is over the shape this frame, and how near.
@(private)
_hit_test :: proc(h: Hit) -> (hit: bool, dist: f32) {
	switch s in h {
	case Hit_Point:
		dist = _mouse_dist(s.pos)
		return dist <= s.px, dist
	case Hit_Segment:
		dist = _mouse_dist_segment(s.a, s.b)
		return dist <= s.px, dist
	case Hit_Ring:
		dist = math.F32_MAX
		prev := s.center + s.u * s.radius
		for k in 1 ..= s.segments {
			a := f32(k) * math.TAU / f32(s.segments)
			p := s.center + (s.u * math.cos(a) + s.v * math.sin(a)) * s.radius
			dist = min(dist, _mouse_dist_segment(prev, p))
			prev = p
		}
		return dist <= s.px, dist
	case Hit_Box:
		lo := [2]f32{math.F32_MAX, math.F32_MAX}
		hi := [2]f32{-math.F32_MAX, -math.F32_MAX}
		for i in 0 ..< s.count {
			sp, ok := gizmos.helper_project_in(_frame.view, s.pts[i])
			if !ok do return false, 0
			lo = {min(lo.x, sp.x), min(lo.y, sp.y)}
			hi = {max(hi.x, sp.x), max(hi.y, sp.y)}
		}
		m := _frame.input.mouse
		inside := m.x >= lo.x - 1 && m.x <= hi.x + 1 && m.y >= lo.y - 1 && m.y <= hi.y + 1
		return inside, linalg.length(m - (lo + hi) * 0.5)
	case Hit_Quad:
		t0, h0 := engine.ray_hit_triangle(_frame.ray, s.c[0], s.c[1], s.c[2])
		t1, h1 := engine.ray_hit_triangle(_frame.ray, s.c[0], s.c[2], s.c[3])
		if !h0 && !h1 do return false, 0
		return true, min(t0 if h0 else math.F32_MAX, t1 if h1 else math.F32_MAX)
	case Hit_Square:
		p, t, ok := _ray_plane_ahead(_frame.ray, s.origin, s.normal)
		if !ok do return false, 0
		su, sv := linalg.dot(p - s.origin, s.u), linalg.dot(p - s.origin, s.v)
		return su >= 0 && su <= s.side && sv >= 0 && sv <= s.side, t
	}
	return false, 0
}

// Ray against a plane, in front of the ray only: the hit and its ray
// parameter.
@(private)
_ray_plane_ahead :: proc(ray: engine.Ray, origin, n: [3]f32) -> (hit: [3]f32, t: f32, ok: bool) {
	denom := linalg.dot(ray.direction, n)
	if abs(denom) < 1e-6 do return {}, 0, false
	t = linalg.dot(origin - ray.origin, n) / denom
	if t < 0 do return {}, 0, false
	return ray.origin + ray.direction * t, t, true
}

// Screen distance from the pointer to a world point.
@(private)
_mouse_dist :: proc(wpos: [3]f32) -> f32 {
	if sp, ok := gizmos.helper_project_in(_frame.view, wpos); ok do return linalg.length(sp - _frame.input.mouse)
	return math.F32_MAX
}

// Screen distance from the pointer to a world segment. F32_MAX when an end
// is behind the camera.
@(private)
_mouse_dist_segment :: proc(wa, wb: [3]f32) -> f32 {
	sa, oka := gizmos.helper_project_in(_frame.view, wa)
	sb, okb := gizmos.helper_project_in(_frame.view, wb)
	if !oka || !okb do return math.F32_MAX
	ab := sb - sa
	t := f32(0)
	if l2 := linalg.dot(ab, ab); l2 > 0 do t = clamp(linalg.dot(_frame.input.mouse - sa, ab) / l2, 0, 1)
	return linalg.length(_frame.input.mouse - (sa + ab * t))
}

// --- Handles ------------------------------------------------------------------------

// Shared interaction step, in world space: records `hit` (world space) for
// the next frame's pick, then reports this frame's state from the hot handle
// frame_begin picked. Higher `prio` wins over nearer. A nil `hit` never gets
// hot (a slider pointing at the camera).
_interact :: proc(id: u64, hit: Hit, prio: int, plane_origin, normal: [3]f32) -> Drag {
	d: Drag
	if !_frame.valid || id == 0 do return d
	if hit != nil {
		if _shapes == nil do _shapes = make([dynamic]_Shape, 0, 64, runtime.default_allocator())
		append(&_shapes, _Shape{id = id, prio = prio, hit = hit})
	}

	if _active == id {
		_active_seen = true
		d.hot = true
		if p, ok := ray_plane(_frame.ray, _grab_origin, _grab_normal); ok {
			d.point = p
			d.delta = p - _grab
		} else {
			d.point = _grab
		}
		if _frame.input.down {
			d.dragging = true
		} else {
			d.released = true
			_active = 0
			_lost_cb = nil
		}
		return d
	}
	if _active != 0 do return d // another handle owns the drag

	d.hot = _hot == id
	if d.hot do _hot_seen = true
	if d.hot && _frame.input.clicked {
		_active = id
		_active_seen = true
		_lost_cb = nil
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

// One Drag for a composite handle (the bounds dots, the transform handles):
// the flags of every part, and the dragged part's delta and point.
@(private)
_merge_drag :: proc(out: ^Drag, d: Drag) {
	out.hot = out.hot || d.hot
	out.started = out.started || d.started
	out.released = out.released || d.released
	if d.dragging || d.released {
		out.dragging = out.dragging || d.dragging
		out.delta = d.delta
		out.point = d.point
	}
}

// A draggable point on the plane through `pos` with `normal`, drawn as a
// camera-facing square `size_px` wide. The drag reports offsets in that plane.
dot :: proc(id: u64, pos, normal: [3]f32, size_px: f32 = 7, color := COLOR_HANDLE) -> Drag {
	s := _space()
	wpos := _to_world(s, pos)
	d := _interact(id, Hit_Point{wpos, DOT_HOVER_PX}, 1, wpos, _normal_to_world(s, normal))
	gizmos.in_world_space()
	square(wpos, world_per_pixels(wpos, size_px) * 0.5, COLOR_HOT if d.hot else color)
	return _finish_plane(s, d, normal)
}

// A dot that moves along `dir` only. `delta` and `point` stay on the line
// through `pos`, and while snapping is on the distance moved snaps to the
// step, in the current space's units. The signed distance moved is
// linalg.dot(d.delta, linalg.normalize(dir)). `prio` as for point.
slider :: proc(id: u64, pos, dir: [3]f32, size_px: f32 = 7, color := COLOR_HANDLE, prio := 1) -> Drag {
	s := _space()
	wpos := _to_world(s, pos)
	ldir := linalg.normalize0(dir)
	wline := _vec_to_world(s, ldir)
	wdir := linalg.normalize0(wline)
	// The drag plane holds the line and turns to the camera as far as it can.
	// A line pointing at the camera has none: it cannot be grabbed.
	normal := linalg.normalize0(linalg.cross(wdir, linalg.cross(_to_camera(wpos), wdir)))
	hit: Hit
	if normal != {} do hit = Hit_Point{wpos, DOT_HOVER_PX}
	d := _interact(id, hit, prio, wpos, normal)
	{
		gizmos.in_world_space()
		square(wpos, world_per_pixels(wpos, size_px) * 0.5, COLOR_HOT if d.hot else color)
	}
	if !d.dragging && !d.released do return _drag_from_world(s, d)
	// Distance along the line in world units, then in the space's units.
	amount: f32
	if l := linalg.length(wline); l > 0 do amount = snap(linalg.dot(d.delta, wdir) / l)
	out := _drag_from_world(s, d)
	grab := out.point - out.delta
	out.delta = ldir * amount
	out.point = grab + out.delta
	return out
}

// A draggable point that draws nothing: the caller draws its own marker
// (the rect tool's anchor triangles). Same priority as a dot.
// `prio` above 1 wins over dots and other points at the same spot (the
// rect tool's pivot over a resize spot it sits on).
point :: proc(id: u64, pos, normal: [3]f32, hover_px: f32 = DOT_HOVER_PX, prio := 1) -> Drag {
	s := _space()
	wpos := _to_world(s, pos)
	return _finish_plane(s, _interact(id, Hit_Point{wpos, hover_px}, prio, wpos, _normal_to_world(s, normal)), normal)
}

// A draggable line segment that draws nothing: the pointer within `hover_px`
// of the segment on screen takes it (the rect tool's edges). The drag plane
// goes through the segment's middle.
segment :: proc(id: u64, a, b, normal: [3]f32, hover_px: f32 = DOT_HOVER_PX, prio := 1) -> Drag {
	s := _space()
	wa, wb := _to_world(s, a), _to_world(s, b)
	return _finish_plane(s, _interact(id, Hit_Segment{wa, wb, hover_px}, prio, (wa + wb) * 0.5, _normal_to_world(s, normal)), normal)
}

// A draggable area that draws nothing: the screen box around `pts` (up to
// four, a marker the caller draws, the rect tool's anchor triangles) is the
// hit area, so it matches what is seen. The drag plane goes through
// `plane_pos`.
area :: proc(id: u64, plane_pos, normal: [3]f32, pts: [][3]f32, prio := 1) -> Drag {
	assert(len(pts) <= 4, "handles.area: at most 4 points")
	s := _space()
	box := Hit_Box{count = len(pts)}
	for p, i in pts do box.pts[i] = _to_world(s, p)
	wpos := _to_world(s, plane_pos)
	return _finish_plane(s, _interact(id, box, prio, wpos, _normal_to_world(s, normal)), normal)
}

// An invisible draggable surface: the quad bl, br, tr, tl. Lower priority
// than dots, so dots on its edges win the pointer.
quad :: proc(id: u64, c: [4][3]f32, normal: [3]f32) -> Drag {
	s := _space()
	w := [4][3]f32{_to_world(s, c[0]), _to_world(s, c[1]), _to_world(s, c[2]), _to_world(s, c[3])}
	return _finish_plane(s, _interact(id, Hit_Quad{w}, 0, w[0], _normal_to_world(s, normal)), normal)
}

// --- Scene picking providers -----------------------------------------------------------

// A package's selectable shapes that are neither renderers nor UI graphics
// (the scene view picks those itself). Both procs are required, so a shape
// that takes a click also takes a box select.
Pick_Provider :: struct {
	// The nearest hit along `ray`: (transform, ray parameter). The editor's
	// pick takes the nearest over icons, renderers, UI and every provider.
	click: proc(view: engine.Render_View, ray: engine.Ray) -> (tH: engine.Transform_Handle, t: f32, ok: bool),
	// Every transform whose shape meets the viewport-pixel rect rmin..rmax,
	// appended to `out`. Duplicates are fine.
	band:  proc(view: engine.Render_View, rmin, rmax: [2]f32, out: ^[dynamic]engine.Transform_Handle),
}

_pick_providers: [dynamic]Pick_Provider

// Process-global registry: never borrows the caller's allocator.
pick_register :: proc(p: Pick_Provider) {
	assert(p.click != nil && p.band != nil, "handles.pick_register: a provider needs both click and band")
	context.allocator = runtime.default_allocator()
	if _pick_providers == nil do _pick_providers = make([dynamic]Pick_Provider)
	append(&_pick_providers, p)
}

pick_providers :: proc() -> []Pick_Provider {
	return _pick_providers[:]
}
