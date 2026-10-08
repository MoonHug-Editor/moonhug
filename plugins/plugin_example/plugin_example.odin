package plugin_example

// Example plugin package (docs/core/Plugins.md). Demonstrates the whole surface:
// a component (inspector + serialization come from the attribute), an
// @(fixed_update) tick, an editor-only subpackage with a menu item (editor/), and
// mounted content (assets/). Everything registers through prebuild — no
// source edits outside this folder.

import "moonhug:packages/engine"

// Spins its transform by `speed` degrees per second around each local axis
// (Unity rotator style: rotation += speed * dt), in playmode.
@(component={menu="Plugin Example/Spinner"})
@(typ_guid={guid = "84040061-0c08-4f71-84ae-255899c77d9f"})
Spinner :: struct {
	using base: engine.CompData `inspect:"-"`,
	speed:      [3]f32,
}

reset_Spinner :: proc(comp: ^Spinner) {
	comp.speed = {0, 0, 90}
}

// Per-item shape: the generated loop calls this for every enabled Spinner.
@(fixed_update={component=Spinner})
spinner_tick :: proc(dt: f32, s: ^Spinner) {
	if s.speed == {} do return
	t := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(s.owner))
	if t == nil do return
	step := engine.quat_from_euler_xyz(s.speed.x * dt, s.speed.y * dt, s.speed.z * dt)
	t.rotation = engine.quat_from_native(engine.quat_to_native(step) * engine.quat_to_native(t.rotation))
}
