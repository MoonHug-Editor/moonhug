package gizmos

// Debug and editor shape drawing (docs/Gizmos.md): one API for @(on_draw_gizmos)
// hooks, handles, the transform gizmo and in-game @(debug_draw) code.
//
// - Calls record world-space shapes into the context's buffer
//   (engine.Gizmo_Buffer), and each view draws the buffer inside its pass. So a
//   call works anywhere (a hook, update, fixed_update, a tool), with no pass
//   open. The matrix applies at call time: a shape stays where it was drawn.
// - State comes from scopes that undo themselves at the end of the enclosing
//   block (@(deferred_out)): with_color, with_matrix, in_local_space,
//   in_world_space, with_depth_test, with_channel. Shape procs take only
//   geometry.
// - A shape lives for one frame: the buffer drops the previous frame's shapes
//   when a new frame starts (gfx.frame_index), so no main loop ends the frame
//   for it. One recorded during a fixed tick lives until the next tick
//   starts, so it does not flicker on frames with no tick.
// - The standalone app draws gameplay shapes from the DebugDraw phase
//   (debug_draw below). Editor views draw the buffer themselves.
// - Naming: line_* for straight strokes, curve_* for curved ones, wire_* and
//   solid_* in pairs for areas and volumes, helper_* for queries.
//
// Single-threaded: record from the main thread.

import "base:runtime"
import "core:strings"
import "core:math/linalg"
import "moonhug:engine"
import gfx "moonhug:engine/gfx"

@(private)
_State :: struct {
	color:      [4]f32,
	space:      matrix[4, 4]f32, // current space (with_matrix, in_local_space)
	depth_test: bool,
	channel:    engine.Gizmo_Channel,
	view:       engine.Render_View,
	has_view:   bool,
}

@(private)
_s := _State{
	color      = {1, 1, 1, 1},
	space      = 1,
	depth_test = true,
	channel    = .Game,
}

// --- Scopes -------------------------------------------------------------------
// Each sets its state until the end of the caller's block, then puts the
// previous value back.

@(deferred_out = _restore_color)
with_color :: proc(color: [4]f32) -> [4]f32 {
	prev := _s.color
	_s.color = color
	return prev
}

@(private)
_restore_color :: proc(prev: [4]f32) {
	_s.color = prev
}

// Composes with the current matrix: nested scopes nest spaces.
@(deferred_out = _restore_matrix)
with_matrix :: proc(m: matrix[4, 4]f32) -> matrix[4, 4]f32 {
	prev := _s.space
	_s.space = prev * m
	return prev
}

// Draws in the transform's own space (its world position, rotation and, with
// `use_scale`, scale). Replaces the current matrix rather than composing with
// it. Colliders pass use_scale=false: their sizes are scaled already.
@(deferred_out = _restore_matrix)
in_local_space :: proc(tH: engine.Transform_Handle, use_scale := true) -> matrix[4, 4]f32 {
	prev := _s.space
	tw := engine.transform_world(tH)
	_s.space = engine.trs_matrix(tw.position, tw.rotation, use_scale ? tw.scale : {1, 1, 1})
	return prev
}

// Draws in world space: replaces the current matrix with identity. Code that
// already converted its points to world space (handles) draws from here.
@(deferred_out = _restore_matrix)
in_world_space :: proc() -> matrix[4, 4]f32 {
	prev := _s.space
	_s.space = 1
	return prev
}

@(private)
_restore_matrix :: proc(prev: matrix[4, 4]f32) {
	_s.space = prev
}

// The current space: local points go to world through it.
helper_matrix :: proc() -> matrix[4, 4]f32 {
	return _s.space
}

// Depth-tested by default. Off draws over everything, as handles do.
@(deferred_out = _restore_depth_test)
with_depth_test :: proc(enabled: bool) -> bool {
	prev := _s.depth_test
	_s.depth_test = enabled
	return prev
}

@(private)
_restore_depth_test :: proc(prev: bool) {
	_s.depth_test = prev
}

// Who the shapes are for: .Game (default) shows in the game view and the scene
// view, .Editor only in the scene view. The editor sets .Editor around its
// gizmo hooks, so hook code never calls this.
@(deferred_out = _restore_channel)
with_channel :: proc(channel: engine.Gizmo_Channel) -> engine.Gizmo_Channel {
	prev := _s.channel
	_s.channel = channel
	return prev
}

@(private)
_restore_channel :: proc(prev: engine.Gizmo_Channel) {
	_s.channel = prev
}

// --- Views --------------------------------------------------------------------

// The view pixel-sized shapes measure against (helper_pixel, helper_project).
// The scene view sets it before its hooks run.
set_view :: proc(view: engine.Render_View) {
	_s.view = view
	_s.has_view = true
}

// World length that spans `px` screen pixels at `pos`, in the current view.
// Exact for perspective and orthographic views alike.
helper_pixel :: proc(pos: [3]f32, px: f32) -> f32 {
	assert(_s.has_view, "gizmos.helper_pixel: no view set (call it from a gizmo hook)")
	return helper_pixel_in(_s.view, pos, px)
}

// helper_pixel for a given view.
helper_pixel_in :: proc(v: engine.Render_View, pos: [3]f32, px: f32) -> f32 {
	sp, ok := helper_project_in(v, pos)
	if !ok do return 0
	n := linalg.normalize0(v.cam_pos - pos)
	if n == {} do n = {0, 0, 1}
	a, aok := _ray_plane(engine.render_view_screen_ray(v, sp.x, sp.y), pos, n)
	b, bok := _ray_plane(engine.render_view_screen_ray(v, sp.x + px, sp.y), pos, n)
	if !aok || !bok do return 0
	return linalg.length(b - a)
}

// World point to pixels of the current view. ok=false behind the camera.
helper_project :: proc(pos: [3]f32) -> (px: [2]f32, ok: bool) {
	assert(_s.has_view, "gizmos.helper_project: no view set (call it from a gizmo hook)")
	return helper_project_in(_s.view, pos)
}

// helper_project for a given view (a view drawing labels).
helper_project_in :: proc(v: engine.Render_View, pos: [3]f32) -> (px: [2]f32, ok: bool) {
	clip := v.view_proj * [4]f32{pos.x, pos.y, pos.z, 1}
	if clip.w <= 1e-6 do return {}, false
	ndc := clip.xy / clip.w
	return {(ndc.x + 1) * 0.5 * v.width, (1 - ndc.y) * 0.5 * v.height}, true
}

@(private)
_ray_plane :: proc(ray: engine.Ray, origin, normal: [3]f32) -> (p: [3]f32, ok: bool) {
	denom := linalg.dot(ray.direction, normal)
	if abs(denom) < 1e-6 do return {}, false
	t := linalg.dot(origin - ray.origin, normal) / denom
	return ray.origin + ray.direction * t, true
}

// --- Drawing and frame end (views, main loops) ----------------------------------

// Draws the recorded shapes of `channels` into the open pass: depth-tested
// ones first, then the ones drawn over everything, each in recorded order.
draw :: proc(channels: bit_set[engine.Gizmo_Channel]) {
	uc := engine.ctx_get()
	if uc == nil do return
	engine.gizmo_buffer_sync_frame(&uc.gizmos, gfx.frame_index)
	for depth in ([2]int{1, 0}) {
		for ch in engine.Gizmo_Channel {
			if ch not_in channels do continue
			for lt in ([2]engine.Gizmo_Lifetime{.Fixed_Tick, .Frame}) {
				for p in uc.gizmos.batches[lt][ch][depth].prims {
					switch p.kind {
					case .Line:     gfx.draw_line(p.p[0], p.p[1], p.color, depth_test = depth == 1)
					case .Triangle: gfx.draw_triangle(p.p[0], p.p[1], p.p[2], p.color, depth_test = depth == 1)
					}
				}
			}
		}
	}
}

// The recorded labels of `channels`, for a view that draws text (temp slice).
labels :: proc(channels: bit_set[engine.Gizmo_Channel]) -> []engine.Gizmo_Label {
	out := make([dynamic]engine.Gizmo_Label, context.temp_allocator)
	uc := engine.ctx_get()
	if uc == nil do return out[:]
	engine.gizmo_buffer_sync_frame(&uc.gizmos, gfx.frame_index)
	for ch in engine.Gizmo_Channel {
		if ch not_in channels do continue
		for lt in engine.Gizmo_Lifetime {
			for b in uc.gizmos.batches[lt][ch] do append(&out, ..b.labels[:])
		}
	}
	return out[:]
}

// Drops the frame-lifetime shapes now. The buffer does this by itself when a
// new frame starts, so only code that runs no gfx frames needs it (tests).
frame_end :: proc() {
	if uc := engine.ctx_get(); uc != nil do engine.gizmo_buffer_clear_lifetime(&uc.gizmos, .Frame)
}

// The standalone app's debug view: after every other DebugDraw subscriber
// recorded its shapes (the physics collider wires), draw them into the camera
// pass the phase runs in.
@(phase={key=DebugDraw, order=1000, mode=App})
debug_draw :: proc() {
	draw({.Game})
}

// --- Recording ------------------------------------------------------------------

@(private)
_Batch :: engine.Gizmo_Batch

// A world-space line with its own color (line_axes).
@(private)
_prim_line :: proc(a, b: [3]f32, color: [4]f32) -> engine.Gizmo_Prim {
	return engine.Gizmo_Prim{p = {a, b, {}}, color = color, kind = .Line}
}

@(private)
_batch :: proc() -> ^_Batch {
	uc := engine.ctx_get()
	assert(uc != nil, "gizmos: no user context")
	engine.gizmo_buffer_sync_frame(&uc.gizmos, gfx.frame_index)
	lt: engine.Gizmo_Lifetime = engine.fixed_in_tick() ? .Fixed_Tick : .Frame
	b := &uc.gizmos.batches[lt][_s.channel][_s.depth_test ? 1 : 0]
	if b.prims == nil do b.prims = make([dynamic]engine.Gizmo_Prim, 0, 256, runtime.default_allocator())
	return b
}

@(private)
_xf :: proc(p: [3]f32) -> [3]f32 {
	v := _s.space * [4]f32{p.x, p.y, p.z, 1}
	return v.xyz
}

// Local-space segment, transformed and recorded.
@(private)
_seg :: proc(b: ^_Batch, a, c: [3]f32) {
	append(&b.prims, engine.Gizmo_Prim{p = {_xf(a), _xf(c), {}}, color = _s.color, kind = .Line})
}

@(private)
_tri :: proc(b: ^_Batch, a, c, d: [3]f32) {
	append(&b.prims, engine.Gizmo_Prim{p = {_xf(a), _xf(c), _xf(d)}, color = _s.color, kind = .Triangle})
}

// A label at a point. Views that draw text show it (the scene view today):
// always readable, never depth-tested. `offset_px` moves it on screen after
// projecting, e.g. a few pixels below a line.
label :: proc(pos: [3]f32, text: string, align := [2]f32{0, 0}, rotated := false, offset_px := [2]f32{0, 0}) {
	b := _batch()
	if b.labels == nil do b.labels = make([dynamic]engine.Gizmo_Label, 0, 16, runtime.default_allocator())
	append(&b.labels, engine.Gizmo_Label{
		pos       = _xf(pos),
		text      = strings.clone(text, runtime.default_allocator()),
		color     = _s.color,
		align     = align,
		rotated   = rotated,
		offset_px = offset_px,
	})
}
