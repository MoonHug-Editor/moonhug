package scene_tools

// Pick locks: an object locked in the Hierarchy, and everything under it,
// cannot be clicked or box-selected in the Scene window. It still selects
// from the Hierarchy, and everything else about it is unchanged: a floor or
// a backdrop stops catching the clicks meant for what stands on it.
//
// - The locks are a developer's own (user settings), kept per scene by the
//   object's local id, like the Hierarchy's folds. A scene never saved has
//   no guid and keeps none.
// - An object inside a prefab instance is locked by the prefab's own scene,
//   so the lock shows on every instance of that prefab.

import "base:runtime"
import core "moonhug:libs/core"
import "moonhug:packages/engine"

@(user_settings={name="Pick Locks"})
pick_locks: core.Per_Asset([dynamic]engine.Local_ID)

@(private = "file")
_lock_key :: proc(tH: engine.Transform_Handle) -> (guid: engine.Asset_GUID, lid: engine.Local_ID, ok: bool) {
	t := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(tH))
	if t == nil || t.scene == nil || t.scene.asset_guid == {} do return
	// An object made since the last save has no id in the file yet: it gets
	// the one the save would give it.
	lid = t.local_id
	if lid == 0 do lid = engine.sm_local_id_get_or_mint(t.scene, engine.Handle(tH))
	if lid == 0 do return
	return t.scene.asset_guid, lid, true
}

// Whether the object itself is locked.
pick_lock_own :: proc(tH: engine.Transform_Handle) -> bool {
	guid, lid, ok := _lock_key(tH)
	if !ok do return false
	locks := core.per_asset_get(&pick_locks, guid)
	if locks == nil do return false
	for l in locks do if l == lid do return true
	return false
}

// Whether the Scene window passes the object over: it or an object above
// it is locked.
pick_locked :: proc(tH: engine.Transform_Handle) -> bool {
	if len(pick_locks.entries) == 0 do return false
	w := engine.ctx_world()
	cur := tH
	for engine.pool_valid(&w.transforms, engine.Handle(cur)) {
		if pick_lock_own(cur) do return true
		cur = engine.Transform_Handle(engine.pool_get(&w.transforms, engine.Handle(cur)).parent.handle)
	}
	return false
}

// Locks or unlocks the object. False when it cannot hold a lock (its scene
// was never saved).
pick_lock_set :: proc(tH: engine.Transform_Handle, locked: bool) -> bool {
	guid, lid, ok := _lock_key(tH)
	if !ok do return false
	if locked == pick_lock_own(tH) do return true
	context.allocator = runtime.default_allocator()
	if locked {
		append(core.per_asset_entry(&pick_locks, guid), lid)
		return true
	}
	locks := core.per_asset_get(&pick_locks, guid)
	for l, i in locks do if l == lid {
		unordered_remove(locks, i)
		break
	}
	// No entry for a scene with no lock left: the settings file lists only
	// scenes that have some.
	if len(locks) == 0 do core.per_asset_drop(&pick_locks, guid)
	return true
}
