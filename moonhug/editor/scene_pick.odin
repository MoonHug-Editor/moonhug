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

	sprite_renderers_pool := engine.sprite_renderers(w)
	if sprite_renderers_pool != nil do for i in 0 ..< len(sprite_renderers_pool.slots) {
		slot := &sprite_renderers_pool.slots[i]
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

	mesh_renderers_pool := engine.mesh_renderers(w)
	if mesh_renderers_pool != nil do for i in 0 ..< len(mesh_renderers_pool.slots) {
		slot := &mesh_renderers_pool.slots[i]
		if !slot.alive do continue
		mr := &slot.data
		if !mr.enabled do continue
		if !engine.transform_active_in_hierarchy(mr.owner) do continue
		_, mf := engine.transform_get_comp(engine.Transform_Handle(mr.owner), engine.MeshFilter)
		if mf == nil || mf.mesh == {} do continue
		mesh, ok := engine.mesh_load(mf.mesh, mf.part)
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

// Rubber-band counterpart of scene_view_pick: every enabled renderer (on an
// active-in-hierarchy transform) whose projected bounds intersect the
// viewport-pixel rect. Temp-allocated; duplicates are fine (sel_scene_add
// dedups).
scene_view_band_query :: proc(view: engine.Render_View, rmin, rmax: [2]f32) -> []engine.Transform_Handle {
	out := make([dynamic]engine.Transform_Handle, context.temp_allocator)
	w := engine.ctx_world()

	sprite_renderers_pool := engine.sprite_renderers(w)
	if sprite_renderers_pool != nil do for i in 0 ..< len(sprite_renderers_pool.slots) {
		slot := &sprite_renderers_pool.slots[i]
		if !slot.alive do continue
		sr := &slot.data
		if !sr.enabled || sr.texture == {} do continue
		if !engine.transform_active_in_hierarchy(sr.owner) do continue
		tex, ok := engine.texture_load(sr.texture)
		if !ok do continue
		tw := engine.transform_world(engine.Transform_Handle(sr.owner))
		c := engine.sprite_world_corners(tw, tex.width, tex.height)
		if _rect_hits_points(view, rmin, rmax, c[:]) {
			append(&out, engine.Transform_Handle(sr.owner))
		}
	}

	mesh_renderers_pool := engine.mesh_renderers(w)
	if mesh_renderers_pool != nil do for i in 0 ..< len(mesh_renderers_pool.slots) {
		slot := &mesh_renderers_pool.slots[i]
		if !slot.alive do continue
		mr := &slot.data
		if !mr.enabled do continue
		if !engine.transform_active_in_hierarchy(mr.owner) do continue
		_, mf := engine.transform_get_comp(engine.Transform_Handle(mr.owner), engine.MeshFilter)
		if mf == nil || mf.mesh == {} do continue
		mesh, ok := engine.mesh_load(mf.mesh, mf.part)
		if !ok do continue
		tw := engine.transform_world(engine.Transform_Handle(mr.owner))
		model := engine.trs_matrix(tw.position, tw.rotation, tw.scale)
		lo, hi := mesh.aabb_min, mesh.aabb_max
		corners: [8][3]f32
		for k in 0 ..< 8 {
			local := [4]f32{
				k & 1 == 0 ? lo.x : hi.x,
				k & 2 == 0 ? lo.y : hi.y,
				k & 4 == 0 ? lo.z : hi.z,
				1,
			}
			corners[k] = (model * local).xyz
		}
		if _rect_hits_points(view, rmin, rmax, corners[:]) {
			append(&out, engine.Transform_Handle(mr.owner))
		}
	}

	return out[:]
}

// Screen-space AABB of the projected points (behind-camera points are
// skipped) intersected with the rect. Cheap and Unity-close; a giant mesh
// whose projected box overlaps without any geometry inside can false-match —
// accepted.
@(private = "file")
_rect_hits_points :: proc(view: engine.Render_View, rmin, rmax: [2]f32, points: [][3]f32) -> bool {
	first := true
	pmin, pmax: [2]f32
	for p in points {
		px, ok := _gizmo_project(view, p)
		if !ok do continue
		if first {
			pmin, pmax = px, px
			first = false
		} else {
			pmin = {min(pmin.x, px.x), min(pmin.y, px.y)}
			pmax = {max(pmax.x, px.x), max(pmax.y, px.y)}
		}
	}
	if first do return false
	return pmin.x <= rmax.x && pmax.x >= rmin.x && pmin.y <= rmax.y && pmax.y >= rmin.y
}
