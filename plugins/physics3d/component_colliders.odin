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
	friction:    f32,
	bounciness:  f32,
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
	comp.friction = 0.6
}

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
	friction:    f32,
	bounciness:  f32,
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
	comp.friction = 0.6
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
	friction:    f32,
	bounciness:  f32,
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
	comp.friction = 0.6
}

cleanup_CapsuleCollider :: proc(comp: ^CapsuleCollider) {
	_destroy_shape(&comp.shape, &comp.static_body)
	engine.comp_zero(comp)
}

// Live destroys (transform_destroy_components) — shapes and implicit static
// bodies must die with their components or they keep colliding as ghosts.
@(comp_on_destroy={component=BoxCollider})
comp_on_destroy_BoxCollider :: proc(comp: ^BoxCollider) {
	_destroy_shape(&comp.shape, &comp.static_body)
}

@(comp_on_destroy={component=SphereCollider})
comp_on_destroy_SphereCollider :: proc(comp: ^SphereCollider) {
	_destroy_shape(&comp.shape, &comp.static_body)
}

@(comp_on_destroy={component=CapsuleCollider})
comp_on_destroy_CapsuleCollider :: proc(comp: ^CapsuleCollider) {
	_destroy_shape(&comp.shape, &comp.static_body)
}
