package simulate

// The world Simulate runs, as a provider the engine installs
// (plugins/engine/editor/sim_world). The state machine asks it for a snapshot
// at Start, hands the snapshot back at Stop, and lets it run each frame's ticks.
// With no world installed a run captures and restores nothing and ticks only
// the per-frame update.

import core "moonhug:host/core"
import "base:runtime"
import "moonhug:editor/provider"

Simulate_World :: struct {
	// The active scene and the loaded scene set, encoded however the world
	// wants. The snapshot stays valid until release. `scene` is the scene a
	// Stop restores. False logs the reason and refuses the Start.
	capture:         proc() -> (snapshot: []byte, scene: core.Scene_Ref, ok: bool),
	// Back to the snapshot: scenes the run loaded go, scenes it unloaded come
	// back, and the captured scene reverts. `scene` is the restored scene.
	restore:         proc(snapshot: []byte) -> (scene: core.Scene_Ref, ok: bool),
	release:         proc(snapshot: []byte),
	// What the game sees as "playing", true from Start to Stop.
	set_playing:     proc(playing: bool),
	// Clears the fixed-tick accumulator, at Start and at Stop.
	reset_time:      proc(),
	// The object a selection can hold for `id` in the restored `scene`.
	select_restored: proc(scene: core.Scene_Ref, id: core.Local_ID) -> (core.Transform_Handle, bool),
}

@(private) _world: Simulate_World

@(init)
_register_simulate_world :: proc "contextless" () {
	context = runtime.default_context()
	provider.register("Simulate_World", &_world)
}

set_world :: proc(w: Simulate_World) {
	_world = w
}

world_capture :: proc() -> (snapshot: []byte, scene: core.Scene_Ref, ok: bool) {
	if _world.capture == nil do return nil, {}, true
	return _world.capture()
}

world_restore :: proc(snapshot: []byte) -> (scene: core.Scene_Ref, ok: bool) {
	if _world.restore == nil do return {}, true
	return _world.restore(snapshot)
}

world_release :: proc(snapshot: []byte) {
	if _world.release != nil do _world.release(snapshot)
}

world_set_playing :: proc(playing: bool) {
	if _world.set_playing != nil do _world.set_playing(playing)
}

world_reset_time :: proc() {
	if _world.reset_time != nil do _world.reset_time()
}

world_select_restored :: proc(scene: core.Scene_Ref, id: core.Local_ID) -> (core.Transform_Handle, bool) {
	if _world.select_restored == nil do return {}, false
	return _world.select_restored(scene, id)
}
