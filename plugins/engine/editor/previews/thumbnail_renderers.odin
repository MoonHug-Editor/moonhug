package previews

// The engine's thumbnail renderers for the shell's cache (moonhug:editor/thumbnails):
// image files (the texture drawn aspect-fit), .mat (a quad drawn with the
// material's shader and block), .scene (the instantiated prefab framed by its
// bounds), and a model's mesh parts and clips as sub-assets.

import "core:math"
import "core:math/linalg"
import engine "moonhug:packages/engine"
import gfx "moonhug:host/gfx"
import "moonhug:editor/thumbnails"
import "moonhug:packages/engine/editor/scene_tools"

// Reserved render layer for preview content (thumbnails AND the inspector's
// live previews), so preview views draw ONLY it. The open scene's content
// (layer 1) never bleeds in.
_THUMB_LAYER :: u32(1) << 31

register_thumbnail_renderers :: proc() {
	for ext in ([]string{".png", ".jpg", ".jpeg", ".bmp", ".tga", ".gif"}) {
		thumbnails.register(ext, _thumb_render_image)
	}
	thumbnails.register(".scene", _thumb_render_scene)
	thumbnails.register(".mat", _thumb_render_material)
	// The only rendered sub-assets are a model's parts and clips. Sprite
	// slices preview as crops of the resident texture, no render.
	thumbnails.register_sub(".glb", _thumb_render_model_sub)
	thumbnails.register_sub(".gltf", _thumb_render_model_sub)
}

@(private = "file")
_thumb_render_model_sub :: proc(path: string, guid: engine.Asset_GUID, sub: engine.Local_ID, target: ^gfx.Render_Target) -> bool {
	if _, is_part := engine.mesh_part_index(guid, sub); is_part {
		return _thumb_render_mesh_part(guid, sub, target)
	}
	return _thumb_render_clip(guid, sub, path, target)
}

// stb rows are top-down: v=1 on the bottom corners (matches render_execute).
@(private = "file")
_THUMB_UVS :: [4][2]f32{{0, 1}, {1, 1}, {1, 0}, {0, 0}}

// The texture drawn aspect-fit on a transparent background. The quad's corners
// are in clip space directly (identity view-proj): bl, br, tr, tl.
@(private = "file")
_thumb_render_image :: proc(path: string, guid: engine.Asset_GUID, sub: engine.Local_ID, target: ^gfx.Render_Target) -> bool {
	t2d, ok := engine.texture_load(guid)
	if !ok || t2d.gfx == nil do return false
	sx, sy: f32 = 1, 1
	if t2d.width > t2d.height {
		sy = f32(t2d.height) / f32(t2d.width)
	} else if t2d.height > 0 {
		sx = f32(t2d.width) / f32(t2d.height)
	}
	corners := [4][3]f32{{-sx, -sy, 0}, {sx, -sy, 0}, {sx, sy, 0}, {-sx, sy, 0}}

	gfx.pass_begin_target(target, [4]f32{0, 0, 0, 0})
	gfx.set_view_proj(linalg.MATRIX4F32_IDENTITY)
	gfx.draw_quad(corners, _THUMB_UVS, {1, 1, 1, 1}, t2d.gfx)
	gfx.pass_end()
	return true
}

// A full-cell quad drawn with the material's shader, block and textures — a
// flat swatch (no preview mesh exists yet).
@(private = "file")
_thumb_render_material :: proc(path: string, guid: engine.Asset_GUID, sub: engine.Local_ID, target: ^gfx.Render_Target) -> bool {
	shader, tex, color, data, extra := engine.material_resolve_draw(guid)
	corners := [4][3]f32{{-0.9, -0.9, 0}, {0.9, -0.9, 0}, {0.9, 0.9, 0}, {-0.9, 0.9, 0}}

	gfx.pass_begin_target(target, [4]f32{0.16, 0.16, 0.18, 1})
	gfx.set_view_proj(linalg.MATRIX4F32_IDENTITY)
	gfx.draw_quad(corners, _THUMB_UVS, color, tex, shader, data, {0, 0, 1}, extra)
	gfx.pass_end()
	return true
}

// Instantiates the prefab into the scratch scene, frames its bounds with a
// perspective camera (front-on when the content is flat — sprite scenes),
// renders through the normal pipeline, and destroys the content again.
@(private = "file")
_thumb_render_scene :: proc(path: string, guid: engine.Asset_GUID, sub: engine.Local_ID, target: ^gfx.Render_Target) -> bool {
	prev := preview_world_begin()
	defer preview_world_end(prev)
	spawned := engine.scene_instantiate_guid(guid, preview_world_root())
	if spawned == {} do return false
	defer engine.transform_destroy(spawned)
	return _thumb_render_framed(spawned, target)
}

// A model's part rendered alone, lit with a camera headlight (the same look
// as the inspector's live mesh preview) — drawn directly, no scene spawn.
@(private = "file")
_thumb_render_mesh_part :: proc(guid: engine.Asset_GUID, sub: engine.Local_ID, target: ^gfx.Render_Target) -> bool {
	idx, iok := engine.mesh_part_index(guid, sub)
	if !iok do return false
	mesh, mok := engine.mesh_load(guid, idx + 1)
	if !mok do return false

	center := (mesh.aabb_min + mesh.aabb_max) * 0.5
	radius := max(linalg.length(mesh.aabb_max - mesh.aabb_min) * 0.5, 0.01)
	forward := linalg.normalize([3]f32{-1, -0.7, -1})
	fov := math.to_radians(f32(35))
	dist := radius / math.sin(fov * 0.5) * 1.05
	eye := center - forward * dist
	view := linalg.matrix4_look_at_f32(eye, center, [3]f32{0, 1, 0})
	proj := gfx.matrix4_perspective_z01(fov, 1, max(dist - radius * 2, 0.01), dist + radius * 2)
	rv := engine.render_view_make(view, proj, thumbnails.SIZE, thumbnails.SIZE, _THUMB_LAYER, .Preview)

	gfx.set_lights([]gfx.Light{{kind = .Directional, direction = forward, color = {1, 1, 1}, intensity = 1}}, 0.35)
	gfx.pass_begin_target(target, [4]f32{0.16, 0.16, 0.18, 1})
	gfx.set_view_proj(rv.view_proj, rv.cam_pos)
	for s in mesh.submeshes {
		gfx.draw_mesh(mesh.gpu, nil, linalg.MATRIX4F32_IDENTITY, {1, 1, 1, 1}, "lit", s.first_index, s.index_count, nil, nil)
	}
	gfx.pass_end()
	gfx.set_lights_default()
	return true
}

// A clip inside a model: the model's rig posed at the clip's midpoint, built
// in the preview world for the one frame and torn down again. Cached to disk
// like every thumbnail, so the rig is built once per clip, not per frame.
@(private = "file")
_thumb_render_clip :: proc(guid: engine.Asset_GUID, sub: engine.Local_ID, path: string, target: ^gfx.Render_Target) -> bool {
	prev := preview_world_begin()
	defer preview_world_end(prev)
	rig, ok := model_clip_rig_build(path, guid, sub, preview_world_root())
	if !ok do return false
	defer model_clip_rig_destroy(&rig)
	model_clip_rig_pose(&rig, rig.length * 0.5)
	return _thumb_render_framed(rig.root, target)
}

// Frames `tH`'s bounds with a perspective camera (front-on when the content
// is flat, sprite scenes), renders through the normal pipeline.
@(private = "file")
_thumb_render_framed :: proc(tH: engine.Transform_Handle, target: ^gfx.Render_Target) -> bool {
	_thumb_set_layer(tH)

	bmin, bmax, bok := _thumb_bounds(tH)
	if !bok do return false
	center := (bmin + bmax) * 0.5
	radius := max(linalg.length(bmax - bmin) * 0.5, 0.01)

	// Flat content (2D scenes) reads best front-on; anything with depth gets
	// the standard 3/4 view.
	forward := [3]f32{0, 0, -1}
	up := [3]f32{0, 1, 0}
	if bmax.z - bmin.z > radius * 0.1 {
		forward = linalg.normalize([3]f32{-1, -0.7, -1})
	}
	fov := math.to_radians(f32(35))
	dist := radius / math.sin(fov * 0.5) * 1.05
	eye := center - forward * dist
	view := linalg.matrix4_look_at_f32(eye, center, up)
	proj := gfx.matrix4_perspective_z01(fov, 1, max(dist - radius * 2, 0.01), dist + radius * 2)
	rv := engine.render_view_make(view, proj, thumbnails.SIZE, thumbnails.SIZE, _THUMB_LAYER, .Preview)

	cmds := make([dynamic]engine.Render_Command, 0, 64, context.temp_allocator)
	engine.render_collect_commands(rv, &cmds)
	if len(cmds) == 0 do return false // nothing drawable — keep the icon

	gfx.pass_begin_target(target, [4]f32{0.16, 0.16, 0.18, 1})
	engine.render_execute(rv, cmds[:])
	gfx.pass_end()
	return true
}

_thumb_set_layer :: proc(tH: engine.Transform_Handle) {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return
	t.render_layer = _THUMB_LAYER
	for child in t.children {
		_thumb_set_layer(engine.Transform_Handle(child.handle))
	}
}

// World bounds of a subtree on the thumbnail layer: mesh AABBs and the quads
// package renderers draw where present, transform positions otherwise. The
// quads come from a collect with a stand-in view: a quad's corners are world
// space, whatever the camera.
_thumb_bounds :: proc(tH: engine.Transform_Handle) -> (bmin, bmax: [3]f32, ok: bool) {
	bmin = {max(f32), max(f32), max(f32)}
	bmax = {min(f32), min(f32), min(f32)}
	probe := engine.render_view_make(linalg.MATRIX4F32_IDENTITY, linalg.MATRIX4F32_IDENTITY, thumbnails.SIZE, thumbnails.SIZE, _THUMB_LAYER, .Preview)
	_thumb_bounds_walk(tH, scene_tools.drawn_quads(probe), &bmin, &bmax, &ok)
	return
}

@(private = "file")
_thumb_bounds_walk :: proc(tH: engine.Transform_Handle, quads: scene_tools.Drawn_Quads, bmin, bmax: ^[3]f32, any_point: ^bool) {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return
	tw := engine.transform_world(tH)

	grow :: proc(bmin, bmax: ^[3]f32, any_point: ^bool, p: [3]f32) {
		bmin^ = linalg.min(bmin^, p)
		bmax^ = linalg.max(bmax^, p)
		any_point^ = true
	}

	if _, mf := engine.transform_get_comp(tH, engine.MeshFilter); mf != nil && mf.mesh != {} {
		if mesh, mok := engine.mesh_load_filter(mf); mok {
			model := engine.trs_matrix(tw.position, tw.rotation, tw.scale)
			for i in 0 ..< 8 {
				c := [4]f32{
					i & 1 == 0 ? mesh.aabb_min.x : mesh.aabb_max.x,
					i & 2 == 0 ? mesh.aabb_min.y : mesh.aabb_max.y,
					i & 4 == 0 ? mesh.aabb_min.z : mesh.aabb_max.z,
					1,
				}
				p := model * c
				grow(bmin, bmax, any_point, p.xyz)
			}
		}
	}
	for i in quads.by_owner[tH] or_else nil {
		for p in quads.all[i].variant.(engine.Draw_Quad).corners do grow(bmin, bmax, any_point, p)
	}
	grow(bmin, bmax, any_point, tw.position)

	for child in t.children {
		_thumb_bounds_walk(engine.Transform_Handle(child.handle), quads, bmin, bmax, any_point)
	}
}
