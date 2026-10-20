package physics2d

// Unity-literal Rigidbody2D: authored as plain data (inspector/serialization
// come from the attributes), synced to a box2d body by the fixed step. The
// live b2 body id is runtime-only — for anything not wrapped here (forces,
// joints, filters) use body_of(tH) and vendor:box2d directly.

import b2 "vendor:box2d"
import "moonhug:packages/engine"

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
	// The colliders' density decides the mass. Off, `mass` does and the density
	// only spreads it: the center of mass and the inertia.
	use_auto_mass:   bool,
	// The body's mass in kilograms, when use_auto_mass is off.
	mass:            f32 `decor:min(0.0001)`,
	gravity_scale:   f32,
	linear_damping:  f32,
	angular_damping: f32,
	fixed_rotation:  bool,
	continuous:      bool, // continuous collision detection (box2d bullet)
	// The material of every collider attached to this body that names none.
	material:        engine.Asset_GUID `ref:"PhysicsMaterial2D" expand`,

	// Collides with these layers besides the collision matrix, or never,
	// for every collider attached to this body.
	using layer_overrides: Physics2D_Layer_Overrides `inline:""`,

	body: b2.BodyId `json:"-" inspect:"-"`,
	// The body carries `mass` instead of its shapes' (physics2d.odin _sync_mass).
	mass_set: bool `json:"-" inspect:"-"`,
}

reset_Rigidbody2D :: proc(comp: ^Rigidbody2D) {
	cleanup_Rigidbody2D(comp)
	comp.mass = 1
	comp.gravity_scale = 1
}

// Runs on destroy, removal, Reset and undo: the body goes with the
// component, or it keeps colliding as a ghost.
cleanup_Rigidbody2D :: proc(comp: ^Rigidbody2D) {
	_destroy_body(&comp.body)
	engine.comp_zero(comp)
}
