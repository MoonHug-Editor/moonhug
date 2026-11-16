package physics3d

// Queries against the colliders of the running game: what a ray hits.
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
	q := _Ray_Query{world = engine.ctx_world(), ignore = ignore, fraction = 2}
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
	world:    ^engine.World,
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
	context = runtime.default_context()
	q := cast(^_Ray_Query)ctx
	if b3.Shape_IsSensor(shape) do return -1
	object, known := _owner_of_shape(q.world, shape)
	if !known do return -1
	if q.ignore != {} && _is_under(q.world, object, q.ignore) do return -1
	if fraction < q.fraction {
		q.fraction = fraction
		q.object = object
		q.point = point
		q.normal = normal
	}
	return fraction
}

// Whether `tH` is `ancestor` or an object under it.
@(private = "file")
_is_under :: proc(w: ^engine.World, tH, ancestor: engine.Transform_Handle) -> bool {
	at := tH
	for _ in 0 ..< 4096 {
		if at == ancestor do return true
		t := engine.pool_get(&w.transforms, engine.Handle(at))
		if t == nil || t.parent.handle == {} do return false
		at = engine.Transform_Handle(t.parent.handle)
	}
	return false
}
