package physics2d

// Unity-literal 2D colliders. A collider attaches to the nearest ancestor
// Rigidbody2D (its own transform included) as a shape — Unity's compound-body
// rule — or, with no rigidbody anywhere above, to its own implicit STATIC
// body. Sizes are in world units (1 unit = 1 m = 100 px, plugins/engine/docs/FixedTick.md).
//
// Runtime ids are created by the fixed step and never serialized. Inspector
// edits don't live-sync (the editor doesn't simulate), except `layers` and
// `mask`: the fixed step pushes those into the live shape's filter. Runtime
// code mutates the rest through body_of(tH) + vendor:box2d.
//
// `layers` is the layers the collider is on and `mask` the layers it collides
// with, bits of the engine's "physics" domain: one list of collision layer
// names for the 2D and the 3D colliders, from the project's Physics Layers asset
// (plugins/engine/docs/Layers.md). Two shapes collide when
// (a.layers & b.mask) != 0 && (b.layers & a.mask) != 0.

import b2 "vendor:box2d"
import "moonhug:packages/engine"

@(component={menu="Physics2D/BoxCollider2D"})
@(typ_guid={guid = "1e2d0da1-9df6-4668-9f86-f76351378394"})
BoxCollider2D :: struct {
	using base:  engine.CompData `inspect:"-"`,
	size:        [2]f32,
	offset:      [2]f32,
	density:     f32,
	friction:    f32,
	bounciness:  f32,
	is_trigger:  bool,
	layers:       u32 `decor:layers(domain="physics")`,
	mask:        u32 `decor:layers(domain="physics")`,

	shape:       b2.ShapeId `json:"-" inspect:"-"`,
	static_body: b2.BodyId `json:"-" inspect:"-"`, // only when no ancestor RB
}

reset_BoxCollider2D :: proc(comp: ^BoxCollider2D) {
	cleanup_BoxCollider2D(comp)
	comp.layers = 1
	comp.mask = ~u32(0)
	comp.size = {1, 1}
	comp.density = 1
	comp.friction = 0.6
}

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
	friction:    f32,
	bounciness:  f32,
	is_trigger:  bool,
	layers:       u32 `decor:layers(domain="physics")`,
	mask:        u32 `decor:layers(domain="physics")`,

	shape:       b2.ShapeId `json:"-" inspect:"-"`,
	static_body: b2.BodyId `json:"-" inspect:"-"`,
}

reset_CircleCollider2D :: proc(comp: ^CircleCollider2D) {
	cleanup_CircleCollider2D(comp)
	comp.layers = 1
	comp.mask = ~u32(0)
	comp.radius = 0.5
	comp.density = 1
	comp.friction = 0.6
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
	friction:    f32,
	bounciness:  f32,
	is_trigger:  bool,
	layers:       u32 `decor:layers(domain="physics")`,
	mask:        u32 `decor:layers(domain="physics")`,

	shape:       b2.ShapeId `json:"-" inspect:"-"`,
	static_body: b2.BodyId `json:"-" inspect:"-"`,
}

reset_CapsuleCollider2D :: proc(comp: ^CapsuleCollider2D) {
	cleanup_CapsuleCollider2D(comp)
	comp.layers = 1
	comp.mask = ~u32(0)
	comp.size = {1, 2}
	comp.density = 1
	comp.friction = 0.6
}

cleanup_CapsuleCollider2D :: proc(comp: ^CapsuleCollider2D) {
	_destroy_shape(&comp.shape, &comp.static_body)
	engine.comp_zero(comp)
}

// Live destroys (transform_destroy_components) — shapes and implicit static
// bodies must die with their components or they keep colliding as ghosts.
on_destroy_BoxCollider2D :: proc(comp: ^BoxCollider2D) {
	_destroy_shape(&comp.shape, &comp.static_body)
}

on_destroy_CircleCollider2D :: proc(comp: ^CircleCollider2D) {
	_destroy_shape(&comp.shape, &comp.static_body)
}

on_destroy_CapsuleCollider2D :: proc(comp: ^CapsuleCollider2D) {
	_destroy_shape(&comp.shape, &comp.static_body)
}
