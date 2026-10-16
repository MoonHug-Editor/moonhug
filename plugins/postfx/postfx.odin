package postfx

// Post effects as render steps (plugins/engine/docs/RenderPipeline.md):
// auto exposure, bloom, a tonemap operator with colour grading
// (grading.odin) and FXAA, placed in a pipeline between the engine's scene
// steps and its final blit. Each step renders a new image
// from the finished one so far (reads="final") and declares its own as the
// new final (`post:LDR*`), so the engine's final_blit copies whichever step
// ran last. Each placed step carries its own settings in the pipeline asset.
// Removing this plugin leaves the engine's own steps untouched, a pipeline
// that placed these warns once and skips them.
//
// The shaders are .glsl assets under assets/resources (so an export ships
// them), compiled by the shader importer and registered as fullscreen
// shaders (engine.shader_load_fullscreen).

import "base:runtime"
import "core:encoding/uuid"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "moonhug:libs/log"
import gfx "moonhug:libs/gfx"
import "moonhug:packages/engine"

Tonemap_Operator :: enum u8 {
	None,     // clamp, the engine's look without post effects
	Reinhard,
	ACES,
	ACES_Hill, // the Khronos glTF Sample Viewer's curve (Stephen Hill's fit)
}

Bloom_Settings :: struct {
	threshold: f32 `decor:min(0)`, // scene color above this blooms
	strength:  f32 `decor:min(0)`, // how much of it the tonemap adds back (baked into the bloom image)
	// The brightest a scene pixel counts for: lower it to keep stray bright
	// pixels from flaring. The default is half-float range.
	clamp:     f32 `decor:min(0)`,
}

bloom_defaults := Bloom_Settings{threshold = 1, strength = 0.3, clamp = 65472}

Tonemap_Settings :: struct {
	operator: Tonemap_Operator,
	// Multiplies the scene, after the auto exposure when one ran.
	exposure: f32 `decor:min(0)`,
	grading:  Color_Grading,
}

tonemap_defaults := Tonemap_Settings{operator = .ACES, exposure = 1, grading = COLOR_GRADING_DEFAULT}

// How the auto exposure weighs the image when it meters the brightness.
Exposure_Metering :: enum u8 {
	Center_Weighted, // the middle of the image counts most, a tenth at the corners: what the camera looks at is exposed well
	Average,         // every part alike
}

Exposure_Settings :: struct {
	metering:     Exposure_Metering,
	// The average scene luminance the exposure brings the scene to: 0.6
	// leaves a sunlit scene as it looks without auto exposure, and lifts a
	// darker one to that brightness.
	target:       f32 `decor:min(0.01)`,
	// The range of average scene brightness metered, in stops (log2 of the
	// average luminance): a scene darker or brighter than this is exposed as
	// if it were at the end of the range, so a black frame or the sun cannot
	// swing the exposure without bound.
	min_ev:       f32,
	max_ev:       f32,
	// Brighter (+) or darker (-) than the metered exposure, in stops.
	compensation: f32,
	// How fast the exposure follows, per second: toward a brighter scene,
	// and toward a darker one (an eye adapts to light faster than to dark).
	speed_dark_to_light: f32 `decor:min(0)`,
	speed_light_to_dark: f32 `decor:min(0)`,
	// Meter from a histogram of the brightness: the darkest `histogram_low`
	// percent of the image and the brightest above `histogram_high` percent
	// are left out of the average, so a black border or the sun does not
	// pull the exposure. Off, every pixel counts.
	histogram:      bool,
	histogram_low:  f32 `decor:range(0, 100)`,
	histogram_high: f32 `decor:range(0, 100)`,
}

exposure_defaults := Exposure_Settings{target = 0.6, min_ev = -4, max_ev = 8, compensation = 0, speed_dark_to_light = 3, speed_light_to_dark = 1, histogram = true, histogram_low = 40, histogram_high = 95}

// The histogram's bins cover this range of log2 luminance, 256 bins over 24
// stops: a tenth of a stop each.
@(private = "file") EXPOSURE_HISTOGRAM_MIN :: -8.0
@(private = "file") EXPOSURE_HISTOGRAM_MAX :: 16.0

// The shader assets, by the guid in their .meta files.
@(private = "file") BLOOM_BRIGHT_GUID := uuid.read("caa45a1a-ee91-410b-951c-60afa81d716f") or_else uuid.Identifier{}
@(private = "file") BLOOM_BLUR_GUID   := uuid.read("e241f892-9582-4ba3-a3df-8404558e446c") or_else uuid.Identifier{}
@(private = "file") TONEMAP_GUID      := uuid.read("ad09953d-bd1e-4958-ad8a-2ad37eae2edb") or_else uuid.Identifier{}
@(private = "file") FXAA_GUID         := uuid.read("774894e7-d7e7-469b-9626-2c38b04cffb9") or_else uuid.Identifier{}
@(private = "file") EXPOSURE_LUM_GUID    := uuid.read("d549108d-4d60-46b2-8c15-116703cefc10") or_else uuid.Identifier{}
@(private = "file") EXPOSURE_REDUCE_GUID := uuid.read("eead4648-77e6-463e-8d8a-c74ad4aff236") or_else uuid.Identifier{}
@(private = "file") EXPOSURE_ADAPT_GUID  := uuid.read("4def1fcf-8e40-45de-8cd5-75550f990c39") or_else uuid.Identifier{}
@(private = "file") DOF_COC_GUID         := uuid.read("14040ade-402b-4109-a8ec-8b896b3eb896") or_else uuid.Identifier{}
@(private = "file") DOF_BOKEH_GUID       := uuid.read("90ca68cd-d796-459f-8be1-93f32a26c24d") or_else uuid.Identifier{}
@(private = "file") DOF_COMBINE_GUID     := uuid.read("eb083392-cd33-4191-8d5f-78d80bb7ec99") or_else uuid.Identifier{}
@(private = "file") MOTION_BLUR_GUID     := uuid.read("e2ab81a3-c95e-4b50-a044-3af61ec110c3") or_else uuid.Identifier{}
@(private = "file") EXPOSURE_HISTOGRAM_GUID  := uuid.read("7e3cacf2-566d-4df7-8cae-944e19b4c8bb") or_else uuid.Identifier{}
@(private = "file") EXPOSURE_PERCENTILE_GUID := uuid.read("c86417c6-cc5e-43ed-9972-7c8fbb225bf4") or_else uuid.Identifier{}

// Target names, as the steps declare them. "bloom" is what tonemap reads,
// the others are the chain's scratch.
BLOOM_TARGET   :: "bloom"
BLOOM_SCRATCH  :: "bloom_scratch"
BLOOM_SOURCE   :: "bloom_source"
TONEMAP_TARGET :: "post"
FXAA_TARGET    :: "aa"
// The auto exposure, 1 x 1: red the factor the bloom and the tonemap
// multiply the scene by. The others are the metering's chain: the reduction
// (the histogram replaces its last three levels when it is on), the
// histogram, and the average both end in.
EXPOSURE_TARGET    :: "exposure"
EXPOSURE_CHAIN     :: [?]string{"exposure_64", "exposure_16", "exposure_4"}
EXPOSURE_HISTOGRAM :: "exposure_hist"
EXPOSURE_AVERAGE   :: "exposure_avg"

// The shaders' property block: one vec4, std140.
@(private = "file")
_Params :: struct {
	params: [4]f32,
}

// One fullscreen pass: `shader` over `inputs` into `dst`.
@(private = "file")
_blit :: proc(dst: ^gfx.Render_Target, shader: string, inputs: []^gfx.Texture, params: [4]f32) {
	p := _Params{params = params}
	gfx.pass_begin_target(dst, nil)
	gfx.draw_fullscreen(shader, inputs, (^[size_of(_Params)]u8)(&p)[:])
	gfx.pass_end()
}

// Auto exposure: the scene's average log2 luminance measured on the GPU
// (256 x 256, reduced to 64 x 64, then either down to 1 x 1 or through a
// histogram whose middle percentiles average to 1 x 1), and the exposure
// that brings it to the target, reached over time from this view's last
// frame. Writes it as a 1 x 1 target the bloom and the tonemap read
// (`exposure?`). Leaves the scene image as the final.
@(render_step={summary="auto exposure: the scene's brightness metered (by average or histogram), the exposure adapted to it over time, for the bloom and the tonemap", reads="final", writes="exposure_lum:HDR@256px exposure_64:HDR@64px exposure_16:HDR@16px exposure_4:HDR@4px exposure_hist:HDR@16px exposure_avg:HDR@1px exposure:HDR@1px", settings="exposure_defaults"})
postfx_exposure :: proc(ctx: ^engine.Render_Ctx) {
	s := (^Exposure_Settings)(ctx.settings)
	src := engine.render_input(ctx, engine.FINAL_INPUT)
	if src == nil do return
	lum_shader, ok1 := engine.shader_load_fullscreen(engine.Asset_GUID(EXPOSURE_LUM_GUID))
	reduce, ok2 := engine.shader_load_fullscreen(engine.Asset_GUID(EXPOSURE_REDUCE_GUID))
	adapt, ok3 := engine.shader_load_fullscreen(engine.Asset_GUID(EXPOSURE_ADAPT_GUID))
	if !ok1 || !ok2 || !ok3 do return

	prev := engine.render_target(ctx, "exposure_lum")
	src_tex := gfx.rt_color_texture(src)
	_blit(prev, lum_shader, {&src_tex}, {s.metering == .Center_Weighted ? 1 : 0, 0, 0, 0})
	average := engine.render_target(ctx, EXPOSURE_AVERAGE)
	histogram, ok4 := engine.shader_load_fullscreen(engine.Asset_GUID(EXPOSURE_HISTOGRAM_GUID))
	percentile, ok5 := engine.shader_load_fullscreen(engine.Asset_GUID(EXPOSURE_PERCENTILE_GUID))
	if s.histogram && ok4 && ok5 {
		// 256 to 64, the histogram of that, the average of its middle.
		first := engine.render_target(ctx, EXPOSURE_CHAIN[0])
		tex := gfx.rt_color_texture(prev)
		_blit(first, reduce, {&tex}, {})
		hist := engine.render_target(ctx, EXPOSURE_HISTOGRAM)
		tex = gfx.rt_color_texture(first)
		_blit(hist, histogram, {&tex}, {EXPOSURE_HISTOGRAM_MIN, EXPOSURE_HISTOGRAM_MAX, 0, 0})
		tex = gfx.rt_color_texture(hist)
		_blit(average, percentile, {&tex}, {clamp(s.histogram_low, 0, 100) / 100, clamp(s.histogram_high, 0, 100) / 100, 0, 0})
	} else {
		// 256, 64, 16, 4, 1: the average of everything.
		for name in EXPOSURE_CHAIN {
			next := engine.render_target(ctx, name)
			tex := gfx.rt_color_texture(prev)
			_blit(next, reduce, {&tex}, {})
			prev = next
		}
		tex := gfx.rt_color_texture(prev)
		_blit(average, reduce, {&tex}, {})
	}
	prev = average

	// Two 1 x 1 targets in turn: last frame's result is this frame's history.
	state := _exposure_state(ctx)
	valid := state.frame == gfx.frame_index
	write := gfx.pool_target(ctx.pool, fmt.tprintf("exposure_history_%d_%d", ctx.view.camera.index, state.parity), 1, 1, .HDR)
	read := gfx.pool_target(ctx.pool, fmt.tprintf("exposure_history_%d_%d", ctx.view.camera.index, 1 - state.parity), 1, 1, .HDR)
	params := _Adapt_Params{
		params = {gfx.delta_time(), valid ? 1 : 0, math.log2(max(s.target, 0.01)) + s.compensation, 0},
		limits = {min(s.min_ev, s.max_ev), max(s.min_ev, s.max_ev), max(s.speed_dark_to_light, 0), max(s.speed_light_to_dark, 0)},
	}
	avg_tex := gfx.rt_color_texture(prev)
	history := gfx.rt_color_texture(read)
	gfx.pass_begin_target(write, nil)
	gfx.draw_fullscreen(adapt, {&avg_tex, &history}, (^[size_of(_Adapt_Params)]u8)(&params)[:])
	gfx.pass_end()
	gfx.rt_copy(engine.render_target(ctx, EXPOSURE_TARGET), write)

	state.frame = gfx.frame_index + 1
	state.parity = 1 - state.parity
}

// The adaptation pass's block (exposure_adapt.glsl).
@(private = "file")
_Adapt_Params :: struct {
	params: [4]f32, // seconds since last frame, history valid, log2 target + compensation
	limits: [4]f32, // metered range min, max, speed dark to light, light to dark
}

@(private = "file")
_Exposure_Key :: struct {
	pool:   ^gfx.Target_Pool,
	camera: engine.Transform_Handle,
}

@(private = "file")
_Exposure_View :: struct {
	parity: int, // which history target this frame writes
	frame:  u64, // gfx.frame_index + 1 when it last ran
}

@(private = "file")
_exposure_views: map[_Exposure_Key]_Exposure_View

@(private = "file")
_exposure_state :: proc(ctx: ^engine.Render_Ctx) -> ^_Exposure_View {
	context.allocator = runtime.default_allocator() // cross-frame state
	key := _Exposure_Key{ctx.pool, ctx.view.camera}
	if v, ok := &_exposure_views[key]; ok do return v
	_exposure_views[key] = {}
	return &_exposure_views[key]
}

@(phase={key=EngineShutdown, order=5})
postfx_shutdown :: proc() {
	delete(_exposure_views)
	_exposure_views = nil
	delete(_motion_blur_views)
	_motion_blur_views = nil
	delete(_lut_warned)
	_lut_warned = nil
}

// The auto exposure for a step that reads `exposure?`: its 1 x 1 target, nil
// when no exposure step ran (the input slot then binds white, 1).
@(private = "file")
_exposure_input :: proc(ctx: ^engine.Render_Ctx, tex: ^gfx.Texture) -> ^gfx.Texture {
	rt := engine.render_input(ctx, EXPOSURE_TARGET)
	if rt == nil do return nil
	tex^ = gfx.rt_color_texture(rt)
	return tex
}

// Bloom: bright pass at half size, then a horizontal and a vertical blur.
// Leaves the scene image as the final: tonemap reads the bloom beside it.
// The bright pass sees the scene as exposed (`exposure?`), so what blooms
// follows the auto exposure.
@(render_step={summary="blurs what is brighter than the threshold", reads="final exposure?", writes="bloom_source:HDR@0.5 bloom_scratch:HDR@0.5 bloom:HDR@0.5", settings="bloom_defaults"})
postfx_bloom :: proc(ctx: ^engine.Render_Ctx) {
	s := (^Bloom_Settings)(ctx.settings)
	src := engine.render_input(ctx, engine.FINAL_INPUT)
	if src == nil do return
	bright, ok1 := engine.shader_load_fullscreen(engine.Asset_GUID(BLOOM_BRIGHT_GUID))
	blur, ok2 := engine.shader_load_fullscreen(engine.Asset_GUID(BLOOM_BLUR_GUID))
	if !ok1 || !ok2 do return

	source := engine.render_target(ctx, BLOOM_SOURCE)
	scratch := engine.render_target(ctx, BLOOM_SCRATCH)
	bloom := engine.render_target(ctx, BLOOM_TARGET)
	w, h := source.width, source.height

	src_tex := gfx.rt_color_texture(src)
	exposure_tex: gfx.Texture
	_blit(source, bright, {&src_tex, _exposure_input(ctx, &exposure_tex)}, {s.threshold, 0.5, s.clamp > 0 ? s.clamp : 65472, 0})
	source_tex := gfx.rt_color_texture(source)
	_blit(scratch, blur, {&source_tex}, {1 / f32(w), 0, 1, 0})
	// The last pass scales by the strength: the bloom image is the light the
	// tonemap adds, so a tonemap needs nothing from this step but the image.
	scratch_tex := gfx.rt_color_texture(scratch)
	_blit(bloom, blur, {&scratch_tex}, {0, 1 / f32(h), max(s.strength, 0), 0})
}

// Tonemap: the HDR scene times the auto exposure (when an exposure step ran
// before it), plus the bloom (when a bloom step did), graded, to an LDR
// image, the chain's new final.
@(render_step={summary="exposure, bloom added, colour graded, HDR to LDR by the operator", reads="final bloom? exposure?", writes="post:LDR*", settings="tonemap_defaults"})
postfx_tonemap :: proc(ctx: ^engine.Render_Ctx) {
	s := (^Tonemap_Settings)(ctx.settings)
	src := engine.render_input(ctx, engine.FINAL_INPUT)
	if src == nil do return
	shader, ok := engine.shader_load_fullscreen(engine.Asset_GUID(TONEMAP_GUID))
	if !ok do return

	dst := engine.render_target(ctx, TONEMAP_TARGET)
	src_tex := gfx.rt_color_texture(src)
	bloom_tex: gfx.Texture
	// Absent when no bloom step ran before this one (an optional read).
	bloom := engine.render_input(ctx, BLOOM_TARGET)
	if bloom != nil do bloom_tex = gfx.rt_color_texture(bloom)
	exposure_tex: gfx.Texture
	lut, lut_size := _lut_texture(s.grading)
	// An unassigned input binds white: the bloom slot is gated by params.z,
	// a white exposure is 1, the lookup texture is gated by params.w.
	inputs := []^gfx.Texture{&src_tex, bloom != nil ? &bloom_tex : nil, _exposure_input(ctx, &exposure_tex), lut}

	balance, hue_sat, contrast := grading_matrices(s.grading)
	p := _Tonemap_Params{
		params  = {f32(s.operator), s.exposure, bloom != nil ? 1 : 0, lut != nil ? clamp(s.grading.lut_contribution, 0, 1) : 0},
		grading = {contrast, f32(lut_size), 0, 0},
		balance = _mat4(balance),
		hue_sat = _mat4(hue_sat),
	}
	gfx.pass_begin_target(dst, nil)
	gfx.draw_fullscreen(shader, inputs, (^[size_of(_Tonemap_Params)]u8)(&p)[:])
	gfx.pass_end()
}

// The tonemap shader's block (tonemap.glsl), std140.
@(private = "file")
_Tonemap_Params :: struct {
	params:  [4]f32,          // operator, exposure, bloom bound, lookup contribution
	grading: [4]f32,          // contrast, lookup size
	balance: matrix[4, 4]f32, // the upper 3 x 3 used
	hue_sat: matrix[4, 4]f32,
}

@(private = "file")
_mat4 :: proc(m: matrix[3, 3]f32) -> matrix[4, 4]f32 {
	out := linalg.MATRIX4F32_IDENTITY
	for r in 0 ..< 3 do for c in 0 ..< 3 do out[r, c] = m[r, c]
	return out
}

// The grading's lookup texture and its square size, nil when none is set or
// it is not a strip of N squares N texels on a side (warned once).
@(private = "file")
_lut_texture :: proc(g: Color_Grading) -> (^gfx.Texture, int) {
	if g.lut == {} || g.lut_contribution <= 0 do return nil, 0
	t, ok := engine.texture_load(g.lut)
	if !ok || t.gfx == nil do return nil, 0
	n := int(t.height)
	if n < 2 || int(t.width) != n * n {
		if g.lut not_in _lut_warned {
			context.allocator = runtime.default_allocator()
			_lut_warned[g.lut] = true
			log.warningf("[PostFX] lookup texture %v is %dx%d, not a strip of N squares N texels on a side (1024 x 32 for N = 32): not applied", g.lut, t.width, t.height)
		}
		return nil, 0
	}
	return t.gfx, n
}

@(private = "file")
_lut_warned: map[engine.Asset_GUID]bool

// Motion blur: the scene smeared along each pixel's motion since last
// frame, the camera's (from the depth) and the moved objects' (motion?, the
// motion_vectors step), back into `hdr`. Placed after scene_taa and before
// scene_over, so the gizmos stay sharp.
Motion_Blur_Settings :: struct {
	// How much of each frame's motion the blur spans: 0.5 is a shutter open
	// for half the frame, the film look.
	intensity: f32 `decor:range(0, 1)`,
	// Taps along the motion: more is smoother and costs more.
	samples:   int `decor:range(2, 32)`,
	// The longest blur, as a fraction of the view's height.
	max_blur:  f32 `decor:range(0, 0.5)`,
	// Blur with the camera's motion too, not only with the objects that moved.
	camera:    bool,
}

motion_blur_defaults := Motion_Blur_Settings{intensity = 0.5, samples = 8, max_blur = 0.05, camera = true}

MOTION_BLUR_TARGET :: "motion_blur"

@(render_step={summary="motion blur: each pixel smeared along how far it moved since last frame, with the camera and with the objects that moved", reads="hdr motion?", writes="motion_blur:HDR hdr:HDR", settings="motion_blur_defaults"})
postfx_motion_blur :: proc(ctx: ^engine.Render_Ctx) {
	if ctx.view.mode != .Shaded do return
	s := (^Motion_Blur_Settings)(ctx.settings)
	hdr := engine.render_input(ctx, engine.HDR_TARGET)
	if hdr == nil do return
	shader, ok := engine.shader_load_fullscreen(engine.Asset_GUID(MOTION_BLUR_GUID))
	if !ok do return

	// Last frame's camera is this view's when it drew last frame at this size.
	state := _motion_blur_state(ctx)
	w, h := hdr.width, hdr.height
	valid := state.frame == gfx.frame_index && state.size == {w, h}
	defer {
		state.prev_view_proj = ctx.view.view_proj
		state.frame = gfx.frame_index + 1
		state.size = {w, h}
	}
	motion_rt := engine.render_input(ctx, engine.MOTION_TARGET)
	if motion_rt == nil && !(valid && s.camera) do return // nothing moved that the step can see

	params := _Motion_Blur_Params{
		reproject = state.prev_view_proj * linalg.inverse(ctx.view.view_proj),
		params    = {clamp(s.intensity, 0, 1), f32(clamp(s.samples, 2, 64)), max(s.max_blur, 0), motion_rt != nil ? 1 : 0},
		params2   = {s.camera ? 1 : 0, valid ? 1 : 0, 0, 0},
	}
	src := gfx.rt_color_texture(hdr)
	depth := gfx.rt_depth_texture(hdr)
	motion := motion_rt != nil ? gfx.rt_color_texture(motion_rt) : src
	dst := engine.render_target(ctx, MOTION_BLUR_TARGET)
	gfx.pass_begin_target(dst, nil)
	gfx.draw_fullscreen(shader, {&src, &depth, &motion}, (^[size_of(_Motion_Blur_Params)]u8)(&params)[:])
	gfx.pass_end()
	gfx.rt_copy(hdr, dst)
}

// The motion blur's block (motion_blur.glsl).
@(private = "file")
_Motion_Blur_Params :: struct {
	reproject: matrix[4, 4]f32, // this frame's clip space to last frame's
	params:    [4]f32,          // intensity, samples, max blur, motion vectors present
	params2:   [4]f32,          // camera motion on, last frame's camera valid
}

@(private = "file")
_Motion_Blur_View :: struct {
	frame:          u64, // gfx.frame_index + 1 when it last ran
	size:           [2]i32,
	prev_view_proj: matrix[4, 4]f32, // last frame's steady camera
}

@(private = "file")
_motion_blur_views: map[_Exposure_Key]_Motion_Blur_View

@(private = "file")
_motion_blur_state :: proc(ctx: ^engine.Render_Ctx) -> ^_Motion_Blur_View {
	context.allocator = runtime.default_allocator() // cross-frame state
	key := _Exposure_Key{ctx.pool, ctx.view.camera}
	if v, ok := &_motion_blur_views[key]; ok do return v
	_motion_blur_views[key] = {}
	return &_motion_blur_views[key]
}

// Depth of field: the scene blurred by how far each pixel is from the
// focus distance, through a thin lens (focal length, aperture), back into
// `hdr`. Placed with the motion blur, before scene_over.
Dof_Settings :: struct {
	// The distance that is sharp, in world units (metres).
	focus_distance: f32 `decor:min(0.01)`,
	// The lens, as a camera's: a longer focal length and a wider aperture
	// (a lower f-number) blur more, either side of the focus. The sensor is
	// 24 mm high.
	focal_length:   f32 `decor:range(1, 300)`,
	aperture:       f32 `decor:range(0.7, 32)`,
	// The widest blur, as a fraction of the view's height.
	max_blur:       f32 `decor:range(0, 0.2)`,
	// Taps on the disc each pixel gathers: more is smoother and costs more.
	samples:        int `decor:range(4, 64)`,
}

dof_defaults := Dof_Settings{focus_distance = 10, focal_length = 50, aperture = 5.6, max_blur = 0.03, samples = 24}

DOF_HALF_TARGET :: "dof_half"
DOF_BLUR_TARGET :: "dof_blur"
DOF_TARGET      :: "dof"

@(render_step={summary="depth of field: the scene blurred by its distance from the focus, through a thin lens", reads="hdr", writes="dof_half:HDR@0.5 dof_blur:HDR@0.5 dof:HDR hdr:HDR", settings="dof_defaults"})
postfx_dof :: proc(ctx: ^engine.Render_Ctx) {
	if ctx.view.mode != .Shaded do return
	s := (^Dof_Settings)(ctx.settings)
	hdr := engine.render_input(ctx, engine.HDR_TARGET)
	if hdr == nil do return
	coc, ok1 := engine.shader_load_fullscreen(engine.Asset_GUID(DOF_COC_GUID))
	bokeh, ok2 := engine.shader_load_fullscreen(engine.Asset_GUID(DOF_BOKEH_GUID))
	combine, ok3 := engine.shader_load_fullscreen(engine.Asset_GUID(DOF_COMBINE_GUID))
	if !ok1 || !ok2 || !ok3 do return

	half := engine.render_target(ctx, DOF_HALF_TARGET)
	max_radius := max(s.max_blur, 0) * f32(half.height)
	if max_radius < 0.5 do return
	// The lens in world units (metres): the sensor is 24 mm high.
	focal := clamp(s.focal_length, 1, 300) / 1000
	aperture := focal / clamp(s.aperture, 0.7, 32)
	params := _Dof_Params{
		inv_proj = linalg.inverse(ctx.view.proj),
		params   = {max(s.focus_distance, 0.01), focal, aperture, max_radius},
		params2  = {f32(half.height) / 0.024, 0, 0, 0},
	}
	src := gfx.rt_color_texture(hdr)
	depth := gfx.rt_depth_texture(hdr)
	gfx.pass_begin_target(half, nil)
	gfx.draw_fullscreen(coc, {&src, &depth}, (^[size_of(_Dof_Params)]u8)(&params)[:])
	gfx.pass_end()

	blur := engine.render_target(ctx, DOF_BLUR_TARGET)
	half_tex := gfx.rt_color_texture(half)
	_blit(blur, bokeh, {&half_tex}, {max_radius, f32(clamp(s.samples, 4, 64)), 0, 0})

	dst := engine.render_target(ctx, DOF_TARGET)
	blur_tex := gfx.rt_color_texture(blur)
	_blit(dst, combine, {&src, &blur_tex}, {})
	gfx.rt_copy(hdr, dst)
}

// The circle of confusion pass's block (dof_coc.glsl).
@(private = "file")
_Dof_Params :: struct {
	inv_proj: matrix[4, 4]f32,
	params:   [4]f32, // focus distance, focal length, aperture diameter (world units), max radius (half-size pixels)
	params2:  [4]f32, // half-size pixels per sensor height
}

// FXAA on the LDR image, the chain's last step.
@(render_step={summary="fast approximate anti-aliasing", reads="final", writes="aa:LDR*"})
postfx_fxaa :: proc(ctx: ^engine.Render_Ctx) {
	src := engine.render_input(ctx, engine.FINAL_INPUT)
	if src == nil do return
	shader, ok := engine.shader_load_fullscreen(engine.Asset_GUID(FXAA_GUID))
	if !ok do return

	dst := engine.render_target(ctx, FXAA_TARGET)
	src_tex := gfx.rt_color_texture(src)
	_blit(dst, shader, {&src_tex}, {1 / f32(src.width), 1 / f32(src.height), 0, 0})
}
