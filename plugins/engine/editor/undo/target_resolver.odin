package scene_undo

// The engine's answer to the undo stack's Target_Resolver: pooled targets are
// objects of the active world, re-found by local id inside their scene, and
// scenes are the scene manager's loaded scenes, found by session id. Installed
// through @(provider_install). The stack
// itself lives on the engine's user context, wired at program start.

import "base:runtime"
import "core:encoding/uuid"
import "core:path/filepath"
import shell "moonhug:editor/undo"
import "moonhug:packages/engine"
import "moonhug:packages/engine/editor/undo_ops"

@(provider_install)
install_target_resolver :: proc() {
	shell.set_target_resolver({
		pooled_base      = _pooled_base,
		pooled_identity  = _pooled_identity,
		fixup_refs       = _fixup_refs,
		scene_alive      = _scene_alive,
		scene_mark_dirty = _scene_mark_dirty,
		scene_name       = _scene_name,
		object_name      = _object_name,
		target_name      = _target_name,
		asset_path       = _asset_path,
	})
}

// Each user context holds its own stack (UserContext.undo), so a preview world
// with no stack records nothing. Wired before main, since the editor installs
// its stack ahead of EditorInit.
@(init)
_install_stack_slot :: proc "contextless" () {
	context = runtime.default_context()
	shell.set_stack_slot(_stack_slot)
}

_stack_slot :: proc() -> ^rawptr {
	uc := engine.ctx_get()
	if uc == nil do return nil
	return &uc.undo
}

// Drops the undo entries that reference this scene. Call BEFORE unloading it.
_purge_scene_ptr :: proc(s: ^shell.Undo_Stack, scene: ^engine.Scene) {
	if scene == nil do return
	shell.purge_scene(s, engine.Scene_Ref{id = scene.session_id})
}

_pooled_base :: proc(t: shell.Property_Target) -> (rawptr, engine.Handle, bool) {
	if t.kind != .Pooled do return nil, {}, false
	w := engine.ctx_world()
	if w == nil do return nil, {}, false
	h := t.handle
	if !engine.world_pool_valid(w, h) {
		sc := engine.sm_scene_find_by_session_id(t.scene.id)
		if sc == nil || t.local_id == 0 do return nil, {}, false
		resolved: engine.Handle
		ok: bool
		if h.type_key == .Transform {
			resolved, ok = undo_ops.scene_find_transform_by_local_id(sc, t.local_id)
		} else {
			resolved, ok = undo_ops.scene_find_component_by_local_id(sc, t.local_id)
		}
		if !ok do return nil, {}, false
		h = resolved
	}
	base := engine.world_pool_get(w, h)
	if base == nil do return nil, h, false
	return base, h, true
}

_pooled_identity :: proc(h: engine.Handle) -> (scene: engine.Scene_Ref, local_id: engine.Local_ID, ok: bool) {
	w := engine.ctx_world()
	if w == nil do return {}, 0, false
	if h.type_key == .Transform {
		t := engine.pool_get(&w.transforms, h)
		if t == nil do return {}, 0, false
		if t.scene != nil do scene = {id = t.scene.session_id}
		return scene, t.local_id, true
	}
	base := engine.world_pool_get(w, h)
	if base == nil do return {}, 0, false
	cbase := cast(^engine.CompData)base
	if t := engine.pool_get(&w.transforms, engine.Handle(cbase.owner)); t != nil && t.scene != nil {
		scene = {id = t.scene.session_id}
	}
	return scene, cbase.local_id, true
}

_fixup_refs :: proc(ptr: rawptr, tid: typeid, scene: engine.Scene_Ref) {
	s := engine.sm_scene_find_by_session_id(scene.id)
	if s == nil do return
	engine._resolve_refs_in_value(ptr, type_info_of(tid), s, nil, false, true)
}

_scene_alive :: proc(r: engine.Scene_Ref) -> bool {
	return engine.sm_scene_find_by_session_id(r.id) != nil
}

_scene_mark_dirty :: proc(r: engine.Scene_Ref) {
	if s := engine.sm_scene_find_by_session_id(r.id); s != nil do s.dirty = true
}

_scene_name :: proc(r: engine.Scene_Ref) -> string {
	s := engine.sm_scene_find_by_session_id(r.id)
	if s == nil do return ""
	if s.path == "" do return "Untitled"
	return filepath.stem(s.path)
}

// The selectable object a selection item names, for the history view.
_object_name :: proc(r: engine.Scene_Ref, local_id: engine.Local_ID) -> (string, bool) {
	sc := engine.sm_scene_find_by_session_id(r.id)
	if sc == nil do return "", false
	tH, ok := engine.scene_find_selectable_transform_local_id(sc, local_id)
	if !ok do return "", false
	t := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(tH))
	if t == nil do return "", false
	return t.name, true
}

// The object a pooled target edits (the owner, for a component), for the
// history view. Found through _pooled_base, so it survives a recreated object.
_target_name :: proc(t: shell.Property_Target) -> (string, bool) {
	w := engine.ctx_world()
	if w == nil do return "", false
	base, h, ok := _pooled_base(t)
	if !ok do return "", false
	if h.type_key == .Transform do return (cast(^engine.Transform)base).name, true
	c := cast(^engine.CompData)base
	ot := engine.pool_get(&w.transforms, engine.Handle(c.owner))
	if ot == nil do return "", false
	return ot.name, true
}

_asset_path :: proc(guid: engine.Asset_GUID) -> (string, bool) {
	return engine.asset_db_get_path(uuid.Identifier(guid))
}

// The shell purges by Scene_Ref, the engine side also by the scene it holds.
purge_scene :: proc{shell.purge_scene, _purge_scene_ptr}
