package drawers

// The engine's answer to the inspector's Object_Provider: objects are the
// transforms of the active world, a component's owner is on its CompData, and
// local ids mint against the owner's root scene. Installed at EditorInit after
// inspector.init, and by moonhug/tests/common for the test binary.

import "moonhug:editor/inspector"
import "moonhug:packages/engine"
import "moonhug:host/gizmos"
import gfx "moonhug:host/gfx"

install_object_provider :: proc() {
	inspector.set_object_provider({
		owner_of          = _owner_of,
		object_name       = _object_name,
		object_local_id   = _object_local_id,
		object_scene      = _object_scene,
		object_parent     = _object_parent,
		owner_scope       = _owner_scope,
		mint_local_id     = _mint_local_id,
		find_objects      = _find_objects,
		object_has_any    = _object_has_any,
		keys_with_ref_tag = _keys_with_ref_tag,
		object_active     = _object_active,
	})
}

@(phase={key=engine.Phase.EditorInit, order=1, mode=Editor})
_install_object_provider_phase :: proc() {
	install_object_provider()
}

_owner_of :: proc(h: engine.Handle) -> (engine.Transform_Handle, bool) {
	w := engine.ctx_world()
	if w == nil || !engine.world_pool_valid(w, h) do return {}, false
	if h.type_key == .Transform do return engine.Transform_Handle(h), true
	raw := engine.world_pool_get(w, h)
	if raw == nil do return {}, false
	return (cast(^engine.CompData)raw).owner, true
}

_object_name :: proc(tH: engine.Transform_Handle) -> string {
	t := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(tH))
	return t.name if t != nil else ""
}

_object_local_id :: proc(tH: engine.Transform_Handle) -> (engine.Local_ID, bool) {
	w := engine.ctx_world()
	if w == nil do return 0, false
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return 0, false
	return t.local_id, true
}

_object_scene :: proc(tH: engine.Transform_Handle) -> engine.Scene_Ref {
	w := engine.ctx_world()
	if w == nil do return {}
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil || t.scene == nil do return {}
	return engine.Scene_Ref{id = t.scene.session_id}
}

_object_parent :: proc(tH: engine.Transform_Handle) -> (engine.Transform_Handle, bool) {
	w := engine.ctx_world()
	if w == nil do return {}, false
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil || !engine.pool_valid(&w.transforms, t.parent.handle) do return {}, false
	return engine.Transform_Handle(t.parent.handle), true
}

_owner_scope :: proc(owner: engine.Handle) -> rawptr {
	tH, ok := _owner_of(owner)
	if !ok do return nil
	return engine.sm_get_root_scene_of_transform(tH)
}

_mint_local_id :: proc(scope: rawptr, h: engine.Handle) -> engine.Local_ID {
	return engine.sm_local_id_get_or_mint(cast(^engine.Scene)scope, h)
}

_find_objects :: proc(key: engine.TypeKey, scope: rawptr) -> []engine.Found_Object {
	return engine.sm_find_objects_of_type(key, cast(^engine.Scene)scope)
}

_object_has_any :: proc(tH: engine.Transform_Handle, keys: []engine.TypeKey) -> bool {
	t := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(tH))
	if t == nil do return false
	for c in t.components do for k in keys do if c.handle.type_key == k do return true
	return false
}

_keys_with_ref_tag :: proc(tag: string) -> []engine.TypeKey {
	return engine.component_keys_with_ref_tag(tag)
}

_object_active :: proc(tH: engine.Transform_Handle) -> bool {
	return engine.transform_active_in_hierarchy(tH)
}

// The gizmos package draws in an object's space and shows asset images on
// icons, and asks the engine for both.
install_gizmo_sources :: proc() {
	gizmos.set_transform_source(proc(tH: engine.Transform_Handle) -> (position: [3]f32, rotation: [4]f32, scale: [3]f32, ok: bool) {
		if !engine.pool_valid(&engine.ctx_world().transforms, engine.Handle(tH)) do return {}, {}, {}, false
		tw := engine.transform_world(tH)
		return tw.position, tw.rotation, tw.scale, true
	})
	gizmos.set_image_source(proc(guid: engine.Asset_GUID) -> ^gfx.Texture {
		// A texture that does not load (a deleted asset) leaves the backdrop.
		if t, ok := engine.texture_load(guid); ok do return t.gfx
		return nil
	})
}

@(phase={key=engine.Phase.EditorInit, order=1, mode=Editor})
_install_gizmo_sources_phase :: proc() {
	install_gizmo_sources()
}
