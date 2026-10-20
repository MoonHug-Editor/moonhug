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
