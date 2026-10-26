package physics3d

// Unity-literal 3D colliders. A collider attaches to the nearest ancestor
// Rigidbody (its own transform included) as a shape — Unity's compound-body
// rule — or, with no rigidbody anywhere above, to its own implicit STATIC
// body. Sizes are in world units (1 unit = 1 m).
//
// Runtime ids are created by the fixed step and never serialized. Inspector
// edits don't live-sync (the editor doesn't simulate), except `layers` and
// `layer_overrides`: the fixed step pushes those into the live shape's filter. Runtime
// code mutates the rest through body_of(tH) + vendor:box3d.
//
// `layers` is the layers the collider is on, bits of this plugin's layer
// domain (layers.odin). The Physics 3D Layers asset the Physics 3D settings
// pick names the layers and holds the matrix of which pairs collide. What a
// collider collides with is that matrix plus its own and its rigidbody's
// `layer_overrides` (collision_mask).

import b3 "vendor:box3d"
import "moonhug:packages/engine"

@(component={menu="Physics/BoxCollider"})
@(typ_guid={guid = "13101cd5-e0a6-49d4-a310-953001ebae6b"})
BoxCollider :: struct {
	using base:  engine.CompData `inspect:"-"`,
	size:        [3]f32,
	center:      [3]f32,
	density:     f32,
	// How the surface slides and bounces (physics_material.odin). Unset is a
	// new Physics Material's defaults.
	material:    engine.Asset_GUID `ref:"PhysicsMaterial" expand`,
	is_trigger:  bool,
	layers:       u32 `decor:layers(domain="physics3d")`,
	using layer_overrides: Physics3D_Layer_Overrides `inline:""`,

	shape:       b3.ShapeId `json:"-" inspect:"-"`,
	static_body: b3.BodyId `json:"-" inspect:"-"`, // only when no ancestor RB
}

reset_BoxCollider :: proc(comp: ^BoxCollider) {
	cleanup_BoxCollider(comp)
	comp.layers = 1
	comp.size = {1, 1, 1}
	comp.density = 1
}

// Every collider's cleanup runs on destroy, removal, Reset and undo: the
// shape and the implicit static body go with the component, or they keep
// colliding as ghosts.
cleanup_BoxCollider :: proc(comp: ^BoxCollider) {
	_destroy_shape(&comp.shape, &comp.static_body)
	engine.comp_zero(comp)
}

@(component={menu="Physics/SphereCollider"})
@(typ_guid={guid = "8295fbf3-a792-4f02-9bea-b63fc056b99f"})
SphereCollider :: struct {
	using base:  engine.CompData `inspect:"-"`,
	radius:      f32,
	center:      [3]f32,
	density:     f32,
	// How the surface slides and bounces (physics_material.odin). Unset is a
	// new Physics Material's defaults.
	material:    engine.Asset_GUID `ref:"PhysicsMaterial" expand`,
	is_trigger:  bool,
	layers:       u32 `decor:layers(domain="physics3d")`,
	using layer_overrides: Physics3D_Layer_Overrides `inline:""`,

	shape:       b3.ShapeId `json:"-" inspect:"-"`,
	static_body: b3.BodyId `json:"-" inspect:"-"`,
}

reset_SphereCollider :: proc(comp: ^SphereCollider) {
	cleanup_SphereCollider(comp)
	comp.layers = 1
	comp.radius = 0.5
	comp.density = 1
}

cleanup_SphereCollider :: proc(comp: ^SphereCollider) {
	_destroy_shape(&comp.shape, &comp.static_body)
	engine.comp_zero(comp)
}

// Unity's capsule axis.
Capsule_Direction :: enum {
	X_Axis,
	Y_Axis,
	Z_Axis,
}

@(component={menu="Physics/CapsuleCollider"})
@(typ_guid={guid = "91ddc047-6a91-4142-bc9c-d219570192b6"})
CapsuleCollider :: struct {
	using base:  engine.CompData `inspect:"-"`,
	radius:      f32,
	height:      f32, // total, caps included (Unity)
	direction:   Capsule_Direction,
	center:      [3]f32,
	density:     f32,
	// How the surface slides and bounces (physics_material.odin). Unset is a
	// new Physics Material's defaults.
	material:    engine.Asset_GUID `ref:"PhysicsMaterial" expand`,
	is_trigger:  bool,
	layers:       u32 `decor:layers(domain="physics3d")`,
	using layer_overrides: Physics3D_Layer_Overrides `inline:""`,

	shape:       b3.ShapeId `json:"-" inspect:"-"`,
	static_body: b3.BodyId `json:"-" inspect:"-"`,
}

reset_CapsuleCollider :: proc(comp: ^CapsuleCollider) {
	cleanup_CapsuleCollider(comp)
	comp.layers = 1
	comp.radius = 0.5
	comp.height = 2
	comp.direction = .Y_Axis
	comp.density = 1
}

cleanup_CapsuleCollider :: proc(comp: ^CapsuleCollider) {
	_destroy_shape(&comp.shape, &comp.static_body)
	engine.comp_zero(comp)
}

// The mesh's own shape. `mesh` names a model or one of its parts the way a
// MeshFilter does, and unset means the MeshFilter on the same object.
// `convex` builds the convex hull of the vertices, reduced to the most box3d
// holds (HULL_MAX_VERTICES): the shape a Rigidbody can carry. A convex
// collider can take one of its model's convex decompositions for that mesh
// instead (`hulls`, PPtr{model guid, engine.Mesh_Hull_Set id}, mesh_hulls.odin):
// several hulls that follow a concave shape, one hull shape each. The set
// must be of the collider's mesh, since the hulls are in that mesh's space. Not convex, the
// triangles collide as they are, which box3d allows on a static body only,
// so it needs no Rigidbody above it. Transform scale applies per axis.
@(component={menu="Physics/MeshCollider"})
@(typ_guid={guid = "d6e5cf75-88a6-45e3-ac22-93aaa6b21a05"})
MeshCollider :: struct {
	using base:  engine.CompData `inspect:"-"`,
	// Drawn by the editor as the Mesh row and the Hulls dropdown.
	mesh:        engine.PPtr `inspect:"-"`,
	hulls:       engine.PPtr `inspect:"-"`,
	convex:      bool `decor:tooltip(desc="Collide as a convex shape, the only kind a Rigidbody can carry: the convex hull of the mesh, or one of its model's convex decompositions picked in Hulls. Off, the triangles collide as they are, on a collider without a Rigidbody only.")`,
	density:     f32 `decor:tooltip(desc="Weight of this collider against the others on the same Rigidbody, in kilograms per cubic metre. The Rigidbody's Mass is the total: density shares it among its colliders, which places the center of mass and sets how the body turns. No effect with one collider or without a Rigidbody.")`,
	// How the surface slides and bounces (physics_material.odin). Unset is a
	// new Physics Material's defaults.
	material:    engine.Asset_GUID `ref:"PhysicsMaterial" expand decor:tooltip(desc="How the surface slides and bounces. None uses the Default Material of the Physics 3D settings.")`,
	is_trigger:  bool `decor:tooltip(desc="Report overlaps instead of colliding: bodies pass through, and the trigger events fire.")`,
	layers:       u32 `decor:layers(domain="physics3d") decor:tooltip(desc="The physics layers this collider is on. The Physics 3D layer matrix says which layers collide.")`,
	using layer_overrides: Physics3D_Layer_Overrides `inline:""`,

	shape:       b3.ShapeId `json:"-" inspect:"-"`,
	static_body: b3.BodyId `json:"-" inspect:"-"`,
	// One hull shape per hull of the decomposition, `shape` unused.
	shapes:      [dynamic]b3.ShapeId `json:"-" inspect:"-"`,
	// The triangles a non-convex shape reads for as long as it lives, owned:
	// one mesh, or a compound of mesh chunks (MESH_CHUNK_TRIANGLES).
	mesh_data:   ^b3.MeshData `json:"-" inspect:"-"`,
	compound:    ^b3.CompoundData `json:"-" inspect:"-"`,
	// The surface the compound's chunks were built with: box3d keeps it in
	// each child, where it cannot change, so a material edit rebuilds them.
	compound_material: b3.SurfaceMaterial `json:"-" inspect:"-"`,
	// The sync logged why the shape cannot be built and stops trying, until
	// a Reset or an undo write clears the component.
	build_failed: bool `json:"-" inspect:"-"`,
}

reset_MeshCollider :: proc(comp: ^MeshCollider) {
	cleanup_MeshCollider(comp)
	comp.layers = 1
	comp.density = 1
}

cleanup_MeshCollider :: proc(comp: ^MeshCollider) {
	for &s in comp.shapes {
		no_body: b3.BodyId // the static body goes once, with `shape` below
		_destroy_shape(&s, &no_body)
	}
	delete(comp.shapes)
	_destroy_shape(&comp.shape, &comp.static_body)
	if comp.mesh_data != nil do b3.DestroyMesh(comp.mesh_data)
	if comp.compound != nil do b3.DestroyCompound(comp.compound)
	engine.comp_zero(comp)
}

// The mesh a MeshCollider collides as: its own, else the MeshFilter's on the
// same object. ok=false when neither names one.
mesh_collider_ref :: proc(c: ^MeshCollider) -> (engine.PPtr, bool) {
	if !engine.asset_guid_is_empty(c.mesh.guid) do return c.mesh, true
	if _, mf := engine.transform_get_comp(c.owner, engine.MeshFilter); mf != nil && !engine.asset_guid_is_empty(mf.mesh.guid) {
		return mf.mesh, true
	}
	return {}, false
}
