package scene_tools

// The selection outline the gizmo pass draws on every selected object, and
// owner_quads, the per-object view of drawn_quads it shares with the scene
// view's framing.

import "core:math/linalg"
import "moonhug:packages/engine"
import "moonhug:host/gizmos"

// Orange wireframe on the selected object: mesh → its local AABB edges
// through the world transform; a package renderer → the quad it draws (a
// sprite), or the box around its quads when it draws several (particles);
// neither → a small axis cross at the position. `quads` is drawn_quads.
// A UI node gets the cross: its rect is its selection shape, and the rect
// tool draws that.
//
// A SKINNED mesh deliberately gets no box. Its mesh aabb is the bind pose in
// the rig's own space, so the box below swings with the animated root while
// the character deforms independently inside it. The box is a stand-in for a
// silhouette outline, which is what an editor draws here when it can, and a
// box at the wrong angle is further from that than nothing — the transform
// gizmo and the axis cross still mark the selection. The scene view's
// framing uses the posed world bounds, so framing the selection still frames
// the character where it actually is.
draw_selection_outline :: proc(tH: engine.Transform_Handle, quads: Drawn_Quads) {
	gizmos.with_color({1, 0.6, 0.1, 1})
	tw := engine.transform_world(tH)

	_, skinned := engine.transform_get_comp(tH, engine.SkinnedMeshRenderer)

	_, mf := engine.transform_get_comp(tH, engine.MeshFilter)
	if skinned == nil && mf != nil && mf.mesh != {} {
		if mesh, ok := engine.mesh_load_filter(mf); ok {
			gizmos.in_local_space(tH)
			lo, hi := mesh.aabb_min, mesh.aabb_max
			gizmos.wire_box((lo + hi) * 0.5, hi - lo)
			return
		}
	}

	if _, rt := engine.transform_get_comp(tH, engine.RectTransform); rt == nil {
		n, first, lo, hi := owner_quads(tH, quads)
		if n == 1 {
			gizmos.wire_quad(first)
			return
		}
		if n > 1 {
			gizmos.wire_box((lo + hi) * 0.5, hi - lo)
			return
		}
	}

	gizmos.line_cross(tw.position, 0.8)
}

// The quads `tH`'s own renderers draw, from drawn_quads: how many, the
// first, and the world box around all of them.
owner_quads :: proc(tH: engine.Transform_Handle, quads: Drawn_Quads) -> (count: int, first: [4][3]f32, lo, hi: [3]f32) {
	for i in quads.by_owner[tH] or_else nil {
		q := quads.all[i].variant.(engine.Draw_Quad)
		if count == 0 {
			first = q.corners
			lo, hi = q.corners[0], q.corners[0]
		}
		for p in q.corners {
			lo = linalg.min(lo, p)
			hi = linalg.max(hi, p)
		}
		count += 1
	}
	return
}
