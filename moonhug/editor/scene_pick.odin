package editor

// Scene-view click picking (docs/SDL3Renderer.md #7). CPU tests — sprites
// against their exact world quads (the SAME corners the renderer draws, via
// sprite_world_corners), meshes against their import-time AABB in local
// space. Nearest hit wins. Like Unity, the editor ignores render layer masks
// — you can pick anything you can see.

import "core:math/linalg"
import "../engine"

// px, py in viewport pixels relative to the scene image's top-left.
scene_view_pick :: proc(view: engine.Render_View, px, py: f32) -> (engine.Transform_Handle, bool) {
	ray := engine.render_view_screen_ray(view, px, py)
	w := engine.ctx_world()

	best_t := f32(1e30)
	best: engine.Transform_Handle
	found := false

	for i in 0 ..< len(w.sprite_renderers.slots) {
		slot := &w.sprite_renderers.slots[i]
		if !slot.alive do continue
		sr := &slot.data
		if !sr.enabled || sr.texture == {} do continue
		if !engine.transform_active_in_hierarchy(sr.owner) do continue
		tex, ok := engine.texture_load(sr.texture)
		if !ok do continue

		tw := engine.transform_world(engine.Transform_Handle(sr.owner))
		c := engine.sprite_world_corners(tw, tex.width, tex.height)
		if t, hit := engine.ray_hit_triangle(ray, c[0], c[1], c[2]); hit && t < best_t {
			best_t = t
			best = engine.Transform_Handle(sr.owner)
			found = true
		}
		if t, hit := engine.ray_hit_triangle(ray, c[0], c[2], c[3]); hit && t < best_t {
			best_t = t
			best = engine.Transform_Handle(sr.owner)
			found = true
		}
	}

	for i in 0 ..< len(w.mesh_renderers.slots) {
		slot := &w.mesh_renderers.slots[i]
		if !slot.alive do continue
		mr := &slot.data
		if !mr.enabled do continue
		if !engine.transform_active_in_hierarchy(mr.owner) do continue
		_, mf := engine.transform_get_comp(engine.Transform_Handle(mr.owner), engine.MeshFilter)
		if mf == nil || mf.mesh == {} do continue
		mesh, ok := engine.mesh_load(mf.mesh)
		if !ok do continue

		// Ray into local space (direction NOT renormalized so t stays
		// comparable with world-space hits).
		tw := engine.transform_world(engine.Transform_Handle(mr.owner))
		inv := linalg.inverse(engine.trs_matrix(tw.position, tw.rotation, tw.scale))
		local_o := inv * [4]f32{ray.origin.x, ray.origin.y, ray.origin.z, 1}
		local_d := inv * [4]f32{ray.direction.x, ray.direction.y, ray.direction.z, 0}
		local_ray := engine.Ray{origin = local_o.xyz, direction = local_d.xyz}

		if t, hit := engine.ray_hit_aabb(local_ray, mesh.aabb_min, mesh.aabb_max); hit && t < best_t {
			best_t = t
			best = engine.Transform_Handle(mr.owner)
			found = true
		}
	}

	return best, found
}
