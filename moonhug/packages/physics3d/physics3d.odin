package physics3d

// 3D physics on vendor:box3d with Unity-literal authoring — the 3D sibling
// of packages/physics2d, same architecture (docs/Plugins.md):
//
// - Components are plain data; this fixed step syncs them to box3d. The
//   editor never simulates — bodies exist only while the app runs.
// - Units: 1 world unit = 1 meter.
// - A collider without a Rigidbody anywhere above it is STATIC (implicit
//   static body). A collider below a Rigidbody attaches to that body as a
//   shape with its relative transform baked at creation (compound bodies).
// - Contacts are POLLED, not called back: the step buffers box3d's begin/end
//   contact + sensor events; read them from a @(fixed_update) subscriber
//   ordered AFTER this step (order > 1000), or next tick at any order.
// - Escape hatch: body_of(tH) returns the live b3.BodyId — use vendor:box3d
//   directly for forces, joints, mass overrides, raycasts, runtime mutation.
//
// v1 limitations (same as physics2d): transform scale is ignored by shapes;
// moving a child collider after creation doesn't re-bake its offset;
// component field edits at runtime don't re-sync (use the escape hatch).

import "base:runtime"
import "core:math/linalg"
import b3 "vendor:box3d"
import "../../engine"

GRAVITY_DEFAULT :: [3]f32{0, -9.81, 0}
_SUB_STEPS :: 4

Contact :: struct {
	a, b: engine.Transform_Handle, // sensor events: a = sensor, b = visitor
}

_state: struct {
	world:         b3.WorldId,
	world_ready:   bool,
	gravity:       [3]f32,
	shape_owner:   map[u64]engine.Transform_Handle,
	contact_begin: [dynamic]Contact,
	contact_end:   [dynamic]Contact,
	sensor_begin:  [dynamic]Contact,
	sensor_end:    [dynamic]Contact,
}

// --- Public API ---------------------------------------------------------------

set_gravity :: proc(g: [3]f32) {
	_state.gravity = g
	if _state.world_ready {
		b3.World_SetGravity(_state.world, g)
	}
}

world :: proc() -> b3.WorldId {
	_ensure_world()
	return _state.world
}

// The live body for a transform carrying a Rigidbody ({}, false before the
// first step or without the component).
body_of :: proc(tH: engine.Transform_Handle) -> (b3.BodyId, bool) {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return {}, false
	owned, idx := engine.transform_find_comp(t, .Rigidbody)
	if idx < 0 do return {}, false
	pool := rigidbodies(w)
	if pool == nil do return {}, false
	rb := engine.pool_get(pool, owned.handle)
	if rb == nil || !b3.Body_IsValid(rb.body) do return {}, false
	return rb.body, true
}

// Events from the LAST physics step, valid until the next one.
contact_begin_events :: proc() -> []Contact { return _state.contact_begin[:] }
contact_end_events   :: proc() -> []Contact { return _state.contact_end[:] }
sensor_begin_events  :: proc() -> []Contact { return _state.sensor_begin[:] }
sensor_end_events    :: proc() -> []Contact { return _state.sensor_end[:] }

// --- Fixed step -----------------------------------------------------------------

@(fixed_update={order=1000})
physics_step :: proc(fixed_dt: f32) {
	// Package-global state must never borrow the caller's allocator — same
	// rule as engine.component_register (test tracking allocators).
	context.allocator = runtime.default_allocator()
	_ensure_world()
	w := engine.ctx_world()
	_sync_bodies(w)
	_sync_colliders(w)
	b3.World_Step(_state.world, fixed_dt, _SUB_STEPS)
	_write_back(w)
	_collect_events(w)
}

_ensure_world :: proc() {
	if _state.world_ready do return
	if _state.gravity == {} do _state.gravity = GRAVITY_DEFAULT
	def := b3.DefaultWorldDef()
	def.gravity = _state.gravity
	_state.world = b3.CreateWorld(def)
	_state.world_ready = true
}

// --- Sync: components -> box3d --------------------------------------------------

_world_quat :: proc(rotation: [4]f32) -> b3.Quat {
	return engine.quat_to_native(rotation)
}

_sync_bodies :: proc(w: ^engine.World) {
	pool := rigidbodies(w)
	if pool == nil do return
	for i in 0 ..< len(pool.slots) {
		slot := &pool.slots[i]
		if !slot.alive do continue
		rb := &slot.data
		if !engine.pool_valid(&w.transforms, engine.Handle(rb.owner)) do continue

		if !b3.Body_IsValid(rb.body) {
			if !rb.enabled do continue
			tw := engine.transform_world(rb.owner)
			def := b3.DefaultBodyDef()
			def.type = rb.is_kinematic ? .kinematicBody : .dynamicBody
			def.position = tw.position
			def.rotation = _world_quat(tw.rotation)
			def.gravityScale = rb.use_gravity ? 1 : 0
			def.linearDamping = rb.linear_damping
			def.angularDamping = rb.angular_damping
			def.isBullet = rb.continuous
			def.motionLocks = {
				linearX  = rb.freeze_position.x,
				linearY  = rb.freeze_position.y,
				linearZ  = rb.freeze_position.z,
				angularX = rb.freeze_rotation.x,
				angularY = rb.freeze_rotation.y,
				angularZ = rb.freeze_rotation.z,
			}
			rb.body = b3.CreateBody(_state.world, def)
			continue
		}

		if rb.enabled != b3.Body_IsEnabled(rb.body) {
			if rb.enabled do b3.Body_Enable(rb.body)
			else do b3.Body_Disable(rb.body)
		}
		// Kinematic bodies follow their transforms (scripts move the
		// transform, physics obeys). Dynamic transforms are owned by the
		// write-back below.
		if rb.is_kinematic && rb.enabled {
			tw := engine.transform_world(rb.owner)
			pos := b3.Body_GetPosition(rb.body)
			q := engine.quat_from_native(b3.Body_GetRotation(rb.body))
			want_q := engine.quat_from_native(_world_quat(tw.rotation))
			if pos != tw.position || q != want_q {
				b3.Body_SetTransform(rb.body, tw.position, _world_quat(tw.rotation))
			}
		}
	}
}

// Nearest Rigidbody on tH or an ancestor, with its owning transform.
_ancestor_body :: proc(w: ^engine.World, tH: engine.Transform_Handle) -> (body: b3.BodyId, body_tH: engine.Transform_Handle, ok: bool) {
	cur := tH
	for engine.pool_valid(&w.transforms, engine.Handle(cur)) {
		t := engine.pool_get(&w.transforms, engine.Handle(cur))
		owned, idx := engine.transform_find_comp(t, .Rigidbody)
		if idx >= 0 {
			pool := rigidbodies(w)
			if pool != nil {
				rb := engine.pool_get(pool, owned.handle)
				if rb != nil && b3.Body_IsValid(rb.body) {
					return rb.body, cur, true
				}
			}
			return {}, {}, false // RB found but no body yet (disabled) — wait
		}
		cur = engine.Transform_Handle(t.parent.handle)
	}
	return {}, {}, false
}

_Shape_Target :: struct {
	body:   b3.BodyId,
	center: [3]f32, // shape center in body-local space
	rot:    b3.Quat, // shape rotation in body-local space
}

// Resolve which body a collider attaches to and the baked relative
// transform. Creates the implicit static body when no RB is above.
_shape_target :: proc(w: ^engine.World, owner: engine.Transform_Handle, center: [3]f32, static_body: ^b3.BodyId) -> (_Shape_Target, bool) {
	if body, body_tH, ok := _ancestor_body(w, owner); ok {
		cw := engine.transform_world(owner)
		bw := engine.transform_world(body_tH)
		inv_bq := linalg.quaternion_inverse(engine.quat_to_native(bw.rotation))
		rel_q := inv_bq * engine.quat_to_native(cw.rotation)
		rel_p := linalg.quaternion128_mul_vector3(inv_bq, cw.position - bw.position)
		return {
			body   = body,
			center = rel_p + linalg.quaternion128_mul_vector3(rel_q, center),
			rot    = rel_q,
		}, true
	}
	// No rigidbody above: implicit static body at the collider's transform.
	if !b3.Body_IsValid(static_body^) {
		tw := engine.transform_world(owner)
		def := b3.DefaultBodyDef()
		def.type = .staticBody
		def.position = tw.position
		def.rotation = _world_quat(tw.rotation)
		static_body^ = b3.CreateBody(_state.world, def)
	}
	return {body = static_body^, center = center, rot = 1}, true
}

_shape_def :: proc(density, friction, bounciness: f32, is_trigger: bool) -> b3.ShapeDef {
	def := b3.DefaultShapeDef()
	def.density = density
	def.baseMaterial.friction = friction
	def.baseMaterial.restitution = bounciness
	def.isSensor = is_trigger
	def.enableContactEvents = true
	def.enableSensorEvents = true
	return def
}

_shape_key :: proc(s: b3.ShapeId) -> u64 {
	return transmute(u64)s
}

_register_shape :: proc(shape: b3.ShapeId, owner: engine.Transform_Handle) {
	_state.shape_owner[_shape_key(shape)] = owner
}

_capsule_axis :: proc(dir: Capsule_Direction) -> [3]f32 {
	switch dir {
	case .X_Axis: return {1, 0, 0}
	case .Y_Axis: return {0, 1, 0}
	case .Z_Axis: return {0, 0, 1}
	}
	return {0, 1, 0}
}

_sync_colliders :: proc(w: ^engine.World) {
	if pool := box_colliders(w); pool != nil {
		for i in 0 ..< len(pool.slots) {
			slot := &pool.slots[i]
			if !slot.alive do continue
			c := &slot.data
			if !c.enabled || b3.Shape_IsValid(c.shape) do continue
			if !engine.pool_valid(&w.transforms, engine.Handle(c.owner)) do continue
			target, ok := _shape_target(w, c.owner, c.center, &c.static_body)
			if !ok do continue
			def := _shape_def(c.density, c.friction, c.bounciness, c.is_trigger)
			h := c.size * 0.5
			bh := b3.MakeTransformedBoxHull(h.x, h.y, h.z, b3.Transform{p = target.center, q = target.rot})
			c.shape = b3.CreateHullShape(target.body, def, &bh.base)
			_register_shape(c.shape, c.owner)
		}
	}
	if pool := sphere_colliders(w); pool != nil {
		for i in 0 ..< len(pool.slots) {
			slot := &pool.slots[i]
			if !slot.alive do continue
			c := &slot.data
			if !c.enabled || b3.Shape_IsValid(c.shape) do continue
			if !engine.pool_valid(&w.transforms, engine.Handle(c.owner)) do continue
			target, ok := _shape_target(w, c.owner, c.center, &c.static_body)
			if !ok do continue
			def := _shape_def(c.density, c.friction, c.bounciness, c.is_trigger)
			sphere := b3.Sphere{center = target.center, radius = c.radius}
			c.shape = b3.CreateSphereShape(target.body, def, &sphere)
			_register_shape(c.shape, c.owner)
		}
	}
	if pool := capsule_colliders(w); pool != nil {
		for i in 0 ..< len(pool.slots) {
			slot := &pool.slots[i]
			if !slot.alive do continue
			c := &slot.data
			if !c.enabled || b3.Shape_IsValid(c.shape) do continue
			if !engine.pool_valid(&w.transforms, engine.Handle(c.owner)) do continue
			target, ok := _shape_target(w, c.owner, c.center, &c.static_body)
			if !ok do continue
			def := _shape_def(c.density, c.friction, c.bounciness, c.is_trigger)
			half := max(c.height * 0.5 - c.radius, 0)
			axis := linalg.quaternion128_mul_vector3(target.rot, _capsule_axis(c.direction))
			capsule := b3.Capsule{
				center1 = target.center - axis * half,
				center2 = target.center + axis * half,
				radius  = c.radius,
			}
			c.shape = b3.CreateCapsuleShape(target.body, def, &capsule)
			_register_shape(c.shape, c.owner)
		}
	}
}

// --- Write back: box3d -> transforms --------------------------------------------

_write_back :: proc(w: ^engine.World) {
	pool := rigidbodies(w)
	if pool == nil do return
	for i in 0 ..< len(pool.slots) {
		slot := &pool.slots[i]
		if !slot.alive do continue
		rb := &slot.data
		if rb.is_kinematic || !rb.enabled || !b3.Body_IsValid(rb.body) do continue
		if !engine.pool_valid(&w.transforms, engine.Handle(rb.owner)) do continue
		pos := b3.Body_GetPosition(rb.body)
		q := b3.Body_GetRotation(rb.body)
		engine.transform_set_world_position(rb.owner, pos)
		engine.transform_set_world_rotation(rb.owner, engine.quat_from_native(q))
	}
}

// --- Events ---------------------------------------------------------------------

_owner_of_shape :: proc(w: ^engine.World, shape: b3.ShapeId) -> (engine.Transform_Handle, bool) {
	tH, found := _state.shape_owner[_shape_key(shape)]
	if !found || !engine.pool_valid(&w.transforms, engine.Handle(tH)) do return {}, false
	return tH, true
}

_collect_events :: proc(w: ^engine.World) {
	clear(&_state.contact_begin)
	clear(&_state.contact_end)
	clear(&_state.sensor_begin)
	clear(&_state.sensor_end)

	ce := b3.World_GetContactEvents(_state.world)
	for i in 0 ..< ce.beginCount {
		a, aok := _owner_of_shape(w, ce.beginEvents[i].shapeIdA)
		b, bok := _owner_of_shape(w, ce.beginEvents[i].shapeIdB)
		if aok && bok do append(&_state.contact_begin, Contact{a, b})
	}
	for i in 0 ..< ce.endCount {
		a, aok := _owner_of_shape(w, ce.endEvents[i].shapeIdA)
		b, bok := _owner_of_shape(w, ce.endEvents[i].shapeIdB)
		if aok && bok do append(&_state.contact_end, Contact{a, b})
	}

	se := b3.World_GetSensorEvents(_state.world)
	for i in 0 ..< se.beginCount {
		a, aok := _owner_of_shape(w, se.beginEvents[i].sensorShapeId)
		b, bok := _owner_of_shape(w, se.beginEvents[i].visitorShapeId)
		if aok && bok do append(&_state.sensor_begin, Contact{a, b})
	}
	for i in 0 ..< se.endCount {
		a, aok := _owner_of_shape(w, se.endEvents[i].sensorShapeId)
		b, bok := _owner_of_shape(w, se.endEvents[i].visitorShapeId)
		if aok && bok do append(&_state.sensor_end, Contact{a, b})
	}
}

// --- Teardown (component cleanup/on_destroy hooks) --------------------------------

_destroy_body :: proc(body: ^b3.BodyId) {
	if _state.world_ready && b3.Body_IsValid(body^) {
		b3.DestroyBody(body^)
	}
	body^ = {}
}

_destroy_shape :: proc(shape: ^b3.ShapeId, static_body: ^b3.BodyId) {
	if _state.world_ready && b3.Shape_IsValid(shape^) {
		delete_key(&_state.shape_owner, _shape_key(shape^))
		b3.DestroyShape(shape^, true)
	}
	shape^ = {}
	// The implicit static body belongs to this collider alone.
	_destroy_body(static_body)
}
