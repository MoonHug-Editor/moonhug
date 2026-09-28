package editor

// Scene-view click picking (docs/SDL3Renderer.md #7). CPU tests — the quads
// package renderers draw (sprites, particles: the render commands the scene
// view collects, so the SAME corners the renderer draws), meshes against
// their import-time AABB in local space, skinned meshes against the world
// bounds of the pose they last drew. Nearest hit wins. The editor ignores
// render layer masks — you can pick anything you can see.
//
// Each renderer is tested the way it is DRAWN. That is the rule that matters:
// a skinned mesh draws posed world vertices under an identity model, so a
// local-space test against its bind pose looks for it where its rig was
// authored rather than where it is on screen.

import "core:math/linalg"
import "core:slice"
import "../engine"
import "moonhug:editor/handles"
import "moonhug:engine/gizmos"

// Every quad `view` draws (temp): what the package renderers registered with
// engine.render_register_collector draw, and UI graphics. Meshes are left
// out: the callers test those from their components, and collecting a skinned
// mesh would pose it before this frame's edits.
Drawn_Quads :: struct {
	all:      []engine.Render_Command,
	by_owner: map[engine.Transform_Handle][dynamic]int, // indices into `all`
}

drawn_quads :: proc(view: engine.Render_View) -> Drawn_Quads {
	cmds := make([dynamic]engine.Render_Command, 0, 64, context.temp_allocator)
	engine.render_collect_commands(view, &cmds, meshes = false)
	out := Drawn_Quads{by_owner = make(map[engine.Transform_Handle][dynamic]int, context.temp_allocator)}
	n := 0
	for c in cmds {
		if _, is_quad := c.variant.(engine.Draw_Quad); !is_quad do continue
		cmds[n] = c
		list, has := &out.by_owner[c.owner]
		if !has {
			out.by_owner[c.owner] = make([dynamic]int, context.temp_allocator)
			list = &out.by_owner[c.owner]
		}
		append(list, n)
		n += 1
	}
	out.all = cmds[:n]
	return out
}

// One object under the pointer.
Scene_Hit :: struct {
	tH: engine.Transform_Handle,
	t:  f32, // along the ray
}

// The object under the pointer: the first of scene_view_pick_all. px, py in
// viewport pixels relative to the scene image's top-left.
scene_view_pick :: proc(view: engine.Render_View, px, py: f32) -> (engine.Transform_Handle, bool) {
	hits := scene_view_pick_all(view, px, py)
	if len(hits) == 0 do return {}, false
	return hits[0].tH, true
}

// Every object under the pointer, nearest first, each once (temp): a click
// takes the first, the pick menu (Cmd + right-click) lists them all. Scene
// icons (handles.icon) draw over everything, so they come before any
// geometry, nearest icon first.
scene_view_pick_all :: proc(view: engine.Render_View, px, py: f32) -> []Scene_Hit {
	ray := engine.render_view_screen_ray(view, px, py)
	w := engine.ctx_world()
	icons := make([dynamic]Scene_Hit, context.temp_allocator)
	geo := make([dynamic]Scene_Hit, context.temp_allocator)

	for ic in gizmos.icons(scene_gizmo_channels()) {
		sp, ok := gizmos.helper_project_in(view, ic.pos)
		if !ok || linalg.length(sp - [2]f32{px, py}) > ic.px * 0.5 do continue
		append(&icons, Scene_Hit{ic.owner, linalg.dot(ic.pos - ray.origin, ray.direction)})
	}

	for c in drawn_quads(view).all {
		q := c.variant.(engine.Draw_Quad)
		for tri in ([2][3]int{{0, 1, 2}, {0, 2, 3}}) {
			if t, hit := engine.ray_hit_triangle(ray, q.corners[tri[0]], q.corners[tri[1]], q.corners[tri[2]]); hit {
				append(&geo, Scene_Hit{c.owner, t})
			}
		}
	}

	mr_it := engine.pool_iterator(engine.mesh_renderers(w))
	for mr, _ in engine.pool_next(&mr_it) {
		if !mr.enabled do continue
		if !engine.transform_active_in_hierarchy(mr.owner) do continue
		_, mf := engine.transform_get_comp(engine.Transform_Handle(mr.owner), engine.MeshFilter)
		if mf == nil || mf.mesh == {} do continue
		mesh, ok := engine.mesh_load_filter(mf)
		if !ok do continue

		// Ray into local space (direction NOT renormalized so t stays
		// comparable with world-space hits).
		tw := engine.transform_world(engine.Transform_Handle(mr.owner))
		inv := linalg.inverse(engine.trs_matrix(tw.position, tw.rotation, tw.scale))
		local_o := inv * [4]f32{ray.origin.x, ray.origin.y, ray.origin.z, 1}
		local_d := inv * [4]f32{ray.direction.x, ray.direction.y, ray.direction.z, 0}
		local_ray := engine.Ray{origin = local_o.xyz, direction = local_d.xyz}

		if t, hit := engine.ray_hit_aabb(local_ray, mesh.aabb_min, mesh.aabb_max); hit {
			append(&geo, Scene_Hit{engine.Transform_Handle(mr.owner), t})
		}
	}

	// Skinned meshes test their POSED world bounds. Their mesh aabb is the bind
	// pose in the skeleton's own space, so the transform-relative test above
	// would look for a character wherever its rig was authored — which is why
	// clicking one selected nothing.
	smr_it := engine.pool_iterator(engine.skinned_mesh_renderers(w))
	for smr, _ in engine.pool_next(&smr_it) {
		if !smr.enabled do continue
		if !engine.transform_active_in_hierarchy(smr.owner) do continue
		lo, hi, ok := engine.skinned_mesh_world_bounds(smr)
		if !ok do continue
		if t, hit := engine.ray_hit_aabb(ray, lo, hi); hit {
			append(&geo, Scene_Hit{engine.Transform_Handle(smr.owner), t})
		}
	}

	// UI: every drawn graphic's rect where the canvas sits, the same set box
	// select takes (any graphic a package registers).
	nodes := make([dynamic]engine.Node_Rect, context.temp_allocator)
	cv_it := engine.pool_iterator(engine.canvases(w))
	for canvas, _ in engine.pool_next(&cv_it) {
		if !canvas.enabled || !engine.transform_active_in_hierarchy(canvas.owner) do continue
		clear(&nodes)
		engine.canvas_resolve_placed(canvas.owner, &nodes)
		for n in nodes {
			_, cr := engine.transform_get_comp(n.tH, engine.CanvasRenderer)
			if cr == nil || !cr.enabled do continue
			if _, _, _, ok := engine.node_graphic(n.tH); !ok do continue
			c := engine.rect_corners(n.rect, n.xform)
			for tri in ([2][3]int{{0, 1, 2}, {0, 2, 3}}) {
				if t, hit := engine.ray_hit_triangle(ray, c[tri[0]], c[tri[1]], c[tri[2]]); hit {
					append(&geo, Scene_Hit{n.tH, t})
				}
			}
		}
	}

	// Package shapes (handles.pick_register).
	for provider in handles.pick_providers() {
		if tH, t, ok := provider.click(view, ray); ok do append(&geo, Scene_Hit{tH, t})
	}

	nearest_first :: proc(a, b: Scene_Hit) -> bool { return a.t < b.t }
	slice.sort_by(icons[:], nearest_first)
	slice.sort_by(geo[:], nearest_first)
	out := make([dynamic]Scene_Hit, 0, len(icons) + len(geo), context.temp_allocator)
	for h in icons do _add_hit(&out, h)
	for h in geo do _add_hit(&out, h)
	return out[:]
}

// Appends `h` unless its object is listed: an object hit twice (both
// triangles of a quad, a mesh and its icon) is one entry, at its first place.
@(private = "file")
_add_hit :: proc(out: ^[dynamic]Scene_Hit, h: Scene_Hit) {
	for have in out do if have.tH == h.tH do return
	append(out, h)
}

// Rubber-band counterpart of scene_view_pick: every enabled renderer (on an
// active-in-hierarchy transform) whose projected bounds intersect the
// viewport-pixel rect. Temp-allocated; duplicates are fine (sel_scene_add
// dedups).
scene_view_band_query :: proc(view: engine.Render_View, rmin, rmax: [2]f32) -> []engine.Transform_Handle {
	out := make([dynamic]engine.Transform_Handle, context.temp_allocator)
	w := engine.ctx_world()

	for c in drawn_quads(view).all {
		q := c.variant.(engine.Draw_Quad)
		if _rect_hits_points(view, rmin, rmax, q.corners[:]) do append(&out, c.owner)
	}

	// UI: every drawn graphic's rect, where the canvas sits (all render modes).
	nodes := make([dynamic]engine.Node_Rect, context.temp_allocator)
	cv_it := engine.pool_iterator(engine.canvases(w))
	for canvas, _ in engine.pool_next(&cv_it) {
		if !canvas.enabled || !engine.transform_active_in_hierarchy(canvas.owner) do continue
		clear(&nodes)
		engine.canvas_resolve_placed(canvas.owner, &nodes)
		for n in nodes {
			_, cr := engine.transform_get_comp(n.tH, engine.CanvasRenderer)
			if cr == nil || !cr.enabled do continue
			if _, _, _, ok := engine.node_graphic(n.tH); !ok do continue
			c := engine.rect_corners(n.rect, n.xform)
			if _rect_hits_points(view, rmin, rmax, c[:]) do append(&out, n.tH)
		}
	}

	mr_it := engine.pool_iterator(engine.mesh_renderers(w))
	for mr, _ in engine.pool_next(&mr_it) {
		if !mr.enabled do continue
		if !engine.transform_active_in_hierarchy(mr.owner) do continue
		_, mf := engine.transform_get_comp(engine.Transform_Handle(mr.owner), engine.MeshFilter)
		if mf == nil || mf.mesh == {} do continue
		mesh, ok := engine.mesh_load_filter(mf)
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

	// Skinned meshes: their posed bounds are already world-space, so unlike the
	// mesh renderers above there is no model matrix to push the corners through.
	smr_it := engine.pool_iterator(engine.skinned_mesh_renderers(w))
	for smr, _ in engine.pool_next(&smr_it) {
		if !smr.enabled do continue
		if !engine.transform_active_in_hierarchy(smr.owner) do continue
		lo, hi, ok := engine.skinned_mesh_world_bounds(smr)
		if !ok do continue
		corners: [8][3]f32
		for k in 0 ..< 8 {
			corners[k] = {
				k & 1 == 0 ? lo.x : hi.x,
				k & 2 == 0 ? lo.y : hi.y,
				k & 4 == 0 ? lo.z : hi.z,
			}
		}
		if _rect_hits_points(view, rmin, rmax, corners[:]) {
			append(&out, engine.Transform_Handle(smr.owner))
		}
	}

	// Scene icons: the icon's center inside the rect.
	for ic in gizmos.icons(scene_gizmo_channels()) {
		sp, ok := gizmos.helper_project_in(view, ic.pos)
		if ok && sp.x >= rmin.x && sp.x <= rmax.x && sp.y >= rmin.y && sp.y <= rmax.y do append(&out, ic.owner)
	}

	// Package shapes (handles.pick_register).
	for provider in handles.pick_providers() do provider.band(view, rmin, rmax, &out)

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
		px, ok := gizmos.helper_project_in(view, p)
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
