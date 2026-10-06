package sim_world

// The engine's side of Simulate's world provider (moonhug/editor/simulate/world.odin):
// the snapshot is the active scene in the on-disk scene format plus the loaded
// scene set, and the tick runs the engine's fixed-tick accumulator.
// It also hands Simulate the table of runnable packages it can tick.

import "base:runtime"
import "core:strings"
import "moonhug:editor/simulate"
import "moonhug:packages/engine"
import "moonhug:host/input"
import "moonhug:host/log"
import "moonhug:registration"

install_simulate_world :: proc() {
	simulate.set_world({
		capture         = _capture,
		restore         = _restore,
		release         = _release,
		set_playing     = _set_playing,
		tick            = _tick,
		reset_time      = engine.fixed_reset,
		select_restored = _select_restored,
	})
}

@(phase={key=engine.Phase.EditorInit, order=1, mode=Editor})
_install_simulate_world_phase :: proc() {
	install_simulate_world()
	// The runnable packages, from the generated registration/sim_hosts_generated.odin.
	simulate.set_hosts(_hosts_table())
}

// simulate.Host rows built once from registration.sim_hosts. set_hosts borrows
// the slice, so it lives on the default allocator for the editor's lifetime.
@(private = "file")
_hosts: []simulate.Host

@(private = "file")
_hosts_table :: proc() -> []simulate.Host {
	if _hosts != nil || len(registration.sim_hosts) == 0 do return _hosts
	_hosts = make([]simulate.Host, len(registration.sim_hosts), runtime.default_allocator())
	for h, i in registration.sim_hosts {
		_hosts[i] = simulate.Host{name = h.name, path = h.path, update = h.update, fixed_update = h.fixed_update}
	}
	return _hosts
}

// A loaded scene at Start, by session id: Stop unloads what the run loaded on
// top and reloads from disk what the run unloaded.
@(private = "file")
_Loaded_Scene :: struct {
	id:   u32, // engine.Scene.session_id
	path: string,
}

// What the snapshot bytes point at. The record and everything in it live on
// the default allocator until _release: the run outlives whatever allocator
// the caller who pressed Play was on.
@(private = "file")
_Snapshot :: struct {
	scene_bytes: []byte, // the scene as a save writes it
	scene_id:    u32,
	scene_path:  string,
	loaded:      [dynamic]_Loaded_Scene,
}

@(private = "file")
_snapshot_of :: proc(bytes: []byte) -> ^_Snapshot {
	assert(len(bytes) == size_of(_Snapshot), "sim_world: not a snapshot from _capture")
	return (^_Snapshot)(raw_data(bytes))
}

@(private = "file")
_capture :: proc() -> (snapshot: []byte, scene: engine.Scene_Ref, ok: bool) {
	active := engine.sm_scene_get_active()
	if active == nil {
		log.error("Simulate: no active scene")
		return nil, {}, false
	}
	serialized, sok := engine.scene_serialize(active)
	if !sok {
		log.error("Simulate: failed to capture scene snapshot")
		return nil, {}, false
	}
	defer delete(serialized)

	// The snapshot outlives this call by the whole length of the run, so it
	// cannot keep the CALLER's allocator: scene_serialize hands back memory
	// from context.allocator, and whoever pressed Play may be running on a
	// scoped or per-frame one. Reusing that memory rewrites bytes inside the
	// snapshot, which shows up as "snapshot restore failed" on Stop with the
	// scene left in its simulated state, a lost edit.
	snap: ^_Snapshot
	{
		context.allocator = runtime.default_allocator()
		snap = new(_Snapshot)
		snap.scene_bytes = make([]byte, len(serialized))
		copy(snap.scene_bytes, serialized)
		snap.scene_id = active.session_id
		snap.scene_path = strings.clone(active.path)
		sm := engine.ctx_scene_manager()
		for i in 0 ..< sm.count {
			sc := sm.loaded[i]
			if sc == nil do continue
			append(&snap.loaded, _Loaded_Scene{id = sc.session_id, path = strings.clone(sc.path)})
		}
	}
	return ([^]byte)(snap)[:size_of(_Snapshot)], engine.Scene_Ref{id = snap.scene_id}, true
}

// Back to the scene set of Start: scenes the run loaded additively go, scenes
// it unloaded come back from disk (their in-memory state at Start is not
// kept, the simulated scene's is, through the scene bytes). Then the scene
// bytes deserialize back over the simulated scene, scoped to that one scene,
// keeping its slot and active status. Additively loaded scenes are untouched.
//
// Not atomic: on failure the target scene is already destroyed.
@(private = "file")
_restore :: proc(snapshot: []byte) -> (scene: engine.Scene_Ref, ok: bool) {
	snap := _snapshot_of(snapshot)
	sm := engine.ctx_scene_manager()
	for i := 0; i < sm.count; i += 1 {
		sc := sm.loaded[i]
		if sc == nil do continue
		known := false
		for l in snap.loaded do if l.id == sc.session_id { known = true; break }
		if !known do engine.sm_scene_unload(sc)
	}
	for l in snap.loaded {
		if engine.sm_scene_find_by_session_id(l.id) != nil || l.path == "" do continue
		engine.scene_load_additive_path(l.path)
	}

	target := engine.sm_scene_find_by_session_id(snap.scene_id)
	if target == nil do return {}, false
	restored := engine.scene_reload_in_place_bytes(target, snap.scene_bytes, target.asset_guid, snap.scene_path)
	if restored == nil do return {}, false
	return engine.Scene_Ref{id = restored.session_id}, true
}

@(private = "file")
_release :: proc(snapshot: []byte) {
	context.allocator = runtime.default_allocator()
	snap := _snapshot_of(snapshot)
	delete(snap.scene_bytes)
	delete(snap.scene_path)
	for l in snap.loaded do delete(l.path)
	delete(snap.loaded)
	free(snap)
}

// Feeds engine.application_is_playing().
@(private = "file")
_set_playing :: proc(playing: bool) {
	if uc := engine.ctx_get(); uc != nil {
		uc.is_playing = playing
	}
}

// The app loop's order: fixed ticks from the accumulator, then the frame tick.
// A step advances exactly one fixed tick and one frame tick, ignoring the
// accumulator.
@(private = "file")
_tick :: proc(dt: f32, step: bool, fixed_update: proc(dt: f32), update: proc(dt: f32)) {
	fdt := engine.fixed_dt()
	steps := 1 if step else engine.fixed_frame_ticks(dt)
	for _ in 0 ..< steps {
		engine.fixed_tick_begin()
		input.fixed_latch()
		if fixed_update != nil do fixed_update(fdt)
		engine.fixed_tick_advance()
	}
	if update != nil do update(fdt if step else dt)
}

@(private = "file")
_select_restored :: proc(scene: engine.Scene_Ref, id: engine.Local_ID) -> (engine.Transform_Handle, bool) {
	s := engine.sm_scene_find_by_session_id(scene.id)
	if s == nil do return {}, false
	return engine.scene_find_selectable_transform_local_id(s, id)
}
