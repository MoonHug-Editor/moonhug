package engine

// Temporal anti-aliasing (plugins/engine/docs/RenderPipeline.md "Temporal
// anti-aliasing"): when a lane holds scene_taa and the view shades normally,
// render_pipeline_run offsets the camera by a fraction of a pixel, a different
// offset each frame (8 points of the Halton 2, 3 sequence), and the scene
// steps draw through that jittered camera (render_draw_view). scene_taa
// then blends the frame into the view's history (gfx TAA_SHADER) and writes
// the result back into "hdr", in place, so the steps after it (the host's
// gizmos, the post chain) see an anti-aliased scene and draw with the steady
// camera again.
//
// The history is reprojected through the camera's motion, from depth, and
// through each moved object's own motion where motion_vectors drew it: the
// meshes whose model changed since the view's last frame, drawn again into
// "motion" against the scene's depth. A frame where nothing moved draws no
// motion vectors at all.
//
// Each view (target pool and camera) keeps its own history, two targets used
// in turn, last frame's camera and the models of the meshes it drew. A view
// that skipped a frame, changed size or has no history yet starts over from
// its current frame.

import "core:fmt"
import "core:math/linalg"
import "base:runtime"
import gfx "moonhug:libs/gfx"

TAA_STEP :: "scene_taa"
MOTION_STEP :: "motion_vectors"

// The motion vectors' target (motion_vectors, scene_taa).
MOTION_TARGET :: "motion"

// Jitter points per cycle: the first 8 of Halton 2, 3.
TAA_JITTER_COUNT :: 8

Taa_Settings :: struct {
	// How much of each frame goes into the result: lower is smoother and
	// steadier, higher follows motion with less ghosting.
	blend: f32 `decor:range(0.02, 0.5)`,
}

taa_defaults := Taa_Settings{blend = 0.1}

@(render_step={summary="temporal anti-aliasing: each frame's sub-pixel offset blended into the view's history, back into the scene image", reads="hdr motion", writes="hdr:HDR", settings="taa_defaults"})
scene_taa :: proc(ctx: ^Render_Ctx) {
	// The steps after this one draw with the steady camera.
	defer ctx.jitter = {}
	if ctx.jitter == {} do return
	settings := (^Taa_Settings)(ctx.settings)

	hdr := render_target(ctx, HDR_TARGET)
	state := _taa_state(ctx)
	w, h := hdr.width, hdr.height
	// Two targets in turn: last frame's result is this frame's history.
	write := gfx.pool_target(ctx.pool, _taa_history_name(ctx, state.parity), w, h, .HDR)
	read := gfx.pool_target(ctx.pool, _taa_history_name(ctx, 1 - state.parity), w, h, .HDR)
	valid := state.frame == gfx.frame_index && state.size == {w, h}

	// Pixel centres through the steady cameras: the history holds the steady
	// image, so a still camera reprojects each pixel onto itself.
	params := new(gfx.Taa_Params, context.temp_allocator)
	params.reproject = state.prev_view_proj * linalg.inverse(ctx.view.view_proj)
	// No motion vectors this frame (nothing moved, or no motion_vectors step):
	// the image binds in their place, unread.
	motion_rt := render_input(ctx, MOTION_TARGET)
	params.params = {clamp(settings.blend, 0.02, 1), valid ? 1 : 0, motion_rt != nil ? 1 : 0, 0}

	current := gfx.rt_color_texture(hdr)
	history := gfx.rt_color_texture(read)
	depth := gfx.rt_depth_texture(hdr)
	motion := motion_rt != nil ? gfx.rt_color_texture(motion_rt) : current
	gfx.pass_begin_target(write, nil)
	gfx.draw_fullscreen(gfx.TAA_SHADER, {&current, &history, &depth, &motion}, (^[size_of(gfx.Taa_Params)]u8)(params)[:])
	gfx.pass_end()
	gfx.rt_copy(hdr, write)

	state.prev_view_proj = ctx.view.view_proj
	state.frame = gfx.frame_index + 1
	state.size = {w, h}
	state.parity = 1 - state.parity
}

@(render_step={summary="motion vectors: how far each pixel of a mesh that moved since the view's last frame moved on screen, for scene_taa", reads="scene hdr", writes="motion:HDR"})
motion_vectors :: proc(ctx: ^Render_Ctx) {
	// Only temporal anti-aliasing reads them.
	if ctx.jitter == {} do return
	hdr := render_input(ctx, HDR_TARGET)
	if hdr == nil do return
	state := _taa_state(ctx)
	// Last frame's models count only when the view drew last frame.
	consecutive := state.frame == gfx.frame_index

	// This frame's models, the next frame's previous ones.
	if state.models == nil do state.models = make(map[Transform_Handle]matrix[4, 4]f32, runtime.default_allocator())
	if state.models_next == nil do state.models_next = make(map[Transform_Handle]matrix[4, 4]f32, runtime.default_allocator())
	clear(&state.models_next)
	Moved :: struct {
		cmd:  ^Render_Command,
		prev: matrix[4, 4]f32,
	}
	moved := make([dynamic]Moved, 0, 16, context.temp_allocator)
	for &cmd in ctx.commands {
		d, is_mesh := cmd.variant.(Draw_Mesh)
		if !is_mesh do continue
		state.models_next[cmd.owner] = d.model
		if !consecutive do continue
		if prev, seen := state.models[cmd.owner]; seen && prev != d.model do append(&moved, Moved{&cmd, prev})
	}
	state.models, state.models_next = state.models_next, state.models
	if len(moved) == 0 do return

	// Against the scene's depth: a moved mesh behind something nearer writes
	// nothing there. Drawn as the scene was, through the jittered camera, so
	// its depth matches the scene's exactly. Both faces: a back face lies
	// behind its front face and fails the depth test.
	motion := render_target(ctx, MOTION_TARGET)
	gfx.pass_begin_target(motion, [4]f32{0, 0, 0, 0}, shared_depth = hdr)
	view := render_draw_view(ctx)
	gfx.set_view_proj(view.view_proj, view.cam_pos)
	for m in moved {
		d := m.cmd.variant.(Draw_Mesh)
		mesh, ok := mesh_load(d.mesh, d.part)
		if !ok do continue
		gpu := d.skinned != nil ? d.skinned^ : mesh.gpu
		params := new(gfx.Motion_Params, context.temp_allocator)
		params^ = {to_prev = m.prev * linalg.inverse(d.model), view_proj = ctx.view.view_proj, prev_view_proj = state.prev_view_proj}
		gfx.draw_mesh(gpu, nil, d.model, {1, 1, 1, 1}, gfx.MOTION_SHADER, material = (^[size_of(gfx.Motion_Params)]u8)(params)[:])
	}
	gfx.pass_end()
}

// This run's camera offset for a view whose lane holds scene_taa: a Halton
// 2, 3 point inside the pixel, in clip space (render_pipeline_run).
taa_jitter :: proc(ctx: ^Render_Ctx) -> [2]f32 {
	state := _taa_state(ctx)
	state.index = state.index % TAA_JITTER_COUNT + 1
	offset := [2]f32{_halton(state.index, 2), _halton(state.index, 3)} - 0.5
	return {offset.x * 2 / max(ctx.view.width, 1), offset.y * 2 / max(ctx.view.height, 1)}
}

// The view the scene steps draw through: the camera with this run's
// sub-pixel offset (taa_jitter), the steady camera when there is none.
render_draw_view :: proc(ctx: ^Render_Ctx) -> Render_View {
	v := ctx.view
	if ctx.jitter == {} do return v
	for c in 0 ..< 4 {
		v.proj[0, c] += ctx.jitter.x * v.proj[3, c]
		v.proj[1, c] += ctx.jitter.y * v.proj[3, c]
	}
	v.view_proj = v.proj * v.view
	v.inv_view_proj = linalg.inverse(v.view_proj)
	return v
}

@(private = "file")
_Taa_Key :: struct {
	pool:   ^gfx.Target_Pool,
	camera: Transform_Handle,
}

@(private = "file")
_Taa_View :: struct {
	index:          int,             // the jitter point last used, 1 ..= TAA_JITTER_COUNT
	parity:         int,             // which history target this frame writes
	frame:          u64,             // gfx.frame_index + 1 when it last resolved
	size:           [2]i32,
	prev_view_proj: matrix[4, 4]f32, // last frame's steady camera
	// The models of the meshes the view drew last frame, by owner, and the
	// map this frame's go into (motion_vectors swaps them).
	models:         map[Transform_Handle]matrix[4, 4]f32,
	models_next:    map[Transform_Handle]matrix[4, 4]f32,
}

@(private = "file")
_taa_views: map[_Taa_Key]_Taa_View

@(private = "file")
_taa_state :: proc(ctx: ^Render_Ctx) -> ^_Taa_View {
	context.allocator = runtime.default_allocator() // cross-frame state
	key := _Taa_Key{ctx.pool, ctx.view.camera}
	if s, ok := &_taa_views[key]; ok do return s
	_taa_views[key] = {}
	return &_taa_views[key]
}

@(private = "file")
_taa_history_name :: proc(ctx: ^Render_Ctx, parity: int) -> string {
	return fmt.tprintf("taa_history_%d_%d", ctx.view.camera.index, parity)
}

// The radical inverse of `i` in `base`: the i-th point of a Halton sequence.
@(private = "file")
_halton :: proc(i, base: int) -> f32 {
	f, r := f32(1), f32(0)
	for n := i; n > 0; n /= base {
		f /= f32(base)
		r += f * f32(n % base)
	}
	return r
}

// Forgets every view's history (engine shutdown).
_render_taa_shutdown :: proc() {
	for _, &v in _taa_views {
		delete(v.models)
		delete(v.models_next)
	}
	delete(_taa_views)
	_taa_views = nil
}
