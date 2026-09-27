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
	target:     ^engine.Gizmo_Batch, // set while a view draws an icon: shapes go here
	shapes:     bool, // off: lines, triangles and labels record nothing (with_shapes)
	icons:      bool, // off: icons record nothing (with_icons)
	group:      ^engine.Gizmo_Group, // with_duration, with_key: shapes outlive the frame here
}

@(private)
_s := _State{
	color      = {1, 1, 1, 1},
	space      = 1,
	depth_test = true,
	channel    = .Game,
	shapes     = true,
	icons      = true,
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
// view. The editor records its @(on_draw_gizmos) procs into .Editor for the
// scene view and into .Editor_Game for the game view, so their code never
// calls this.
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

// Lines, triangles and labels inside the scope record (true, the default) or
// not. Icons are not shapes: with_icons covers them. The editor's gizmo
// settings hide a component type's gizmo this way around its hook.
@(deferred_out = _restore_shapes)
with_shapes :: proc(enabled: bool) -> bool {
	prev := _s.shapes
	_s.shapes = enabled
	return prev
}

@(private)
_restore_shapes :: proc(prev: bool) {
	_s.shapes = prev
}

// Icons inside the scope record (true, the default) or not: the editor's
// gizmo settings hide a component type's icon this way around its hook.
@(deferred_out = _restore_icons)
with_icons :: proc(enabled: bool) -> bool {
	prev := _s.icons
	_s.icons = enabled
	return prev
}

@(private)
_restore_icons :: proc(prev: bool) {
	_s.icons = prev
}

// --- Lifetimes ---------------------------------------------------------------

// Shapes inside the scope stay for `seconds` on `clock`, then go: .Game (the
// simulation, so they pause with Pause and go on Stop) or .Real (wall time,
// for editor tools). A shape normally lives one frame.
@(deferred_out = _restore_group)
with_duration :: proc(seconds: f32, clock := engine.Gizmo_Clock.Game) -> ^engine.Gizmo_Group {
	prev := _s.group
	_s.group = engine.gizmo_buffer_timed_group(_buffer(), seconds, clock)
	return prev
}

// Shapes inside the scope stay until clear_key(key), or until shapes record
// under `key` in a later frame, which replace them: draw a path once and
// keep it, or redraw it only when it changes. `key` is any non-zero id.
@(deferred_out = _restore_group)
with_key :: proc(key: u64) -> ^engine.Gizmo_Group {
	assert(key != 0, "gizmos.with_key: 0 is no key")
	prev := _s.group
	_s.group = engine.gizmo_buffer_key_group(_buffer(), key)
	return prev
}

@(private)
_restore_group :: proc(prev: ^engine.Gizmo_Group) {
	_s.group = prev
}

// Drops the shapes kept under `key`.
clear_key :: proc(key: u64) {
	buf := _buffer()
	for g in buf.groups {
		if g.key == key && _s.group == g do _s.group = nil // cleared inside its own scope
	}
	engine.gizmo_buffer_clear_key(buf, key)
}

// The current context's buffer, synced to the frame.
@(private)
_buffer :: proc() -> ^engine.Gizmo_Buffer {
	uc := engine.ctx_get()
	assert(uc != nil, "gizmos: no user context")
	engine.gizmo_buffer_sync_frame(&uc.gizmos, gfx.frame_index)
	return &uc.gizmos
}

// --- Views --------------------------------------------------------------------

// The view pixel-sized shapes measure against (helper_pixel, helper_project).
// The scene view sets it before its hooks run.
set_view :: proc(view: engine.Render_View) {
	_s.view = view
	_s.has_view = true
}

// `v` is the current view until the end of the enclosing block: a view that
// draws icons for its own camera, then gives the view back.
@(deferred_out = _restore_view)
with_view :: proc(v: engine.Render_View) -> (prev: engine.Render_View, had: bool) {
	prev, had = _s.view, _s.has_view
	set_view(v)
	return
}

@(private)
_restore_view :: proc(prev: engine.Render_View, had: bool) {
	_s.view = prev
	_s.has_view = had
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
// Icons draw after their batch's shapes, facing the current view's camera
// (set_view).
draw :: proc(channels: bit_set[engine.Gizmo_Channel]) {
	uc := engine.ctx_get()
	if uc == nil do return
	engine.gizmo_buffer_sync_frame(&uc.gizmos, gfx.frame_index)
	for depth in ([2]int{1, 0}) {
		for ch in engine.Gizmo_Channel {
			if ch not_in channels do continue
			for lt in ([2]engine.Gizmo_Lifetime{.Fixed_Tick, .Frame}) {
				b := &uc.gizmos.batches[lt][ch][depth]
				_draw_prims(b.prims[:], depth == 1)
				for ic in b.icons do _draw_icon(ic, depth == 1)
			}
			for g in uc.gizmos.groups {
				b := &g.batches[ch][depth]
				_draw_prims(b.prims[:], depth == 1)
				for ic in b.icons do _draw_icon(ic, depth == 1)
			}
		}
	}
}

// The recorded scene icons of `channels`, for picking (temp slice).
icons :: proc(channels: bit_set[engine.Gizmo_Channel]) -> []engine.Gizmo_Icon {
	out := make([dynamic]engine.Gizmo_Icon, context.temp_allocator)
	uc := engine.ctx_get()
	if uc == nil do return out[:]
	engine.gizmo_buffer_sync_frame(&uc.gizmos, gfx.frame_index)
	for ch in engine.Gizmo_Channel {
		if ch not_in channels do continue
		for lt in engine.Gizmo_Lifetime {
			for b in uc.gizmos.batches[lt][ch] do append(&out, ..b.icons[:])
		}
		for g in uc.gizmos.groups {
			for b in g.batches[ch] do append(&out, ..b.icons[:])
		}
	}
	return out[:]
}

@(private)
_draw_prims :: proc(prims: []engine.Gizmo_Prim, depth_test: bool) {
	for p in prims {
		switch p.kind {
		case .Line:
			gfx.draw_line(p.p[0], p.p[1], p.color, depth_test = depth_test)
		case .Triangle:
			gfx.draw_triangle(p.p[0], p.p[1], p.p[2], p.color, depth_test = depth_test)
		case .Face:
			color := p.color
			if !depth_test && _s.has_view {
				shade, visible := helper_face(_s.view, p)
				if !visible do continue
				color = {color.r * shade, color.g * shade, color.b * shade, color.a}
			}
			gfx.draw_triangle(p.p[0], p.p[1], p.p[2], color, depth_test = depth_test)
		}
	}
}

// How a solid's face shows without depth test in view `v`: visible when it
// faces the camera (a back face would paint over the front ones, nothing
// sorts them), and its shade, from 0.55 edge-on to 1 facing the camera.
helper_face :: proc(v: engine.Render_View, p: engine.Gizmo_Prim) -> (shade: f32, visible: bool) {
	n := linalg.cross(p.p[1] - p.p[0], p.p[2] - p.p[0])
	mid := (p.p[0] + p.p[1] + p.p[2]) / 3
	facing := linalg.dot(linalg.normalize0(n), linalg.normalize0(v.cam_pos - mid))
	if facing <= 0 do return 0, false
	return 0.55 + 0.45 * facing, true
}

// Shapes of the icon being drawn. Default allocator: it outlives the frame.
@(private)
_icon_scratch: engine.Gizmo_Batch

// A glyph or texture image fills this much of the icon square (-FILL..FILL).
ICON_IMAGE_FILL :: f32(0.72)

// Turns a glyph of the editor's icon font into its texture: white, coverage
// in alpha. The editor installs one (handles.icon_font_set).
Glyph_Source :: proc(glyph: rune) -> ^gfx.Texture

@(private)
_glyph_source: Glyph_Source

// Installs the glyph source icons draw their glyphs with.
set_glyph_source :: proc(source: Glyph_Source) {
	_glyph_source = source
}

// Draws an icon facing the current view's camera: its shapes record into a
// scratch batch with that view's icon space, and draw at once. A glyph or
// texture image draws as a quad over them.
@(private)
_draw_icon :: proc(ic: engine.Gizmo_Icon, depth_test: bool) {
	assert(_s.has_view, "gizmos.draw: icons need the view (set_view before draw)")
	if _icon_scratch.prims == nil do _icon_scratch.prims = make([dynamic]engine.Gizmo_Prim, 0, 64, runtime.default_allocator())
	space := helper_icon_space(_s.view, ic.pos, ic.px)
	{
		prev := _s
		defer _s = prev
		_s.space = space
		_s.target = &_icon_scratch
		_s.shapes = true
		if ic.backdrop.a > 0 {
			_s.color = ic.backdrop
			solid_circle({}, {0, 0, 1}, 1, segments = 20)
		}
		_s.color = ic.color
		if symbol, ok := ic.image.(engine.Gizmo_Symbol); ok do symbol()
	}
	_draw_prims(_icon_scratch.prims[:], depth_test)
	clear(&_icon_scratch.prims)

	tex: ^gfx.Texture
	switch img in ic.image {
	case engine.Gizmo_Symbol:
	case rune:
		assert(_glyph_source != nil, "gizmos: a glyph icon needs a glyph source (the editor installs one)")
		tex = _glyph_source(img)
	case engine.Asset_GUID:
		// A texture that does not load (a deleted asset) leaves the backdrop.
		if t, ok := engine.texture_load(img); ok do tex = t.gfx
	}
	if tex == nil do return
	f := ICON_IMAGE_FILL
	at :: proc(m: matrix[4, 4]f32, x, y: f32) -> [3]f32 {
		v := m * [4]f32{x, y, 0, 1}
		return v.xyz
	}
	corners := [4][3]f32{at(space, -f, -f), at(space, f, -f), at(space, f, f), at(space, -f, f)}
	gfx.draw_quad(corners, {{0, 1}, {1, 1}, {1, 0}, {0, 0}}, ic.color, tex, depth_test = depth_test)
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
		for g in uc.gizmos.groups {
			for b in g.batches[ch] do append(&out, ..b.labels[:])
		}
	}
	return out[:]
}

// Ends the frame now: its shapes go, timed shapes whose clock has passed go,
// and keys record into a new frame. The buffer does this by itself when a
// new gfx frame starts, so only code that runs no gfx frames needs it (tests).
frame_end :: proc() {
	if uc := engine.ctx_get(); uc != nil do engine.gizmo_buffer_frame_boundary(&uc.gizmos)
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
	if _s.target != nil do return _s.target
	uc := engine.ctx_get()
	assert(uc != nil, "gizmos: no user context")
	engine.gizmo_buffer_sync_frame(&uc.gizmos, gfx.frame_index)
	b: ^_Batch
	if _s.group != nil {
		b = &_s.group.batches[_s.channel][_s.depth_test ? 1 : 0]
	} else {
		lt: engine.Gizmo_Lifetime = engine.fixed_in_tick() ? .Fixed_Tick : .Frame
		b = &uc.gizmos.batches[lt][_s.channel][_s.depth_test ? 1 : 0]
	}
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
	if !_s.shapes do return
	append(&b.prims, engine.Gizmo_Prim{p = {_xf(a), _xf(c), {}}, color = _s.color, kind = .Line})
}

@(private)
_tri :: proc(b: ^_Batch, a, c, d: [3]f32) {
	if !_s.shapes do return
	append(&b.prims, engine.Gizmo_Prim{p = {_xf(a), _xf(c), _xf(d)}, color = _s.color, kind = .Triangle})
}

// A scene icon at `pos` (in the current space): `image` (a symbol, a glyph
// of the editor's icon font, or a texture asset) in a square `size_px`
// pixels wide, over `backdrop` (a disc, alpha 0 for none). `color` tints a
// symbol or glyph and multiplies a texture. Each view draws it facing its own
// camera, so it faces the game camera in the game view too. The scene view
// selects `owner` on a click inside it. For components with nothing else to
// click (lights, cameras, audio sources): handles.icon draws the editor's.
icon :: proc(pos: [3]f32, size_px: f32, owner: engine.Transform_Handle, image: engine.Gizmo_Icon_Image, color: [4]f32, backdrop := [4]f32{}) {
	if !_s.icons do return
	b := _batch()
	if b.icons == nil do b.icons = make([dynamic]engine.Gizmo_Icon, 0, 16, runtime.default_allocator())
	append(&b.icons, engine.Gizmo_Icon{pos = _xf(pos), px = size_px, owner = owner, image = image, color = color, backdrop = backdrop})
}

// The space an icon at world `pos` draws in for view `v`: -1..1 spans a
// square `size_px` pixels wide facing the camera, +X right and +Y up on
// screen.
helper_icon_space :: proc(v: engine.Render_View, pos: [3]f32, size_px: f32) -> matrix[4, 4]f32 {
	half := helper_pixel_in(v, pos, size_px * 0.5)
	m := v.view
	right := [3]f32{m[0, 0], m[0, 1], m[0, 2]} * half
	up := [3]f32{m[1, 0], m[1, 1], m[1, 2]} * half
	back := [3]f32{m[2, 0], m[2, 1], m[2, 2]} * half
	return matrix[4, 4]f32{
		right.x, up.x, back.x, pos.x,
		right.y, up.y, back.y, pos.y,
		right.z, up.z, back.z, pos.z,
		0, 0, 0, 1,
	}
}

// A label at a point. Views that draw text show it (the scene view today):
// always readable, never depth-tested. `offset_px` moves it on screen after
// projecting, e.g. a few pixels below a line.
label :: proc(pos: [3]f32, text: string, align := [2]f32{0, 0}, rotated := false, offset_px := [2]f32{0, 0}) {
	if !_s.shapes do return
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
