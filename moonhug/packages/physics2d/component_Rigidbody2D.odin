package physics2d

// Unity-literal Rigidbody2D: authored as plain data (inspector/serialization
// come from the attributes), synced to a box2d body by the fixed step. The
// live b2 body id is runtime-only — for anything not wrapped here (forces,
// joints, filters) use body_of(tH) and vendor:box2d directly.

import b2 "vendor:box2d"
import "moonhug:engine"

// Unity's order (Dynamic is the default zero value).
Body_Type :: enum {
	Dynamic,
	Kinematic,
	Static,
}

@(component={menu="Physics2D/Rigidbody2D"})
@(typ_guid={guid = "add56122-a3b9-4fcb-a924-0fa64b35d523"})
Rigidbody2D :: struct {
	using base:      engine.CompData `inspect:"-"`,
	body_type:       Body_Type,
	gravity_scale:   f32,
	linear_damping:  f32,
	angular_damping: f32,
	fixed_rotation:  bool,
	continuous:      bool, // continuous collision detection (box2d bullet)

	body: b2.BodyId `json:"-" inspect:"-"`,
}

reset_Rigidbody2D :: proc(comp: ^Rigidbody2D) {
	comp.gravity_scale = 1
}

cleanup_Rigidbody2D :: proc(comp: ^Rigidbody2D) {
	_destroy_body(&comp.body)
	engine.comp_zero(comp)
}

// Live destroy (transform_destroy_components) — the body must die with the
// component or it keeps colliding as a ghost.
on_destroy_Rigidbody2D :: proc(comp: ^Rigidbody2D) {
	_destroy_body(&comp.body)
}
