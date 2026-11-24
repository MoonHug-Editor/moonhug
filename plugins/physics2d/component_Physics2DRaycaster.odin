package physics2d

// Physics2DRaycaster: lets the pointer reach 2D colliders. It goes on a
// camera. Each frame the pointer pass (plugins/engine/pointer) asks it what
// is under the pointer: it finds where the camera's ray through the pointer crosses
// the XY plane the 2D bodies live in, and answers with a collider that
// holds that point. The object with that collider then gets pointer events
// like a UI node does: a component on it, or on a parent, takes them with
// @(comp_on_pointer).
//
// - UI comes first: a pointer over a canvas's graphic hits nothing behind it.
// - With several raycasters the nearest hit wins.
// - Where colliders overlap, which one answers is not defined.
// - Triggers are passed through, as for every query.
// - Colliders exist while the game runs, so nothing is hit in edit mode.

import "base:runtime"
import "moonhug:packages/engine"
import pointer "moonhug:packages/engine/pointer"

@(component={menu="Physics2D/Physics2DRaycaster"})
@(typ_guid={guid = "7f1c3e59-8a2d-4b06-a4e7-0d9b5c3f6e28"})
Physics2DRaycaster :: struct {
	using base: engine.CompData `inspect:"-"`,
	layers:     u32 `decor:layers(domain="physics2d") decor:tooltip(desc="The physics2d layers whose colliders the pointer can hit.")`,
}

type_reset_Physics2DRaycaster :: proc(r: ^Physics2DRaycaster) {
	engine.comp_zero(r)
	r.layers = ~u32(0)
}

// How near the pointer's point a collider must be: the point itself.
POINTER_RADIUS :: f32(0.001)

@(init)
_register_pointer_raycaster :: proc "contextless" () {
	context = runtime.default_context()
	pointer.raycaster_register(pointer_raycast)
}

// A collider under a viewport point, over every enabled Physics2DRaycaster
// whose camera is enabled: the nearest camera plane crossing wins.
pointer_raycast :: proc(position: [2]f32, viewport: [2]f32) -> (best: pointer.Pointer_Hit, ok: bool) {
	w := engine.ctx_world()
	if w == nil do return
	pool := physics2_d_raycasters(w)
	if pool == nil || pool.count == 0 do return
	it := engine.pool_iterator(pool)
	for r, _ in engine.pool_next(&it) {
		if !r.enabled || !engine.transform_active_in_hierarchy(r.owner) do continue
		_, cam := engine.transform_get_comp(r.owner, engine.Camera)
		if cam == nil || !cam.enabled do continue
		ray := engine.camera_screen_ray(cam, position, viewport)
		// Where the ray crosses z = 0.
		if abs(ray.direction.z) < 1e-6 do continue
		t := -ray.origin.z / ray.direction.z
		if t < 0 || (ok && t >= best.distance) do continue
		point := ray.origin + ray.direction * t
		touched := overlap_circle(point.xy, POINTER_RADIUS, r.layers)
		if len(touched) == 0 do continue
		best = {node = touched[0], source = .World_2D, point = {point.x, point.y, 0}, normal = {0, 0, 1}, distance = t}
		ok = true
	}
	return
}
