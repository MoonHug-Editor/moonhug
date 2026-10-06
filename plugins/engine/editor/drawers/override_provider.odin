package drawers

// The engine's answer to the inspector's Override_Provider: overrides live on
// the root nested scene of the instance (plugins/engine/docs/PrefabsSpec.md §3.2), found
// from the host's scene. Installed through @(provider_install).

import "moonhug:editor/inspector"
import "moonhug:packages/engine"
import undo "moonhug:packages/engine/editor/undo"

@(provider_install)
install_override_provider :: proc() {
	inspector.set_override_provider({
		is_overridden     = _ov_is_overridden,
		record            = _ov_record,
		revert            = _ov_revert,
		apply_targets     = _ov_apply_targets,
		apply             = _ov_apply,
		component_context = _ov_component_context,
		object_context    = _ov_object_context,
	})
}

// The scene the instance host lives in, nil when the host is gone.
@(private = "file")
_host_scene :: proc(host: engine.Transform_Handle) -> ^engine.Scene {
	w := engine.ctx_world()
	if w == nil do return nil
	ht := engine.pool_get(&w.transforms, engine.Handle(host))
	if ht == nil do return nil
	return ht.scene
}

@(private = "file")
_host_alive :: proc(host: engine.Transform_Handle) -> bool {
	w := engine.ctx_world()
	return w != nil && engine.pool_get(&w.transforms, engine.Handle(host)) != nil
}

@(private = "file")
_ov_is_overridden :: proc(host: engine.Transform_Handle, lid: engine.Local_ID, path: string) -> bool {
	if !_host_alive(host) do return false
	return engine.nested_scene_has_root_override(_host_scene(host), host, lid, path)
}

@(private = "file")
_ov_record :: proc(host: engine.Transform_Handle, lid: engine.Local_ID, path: string, field_ptr: rawptr, field_tid: typeid) {
	if !_host_alive(host) do return
	scene := _host_scene(host)
	created, ok := engine.nested_scene_record_override_for_host(scene, host, lid, path, field_ptr, field_tid)
	if ok && created {
		undo.record_override_created(scene, host, lid, path)
	}
}

@(private = "file")
_ov_revert :: proc(host: engine.Transform_Handle, lid: engine.Local_ID, path: string, value_ptr: rawptr, value_tid: typeid) {
	if !_host_alive(host) do return
	scene := _host_scene(host)
	root_ns, root_target, ok := engine.nested_scene_locate_root_override(scene, host, lid)
	if !ok do return
	// Snapshot the entries BEFORE the revert deletes them. They are attached
	// to the undo step after it commits, so the record undoes together with
	// the value.
	snap := undo.override_removal_snapshot(root_ns, root_target, path)
	u := inspector.field_undo_begin(value_ptr, value_tid, "Revert")
	engine.nested_scene_revert_override(scene, root_ns, root_target, path, value_ptr)
	inspector.field_undo_end(u)
	undo.record_override_removed(scene, host, lid, path, snap)
}

@(private = "file")
_ov_apply_targets :: proc(host: engine.Transform_Handle, lid: engine.Local_ID) -> []inspector.Override_Apply_Target {
	if !_host_alive(host) do return {}
	scene := _host_scene(host)
	root_ns, root_target, ok := engine.nested_scene_locate_root_override(scene, host, lid)
	if !ok do return {}
	targets := engine.nested_scene_apply_targets(scene, root_ns, root_target)
	out := make([]inspector.Override_Apply_Target, len(targets), context.temp_allocator)
	for t, i in targets do out[i] = {guid = t.guid, is_owner = t.is_owner}
	return out
}

@(private = "file")
_ov_apply :: proc(host: engine.Transform_Handle, lid: engine.Local_ID, path: string, target: engine.Asset_GUID) {
	if !_host_alive(host) do return
	scene := _host_scene(host)
	root_ns, root_target, ok := engine.nested_scene_locate_root_override(scene, host, lid)
	if !ok do return
	entry := engine.Override_Entry{
		kind          = .Modified_Property,
		target        = root_target,
		property_path = path,
	}
	root_host := engine.Transform_Handle(engine.nested_scene_resolve_host_handle(scene, root_ns))
	undo.apply_to_prefab(scene, root_host, target, {entry})
}

// A component outside any instance yields a zero host, which makes the
// inspector's override record a no-op: the right outcome for plain scene
// content, and for a component ADDED to an instance, which is not prefab
// content either.
@(private = "file")
_ov_component_context :: proc(comp: engine.Handle) -> (host: engine.Transform_Handle, lid: engine.Local_ID) {
	w := engine.ctx_world()
	if w == nil do return {}, 0
	raw := engine.world_pool_get(w, comp)
	if raw == nil do return {}, 0
	base := cast(^engine.CompData)raw
	if !base.nested_owned do return {}, 0
	return engine.transform_immediate_nested_host(base.owner), base.local_id
}

// The hierarchy inspector's rule: the transform is instance content when it is
// nested-owned or is itself an instance host. A host ADDITION is neither.
@(private = "file")
_ov_object_context :: proc(tH: engine.Transform_Handle) -> (host: engine.Transform_Handle, lid: engine.Local_ID) {
	w := engine.ctx_world()
	if w == nil do return {}, 0
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return {}, 0
	is_host := engine.scene_find_nested_scene_for_host(t.scene, tH) != nil
	if !t.nested_owned && !is_host do return {}, 0
	return engine.transform_immediate_nested_host(tH), t.local_id
}
