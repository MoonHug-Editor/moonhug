package physics2d

// 2D physics on vendor:box2d with Unity-literal authoring (docs/Plugins.md
// picked the surface, memory holds the decisions):
//
// - Components are plain data; this fixed step syncs them to box2d. The
//   editor never simulates — bodies exist only while the app runs.
// - Units: 1 world unit = 1 meter (= 100 px on screen). No conversion here.
// - A collider without a Rigidbody2D anywhere above it is STATIC (implicit
//   static body). A collider below a Rigidbody2D attaches to that body as a
//   shape with its relative transform baked at creation (compound bodies).
// - Contacts are POLLED, not called back: the step buffers box2d's begin/end
//   contact + sensor events; read them from a @(fixed_update) subscriber
//   ordered AFTER this step (order > 1000), or next tick at any order.
// - Escape hatch: body_of(tH) returns the live b2.BodyId — use vendor:box2d
//   directly for forces, joints, filters, raycasts and runtime mutation.
//
// Transform scale affects shapes (Unity semantics — see collider_scale). The
// whole relative transform, scale included, is BAKED at shape creation:
// moving or rescaling a child collider afterwards doesn't re-bake, and
// component field edits at runtime don't re-sync (use the escape hatch).

import "base:runtime"
import "core:math"
import b2 "vendor:box2d"
import "../../engine"

GRAVITY_DEFAULT :: [2]f32{0, -9.81}
_SUB_STEPS :: 4

Contact :: struct {
	a, b: engine.Transform_Handle, // sensor events: a = sensor, b = visitor
}

_state: struct {
	world:         b2.WorldId,
	world_ready:   bool,
	gravity:       [2]f32,
	shape_owner:   map[u64]engine.Transform_Handle,
	contact_begin: [dynamic]Contact,
	contact_end:   [dynamic]Contact,
	sensor_begin:  [dynamic]Contact,
	sensor_end:    [dynamic]Contact,
}

// --- Public API ---------------------------------------------------------------

set_gravity :: proc(g: [2]f32) {
	_state.gravity = g
	if _state.world_ready {
		b2.World_SetGravity(_state.world, g)
	}
}

world :: proc() -> b2.WorldId {
	_ensure_world()
	return _state.world
}

// The live body for a transform carrying a Rigidbody2D ({}, false before the
// first step or without the component).
body_of :: proc(tH: engine.Transform_Handle) -> (b2.BodyId, bool) {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return {}, false
	owned, idx := engine.transform_find_comp(t, .Rigidbody2D)
	if idx < 0 do return {}, false
	pool := rigidbody2_ds(w)
	if pool == nil do return {}, false
	rb := engine.pool_get(pool, owned.handle)
	if rb == nil || !b2.Body_IsValid(rb.body) do return {}, false
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
	// Package-global state (shape map, event buffers) must never borrow the
	// caller's allocator — same rule as engine.component_register (the test
	// runner hands each test a scoped tracking allocator).
	context.allocator = runtime.default_allocator()
	_ensure_world()
	w := engine.ctx_world()
	_sync_bodies(w, fixed_dt)
	_sync_colliders(w)
	b2.World_Step(_state.world, fixed_dt, _SUB_STEPS)
	_write_back(w)
	_collect_events(w)
}

_ensure_world :: proc() {
	if _state.world_ready do return
	if _state.gravity == {} do _state.gravity = GRAVITY_DEFAULT
	def := b2.DefaultWorldDef()
	def.gravity = _state.gravity
	_state.world = b2.CreateWorld(def)
	_state.world_ready = true
}

// --- Sync: components -> box2d --------------------------------------------------

_world_z_angle :: proc(rotation: [4]f32) -> f32 {
	return math.to_radians(engine.quat_to_euler_xyz(rotation).z)
}

_sync_bodies :: proc(w: ^engine.World, fixed_dt: f32) {
	pool := rigidbody2_ds(w)
	if pool == nil do return
	for i in 0 ..< len(pool.slots) {
		slot := &pool.slots[i]
		if !slot.alive do continue
		rb := &slot.data
		if !engine.pool_valid(&w.transforms, engine.Handle(rb.owner)) do continue

		if !b2.Body_IsValid(rb.body) {
			if !rb.enabled do continue
			tw := engine.transform_world(rb.owner)
			def := b2.DefaultBodyDef()
			switch rb.body_type {
			case .Dynamic:   def.type = .dynamicBody
			case .Kinematic: def.type = .kinematicBody
			case .Static:    def.type = .staticBody
			}
			def.position = {tw.position.x, tw.position.y}
			def.rotation = b2.MakeRot(_world_z_angle(tw.rotation))
			def.gravityScale = rb.gravity_scale
			def.linearDamping = rb.linear_damping
			def.angularDamping = rb.angular_damping
			def.fixedRotation = rb.fixed_rotation
			def.isBullet = rb.continuous
			rb.body = b2.CreateBody(_state.world, def)
			continue
		}

		if rb.enabled != b2.Body_IsEnabled(rb.body) {
			if rb.enabled do b2.Body_Enable(rb.body)
			else do b2.Body_Disable(rb.body)
		}
		// Kinematic bodies follow their transforms (scripts move the
		// transform, physics obeys) — driven by VELOCITY, not teleport
		// (Unity MovePosition): the step itself moves the body, so contacts
		// push dynamic bodies. A Body_SetTransform teleport carries zero
		// velocity — dynamics would only depenetrate, never be pushed.
		// Static bodies keep the teleport (they aren't supposed to move),
		// dynamic transforms are owned by the write-back below.
		if rb.body_type != .Dynamic && rb.enabled {
			tw := engine.transform_world(rb.owner)
			pos := b2.Body_GetPosition(rb.body)
			angle := b2.Rot_GetAngle(b2.Body_GetRotation(rb.body))
			want := [2]f32{tw.position.x, tw.position.y}
			want_angle := _world_z_angle(tw.rotation)
			if rb.body_type == .Kinematic {
				inv_dt := 1.0 / fixed_dt
				b2.Body_SetLinearVelocity(rb.body, (want - pos) * inv_dt)
				// Shortest-arc angle delta, wrapped to [-pi, pi].
				dang := math.mod(want_angle - angle + math.PI, math.TAU)
				if dang < 0 do dang += math.TAU
				b2.Body_SetAngularVelocity(rb.body, (dang - math.PI) * inv_dt)
			} else if pos != want || angle != want_angle {
				b2.Body_SetTransform(rb.body, want, b2.MakeRot(want_angle))
			}
		}
	}
}

// Nearest Rigidbody2D on tH or an ancestor, with its owning transform.
_ancestor_body :: proc(w: ^engine.World, tH: engine.Transform_Handle) -> (body: b2.BodyId, body_tH: engine.Transform_Handle, ok: bool) {
	cur := tH
	for engine.pool_valid(&w.transforms, engine.Handle(cur)) {
		t := engine.pool_get(&w.transforms, engine.Handle(cur))
		owned, idx := engine.transform_find_comp(t, .Rigidbody2D)
		if idx >= 0 {
			pool := rigidbody2_ds(w)
			if pool != nil {
				rb := engine.pool_get(pool, owned.handle)
				if rb != nil && b2.Body_IsValid(rb.body) {
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
	body:   b2.BodyId,
	center: [2]f32, // shape center in body-local space
	angle:  f32,    // shape rotation in body-local space
}

_rotate2 :: proc(v: [2]f32, angle: f32) -> [2]f32 {
	s, c := math.sin(angle), math.cos(angle)
	return {v.x * c - v.y * s, v.x * s + v.y * c}
}

// --- Scale (Unity semantics) ----------------------------------------------------
// The owner's ABSOLUTE world scale affects collider dims: box/capsule size
// scales per-axis, circle radius by the LARGER axis, offsets scale too.
// Shared by the sync and the editor gizmos; baked at shape creation like the
// rest of the relative transform (rescaling later doesn't re-bake).

collider_scale :: proc(owner: engine.Transform_Handle) -> [2]f32 {
	tw := engine.transform_world(owner)
	return {abs(tw.scale.x), abs(tw.scale.y)}
}

box_scaled :: proc(c: ^BoxCollider2D, s: [2]f32) -> (size, offset: [2]f32) {
	return c.size * s, c.offset * s
}

circle_scaled :: proc(c: ^CircleCollider2D, s: [2]f32) -> (radius: f32, offset: [2]f32) {
	return c.radius * max(s.x, s.y), c.offset * s
}

capsule_scaled :: proc(c: ^CapsuleCollider2D, s: [2]f32) -> (size, offset: [2]f32) {
	return c.size * s, c.offset * s
}

// Resolve which body a collider attaches to and the baked relative
// transform. Creates the implicit static body when no RB is above.
_shape_target :: proc(w: ^engine.World, owner: engine.Transform_Handle, offset: [2]f32, static_body: ^b2.BodyId) -> (_Shape_Target, bool) {
	if body, body_tH, ok := _ancestor_body(w, owner); ok {
		cw := engine.transform_world(owner)
		bw := engine.transform_world(body_tH)
		body_angle := _world_z_angle(bw.rotation)
		col_angle := _world_z_angle(cw.rotation)
		rel_angle := col_angle - body_angle
		rel_pos := _rotate2({cw.position.x - bw.position.x, cw.position.y - bw.position.y}, -body_angle)
		return {body = body, center = rel_pos + _rotate2(offset, rel_angle), angle = rel_angle}, true
	}
	// No rigidbody above: implicit static body at the collider's transform.
	if !b2.Body_IsValid(static_body^) {
		tw := engine.transform_world(owner)
		def := b2.DefaultBodyDef()
		def.type = .staticBody
		def.position = {tw.position.x, tw.position.y}
		def.rotation = b2.MakeRot(_world_z_angle(tw.rotation))
		static_body^ = b2.CreateBody(_state.world, def)
	}
	return {body = static_body^, center = offset, angle = 0}, true
}

_shape_def :: proc(density, friction, bounciness: f32, is_trigger: bool) -> b2.ShapeDef {
	def := b2.DefaultShapeDef()
	def.density = density
	def.material.friction = friction
	def.material.restitution = bounciness
	def.isSensor = is_trigger
	def.enableContactEvents = true
	def.enableSensorEvents = true
	return def
}

_shape_key :: proc(s: b2.ShapeId) -> u64 {
	return transmute(u64)s
}

_register_shape :: proc(shape: b2.ShapeId, owner: engine.Transform_Handle) {
	_state.shape_owner[_shape_key(shape)] = owner
}

_sync_colliders :: proc(w: ^engine.World) {
	if pool := box_collider2_ds(w); pool != nil {
		for i in 0 ..< len(pool.slots) {
			slot := &pool.slots[i]
			if !slot.alive do continue
			c := &slot.data
			if !c.enabled || b2.Shape_IsValid(c.shape) do continue
			if !engine.pool_valid(&w.transforms, engine.Handle(c.owner)) do continue
			size, offset := box_scaled(c, collider_scale(c.owner))
			target, ok := _shape_target(w, c.owner, offset, &c.static_body)
			if !ok do continue
			def := _shape_def(c.density, c.friction, c.bounciness, c.is_trigger)
			box := b2.MakeOffsetBox(size.x * 0.5, size.y * 0.5, target.center, b2.MakeRot(target.angle))
			c.shape = b2.CreatePolygonShape(target.body, def, &box)
			_register_shape(c.shape, c.owner)
		}
	}
	if pool := circle_collider2_ds(w); pool != nil {
		for i in 0 ..< len(pool.slots) {
			slot := &pool.slots[i]
			if !slot.alive do continue
			c := &slot.data
			if !c.enabled || b2.Shape_IsValid(c.shape) do continue
			if !engine.pool_valid(&w.transforms, engine.Handle(c.owner)) do continue
			radius, offset := circle_scaled(c, collider_scale(c.owner))
			target, ok := _shape_target(w, c.owner, offset, &c.static_body)
			if !ok do continue
			def := _shape_def(c.density, c.friction, c.bounciness, c.is_trigger)
			circle := b2.Circle{center = target.center, radius = radius}
			c.shape = b2.CreateCircleShape(target.body, def, &circle)
			_register_shape(c.shape, c.owner)
		}
	}
	if pool := capsule_collider2_ds(w); pool != nil {
		for i in 0 ..< len(pool.slots) {
			slot := &pool.slots[i]
			if !slot.alive do continue
			c := &slot.data
			if !c.enabled || b2.Shape_IsValid(c.shape) do continue
			if !engine.pool_valid(&w.transforms, engine.Handle(c.owner)) do continue
			size, offset := capsule_scaled(c, collider_scale(c.owner))
			target, ok := _shape_target(w, c.owner, offset, &c.static_body)
			if !ok do continue
			def := _shape_def(c.density, c.friction, c.bounciness, c.is_trigger)
			radius, half: f32
			axis: [2]f32
			if c.direction == .Vertical {
				radius = size.x * 0.5
				half = max(size.y * 0.5 - radius, 0)
				axis = {0, 1}
			} else {
				radius = size.y * 0.5
				half = max(size.x * 0.5 - radius, 0)
				axis = {1, 0}
			}
			axis = _rotate2(axis, target.angle)
			capsule := b2.Capsule{
				center1 = target.center - axis * half,
				center2 = target.center + axis * half,
				radius  = radius,
			}
			c.shape = b2.CreateCapsuleShape(target.body, def, &capsule)
			_register_shape(c.shape, c.owner)
		}
	}
}

// --- Write back: box2d -> transforms --------------------------------------------

_write_back :: proc(w: ^engine.World) {
	pool := rigidbody2_ds(w)
	if pool == nil do return
	for i in 0 ..< len(pool.slots) {
		slot := &pool.slots[i]
		if !slot.alive do continue
		rb := &slot.data
		if rb.body_type != .Dynamic || !rb.enabled || !b2.Body_IsValid(rb.body) do continue
		if !engine.pool_valid(&w.transforms, engine.Handle(rb.owner)) do continue
		pos := b2.Body_GetPosition(rb.body)
		angle := b2.Rot_GetAngle(b2.Body_GetRotation(rb.body))
		z := engine.transform_world(rb.owner).position.z
		engine.transform_set_world_position(rb.owner, {pos.x, pos.y, z})
		engine.transform_set_world_rotation(rb.owner, engine.quat_from_euler_xyz(0, 0, math.to_degrees(angle)))
	}
}

// --- Events ---------------------------------------------------------------------

_owner_of_shape :: proc(w: ^engine.World, shape: b2.ShapeId) -> (engine.Transform_Handle, bool) {
	tH, found := _state.shape_owner[_shape_key(shape)]
	if !found || !engine.pool_valid(&w.transforms, engine.Handle(tH)) do return {}, false
	return tH, true
}

_collect_events :: proc(w: ^engine.World) {
	clear(&_state.contact_begin)
	clear(&_state.contact_end)
	clear(&_state.sensor_begin)
	clear(&_state.sensor_end)

	ce := b2.World_GetContactEvents(_state.world)
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

	se := b2.World_GetSensorEvents(_state.world)
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

_destroy_body :: proc(body: ^b2.BodyId) {
	if _state.world_ready && b2.Body_IsValid(body^) {
		b2.DestroyBody(body^)
	}
	body^ = {}
}

_destroy_shape :: proc(shape: ^b2.ShapeId, static_body: ^b2.BodyId) {
	if _state.world_ready && b2.Shape_IsValid(shape^) {
		delete_key(&_state.shape_owner, _shape_key(shape^))
		b2.DestroyShape(shape^, true)
	}
	shape^ = {}
	// The implicit static body belongs to this collider alone.
	_destroy_body(static_body)
}
