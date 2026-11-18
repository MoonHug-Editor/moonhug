package physics3d

// Queries against the colliders of the running game: what a ray hits, what
// a moving shape hits, and what a shape touches.
//
// - Bodies exist only while the game runs (physics_step builds them), so a
//   query in edit mode, or before the first step, hits nothing.
// - A query sees the colliders as of the last step: a body moved since then
//   by its transform is found where the step left it.

import "base:runtime"
import "core:c"
import "core:math/linalg"
import b3 "vendor:box3d"
import "moonhug:packages/engine"

// What a ray hit.
Raycast_Hit :: struct {
	object:   engine.Transform_Handle, // the object carrying the collider hit
	point:    [3]f32,
	normal:   [3]f32, // the surface's, at `point`
	distance: f32, // from the ray's origin to `point`
}

// The first collider a ray hits, from `origin` along `direction`, at most
// `max_distance` away.
//
// - `layers`: the physics layers whose colliders the ray can hit, all of them
//   by default. A collider is hit when one of its layers is in `layers`.
// - `ignore`: an object the ray passes through, with every object under it,
//   such as the object casting the ray. {} for none.
// - Triggers are passed through.
//
// False when nothing is hit, and while the game is not running.
raycast :: proc(origin, direction: [3]f32, max_distance: f32, layers := ~u32(0), ignore := engine.Transform_Handle{}) -> (hit: Raycast_Hit, ok: bool) {
	if !_state.world_ready || max_distance <= 0 do return
	dir := linalg.normalize0(direction)
	if dir == {} do return
	q := _Ray_Query{ctx = context, ignore = ignore, fraction = 2}
	// The query is on every layer, so a collider's own mask never hides it:
	// `layers` alone says what it hits.
	filter := b3.QueryFilter{categoryBits = ~u64(0), maskBits = u64(layers)}
	_ = b3.World_CastRay(_state.world, origin, dir * max_distance, filter, _ray_hit_fcn, &q)
	if q.fraction > 1 do return
	return {object = q.object, point = q.point, normal = q.normal, distance = q.fraction * max_distance}, true
}

// The closest hit so far of one raycast.
@(private = "file")
_Ray_Query :: struct {
	ctx:      runtime.Context, // the caller's, for the callback
	ignore:   engine.Transform_Handle,
	fraction: f32, // above 1: nothing hit yet
	object:   engine.Transform_Handle,
	point:    [3]f32,
	normal:   [3]f32,
}

// Called by box3d for each collider along the ray, in no order. Returns -1
// to pass through a hit, else its fraction, which shortens the ray to it so
// only closer hits come after.
@(private = "file")
_ray_hit_fcn :: proc "c" (shape: b3.ShapeId, point: b3.Pos, normal: b3.Vec3, fraction: f32, material: u64, triangle: c.int, child: c.int, ctx: rawptr) -> f32 {
	q := cast(^_Ray_Query)ctx
	context = q.ctx
	if b3.Shape_IsSensor(shape) do return -1
	object, known := _owner_of_shape(engine.ctx_world(), shape)
	if !known do return -1
	if q.ignore != {} && engine.transform_is_under(object, q.ignore) do return -1
	if fraction < q.fraction {
		q.fraction = fraction
		q.object = object
		q.point = point
		q.normal = normal
	}
	return fraction
}

// --- Shapes -------------------------------------------------------------------
// A query's own shape, placed in the world for the one call: a sphere, a box
// or a capsule. It is no collider and nothing collides with it.

// A query shape as box3d takes it: points around `origin` with a radius.
@(private = "file")
_Shape :: struct {
	origin: [3]f32,
	points: [8][3]f32,
	count:  c.int,
	radius: f32,
}

@(private = "file")
_sphere :: proc(center: [3]f32, radius: f32) -> _Shape {
	return {origin = center, count = 1, radius = max(radius, 0)}
}

@(private = "file")
_capsule :: proc(a, b: [3]f32, radius: f32) -> _Shape {
	s := _Shape{origin = a, count = 2, radius = max(radius, 0)}
	s.points[1] = b - a
	return s
}

@(private = "file")
_box :: proc(center, half_extents: [3]f32, rotation: [4]f32) -> _Shape {
	s := _Shape{origin = center, count = 8}
	q := engine.quat_to_native(rotation)
	for i in 0 ..< 8 {
		corner := [3]f32{
			-half_extents.x if i & 1 == 0 else half_extents.x,
			-half_extents.y if i & 2 == 0 else half_extents.y,
			-half_extents.z if i & 4 == 0 else half_extents.z,
		}
		s.points[i] = linalg.quaternion128_mul_vector3(q, corner)
	}
	return s
}

@(private = "file")
_proxy :: proc(s: ^_Shape) -> b3.ShapeProxy {
	return {points = raw_data(s.points[:]), count = s.count, radius = s.radius}
}

// --- Overlap ------------------------------------------------------------------

// Every object with a collider that touches a sphere.
//
// - `layers` and `ignore` are raycast's. Triggers are left out.
// - An object is listed once, however many of its colliders touch.
// - The list is in no order, and it is allocated with `allocator`, the
//   temporary one by default.
//
// Empty when nothing touches, and while the game is not running.
overlap_sphere :: proc(center: [3]f32, radius: f32, layers := ~u32(0), ignore := engine.Transform_Handle{}, allocator := context.temp_allocator) -> []engine.Transform_Handle {
	s := _sphere(center, radius)
	return _overlap(&s, layers, ignore, allocator)
}

// Every object with a collider that touches a box: `half_extents` each way
// from `center`, turned by `rotation`. The rest is overlap_sphere's.
overlap_box :: proc(center, half_extents: [3]f32, rotation := [4]f32{0, 0, 0, 1}, layers := ~u32(0), ignore := engine.Transform_Handle{}, allocator := context.temp_allocator) -> []engine.Transform_Handle {
	s := _box(center, half_extents, rotation)
	return _overlap(&s, layers, ignore, allocator)
}

// Every object with a collider that touches a capsule: the segment from `a`
// to `b`, `radius` thick. The rest is overlap_sphere's.
overlap_capsule :: proc(a, b: [3]f32, radius: f32, layers := ~u32(0), ignore := engine.Transform_Handle{}, allocator := context.temp_allocator) -> []engine.Transform_Handle {
	s := _capsule(a, b, radius)
	return _overlap(&s, layers, ignore, allocator)
}

@(private = "file")
_Overlap_Query :: struct {
	ctx:    runtime.Context,
	ignore: engine.Transform_Handle,
	found:  [dynamic]engine.Transform_Handle,
}

@(private = "file")
_overlap :: proc(s: ^_Shape, layers: u32, ignore: engine.Transform_Handle, allocator: runtime.Allocator) -> []engine.Transform_Handle {
	if !_state.world_ready do return nil
	q := _Overlap_Query{ctx = context, ignore = ignore, found = make([dynamic]engine.Transform_Handle, allocator)}
	filter := b3.QueryFilter{categoryBits = ~u64(0), maskBits = u64(layers)}
	proxy := _proxy(s)
	_ = b3.World_OverlapShape(_state.world, s.origin, proxy, filter, _overlap_fcn, &q)
	return q.found[:]
}

// Called by box3d for each collider the shape touches. True goes on.
@(private = "file")
_overlap_fcn :: proc "c" (shape: b3.ShapeId, ctx: rawptr) -> bool {
	q := cast(^_Overlap_Query)ctx
	context = q.ctx
	if b3.Shape_IsSensor(shape) do return true
	object, known := _owner_of_shape(engine.ctx_world(), shape)
	if !known do return true
	if q.ignore != {} && engine.transform_is_under(object, q.ignore) do return true
	for o in q.found do if o == object do return true
	append(&q.found, object)
	return true
}

// --- Shape casts --------------------------------------------------------------

// The first collider a sphere hits when it moves from `origin` along
// `direction`, at most `max_distance`. A raycast with thickness.
//
// - `hit.distance` is how far the sphere moves before it touches, and
//   `hit.point` where it touches.
// - `layers`, `ignore` and triggers are raycast's.
// - A collider the sphere touches where it starts is hit at distance 0, with
//   a zero normal: there is no surface it ran into.
//
// False when nothing is hit, and while the game is not running.
sphere_cast :: proc(origin: [3]f32, radius: f32, direction: [3]f32, max_distance: f32, layers := ~u32(0), ignore := engine.Transform_Handle{}) -> (hit: Raycast_Hit, ok: bool) {
	s := _sphere(origin, radius)
	return _cast_shape(&s, direction, max_distance, layers, ignore)
}

// The first collider a box hits when it moves from `origin` along
// `direction`: `half_extents` each way, turned by `rotation`. The rest is
// sphere_cast's.
box_cast :: proc(origin, half_extents: [3]f32, direction: [3]f32, max_distance: f32, rotation := [4]f32{0, 0, 0, 1}, layers := ~u32(0), ignore := engine.Transform_Handle{}) -> (hit: Raycast_Hit, ok: bool) {
	s := _box(origin, half_extents, rotation)
	return _cast_shape(&s, direction, max_distance, layers, ignore)
}

// The first collider a capsule hits when it moves along `direction`: the
// segment from `a` to `b`, `radius` thick. The rest is sphere_cast's.
capsule_cast :: proc(a, b: [3]f32, radius: f32, direction: [3]f32, max_distance: f32, layers := ~u32(0), ignore := engine.Transform_Handle{}) -> (hit: Raycast_Hit, ok: bool) {
	s := _capsule(a, b, radius)
	return _cast_shape(&s, direction, max_distance, layers, ignore)
}

@(private = "file")
_cast_shape :: proc(s: ^_Shape, direction: [3]f32, max_distance: f32, layers: u32, ignore: engine.Transform_Handle) -> (hit: Raycast_Hit, ok: bool) {
	if !_state.world_ready || max_distance <= 0 do return
	dir := linalg.normalize0(direction)
	if dir == {} do return
	q := _Ray_Query{ctx = context, ignore = ignore, fraction = 2}
	filter := b3.QueryFilter{categoryBits = ~u64(0), maskBits = u64(layers)}
	proxy := _proxy(s)
	_ = b3.World_CastShape(_state.world, s.origin, proxy, dir * max_distance, filter, _ray_hit_fcn, &q)
	if q.fraction > 1 do return
	return {object = q.object, point = q.point, normal = q.normal, distance = q.fraction * max_distance}, true
}
