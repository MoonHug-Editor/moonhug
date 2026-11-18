package physics2d

// Queries against the 2D colliders of the running game: what a ray hits,
// what a moving shape hits, and what a shape touches.
//
// - Bodies exist only while the game runs (physics_step builds them), so a
//   query in edit mode, or before the first step, hits nothing.
// - A query sees the colliders as of the last step: a body moved since then
//   by its transform is found where the step left it.

import "base:runtime"
import "core:math"
import "core:math/linalg"
import b2 "vendor:box2d"
import "moonhug:packages/engine"

// What a ray hit.
Raycast_Hit :: struct {
	object:   engine.Transform_Handle, // the object carrying the collider hit
	point:    [2]f32,
	normal:   [2]f32, // the surface's, at `point`
	distance: f32, // from the ray's origin to `point`
}

// The first collider a ray hits, from `origin` along `direction`, at most
// `max_distance` away, in the XY plane the 2D bodies live in.
//
// - `layers`: the physics2d layers whose colliders the ray can hit, all of
//   them by default. A collider is hit when one of its layers is in `layers`.
// - `ignore`: an object the ray passes through, with every object under it,
//   such as the object casting the ray. {} for none.
// - Triggers are passed through.
//
// False when nothing is hit, and while the game is not running.
raycast :: proc(origin, direction: [2]f32, max_distance: f32, layers := ~u32(0), ignore := engine.Transform_Handle{}) -> (hit: Raycast_Hit, ok: bool) {
	if !_state.world_ready || max_distance <= 0 do return
	dir := linalg.normalize0(direction)
	if dir == {} do return
	q := _Ray_Query{ctx = context, ignore = ignore, fraction = 2}
	// The query is on every layer, so a collider's own mask never hides it:
	// `layers` alone says what it hits.
	filter := b2.QueryFilter{categoryBits = ~u64(0), maskBits = u64(layers)}
	_ = b2.World_CastRay(_state.world, origin, dir * max_distance, filter, _ray_hit_fcn, &q)
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
	point:    [2]f32,
	normal:   [2]f32,
}

// Called by box2d for each collider along the ray, in no order. Returns -1
// to pass through a hit, else its fraction, which shortens the ray to it so
// only closer hits come after.
@(private = "file")
_ray_hit_fcn :: proc "c" (shape: b2.ShapeId, point: b2.Vec2, normal: b2.Vec2, fraction: f32, ctx: rawptr) -> f32 {
	q := cast(^_Ray_Query)ctx
	context = q.ctx
	if b2.Shape_IsSensor(shape) do return -1
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
// A query's own shape, placed in the world for the one call: a circle, a box
// or a capsule. It is no collider and nothing collides with it.

@(private = "file")
_circle :: proc(center: [2]f32, radius: f32) -> b2.ShapeProxy {
	points := [1]b2.Vec2{center}
	return b2.MakeProxy(points[:], max(radius, 0))
}

@(private = "file")
_capsule :: proc(a, b: [2]f32, radius: f32) -> b2.ShapeProxy {
	points := [2]b2.Vec2{a, b}
	return b2.MakeProxy(points[:], max(radius, 0))
}

// `angle` in degrees, counterclockwise.
@(private = "file")
_box :: proc(center, half_extents: [2]f32, angle: f32) -> b2.ShapeProxy {
	sn, cs := math.sincos(math.to_radians(angle))
	points: [4]b2.Vec2
	for i in 0 ..< 4 {
		x := -half_extents.x if i == 0 || i == 3 else half_extents.x
		y := -half_extents.y if i < 2 else half_extents.y
		points[i] = center + {x * cs - y * sn, x * sn + y * cs}
	}
	return b2.MakeProxy(points[:], 0)
}

// --- Overlap ------------------------------------------------------------------

// Every object with a collider that touches a circle.
//
// - `layers` and `ignore` are raycast's. Triggers are left out.
// - An object is listed once, however many of its colliders touch.
// - The list is in no order, and it is allocated with `allocator`, the
//   temporary one by default.
//
// Empty when nothing touches, and while the game is not running.
overlap_circle :: proc(center: [2]f32, radius: f32, layers := ~u32(0), ignore := engine.Transform_Handle{}, allocator := context.temp_allocator) -> []engine.Transform_Handle {
	s := _circle(center, radius)
	return _overlap(&s, layers, ignore, allocator)
}

// Every object with a collider that touches a box: `half_extents` each way
// from `center`, turned by `angle` degrees counterclockwise. The rest is
// overlap_circle's.
overlap_box :: proc(center, half_extents: [2]f32, angle: f32 = 0, layers := ~u32(0), ignore := engine.Transform_Handle{}, allocator := context.temp_allocator) -> []engine.Transform_Handle {
	s := _box(center, half_extents, angle)
	return _overlap(&s, layers, ignore, allocator)
}

// Every object with a collider that touches a capsule: the segment from `a`
// to `b`, `radius` thick. The rest is overlap_circle's.
overlap_capsule :: proc(a, b: [2]f32, radius: f32, layers := ~u32(0), ignore := engine.Transform_Handle{}, allocator := context.temp_allocator) -> []engine.Transform_Handle {
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
_overlap :: proc(s: ^b2.ShapeProxy, layers: u32, ignore: engine.Transform_Handle, allocator: runtime.Allocator) -> []engine.Transform_Handle {
	if !_state.world_ready do return nil
	q := _Overlap_Query{ctx = context, ignore = ignore, found = make([dynamic]engine.Transform_Handle, allocator)}
	filter := b2.QueryFilter{categoryBits = ~u64(0), maskBits = u64(layers)}
	_ = b2.World_OverlapShape(_state.world, s^, filter, _overlap_fcn, &q)
	return q.found[:]
}

// Called by box2d for each collider the shape touches. True goes on.
@(private = "file")
_overlap_fcn :: proc "c" (shape: b2.ShapeId, ctx: rawptr) -> bool {
	q := cast(^_Overlap_Query)ctx
	context = q.ctx
	if b2.Shape_IsSensor(shape) do return true
	object, known := _owner_of_shape(engine.ctx_world(), shape)
	if !known do return true
	if q.ignore != {} && engine.transform_is_under(object, q.ignore) do return true
	for o in q.found do if o == object do return true
	append(&q.found, object)
	return true
}

// --- Shape casts --------------------------------------------------------------

// The first collider a circle hits when it moves from `origin` along
// `direction`, at most `max_distance`. A raycast with thickness.
//
// - `hit.distance` is how far the circle moves before it touches, and
//   `hit.point` where it touches.
// - `layers`, `ignore` and triggers are raycast's.
// - A collider the circle touches where it starts is hit at distance 0, with
//   a zero normal: there is no surface it ran into.
//
// False when nothing is hit, and while the game is not running.
circle_cast :: proc(origin: [2]f32, radius: f32, direction: [2]f32, max_distance: f32, layers := ~u32(0), ignore := engine.Transform_Handle{}) -> (hit: Raycast_Hit, ok: bool) {
	s := _circle(origin, radius)
	return _cast_shape(&s, direction, max_distance, layers, ignore)
}

// The first collider a box hits when it moves from `origin` along
// `direction`: `half_extents` each way, turned by `angle` degrees
// counterclockwise. The rest is circle_cast's.
box_cast :: proc(origin, half_extents: [2]f32, direction: [2]f32, max_distance: f32, angle: f32 = 0, layers := ~u32(0), ignore := engine.Transform_Handle{}) -> (hit: Raycast_Hit, ok: bool) {
	s := _box(origin, half_extents, angle)
	return _cast_shape(&s, direction, max_distance, layers, ignore)
}

// The first collider a capsule hits when it moves along `direction`: the
// segment from `a` to `b`, `radius` thick. The rest is circle_cast's.
capsule_cast :: proc(a, b: [2]f32, radius: f32, direction: [2]f32, max_distance: f32, layers := ~u32(0), ignore := engine.Transform_Handle{}) -> (hit: Raycast_Hit, ok: bool) {
	s := _capsule(a, b, radius)
	return _cast_shape(&s, direction, max_distance, layers, ignore)
}

@(private = "file")
_cast_shape :: proc(s: ^b2.ShapeProxy, direction: [2]f32, max_distance: f32, layers: u32, ignore: engine.Transform_Handle) -> (hit: Raycast_Hit, ok: bool) {
	if !_state.world_ready || max_distance <= 0 do return
	dir := linalg.normalize0(direction)
	if dir == {} do return
	q := _Ray_Query{ctx = context, ignore = ignore, fraction = 2}
	filter := b2.QueryFilter{categoryBits = ~u64(0), maskBits = u64(layers)}
	_ = b2.World_CastShape(_state.world, s^, dir * max_distance, filter, _ray_hit_fcn, &q)
	if q.fraction > 1 do return
	return {object = q.object, point = q.point, normal = q.normal, distance = q.fraction * max_distance}, true
}
