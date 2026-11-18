package rigging

// SpringBones (plugins/rigging/docs/components/SpringBones.md): a chain of
// bones that lags behind its root and swings back, for hair, tails, ears,
// capes and antennas. Nothing is animated by hand: the motion comes from how
// the root moves.
//
// - `root` is the first bone of the chain, empty for this object. Every
//   bone under it that has a child swings. A bone points at its first
//   child, and a bone with no child is the end of a chain and only follows.
// - Each bone's far end is a point with inertia. Every frame the point keeps
//   moving as it was (less `drag`), is pulled toward where the pose puts it
//   (`stiffness`) and along `gravity`, is pushed out of the colliders, and
//   is put back at the bone's length from the bone. The bone then turns to
//   point at it.
// - The pose the bones return to is the one they have when the component
//   starts, or the one animation writes each frame.
// - `colliders` is an object: every SpringBoneCollider on it or under it
//   keeps the chain's points outside its sphere. Empty for none.

import "core:math/linalg"
import "moonhug:packages/engine"

@(component={menu="Rigging/SpringBones"})
@(typ_guid={guid="5eb047b4-f145-4d04-9826-11f4a7ef51af"})
SpringBones :: struct {
	using base: engine.CompData `inspect:"-"`,
	root:       engine.Ref_Local `ref:"Transform"`, // the chain's first bone, empty = this object
	stiffness:  f32 `decor:min(0)`,      // how hard a bone returns to its pose
	drag:       f32 `decor:range(0, 1)`, // the part of its motion a bone loses each frame
	gravity:    [3]f32,                   // a steady pull, world units per second
	radius:     f32 `decor:min(0)`,      // a bone end's size against the colliders
	colliders:  engine.Ref_Local `ref:"Transform"`, // the object whose SpringBoneColliders this chain stays out of
	// The chain as simulated, rebuilt when its bones change.
	joints:     [dynamic]Spring_Joint `json:"-" inspect:"-"`,
	built_for:  engine.Transform_Handle `json:"-" inspect:"-"`,
}

// One swinging bone: `bone` points at `child`, whose position is the
// simulated point.
Spring_Joint :: struct {
	bone, child: engine.Transform_Handle,
	axis:        [3]f32, // the direction to the child in the bone's own space
	length:      f32,    // world distance to the child
	rest:        [4]f32, // the local rotation the bone returns to
	written:     [4]f32, // the local rotation written last frame
	tail, prev:  [3]f32, // the point now and a frame ago, world
}

// A sphere the bones of a SpringBones chain stay out of: a head for hair, a
// body for a cape.
@(component={menu="Rigging/SpringBoneCollider"})
@(typ_guid={guid="f7f0458e-eaf1-4e70-9b88-28b1fb7058a4"})
SpringBoneCollider :: struct {
	using base: engine.CompData `inspect:"-"`,
	radius:     f32 `decor:min(0)`,
	offset:     [3]f32, // the sphere's center from the object, in its space
}

type_reset_SpringBones :: proc(s: ^SpringBones) {
	type_cleanup_SpringBones(s)
	s.stiffness = 1
	s.drag = 0.4
	s.radius = 0.02
}

type_cleanup_SpringBones :: proc(s: ^SpringBones) {
	delete(s.joints)
	engine.comp_zero(s)
}

type_reset_SpringBoneCollider :: proc(c: ^SpringBoneCollider) {
	engine.comp_zero(c)
	c.radius = 0.1
}

// The chain's first bone.
spring_bones_root :: proc(s: ^SpringBones) -> engine.Transform_Handle {
	if h := engine.Transform_Handle(s.root.handle); h != {} do return h
	return s.owner
}

// Collects the chain from the hierarchy as it is posed now: that pose is
// the one the bones return to.
spring_bones_rebuild :: proc(s: ^SpringBones) {
	w := engine.ctx_world()
	if s.joints == nil do s.joints = make([dynamic]Spring_Joint)
	clear(&s.joints)
	root := spring_bones_root(s)
	s.built_for = root
	stack := make([dynamic]engine.Transform_Handle, context.temp_allocator)
	append(&stack, root)
	for len(stack) > 0 {
		h := pop(&stack)
		t := engine.pool_get(&w.transforms, engine.Handle(h))
		if t == nil do continue
		// Parents before children: a bone is turned before the bones under it.
		#reverse for c in t.children do append(&stack, engine.Transform_Handle(c.handle))
		if len(t.children) == 0 do continue
		child := engine.Transform_Handle(t.children[0].handle)
		ct := engine.pool_get(&w.transforms, engine.Handle(child))
		if ct == nil || linalg.length(ct.position) < 1e-6 do continue
		head := engine.transform_world(h).position
		tail := engine.transform_world(child).position
		rot := t.rotation if t.rotation != {} else engine.QUAT_IDENTITY
		append(&s.joints, Spring_Joint{
			bone = h, child = child,
			axis = linalg.normalize(ct.position),
			length = linalg.length(tail - head),
			rest = rot, written = rot,
			tail = tail, prev = tail,
		})
	}
}

@(private = "file")
_chain_alive :: proc(s: ^SpringBones) -> bool {
	w := engine.ctx_world()
	if s.joints == nil || s.built_for != spring_bones_root(s) do return false
	for j in s.joints {
		if !engine.pool_valid(&w.transforms, engine.Handle(j.bone)) do return false
		if !engine.pool_valid(&w.transforms, engine.Handle(j.child)) do return false
	}
	return true
}

@(private = "file")
_Sphere :: struct {
	center: [3]f32,
	radius: f32,
}

// The spheres of the enabled SpringBoneColliders on `under` or below it.
@(private = "file")
_collider_spheres :: proc(under: engine.Transform_Handle) -> []_Sphere {
	w := engine.ctx_world()
	out := make([dynamic]_Sphere, context.temp_allocator)
	if under == {} || !engine.pool_valid(&w.transforms, engine.Handle(under)) do return out[:]
	pool := spring_bone_colliders(w)
	if pool == nil do return out[:]
	it := engine.pool_iterator(pool)
	for c, _ in engine.pool_next(&it) {
		if !c.enabled || !engine.transform_active_in_hierarchy(c.owner) do continue
		if c.owner != under && !engine.transform_is_under(c.owner, under) do continue
		center, radius := spring_collider_sphere(c)
		append(&out, _Sphere{center, radius})
	}
	return out[:]
}

// The collider's sphere in the world: the radius grows with the object's
// largest scale.
spring_collider_sphere :: proc(c: ^SpringBoneCollider) -> (center: [3]f32, radius: f32) {
	tw := engine.transform_world(c.owner)
	center = tw.position + linalg.quaternion128_mul_vector3(engine.quat_to_native(tw.rotation), c.offset * tw.scale)
	radius = c.radius * max(abs(tw.scale.x), abs(tw.scale.y), abs(tw.scale.z))
	return
}

// One step of the chain, `dt` seconds long. The update below calls it for
// every enabled SpringBones.
spring_bones_step :: proc(s: ^SpringBones, dt: f32) {
	w := engine.ctx_world()
	if !_chain_alive(s) do spring_bones_rebuild(s)
	spheres := _collider_spheres(engine.Transform_Handle(s.colliders.handle))
	keep := 1 - clamp(s.drag, 0, 1)
	for &j in s.joints {
		t := engine.pool_get(&w.transforms, engine.Handle(j.bone))
		// A rotation other than the one written last frame came from
		// animation or code: it is the pose to return to now.
		if t.rotation != j.written do j.rest = t.rotation if t.rotation != {} else engine.QUAT_IDENTITY

		parent_rot := linalg.QUATERNIONF32_IDENTITY
		if engine.pool_valid(&w.transforms, t.parent.handle) {
			parent_rot = engine.quat_to_native(engine.transform_world(engine.Transform_Handle(t.parent.handle)).rotation)
		}
		rest_rot := parent_rot * engine.quat_to_native(j.rest)
		rest_dir := linalg.quaternion128_mul_vector3(rest_rot, j.axis)
		head := engine.transform_world(j.bone).position

		next := j.tail + (j.tail - j.prev) * keep + rest_dir * (s.stiffness * dt) + s.gravity * dt
		next = head + linalg.normalize0(next - head) * j.length
		for sp in spheres {
			reach := sp.radius + s.radius
			away := next - sp.center
			if d := linalg.length(away); d < reach && d > 1e-6 {
				next = sp.center + away * (reach / d)
				next = head + linalg.normalize0(next - head) * j.length
			}
		}
		if next == head do next = head + rest_dir * j.length
		j.prev = j.tail
		j.tail = next

		rot := quat_from_to(rest_dir, next - head) * rest_rot
		engine.transform_set_world_rotation(j.bone, engine.quat_from_native(linalg.quaternion_normalize(rot)))
		j.written = t.rotation
	}
}

// After TwoBoneIK (order 0): a chain on a limb follows the solved limb.
@(late_update={order=10})
spring_bones_update :: proc(dt: f32) {
	w := engine.ctx_world()
	if w == nil do return
	pool := spring_boneses(w)
	if pool == nil do return
	// A long frame (a load, a breakpoint) is not a long pull.
	step := min(dt, 1.0 / 20)
	it := engine.pool_iterator(pool)
	for s, _ in engine.pool_next(&it) {
		if !s.enabled || !engine.transform_active_in_hierarchy(s.owner) do continue
		spring_bones_step(s, step)
	}
}
