package engine

// Screen-space reflections (plugins/engine/docs/RenderPipeline.md
// "Screen-space reflections"): scene_ssr, placed before scene_opaque, finds
// for each pixel of the opaque surfaces where its mirror ray lands in the
// view's depth, and takes the colour there from last frame's opaque image
// (the scene_copy step's target, read from the pool), into the "ssr" target:
// premultiplied, rgb the colour times the confidence, alpha the confidence,
// with mip levels. A step that reads `ssr?` (scene_opaque) gets it for its
// lit draws (gfx.set_screen_reflections, bound by scene_target_begin), which
// put it in place of the environment's reflection by its confidence, read
// blurrier the rougher the surface. The normals come from a pass of the
// opaque meshes the step draws itself through their own materials, with
// their normal maps, as a normals pass (gfx.pass_output_normals), which
// also writes their depth, so scene_opaque keeps it like after a depth
// prepass.

import "base:runtime"
import "core:math/linalg"
import gfx "moonhug:libs/gfx"
import "moonhug:libs/log"

SSR_STEP :: "scene_ssr"

// The reflections, the opaque surfaces' world-space normals, and the trace
// before its mip levels.
SSR_TARGET         :: "ssr"
SSR_NORMALS_TARGET :: "ssr_normals"
SSR_TRACE_TARGET   :: "ssr_trace"

Ssr_Settings :: struct {
	// How far a reflected ray travels before it gives up, in world units.
	max_distance: f32 `decor:range(1, 100)`,
	// How far behind the depth's surface a ray still counts as hitting it,
	// in world units: thinner misses more, thicker reflects through thin
	// objects.
	thickness:    f32 `decor:range(0.01, 2)`,
	// Samples along each ray: more find thinner objects and cost more.
	steps:        int `decor:range(8, 128)`,
	// The fraction of the screen's width and height over which a reflection
	// fades out toward the edge, where the ray leaves what is on screen.
	edge_fade:    f32 `decor:range(0, 0.5)`,
}

ssr_defaults := Ssr_Settings{max_distance = 20, thickness = 0.3, steps = 48, edge_fade = 0.1}

@(render_step={summary="screen-space reflections from the view's depth, its normals and last frame's opaque image, replacing the environment's reflection in the lit draws after it", reads="scene", writes="hdr:HDR* ssr_normals:HDR ssr_trace:HDR ssr:HDR", settings="ssr_defaults"})
scene_ssr :: proc(ctx: ^Render_Ctx) {
	if ctx.view.mode != .Shaded do return
	settings := (^Ssr_Settings)(ctx.settings)
	hdr := render_target(ctx, HDR_TARGET)
	w, h := hdr.width, hdr.height

	// The opaque surfaces' normals, and their depth, through the view's
	// camera (with this run's jitter) and their own materials, as
	// scene_opaque will draw them.
	normals := render_target(ctx, SSR_NORMALS_TARGET)
	gfx.pass_begin_target(normals, [4]f32{0, 0, 0, 0}, keep_depth = ctx.depth_primed, shared_depth = hdr)
	gfx.pass_output_normals()
	view := render_draw_view(ctx)
	render_execute(view, ctx.commands, {.Opaque})
	gfx.pass_end()
	ctx.depth_primed = true
	_inspect_depth_view(HDR_TARGET)

	// Last frame's opaque image: the scene_copy target as the pool kept it.
	// It is this view's only when the view drew last frame at this size.
	state := _ssr_state(ctx)
	defer {
		state.prev_view_proj = ctx.view.view_proj
		state.frame = gfx.frame_index + 1
		state.size = {w, h}
	}
	consecutive := state.frame == gfx.frame_index && state.size == {w, h}
	prev := gfx.pool_find(ctx.pool, SCENE_COLOR_TARGET)
	if prev == nil && consecutive && !state.warned {
		log.warningf("[Render] scene_ssr reflects last frame's opaque image, which a scene_copy step in the lane keeps: without one nothing reflects")
		state.warned = true
	}
	valid := consecutive && prev != nil && prev.width == w && prev.height == h

	params := new(gfx.Ssr_Params, context.temp_allocator)
	params^ = {
		proj      = view.proj,
		inv_proj  = linalg.inverse(view.proj),
		view      = view.view,
		reproject = state.prev_view_proj * linalg.inverse(view.view),
		params    = {max(settings.max_distance, 0.1), max(settings.thickness, 0.001), f32(clamp(settings.steps, 1, 256)), clamp(settings.edge_fade, 0, 0.5)},
		params2   = {valid ? 1 : 0, 0, 0, 0},
	}
	trace := render_target(ctx, SSR_TRACE_TARGET)
	depth := gfx.rt_depth_texture(hdr)
	normals_tex := gfx.rt_color_texture(normals)
	prev_tex := valid ? gfx.rt_color_texture(prev) : normals_tex // unread when not valid
	gfx.pass_begin_target(trace, nil)
	gfx.draw_fullscreen(gfx.SSR_SHADER, {&depth, &normals_tex, &prev_tex}, (^[size_of(gfx.Ssr_Params)]u8)(params)[:])
	gfx.pass_end()
	// With mip levels: a lit draw reads a blurrier one the rougher its surface.
	gfx.rt_copy(render_target(ctx, SSR_TARGET, mips = true), trace)
}

@(private = "file")
_Ssr_Key :: struct {
	pool:   ^gfx.Target_Pool,
	camera: Transform_Handle,
}

@(private = "file")
_Ssr_View :: struct {
	frame:          u64, // gfx.frame_index + 1 when it last ran
	size:           [2]i32,
	prev_view_proj: matrix[4, 4]f32, // last frame's steady camera
	warned:         bool,
}

@(private = "file")
_ssr_views: map[_Ssr_Key]_Ssr_View

@(private = "file")
_ssr_state :: proc(ctx: ^Render_Ctx) -> ^_Ssr_View {
	context.allocator = runtime.default_allocator() // cross-frame state
	key := _Ssr_Key{ctx.pool, ctx.view.camera}
	if s, ok := &_ssr_views[key]; ok do return s
	_ssr_views[key] = {}
	return &_ssr_views[key]
}

// Forgets every view's state (engine shutdown).
_render_ssr_shutdown :: proc() {
	delete(_ssr_views)
	_ssr_views = nil
}
