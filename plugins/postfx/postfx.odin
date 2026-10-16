package postfx

// Post effects as render steps (plugins/engine/docs/RenderPipeline.md):
// bloom, a tonemap operator and FXAA, placed in a pipeline between the
// engine's scene steps and its final blit. Each step renders a new image
// from the finished one so far (reads="final") and declares its own as the
// new final (`post:LDR*`), so the engine's final_blit copies whichever step
// ran last. Each placed step carries its own settings in the pipeline asset.
// Removing this plugin leaves the engine's own steps untouched, a pipeline
// that placed these warns once and skips them.
//
// The shaders are .glsl assets under assets/resources (so an export ships
// them), compiled by the shader importer and registered as fullscreen
// shaders (engine.shader_load_fullscreen).

import "core:encoding/uuid"
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
	exposure: f32 `decor:min(0)`,
}

tonemap_defaults := Tonemap_Settings{operator = .ACES, exposure = 1}

// The shader assets, by the guid in their .meta files.
@(private = "file") BLOOM_BRIGHT_GUID := uuid.read("caa45a1a-ee91-410b-951c-60afa81d716f") or_else uuid.Identifier{}
@(private = "file") BLOOM_BLUR_GUID   := uuid.read("e241f892-9582-4ba3-a3df-8404558e446c") or_else uuid.Identifier{}
@(private = "file") TONEMAP_GUID      := uuid.read("ad09953d-bd1e-4958-ad8a-2ad37eae2edb") or_else uuid.Identifier{}
@(private = "file") FXAA_GUID         := uuid.read("774894e7-d7e7-469b-9626-2c38b04cffb9") or_else uuid.Identifier{}

// Target names, as the steps declare them. "bloom" is what tonemap reads,
// the others are the chain's scratch.
BLOOM_TARGET   :: "bloom"
BLOOM_SCRATCH  :: "bloom_scratch"
BLOOM_SOURCE   :: "bloom_source"
TONEMAP_TARGET :: "post"
FXAA_TARGET    :: "aa"

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

// Bloom: bright pass at half size, then a horizontal and a vertical blur.
// Leaves the scene image as the final: tonemap reads the bloom beside it.
@(render_step={summary="blurs what is brighter than the threshold", reads="final", writes="bloom_source:HDR@0.5 bloom_scratch:HDR@0.5 bloom:HDR@0.5", settings="bloom_defaults"})
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
	_blit(source, bright, {&src_tex}, {s.threshold, 0.5, s.clamp > 0 ? s.clamp : 65472, 0})
	source_tex := gfx.rt_color_texture(source)
	_blit(scratch, blur, {&source_tex}, {1 / f32(w), 0, 1, 0})
	// The last pass scales by the strength: the bloom image is the light the
	// tonemap adds, so a tonemap needs nothing from this step but the image.
	scratch_tex := gfx.rt_color_texture(scratch)
	_blit(bloom, blur, {&scratch_tex}, {0, 1 / f32(h), max(s.strength, 0), 0})
}

// Tonemap: the HDR scene plus the bloom (when a bloom step ran before it)
// to an LDR image, the chain's new final.
@(render_step={summary="exposure, bloom added, HDR to LDR by the operator", reads="final bloom?", writes="post:LDR*", settings="tonemap_defaults"})
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
	// An unassigned input binds white, so the bloom slot is always given.
	inputs := bloom != nil ? []^gfx.Texture{&src_tex, &bloom_tex} : []^gfx.Texture{&src_tex, nil}
	_blit(dst, shader, inputs, {f32(s.operator), s.exposure, bloom != nil ? 1 : 0, 0})
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
