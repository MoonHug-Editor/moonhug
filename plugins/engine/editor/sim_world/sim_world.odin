package sim_world

// The engine's side of Simulate's world provider (moonhug/editor/simulate/world.odin):
// the snapshot is the active scene in the on-disk scene format plus the loaded
// scene set, and the tick runs the engine's fixed-tick accumulator.
// It also hands Simulate the table of runnable packages it can tick.

import "base:runtime"
import "core:strings"
import "moonhug:editor/simulate"
import "moonhug:packages/engine"
import "moonhug:libs/log"
import ser "moonhug:libs/serialization"
import "moonhug:registration"

@(provider_install)
install_simulate_world :: proc() {
	simulate.set_world({
		capture         = _capture,
		restore         = _restore,
		release         = _release,
		set_playing     = _set_playing,
		reset_time      = engine.fixed_reset,
		select_restored = _select_restored,
		scene_asset     = _scene_asset,
		scene_of_asset  = _scene_of_asset,
	})
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
		_hosts[i] = simulate.Host{name = h.name, path = h.path, tick = h.tick}
	}
	return _hosts
}

// A loaded scene at Start, by session id: Stop unloads what the run loaded on
// top, brings back what the run unloaded, and gives every scene the run
// changed its content of Start.
@(private = "file")
_Loaded_Scene :: struct {
	id:    u32, // engine.Scene.session_id
	path:  string,
	// The scene as a save writes it, nil for the simulated scene, whose
	// bytes are the snapshot's own.
	bytes: []byte,
	dirty: bool,
}

// What the snapshot bytes point at. The record and everything in it live on
// the default allocator until _release: the run outlives whatever allocator
// the caller who pressed Play was on.
@(private = "file")
_Snapshot :: struct {
	scene_bytes: []byte, // the scene as a save writes it
	scene_id:    u32,
	scene_path:  string,
	// The scene had edits not saved at Start. The restore brings those
	// edits back, so it brings this back too: Save still writes them.
	scene_dirty: bool,
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
	serialized, sok := _scene_bytes(active)
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
		snap.scene_dirty = active.dirty
		sm := engine.ctx_scene_manager()
		for i in 0 ..< sm.count {
			sc := sm.loaded[i]
			if sc == nil do continue
			l := _Loaded_Scene{id = sc.session_id, path = strings.clone(sc.path), dirty = sc.dirty}
			// The other loaded scenes too: the run can change any of them.
			if sc != active {
				if other, other_ok := _scene_bytes(sc, context.temp_allocator); other_ok {
					l.bytes = make([]byte, len(other))
					copy(l.bytes, other)
				}
			}
			append(&snap.loaded, l)
		}
	}
	return ([^]byte)(snap)[:size_of(_Snapshot)], engine.Scene_Ref{id = snap.scene_id}, true
}

// A scene as a save writes it, with embedded assets' ids, as an undo
// snapshot: Stop gives each field its embedded asset back, so edit steps
// recorded before Play still reach it.
@(private = "file")
_scene_bytes :: proc(s: ^engine.Scene, allocator := context.allocator) -> ([]byte, bool) {
	prev := ser.pptr_embedded_ids
	ser.pptr_embedded_ids = true
	defer ser.pptr_embedded_ids = prev
	context.allocator = allocator
	return engine.scene_serialize(s)
}

// Back to the scene set of Start: scenes the run loaded additively go, and
// scenes it unloaded come back from disk. Then each scene gets its content of
// Start back from its bytes, in place, keeping its slot and active status.
// The simulated scene always does. Another loaded scene does when the run
// changed it, so one the run left alone keeps its objects' handles.
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
		if l.id == snap.scene_id do continue
		sc := engine.sm_scene_find_by_session_id(l.id)
		if sc == nil {
			// Unloaded by the run: from disk, then its content of Start over it.
			if l.path == "" do continue
			sc = engine.scene_load(l.path, additive = true)
			if sc == nil do continue
		} else if l.bytes != nil {
			now, now_ok := _scene_bytes(sc, context.temp_allocator)
			if now_ok && string(now) == string(l.bytes) do continue // the run left it alone
		}
		if l.bytes == nil do continue
		back := engine.scene_reload_in_place_bytes(sc, l.bytes, sc.asset_guid, l.path)
		if back == nil {
			log.errorf("Simulate: scene %s did not restore", l.path)
			continue
		}
		back.session_id = l.id
		back.dirty = l.dirty
	}

	target := engine.sm_scene_find_by_session_id(snap.scene_id)
	if target == nil do return {}, false
	restored := engine.scene_reload_in_place_bytes(target, snap.scene_bytes, target.asset_guid, snap.scene_path)
	if restored == nil do return {}, false
	restored.dirty = snap.scene_dirty
	return engine.Scene_Ref{id = restored.session_id}, true
}

@(private = "file")
_release :: proc(snapshot: []byte) {
	context.allocator = runtime.default_allocator()
	snap := _snapshot_of(snapshot)
	delete(snap.scene_bytes)
	delete(snap.scene_path)
	for l in snap.loaded {
		delete(l.path)
		delete(l.bytes)
	}
	delete(snap.loaded)
	free(snap)
}

// Feeds engine.application_is_playing(): Start awakes the loaded scenes, Stop
// runs the game's comp_on_destroy pass before the restore.
@(private = "file")
_set_playing :: proc(playing: bool) {
	engine.application_set_playing(playing)
}

@(private = "file")
_scene_asset :: proc(scene: engine.Scene_Ref) -> engine.Asset_GUID {
	s := engine.sm_scene_find_by_session_id(scene.id)
	return s != nil ? s.asset_guid : {}
}

@(private = "file")
_scene_of_asset :: proc(guid: engine.Asset_GUID) -> engine.Scene_Ref {
	if engine.asset_guid_is_empty(guid) do return {}
	s := engine.sm_scene_find_by_guid(guid)
	return s != nil ? engine.Scene_Ref{id = s.session_id} : {}
}

@(private = "file")
_select_restored :: proc(scene: engine.Scene_Ref, id: engine.Local_ID) -> (engine.Transform_Handle, bool) {
	s := engine.sm_scene_find_by_session_id(scene.id)
	if s == nil do return {}, false
	return engine.scene_find_selectable_transform_local_id(s, id)
}
