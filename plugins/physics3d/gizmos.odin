package physics3d

// Collider wireframes, shared by two callers: the editor's selected-object
// gizmos (packages/physics3d/editor delegates here) and the in-app debug
// view — the DebugDraw phase subscriber draws EVERY enabled collider when
// engine.debug_draw_enabled is on. Full 3D: shapes go through the owner's
// world position and rotation (scale ignored, matching the sync: the sizes
// are scaled already). Drawn through libs/gizmos.

import "base:runtime"
import b3 "vendor:box3d"
import "moonhug:packages/engine"
import "moonhug:libs/gizmos"

// Unity's collider gizmo green.
COLLIDER_GIZMO_COLOR :: [4]f32{0.57, 0.96, 0.55, 1}

draw_box_collider_wires :: proc(c: ^BoxCollider, color: [4]f32) {
	gizmos.with_color(color)
	gizmos.in_local_space(c.owner, use_scale = false)
	size, o := box_scaled(c, collider_scale(c.owner))
	gizmos.wire_box(o, size)
}

draw_sphere_collider_wires :: proc(c: ^SphereCollider, color: [4]f32) {
	gizmos.with_color(color)
	gizmos.in_local_space(c.owner, use_scale = false)
	radius, o := sphere_scaled(c, collider_scale(c.owner))
	gizmos.wire_sphere(o, radius)
}

draw_capsule_collider_wires :: proc(c: ^CapsuleCollider, color: [4]f32) {
	gizmos.with_color(color)
	gizmos.in_local_space(c.owner, use_scale = false)
	axis: [3]f32
	switch c.direction {
	case .X_Axis: axis = {1, 0, 0}
	case .Y_Axis: axis = {0, 1, 0}
	case .Z_Axis: axis = {0, 0, 1}
	}
	radius, height, o := capsule_scaled(c, collider_scale(c.owner))
	half := max(height * 0.5 - radius, 0)
	gizmos.wire_capsule(o - axis * half, o + axis * half, radius)
}

// A mesh collider in the owner's space with its scale, the way the shape is
// built: the edges of its hull or of each piece of its decomposition when
// convex, the mesh's triangles otherwise.
draw_mesh_collider_wires :: proc(c: ^MeshCollider, color: [4]f32) {
	ref, has := mesh_collider_ref(c)
	if !has do return
	gizmos.with_color(color)
	gizmos.in_local_space(c.owner)
	if c.convex && c.hulls.local_id != 0 {
		for e in _hull_wire(c.hulls, nil) do gizmos.line(e[0], e[1])
		return
	}
	geom, ok := engine.mesh_geometry_of(ref)
	if !ok do return
	if c.convex {
		for e in _hull_wire(ref, geom) do gizmos.line(e[0], e[1])
		return
	}
	for i := 0; i + 2 < len(geom.indices); i += 3 {
		a := geom.positions[geom.indices[i]]
		b := geom.positions[geom.indices[i + 1]]
		d := geom.positions[geom.indices[i + 2]]
		gizmos.line(a, b)
		gizmos.line(b, d)
		gizmos.line(d, a)
	}
}

// The edges of a mesh's hull, or of the hulls of a convex decomposition
// (a reference to the set, with no geometry), built once per reference the way the shapes build them
// and kept until the model is reimported. Mesh space, unscaled.
@(private = "file") _hull_wires: map[engine.PPtr][][2][3]f32

@(private = "file")
_hull_wire :: proc(ref: engine.PPtr, geom: ^engine.Mesh_Geometry) -> [][2][3]f32 {
	if edges, cached := _hull_wires[ref]; cached do return edges
	context.allocator = runtime.default_allocator()
	@(static) hooked := false
	if !hooked {
		hooked = true
		_hull_wires = make(map[engine.PPtr][][2][3]f32)
		engine.asset_pipeline_add_reimport_hook(_hull_wires_drop)
	}
	list := make([dynamic][2][3]f32)
	if geom == nil {
		// Nothing to draw until the editor has computed the set, and nothing
		// for a missing one, which builds no shape either.
		hulls, state := mesh_hulls(ref.guid, ref.local_id)
		if state != .Ready {
			delete(list)
			return nil
		}
		for points in hulls do _append_hull_edges(&list, points)
	} else {
		_append_hull_edges(&list, geom.positions)
	}
	_hull_wires[ref] = list[:]
	return list[:]
}

@(private = "file")
_append_hull_edges :: proc(list: ^[dynamic][2][3]f32, points: [][3]f32) {
	hull := b3.CreateHull(raw_data(points), i32(len(points)), HULL_MAX_VERTICES)
	if hull == nil do return
	defer b3.DestroyHull(hull)
	base := uintptr(hull)
	verts := ([^][3]f32)(base + uintptr(hull.pointOffset))
	half_edges := ([^]b3.HullHalfEdge)(base + uintptr(hull.edgeOffset))
	for i in 0 ..< hull.edgeCount {
		e := half_edges[i]
		if int(e.twin) < int(i) do continue // each edge once
		append(list, [2][3]f32{verts[e.origin], verts[half_edges[e.twin].origin]})
	}
}

// A reimport rewrites the model, so its hulls go with the mesh cache.
@(private = "file")
_hull_wires_drop :: proc(guid: engine.Asset_GUID) {
	context.allocator = runtime.default_allocator()
	keys := make([dynamic]engine.PPtr, context.temp_allocator)
	for key in _hull_wires do if key.guid == guid do append(&keys, key)
	for key in keys {
		delete(_hull_wires[key])
		delete_key(&_hull_wires, key)
	}
}

// Every enabled collider as a wireframe (Unity's Physics Debug view, there is
// no selection in the app).
@(phase={key=DebugDraw, mode=App})
debug_draw :: proc() {
	w := engine.ctx_world()
	it := engine.pool_iterator(box_colliders(w))
	for c, _ in engine.pool_next(&it) {
		if c.enabled do draw_box_collider_wires(c, COLLIDER_GIZMO_COLOR)
	}
	it2 := engine.pool_iterator(sphere_colliders(w))
	for c, _ in engine.pool_next(&it2) {
		if c.enabled do draw_sphere_collider_wires(c, COLLIDER_GIZMO_COLOR)
	}
	it3 := engine.pool_iterator(capsule_colliders(w))
	for c, _ in engine.pool_next(&it3) {
		if c.enabled do draw_capsule_collider_wires(c, COLLIDER_GIZMO_COLOR)
	}
	it4 := engine.pool_iterator(mesh_colliders(w))
	for c, _ in engine.pool_next(&it4) {
		if c.enabled do draw_mesh_collider_wires(c, COLLIDER_GIZMO_COLOR)
	}
}
