package scene_tools

// The engine's side of the shell's viewport (moonhug/editor/viewport): render,
// pick, frame and run the tools. Installed through @(provider_install).

import "core:math/linalg"
import "moonhug:editor/viewport"
import "moonhug:packages/engine"
import gfx "moonhug:host/gfx"

@(provider_install)
install_viewport_provider :: proc() {
	viewport.set_provider({
		render              = _vp_render,
		object_bounds       = _vp_object_bounds,
		pick                = scene_view_pick,
		pick_all            = _vp_pick_all,
		band_query          = scene_view_band_query,
		tools_frame         = scene_tools_frame,
		tools_consume_mouse = scene_tools_consume_mouse,
		tools_dragging      = scene_tools_dragging,
		tools_shutdown      = gizmo_shutdown,
		marks_rebuild       = gizmo_marks_rebuild,
		draw_gizmos         = draw_gizmos,
		game_view           = _vp_game_view,
		dirty               = _vp_dirty,
		render_game         = _vp_render_game,
		debug_draw          = _vp_debug_draw,
	})
}

@(private = "file")
_vp_render :: proc(view: engine.Render_View) {
	commands := make([dynamic]engine.Render_Command, 0, 64, context.temp_allocator)
	engine.render_collect_commands(view, &commands)
	engine.render_execute(view, commands[:])
}

@(private = "file")
_vp_pick_all :: proc(view: engine.Render_View, px, py: f32) -> []engine.Transform_Handle {
	hits := scene_view_pick_all(view, px, py)
	out := make([]engine.Transform_Handle, len(hits), context.temp_allocator)
	for h, i in hits do out[i] = h.tH
	return out
}

// The game camera's view at this size: the highest-order camera, the one the
// game view renders last.
@(private = "file")
_vp_game_view :: proc(width, height: f32) -> (engine.Render_View, bool) {
	cam := engine.camera_active()
	if cam == nil do return {}, false
	return engine.camera_render_view(cam, width, height), true
}

@(private = "file")
_vp_render_game :: proc(target: ^gfx.Render_Target) -> bool {
	had_camera := engine.camera_active() != nil
	engine.render_world_cameras(target)
	return had_camera
}

@(private = "file")
_vp_debug_draw :: proc() -> bool {
	return engine.debug_draw_enabled
}

@(private = "file")
_vp_dirty :: proc() -> bool {
	active := engine.sm_scene_get_active()
	return active != nil && active.dirty
}

// Framing bounds of one object, false when it no longer exists.
@(private = "file")
_vp_object_bounds :: proc(view: engine.Render_View, tH: engine.Transform_Handle) -> (center: [3]f32, radius: f32, ok: bool) {
	if !engine.pool_valid(&engine.ctx_world().transforms, engine.Handle(tH)) do return {}, 0, false
	center, radius = _selection_bounds(view, tH)
	return center, radius, true
}

// UI bounds: a Canvas frames its whole rect, a RectTransform its resolved
// corners in canvas (world) space — the Transform position of a UI node means
// nothing, so framing it would go to the origin.
@(private = "file")
_ui_bounds :: proc(tH: engine.Transform_Handle) -> (center: [3]f32, radius: f32, ok: bool) {
	corners: [4][3]f32
	if _, cv := engine.transform_get_comp(tH, engine.Canvas); cv != nil {
		root, xform, _ := engine.canvas_placement(tH, engine.canvas_game_viewport())
		corners = engine.rect_corners(root, xform)
	} else if _, rt := engine.transform_get_comp(tH, engine.RectTransform); rt != nil {
		canvas := engine.canvas_of(tH)
		if canvas == {} do return {}, 0, false
		nodes := make([dynamic]engine.Node_Rect, context.temp_allocator)
		engine.canvas_resolve_placed(canvas, &nodes)
		found := false
		for n in nodes {
			if n.tH == tH {
				corners = engine.rect_corners(n.rect, n.xform)
				found = true
				break
			}
		}
		if !found do return {}, 0, false
	} else {
		return {}, 0, false
	}
	lo, hi := corners[0], corners[0]
	for c in corners[1:] {
		lo = {min(lo.x, c.x), min(lo.y, c.y), min(lo.z, c.z)}
		hi = {max(hi.x, c.x), max(hi.y, c.y), max(hi.z, c.z)}
	}
	return (lo + hi) * 0.5, max(linalg.length(hi - lo) * 0.5, 0.1), true
}

// World bounds of a skinned mesh, for the selection shapes below.
//
// A skinned mesh is posed straight into WORLD space
// (component_SkinnedMeshRenderer.odin), so its box is axis-aligned and takes
// no model matrix. The MeshFilter path below is wrong for one twice over: the
// mesh aabb is the BIND pose in the rig's own space, and pushing it through
// the owner's transform makes a box that swings with the animated root while
// the character deforms independently inside it — which reads as a shaky box
// at a strange angle.
//
// nil when the renderer has never been skinned: there is no pose to bound yet,
// and the callers fall through to the shapes they already drew.
@(private = "file")
_skinned_world_aabb :: proc(tH: engine.Transform_Handle) -> (lo, hi: [3]f32, ok: bool) {
	_, smr := engine.transform_get_comp(tH, engine.SkinnedMeshRenderer)
	if smr == nil do return {}, {}, false
	return engine.skinned_mesh_world_bounds(smr)
}

// Bounding sphere of the selection: skinned mesh from its posed world bounds,
// mesh AABB through the world transform, the quads a package renderer draws
// in `view` (drawn_quads), or a default radius around the position
// (mirrors the shapes draw_selection_outline draws).
@(private = "file")
_selection_bounds :: proc(view: engine.Render_View, tH: engine.Transform_Handle) -> (center: [3]f32, radius: f32) {
	if c, r, ok := _ui_bounds(tH); ok do return c, r
	tw := engine.transform_world(tH)
	center = tw.position
	radius = 1.5

	vmin :: proc(a, b: [3]f32) -> [3]f32 {return {min(a.x, b.x), min(a.y, b.y), min(a.z, b.z)}}
	vmax :: proc(a, b: [3]f32) -> [3]f32 {return {max(a.x, b.x), max(a.y, b.y), max(a.z, b.z)}}

	// Before the MeshFilter branch: a skinned character carries both, and only
	// this one describes where it currently is.
	if lo, hi, ok := _skinned_world_aabb(tH); ok {
		center = (lo + hi) * 0.5
		radius = max(linalg.length(hi - lo) * 0.5, 0.1)
		return
	}

	_, mf := engine.transform_get_comp(tH, engine.MeshFilter)
	if mf != nil && mf.mesh != {} {
		if mesh, ok := engine.mesh_load_filter(mf); ok {
			model := engine.trs_matrix(tw.position, tw.rotation, tw.scale)
			lo, hi := mesh.aabb_min, mesh.aabb_max
			cmin, cmax: [3]f32
			for i in 0 ..< 8 {
				local := [4]f32{
					i & 1 == 0 ? lo.x : hi.x,
					i & 2 == 0 ? lo.y : hi.y,
					i & 4 == 0 ? lo.z : hi.z,
					1,
				}
				p := (model * local).xyz
				cmin = i == 0 ? p : vmin(cmin, p)
				cmax = i == 0 ? p : vmax(cmax, p)
			}
			center = (cmin + cmax) * 0.5
			radius = max(linalg.length(cmax - cmin) * 0.5, 0.1)
			return
		}
	}

	if n, _, lo, hi := owner_quads(tH, drawn_quads(view)); n > 0 {
		center = (lo + hi) * 0.5
		radius = max(linalg.length(hi - lo) * 0.5, 0.1)
	}
	return
}
