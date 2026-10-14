package engine

// The engine's render nodes: what the default pipeline places in its Main
// slot (render_pipeline.odin, plugins/engine/docs/RenderPipeline.md).
//
//   shadow_pass       (render_shadow.odin, per frame) renders the shadow map
//                     of the first directional Light with shadows on
//   scene_opaque      clears the view's "hdr" target and its depth, draws the
//                     opaque meshes
//   scene_under       the host's drawing under the scene (the editor's grid),
//                     depth-tested against the opaques
//   scene_transparent the alpha-blended quads, back to front
//   scene_over        the host's drawing over the scene (gizmos, the app's
//                     DebugDraw phase)
//   final_blit        copies the finished image (ctx.final) onto the view's
//                     target. A post chain (the postfx plugin: bloom, tonemap,
//                     FXAA) slots in between, each node rendering a new image
//                     and naming it
//
// Every scene node is one gfx pass on the same target, sharing its depth
// (scene_target_begin): a node placed between them in the pipeline draws
// into the scene (decals after the opaques, a debug pass before the
// overlays) and depth-tests against what came before.

import gfx "moonhug:libs/gfx"

// The scene color before tonemapping, written by the scene nodes. Its depth
// (gfx.rt_depth_texture) is the scene depth.
HDR_TARGET :: "hdr"

// Begins a pass on the view's scene target for a node that draws into the
// scene: the "hdr" color kept (or cleared to `clear`), the depth kept from
// the earlier scene nodes unless `keep_depth` is false, the view's camera set
// and this frame's shadow map bound. pass_end closes it.
scene_target_begin :: proc(ctx: ^Render_Ctx, clear: Maybe([4]f32) = nil, keep_depth := true) -> ^gfx.Render_Target {
	hdr := render_target(ctx, HDR_TARGET) // every scene node declares `hdr:HDR`
	gfx.pass_begin_target(hdr, clear, keep_depth)
	gfx.set_view_proj(ctx.view.view_proj, ctx.view.cam_pos)
	shadow_bind() // render_shadow.odin: this frame's map, if a light cast one
	environment_bind() // render_environment.odin: this frame's sky light, if an Environment set one
	return hdr
}

// The first scene node: starts the view's image with the camera's clear and
// a fresh depth, then the opaque meshes. Its "hdr" is the view's final image
// until a post node renders a later one.
@(render_node={summary="clears the view, draws the opaque meshes", reads="scene shadow", writes="hdr:HDR*"})
scene_opaque :: proc(ctx: ^Render_Ctx) {
	scene_target_begin(ctx, ctx.clear, keep_depth = false)
	render_execute(ctx.view, ctx.commands, {.Opaque})
	gfx.pass_end()
}

// The host's drawing under the scene: the editor's grid. Depth-tested against
// the opaques, so a grid line hides behind a mesh, and drawn before the
// transparents, so a sprite blends over it.
@(render_node={summary="what the host draws under the scene: the editor grid", reads="hdr", writes="hdr:HDR"})
scene_under :: proc(ctx: ^Render_Ctx) {
	if ctx.overlay_under == nil do return
	scene_target_begin(ctx)
	ctx.overlay_under()
	gfx.pass_end()
}

@(render_node={summary="draws the alpha-blended quads back to front", reads="scene shadow hdr", writes="hdr:HDR"})
scene_transparent :: proc(ctx: ^Render_Ctx) {
	scene_target_begin(ctx)
	render_execute(ctx.view, ctx.commands, {.Transparent})
	gfx.pass_end()
}

// The host's drawing over the scene: the editor's gizmos, the app's DebugDraw
// phase. Depth-tested against the whole scene.
@(render_node={summary="what the host draws over the scene: gizmos, debug draw", reads="hdr", writes="hdr:HDR"})
scene_over :: proc(ctx: ^Render_Ctx) {
	if ctx.overlay_over == nil do return
	scene_target_begin(ctx)
	ctx.overlay_over()
	gfx.pass_end()
}

// The last node: copies the finished image (the scene's "hdr" unless a post
// node rendered a later one) onto the view's target. A post chain slots in
// between scene_over and this node (the postfx plugin).
@(render_node={summary="copies the final image to the view", reads="final"})
final_blit :: proc(ctx: ^Render_Ctx) {
	src := render_input(ctx, FINAL_INPUT)
	if src == nil do return
	// Linear to the view's sRGB bytes. A minimized window draws nothing.
	gfx.display_blit(ctx.target, gfx.rt_color_texture(src))
}
