package physics3d

// PhysicsRaycaster: lets the pointer reach 3D colliders. It goes on a camera.
// Each frame the pointer pass (plugins/engine/pointer) asks it what is under
// the pointer: it casts a ray from its camera through the pointer and answers
// with the first collider hit. The object with that collider then gets
// pointer events like a UI node does: a component on it, or on a parent,
// takes them with @(comp_on_pointer).
//
// - UI comes first: a pointer over a canvas's graphic hits nothing behind it.
// - With several raycasters the nearest hit wins.
// - Triggers are passed through, as for every raycast.
// - Colliders exist while the game runs, so nothing is hit in edit mode.

import "moonhug:packages/engine"
import pointer "moonhug:packages/engine/pointer"

@(component={menu="Physics/PhysicsRaycaster", icon="ADS_CLICK"})
@(typ_guid={guid = "d2a4f6c8-1b3e-4a57-9c80-6e2f4b8d0a13"})
PhysicsRaycaster :: struct {
	using base:   engine.CompData `inspect:"-"`,
	layers:       u32 `decor:layers(domain="physics3d") decor:tooltip(desc="The physics layers whose colliders the pointer can hit.")`,
	max_distance: f32 `decor:min(0) decor:tooltip(desc="How far from the camera the pointer reaches.")`,
}

type_reset_PhysicsRaycaster :: proc(r: ^PhysicsRaycaster) {
	engine.comp_zero(r)
	r.layers = ~u32(0)
	r.max_distance = 1000
}

// The nearest collider under a viewport point, over every enabled
// PhysicsRaycaster whose camera is enabled.
@(pointer_raycaster)
pointer_raycast :: proc(position: [2]f32, viewport: [2]f32) -> (best: pointer.Pointer_Hit, ok: bool) {
	w := engine.ctx_world()
	if w == nil do return
	pool := physics_raycasters(w)
	if pool == nil || pool.count == 0 do return
	it := engine.pool_iterator(pool)
	for r, _ in engine.pool_next(&it) {
		if !r.enabled || !engine.transform_active_in_hierarchy(r.owner) do continue
		_, cam := engine.transform_get_comp(r.owner, engine.Camera)
		if cam == nil || !cam.enabled do continue
		ray := engine.camera_screen_ray(cam, position, viewport)
		hit, found := raycast(ray.origin, ray.direction, r.max_distance, r.layers)
		if !found || (ok && hit.distance >= best.distance) do continue
		best = {node = hit.object, source = .World_3D, point = hit.point, normal = hit.normal, distance = hit.distance}
		ok = true
	}
	return
}
