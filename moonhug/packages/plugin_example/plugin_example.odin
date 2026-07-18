package plugin_example

// Example plugin package (docs/Plugins.md). Demonstrates the whole surface:
// a component (inspector + serialization come from the attribute), an
// @(update) tick, an editor-only subpackage with a menu item (editor/), and
// mounted content (assets/). Everything registers through prebuild — no
// source edits outside this folder.

import "../../engine"

// Spins its transform by `speed` degrees per second around each local axis
// (Unity rotator style: rotation += speed * dt), in playmode.
@(component)
@(typ_guid={guid = "84040061-0c08-4f71-84ae-255899c77d9f"})
Spinner :: struct {
	using base: engine.CompData `inspect:"-"`,
	speed:      [3]f32,
}

reset_Spinner :: proc(comp: ^Spinner) {
	comp.speed = {0, 0, 90}
}

@(update={order=0})
spinner_tick :: proc(dt: f32) {
	w := engine.ctx_world()
	pool := spinners(w)
	if pool == nil do return
	for i in 0 ..< len(pool.slots) {
		slot := &pool.slots[i]
		if !slot.alive do continue
		s := &slot.data
		if !s.enabled do continue
		t := engine.pool_get(&w.transforms, engine.Handle(s.owner))
		if t == nil do continue
		if s.speed == {} do continue
		step := engine.quat_from_euler_xyz(s.speed.x * dt, s.speed.y * dt, s.speed.z * dt)
		t.rotation = engine.quat_from_native(engine.quat_to_native(step) * engine.quat_to_native(t.rotation))
	}
}
