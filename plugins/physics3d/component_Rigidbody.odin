package physics3d

// Unity-literal Rigidbody (3D): authored as plain data, synced to a box3d
// body by the fixed step. Unity's 3D model — no body-type enum: a collider
// WITHOUT a Rigidbody is static, is_kinematic switches dynamic/kinematic.
// The live b3 body id is runtime-only — for anything not wrapped here
// (forces, joints, mass overrides) use body_of(tH) and vendor:box3d.

import b3 "vendor:box3d"
import "moonhug:packages/engine"

@(component={menu="Physics/Rigidbody"})
@(typ_guid={guid = "82976d39-c450-4464-87e2-c260c430c157"})
Rigidbody :: struct {
	using base:      engine.CompData `inspect:"-"`,
	use_gravity:     bool,
	is_kinematic:    bool,
	linear_damping:  f32,
	angular_damping: f32,
	continuous:      bool, // continuous collision detection (box3d bullet)
	freeze_position: [3]bool,
	freeze_rotation: [3]bool,

	// Collides with these layers besides the collision matrix, or never,
	// for every collider attached to this body.
	using layer_overrides: Physics3D_Layer_Overrides `inline:""`,

	body: b3.BodyId `json:"-" inspect:"-"`,
}

reset_Rigidbody :: proc(comp: ^Rigidbody) {
	cleanup_Rigidbody(comp)
	comp.use_gravity = true
}

cleanup_Rigidbody :: proc(comp: ^Rigidbody) {
	_destroy_body(&comp.body)
	engine.comp_zero(comp)
}

// Live destroy (transform_destroy_components) — the body must die with the
// component or it keeps colliding as a ghost.
@(comp_on_destroy={component=Rigidbody})
comp_on_destroy_Rigidbody :: proc(comp: ^Rigidbody) {
	_destroy_body(&comp.body)
}
