package physics2d

// Queries against the 2D colliders of the running game: what a ray hits.
//
// - Bodies exist only while the game runs (physics_step builds them), so a
//   query in edit mode, or before the first step, hits nothing.
// - A query sees the colliders as of the last step: a body moved since then
//   by its transform is found where the step left it.

import "base:runtime"
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
