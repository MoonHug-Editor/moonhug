package engine

// Screen-space ambient occlusion (plugins/engine/docs/RenderPipeline.md
// "Ambient occlusion"): scene_ssao, placed before scene_opaque, works out
// from the view's depth how open each pixel's surroundings are and hands the
// result to the lit draws after it (gfx.set_ambient_occlusion, bound by
// scene_target_begin): it shades the environment's light, and a part of the
// lights'. The depth comes from the depth prepass, which scene_ssao draws
// itself when no depth_prepass ran before it.

import gfx "moonhug:libs/gfx"
import "core:math/linalg"

SSAO_NODE :: "scene_ssao"

// The occlusion, and the blur's first pass.
SSAO_TARGET      :: "ssao"
SSAO_BLUR_TARGET :: "ssao_blur"

Ssao_Settings :: struct {
	// How far around a point occluders count, in world units.
	radius:    f32 `decor:range(0.05, 5)`,
	// How dark a fully occluded point gets: 1 is black where every sample is
	// covered.
	intensity: f32 `decor:range(0, 4)`,
	// Samples per pixel: more is smoother and costs more.
	samples:   int `decor:range(4, 32)`,
	// How much of the occlusion also darkens direct light: 0 shades only the
	// environment's light, as the physics says, a little more grounds objects.
	direct:    f32 `decor:range(0, 1)`,
}

ssao_defaults := Ssao_Settings{radius = 0.5, intensity = 1, samples = 12, direct = 0.25}

@(render_node={summary="screen-space ambient occlusion from the view's depth, shading the environment's light of the lit draws after it", reads="scene", writes="hdr:HDR* ssao:HDR ssao_blur:HDR", settings="ssao_defaults"})
scene_ssao :: proc(ctx: ^Render_Ctx) {
	if ctx.view.mode != .Shaded do return
	settings := (^Ssao_Settings)(ctx.settings)
	hdr := render_target(ctx, HDR_TARGET)
	if !ctx.depth_primed do render_depth_prime(ctx, hdr)

	view := render_draw_view(ctx) // as the depth was drawn
	params := new(gfx.Ssao_Params, context.temp_allocator)
	params^ = {
		proj     = view.proj,
		inv_proj = linalg.inverse(view.proj),
		params   = {max(settings.radius, 0.01), max(settings.intensity, 0), f32(clamp(settings.samples, 1, 64)), 0},
	}
	ao := render_target(ctx, SSAO_TARGET)
	blur := render_target(ctx, SSAO_BLUR_TARGET)
	depth := gfx.rt_depth_texture(hdr)
	gfx.pass_begin_target(ao, nil)
	gfx.draw_fullscreen(gfx.SSAO_SHADER, {&depth}, (^[size_of(gfx.Ssao_Params)]u8)(params)[:])
	gfx.pass_end()

	// Across, into the blur's target, then down, back into the occlusion.
	steps := [2]gfx.Ssao_Blur_Params{{params = {1, 0, 0, 0}}, {params = {0, 1, 0, 0}}}
	across := new_clone(steps[0], context.temp_allocator)
	down := new_clone(steps[1], context.temp_allocator)
	ao_tex := gfx.rt_color_texture(ao)
	blur_tex := gfx.rt_color_texture(blur)
	gfx.pass_begin_target(blur, nil)
	gfx.draw_fullscreen(gfx.SSAO_BLUR_SHADER, {&ao_tex}, (^[size_of(gfx.Ssao_Blur_Params)]u8)(across)[:])
	gfx.pass_end()
	gfx.pass_begin_target(ao, nil)
	gfx.draw_fullscreen(gfx.SSAO_BLUR_SHADER, {&blur_tex}, (^[size_of(gfx.Ssao_Blur_Params)]u8)(down)[:])
	gfx.pass_end()

	ctx.occlusion = gfx.Ambient_Occlusion{tex = gfx.rt_color_texture(ao), direct = settings.direct}
}
