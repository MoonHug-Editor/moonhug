package undo

// What the undo stack asks of whoever owns pooled objects and scenes. The
// shell has no world: a Value_Command on a .Pooled target names a handle, the
// scene it lives in and its local id, and the installed engine turns that into
// a live pointer (plugins/engine/editor/undo/target_resolver.odin).
// Without a resolver, .Pooled targets never resolve and scenes are never
// dirtied, while .Raw and .Asset targets work as before.

import core "moonhug:host/core"

Target_Resolver :: struct {
	// The live base pointer of a pooled target, re-found through scene and
	// local id when the handle is stale (a reload, or a redo of a delete).
	pooled_base:      proc(t: Property_Target) -> (base: rawptr, handle: core.Handle, ok: bool),
	// The scene and local id a handle is recorded under, for make_pooled_target.
	pooled_identity:  proc(h: core.Handle) -> (scene: core.Scene_Ref, local_id: core.Local_ID, ok: bool),
	// After a value is written back: rebinds reference fields inside it against the scene.
	fixup_refs:       proc(ptr: rawptr, tid: typeid, scene: core.Scene_Ref),
	scene_alive:      proc(r: core.Scene_Ref) -> bool,
	scene_mark_dirty: proc(r: core.Scene_Ref),
	scene_name:       proc(r: core.Scene_Ref) -> string,
	// Display names for the history view (describe).
	object_name:      proc(r: core.Scene_Ref, local_id: core.Local_ID) -> (string, bool),
	target_name:      proc(t: Property_Target) -> (string, bool),
	asset_path:       proc(guid: core.Asset_GUID) -> (string, bool),
}

@(private) _resolver: Target_Resolver

set_target_resolver :: proc(r: Target_Resolver) {
	_resolver = r
}

scene_alive :: proc(r: core.Scene_Ref) -> bool {
	if r.id == 0 || _resolver.scene_alive == nil do return false
	return _resolver.scene_alive(r)
}

scene_mark_dirty :: proc(r: core.Scene_Ref) {
	if r.id == 0 || _resolver.scene_mark_dirty == nil do return
	_resolver.scene_mark_dirty(r)
}

scene_name :: proc(r: core.Scene_Ref) -> string {
	if r.id == 0 || _resolver.scene_name == nil do return ""
	return _resolver.scene_name(r)
}

// The name of the object a selection item names, "" when it does not resolve.
object_name :: proc(r: core.Scene_Ref, local_id: core.Local_ID) -> (string, bool) {
	if r.id == 0 || _resolver.object_name == nil do return "", false
	return _resolver.object_name(r, local_id)
}

// The name of the object a pooled target edits (its owner, for a component).
target_name :: proc(t: Property_Target) -> (string, bool) {
	if t.kind != .Pooled || _resolver.target_name == nil do return "", false
	return _resolver.target_name(t)
}

asset_path :: proc(guid: core.Asset_GUID) -> (string, bool) {
	if _resolver.asset_path == nil do return "", false
	return _resolver.asset_path(guid)
}
