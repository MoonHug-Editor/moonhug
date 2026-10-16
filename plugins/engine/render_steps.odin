package engine

// The engine's render steps: what the default pipeline places in its Main
// slot (render_pipeline.odin, plugins/engine/docs/RenderPipeline.md).
//
//   environment_pass  (render_environment.odin, per frame) the sky light's
//                     cubes from the scene's Environment
//   shadow_atlas      (render_shadow.odin, per frame) spot and point Light
//                     shadows, tiles of one atlas
//   shadow_cascades   (render_shadow.odin) the first shadowing directional
//                     Light's cascades, fitted to the view
//   depth_prepass     the opaque meshes' depth first (optional, not in the
//                     Default pipeline), so scene_opaque shades each pixel once
//   scene_ssao        (render_ssao.odin) screen-space ambient occlusion from
//                     the depth (muted in the Default pipeline)
//   scene_ssr         (render_ssr.odin) screen-space reflections from the
//                     depth, the normals and last frame's opaque image
//                     (muted in the Default pipeline)
//   scene_opaque      clears the view's "hdr" target and its depth (keeps the
//                     depth after a depth_prepass), draws the opaque meshes
//   scene_sky         (render_environment.odin) the sky behind the opaques
//   scene_copy        the opaque image, sky included, for the materials that
//                     refract and for next frame's reflections
//   scene_under       the host's drawing under the scene (the editor's grid),
//                     depth-tested against the opaques
//   scene_transparent the alpha-blended quads, back to front
//   motion_vectors    (render_taa.odin) the moved meshes' motion vectors
//   scene_taa         (render_taa.odin) temporal anti-aliasing
//   scene_over        the host's drawing over the scene (gizmos, the app's
//                     DebugDraw phase)
//   final_blit        copies the finished image (ctx.final) onto the view's
//                     target. A post chain (the postfx plugin: bloom, tonemap,
//                     FXAA) slots in between, each step rendering a new image
//                     and naming it
//
// Every scene step is one gfx pass on the same target, sharing its depth
// (scene_target_begin): a step placed between them in the pipeline draws
// into the scene (decals after the opaques, a debug pass before the
// overlays) and depth-tests against what came before.

import gfx "moonhug:libs/gfx"

// The scene color before tonemapping, written by the scene steps. Its depth
// (gfx.rt_depth_texture) is the scene depth.
HDR_TARGET :: "hdr"

// Begins a pass on the view's scene target for a step that draws into the
// scene: the "hdr" color kept (or cleared to `clear`), the depth kept from
// the earlier scene steps unless `keep_depth` is false, the view's camera
// set, and what the running step reads of the shadows, the ambient
// occlusion, the screen's reflections and the opaque copy bound for its lit
// draws. pass_end closes it.
scene_target_begin :: proc(ctx: ^Render_Ctx, clear: Maybe([4]f32) = nil, keep_depth := true) -> ^gfx.Render_Target {
	hdr := render_target(ctx, HDR_TARGET) // every scene step declares `hdr:HDR`
	gfx.pass_begin_target(hdr, clear, keep_depth)
	sv := render_draw_view(ctx) // with the TAA jitter, when this run has one
	gfx.set_view_proj(sv.view_proj, sv.cam_pos)
	shadow_bind(ctx) // render_shadow.odin: this view's cascades and this frame's atlas, when the step reads them
	environment_bind() // render_environment.odin: this frame's sky light, if an Environment set one
	if render_reads(ctx, SSAO_TARGET) {
		if ao := render_input(ctx, SSAO_TARGET); ao != nil do gfx.set_ambient_occlusion(gfx.rt_color_texture(ao)) // render_ssao.odin
	}
	if render_reads(ctx, SCENE_COLOR_TARGET) {
		if copy := render_input(ctx, SCENE_COLOR_TARGET); copy != nil do gfx.set_scene_color(gfx.rt_color_texture(copy)) // scene_copy
	}
	if render_reads(ctx, SSR_TARGET) {
		if ssr := render_input(ctx, SSR_TARGET); ssr != nil do gfx.set_screen_reflections(gfx.rt_color_texture(ssr)) // render_ssr.odin
	}
	return hdr
}

// Draws the opaque meshes' depth into `hdr`'s depth, through the view's
// camera (with this run's jitter), and marks it primed so scene_opaque keeps
// it: depth_prepass, and scene_ssao when no prepass ran before it.
render_depth_prime :: proc(ctx: ^Render_Ctx, hdr: ^gfx.Render_Target) {
	gfx.pass_begin_target(hdr, nil, color = false)
	sv := render_draw_view(ctx)
	gfx.set_view_proj(sv.view_proj, sv.cam_pos)
	render_execute_depth(ctx.commands)
	gfx.pass_end()
	ctx.depth_primed = true
	_inspect_depth_view(HDR_TARGET)
}

// The opaque meshes' depth before they are shaded. With it scene_opaque
// keeps the depth instead of clearing it, so each covered pixel is shaded
// once instead of once per mesh drawn over it. It costs a second pass over
// the geometry, so it pays off with expensive materials and heavy overdraw,
// and the Default pipeline leaves it out. The scene view's debug modes draw
// without it: a wireframe has to show what lies behind the front surface.
@(render_step={summary="the opaque meshes' depth before shading, so each pixel is shaded once", reads="scene", writes="hdr:HDR*"})
depth_prepass :: proc(ctx: ^Render_Ctx) {
	if ctx.view.mode != .Shaded do return
	render_depth_prime(ctx, render_target(ctx, HDR_TARGET))
}

// The first scene step: starts the view's image with the camera's clear and
// a fresh depth (the depth prepass's when one ran), then the opaque meshes.
// Its "hdr" is the view's final image until a post step renders a later one.
@(render_step={summary="clears the view, draws the opaque meshes", reads="scene shadow? shadow_atlas? ssao? ssr?", writes="hdr:HDR*"})
scene_opaque :: proc(ctx: ^Render_Ctx) {
	scene_target_begin(ctx, ctx.clear, keep_depth = ctx.depth_primed)
	render_execute(render_draw_view(ctx), ctx.commands, {.Opaque})
	gfx.pass_end()
}

// The host's drawing under the scene: the editor's grid. Depth-tested against
// the opaques, so a grid line hides behind a mesh, and drawn before the
// transparents, so a sprite blends over it.
@(render_step={summary="what the host draws under the scene: the editor grid", reads="hdr", writes="hdr:HDR"})
scene_under :: proc(ctx: ^Render_Ctx) {
	if ctx.overlay_under == nil do return
	scene_target_begin(ctx)
	ctx.overlay_under()
	gfx.pass_end()
}

// The opaque image, sky included, for the transparent materials that refract
// (Material.refraction): scene_transparent reads it as `scene_color?`. With
// mip levels, so a lens that minifies what is behind it samples a blur
// instead of aliasing (and TAA's sub-pixel jitter, magnified through the
// lens, moves a smooth image). Next frame's scene_ssr reads the same target
// from the pool as last frame's image, so a step placed before this one
// (the editor's grid, scene_under) stays out of the reflections.
@(render_step={summary="copies the opaque image for the materials that refract and next frame's reflections", reads="hdr", writes="scene_color:HDR"})
scene_copy :: proc(ctx: ^Render_Ctx) {
	hdr := render_input(ctx, HDR_TARGET)
	if hdr == nil do return
	gfx.rt_copy(render_target(ctx, SCENE_COLOR_TARGET, mips = true), hdr)
}

SCENE_COLOR_TARGET :: "scene_color"

@(render_step={summary="draws the transparent meshes and the alpha-blended quads back to front", reads="scene shadow? shadow_atlas? hdr scene_color?", writes="hdr:HDR"})
scene_transparent :: proc(ctx: ^Render_Ctx) {
	scene_target_begin(ctx)
	render_execute(render_draw_view(ctx), ctx.commands, {.Transparent})
	gfx.pass_end()
}

// The host's drawing over the scene: the editor's gizmos, the app's DebugDraw
// phase. Depth-tested against the whole scene.
@(render_step={summary="what the host draws over the scene: gizmos, debug draw", reads="hdr", writes="hdr:HDR"})
scene_over :: proc(ctx: ^Render_Ctx) {
	if ctx.overlay_over == nil do return
	scene_target_begin(ctx)
	ctx.overlay_over()
	gfx.pass_end()
}

// The last step: copies the finished image (the scene's "hdr" unless a post
// step rendered a later one) onto the view's target. A post chain slots in
// between scene_over and this step (the postfx plugin).
@(render_step={summary="copies the final image to the view", reads="final"})
final_blit :: proc(ctx: ^Render_Ctx) {
	src := render_input(ctx, FINAL_INPUT)
	if src == nil do return
	// Linear to the view's sRGB bytes. A minimized window draws nothing.
	gfx.display_blit(ctx.target, gfx.rt_color_texture(src))
}
