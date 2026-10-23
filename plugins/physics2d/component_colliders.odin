package physics2d

// Unity-literal 2D colliders. A collider attaches to the nearest ancestor
// Rigidbody2D (its own transform included) as a shape — Unity's compound-body
// rule — or, with no rigidbody anywhere above, to its own implicit STATIC
// body. Sizes are in world units (1 unit = 1 m = 100 px, plugins/engine/docs/FixedTick.md).
//
// Runtime ids are created by the fixed step and never serialized. Inspector
// edits don't live-sync (the editor doesn't simulate), except `layers` and
// `layer_overrides`: the fixed step pushes those into the live shape's filter. Runtime
// code mutates the rest through body_of(tH) + vendor:box2d.
//
// `layers` is the layers the collider is on, bits of this plugin's layer
// domain (layers.odin). The Physics 2D Layers asset the Physics 2D settings
// pick names the layers and holds the matrix of which pairs collide. What a
// collider collides with is that matrix plus its own and its rigidbody's
// `layer_overrides` (collision_mask).

import b2 "vendor:box2d"
import "moonhug:packages/engine"

@(component={menu="Physics2D/BoxCollider2D"})
@(typ_guid={guid = "1e2d0da1-9df6-4668-9f86-f76351378394"})
BoxCollider2D :: struct {
	using base:  engine.CompData `inspect:"-"`,
	size:        [2]f32,
	offset:      [2]f32,
	density:     f32,
	// How the surface slides and bounces (physics_material.odin). Unset is
	// the Rigidbody2D's material, then a new Physics Material 2D's defaults.
	material:    engine.Asset_GUID `ref:"PhysicsMaterial2D" expand`,
	is_trigger:  bool,
	layers:       u32 `decor:layers(domain="physics2d")`,
	using layer_overrides: Physics2D_Layer_Overrides `inline:""`,

	shape:       b2.ShapeId `json:"-" inspect:"-"`,
	static_body: b2.BodyId `json:"-" inspect:"-"`, // only when no ancestor RB
}

reset_BoxCollider2D :: proc(comp: ^BoxCollider2D) {
	cleanup_BoxCollider2D(comp)
	comp.layers = 1
	comp.size = {1, 1}
	comp.density = 1
}

// Every collider's cleanup runs on destroy, removal, Reset and undo: the
// shape and the implicit static body go with the component, or they keep
// colliding as ghosts.
cleanup_BoxCollider2D :: proc(comp: ^BoxCollider2D) {
	_destroy_shape(&comp.shape, &comp.static_body)
	engine.comp_zero(comp)
}

@(component={menu="Physics2D/CircleCollider2D"})
@(typ_guid={guid = "657711b4-6689-479e-9eec-da439658cadf"})
CircleCollider2D :: struct {
	using base:  engine.CompData `inspect:"-"`,
	radius:      f32,
	offset:      [2]f32,
	density:     f32,
	// How the surface slides and bounces (physics_material.odin). Unset is
	// the Rigidbody2D's material, then a new Physics Material 2D's defaults.
	material:    engine.Asset_GUID `ref:"PhysicsMaterial2D" expand`,
	is_trigger:  bool,
	layers:       u32 `decor:layers(domain="physics2d")`,
	using layer_overrides: Physics2D_Layer_Overrides `inline:""`,

	shape:       b2.ShapeId `json:"-" inspect:"-"`,
	static_body: b2.BodyId `json:"-" inspect:"-"`,
}

reset_CircleCollider2D :: proc(comp: ^CircleCollider2D) {
	cleanup_CircleCollider2D(comp)
	comp.layers = 1
	comp.radius = 0.5
	comp.density = 1
}

cleanup_CircleCollider2D :: proc(comp: ^CircleCollider2D) {
	_destroy_shape(&comp.shape, &comp.static_body)
	engine.comp_zero(comp)
}

Capsule_Direction :: enum {
	Vertical,
	Horizontal,
}

@(component={menu="Physics2D/CapsuleCollider2D"})
@(typ_guid={guid = "11cbe045-afe7-413a-837e-167ca23b7ca1"})
CapsuleCollider2D :: struct {
	using base:  engine.CompData `inspect:"-"`,
	size:        [2]f32, // width x height, like Unity
	direction:   Capsule_Direction,
	offset:      [2]f32,
	density:     f32,
	// How the surface slides and bounces (physics_material.odin). Unset is
	// the Rigidbody2D's material, then a new Physics Material 2D's defaults.
	material:    engine.Asset_GUID `ref:"PhysicsMaterial2D" expand`,
	is_trigger:  bool,
	layers:       u32 `decor:layers(domain="physics2d")`,
	using layer_overrides: Physics2D_Layer_Overrides `inline:""`,

	shape:       b2.ShapeId `json:"-" inspect:"-"`,
	static_body: b2.BodyId `json:"-" inspect:"-"`,
}

reset_CapsuleCollider2D :: proc(comp: ^CapsuleCollider2D) {
	cleanup_CapsuleCollider2D(comp)
	comp.layers = 1
	comp.size = {1, 2}
	comp.density = 1
}

cleanup_CapsuleCollider2D :: proc(comp: ^CapsuleCollider2D) {
	_destroy_shape(&comp.shape, &comp.static_body)
	engine.comp_zero(comp)
}

// Any simple polygon as a solid shape: a closed path of `points` in the
// collider's space, around `offset`. box2d collides convex polygons of at
// most 8 vertices, so the path is partitioned into such pieces
// (polygon.odin), one shape each on the body. A path that is not a simple
// polygon (self-intersecting, all on a line) builds nothing and says so in
// the log, until it is edited. Transform scale applies per axis.
@(component={menu="Physics2D/PolygonCollider2D"})
@(typ_guid={guid = "2db4c7a5-5189-4f3f-a96f-36f1b3c13b20"})
PolygonCollider2D :: struct {
	using base:  engine.CompData `inspect:"-"`,
	points:      [dynamic][2]f32,
	offset:      [2]f32,
	density:     f32,
	// How the surface slides and bounces (physics_material.odin). Unset is
	// the Rigidbody2D's material, then a new Physics Material 2D's defaults.
	material:    engine.Asset_GUID `ref:"PhysicsMaterial2D" expand`,
	is_trigger:  bool,
	layers:       u32 `decor:layers(domain="physics2d")`,
	using layer_overrides: Physics2D_Layer_Overrides `inline:""`,

	shapes:      [dynamic]b2.ShapeId `json:"-" inspect:"-"`, // one per convex piece
	static_body: b2.BodyId `json:"-" inspect:"-"`,
	// The sync logged why the shapes cannot be built and stops trying, until
	// a Reset or an undo write clears the component.
	build_failed: bool `json:"-" inspect:"-"`,
}

reset_PolygonCollider2D :: proc(comp: ^PolygonCollider2D) {
	cleanup_PolygonCollider2D(comp)
	comp.layers = 1
	comp.density = 1
	polygon_regular(&comp.points, 5, 0.5)
}

cleanup_PolygonCollider2D :: proc(comp: ^PolygonCollider2D) {
	_destroy_shapes(&comp.shapes, &comp.static_body)
	if comp.points != nil do delete(comp.points)
	engine.comp_zero(comp)
}

// An open line of `points` in the collider's space, around `offset`: ground
// outlines, as box2d's chain, smooth across its corners and one-sided. The
// solid side is to the right of the path's direction, so a floor's points
// run from right to left, and a body behind the line passes through it.
// The ends continue straight for a body sliding off them.
@(component={menu="Physics2D/EdgeCollider2D"})
@(typ_guid={guid = "d3835978-f15b-4a58-b33a-774f6a83daf4"})
EdgeCollider2D :: struct {
	using base:  engine.CompData `inspect:"-"`,
	points:      [dynamic][2]f32,
	offset:      [2]f32,
	// How the surface slides and bounces (physics_material.odin). Unset is
	// the Rigidbody2D's material, then a new Physics Material 2D's defaults.
	material:    engine.Asset_GUID `ref:"PhysicsMaterial2D" expand`,
	layers:       u32 `decor:layers(domain="physics2d")`,
	using layer_overrides: Physics2D_Layer_Overrides `inline:""`,

	chain:       b2.ChainId `json:"-" inspect:"-"`,
	segments:    [dynamic]b2.ShapeId `json:"-" inspect:"-"`, // the chain's segment shapes
	static_body: b2.BodyId `json:"-" inspect:"-"`,
}

reset_EdgeCollider2D :: proc(comp: ^EdgeCollider2D) {
	cleanup_EdgeCollider2D(comp)
	comp.layers = 1
	clear(&comp.points)
	append(&comp.points, [2]f32{-0.5, 0}, [2]f32{0.5, 0})
}

cleanup_EdgeCollider2D :: proc(comp: ^EdgeCollider2D) {
	_destroy_chain(&comp.chain, &comp.segments, &comp.static_body)
	if comp.points != nil do delete(comp.points)
	engine.comp_zero(comp)
}
