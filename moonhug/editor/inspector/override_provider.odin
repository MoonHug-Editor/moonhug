package inspector

// What the inspector asks about prefab-instance overrides: the override marker,
// the record on commit, and Revert and Apply in a field's context menu. A
// field is named by the inspector's ambient prefab context (the instance host
// and the object's local id, core.inspector_get_nested_*) plus its property
// path. The installed engine answers (plugins/engine/editor/drawers/override_provider.odin).
// With no provider nothing is instance content and no row shows a marker.

import core "moonhug:host/core"
import "base:runtime"
import "moonhug:editor/provider"

// One prefab an override can be applied to, closest first.
Override_Apply_Target :: struct {
	guid:     core.Asset_GUID,
	is_owner: bool, // the file that owns the row: Apply bakes the value in, otherwise it records an override there
}

Override_Provider :: struct {
	// The field at `path` is overridden on its instance.
	is_overridden:     proc(host: core.Transform_Handle, lid: core.Local_ID, path: string) -> bool,
	// Records an override for a field whose edit just committed, and tells the
	// undo step when the edit created it.
	record:            proc(host: core.Transform_Handle, lid: core.Local_ID, path: string, field_ptr: rawptr, field_tid: typeid),
	// Reverts the field to its prefab value as one undo step, the override
	// record included. `value_ptr` is the field the override names.
	revert:            proc(host: core.Transform_Handle, lid: core.Local_ID, path: string, value_ptr: rawptr, value_tid: typeid),
	// The prefabs the field's override can be applied to. Temp-allocated.
	apply_targets:     proc(host: core.Transform_Handle, lid: core.Local_ID) -> []Override_Apply_Target,
	// Pushes the field's override into the prefab `target`.
	apply:             proc(host: core.Transform_Handle, lid: core.Local_ID, path: string, target: core.Asset_GUID),
	// The instance host and local id of a component that is prefab content, zero otherwise.
	component_context: proc(comp: core.Handle) -> (host: core.Transform_Handle, lid: core.Local_ID),
	// The same for an object: instance content or an instance host itself.
	object_context:    proc(tH: core.Transform_Handle) -> (host: core.Transform_Handle, lid: core.Local_ID),
}

@(private) _override_provider: Override_Provider

@(init)
_register_override_provider :: proc "contextless" () {
	context = runtime.default_context()
	provider.register("Override_Provider", &_override_provider)
}

set_override_provider :: proc(p: Override_Provider) {
	_override_provider = p
}

override_is_overridden :: proc(host: core.Transform_Handle, lid: core.Local_ID, path: string) -> bool {
	if _override_provider.is_overridden == nil do return false
	return _override_provider.is_overridden(host, lid, path)
}

override_record :: proc(host: core.Transform_Handle, lid: core.Local_ID, path: string, field_ptr: rawptr, field_tid: typeid) {
	if _override_provider.record != nil do _override_provider.record(host, lid, path, field_ptr, field_tid)
}

override_revert :: proc(host: core.Transform_Handle, lid: core.Local_ID, path: string, value_ptr: rawptr, value_tid: typeid) {
	if _override_provider.revert != nil do _override_provider.revert(host, lid, path, value_ptr, value_tid)
}

override_apply_targets :: proc(host: core.Transform_Handle, lid: core.Local_ID) -> []Override_Apply_Target {
	if _override_provider.apply_targets == nil do return {}
	return _override_provider.apply_targets(host, lid)
}

override_apply :: proc(host: core.Transform_Handle, lid: core.Local_ID, path: string, target: core.Asset_GUID) {
	if _override_provider.apply != nil do _override_provider.apply(host, lid, path, target)
}

override_component_context :: proc(comp: core.Handle) -> (host: core.Transform_Handle, lid: core.Local_ID) {
	if _override_provider.component_context == nil do return {}, 0
	return _override_provider.component_context(comp)
}

override_object_context :: proc(tH: core.Transform_Handle) -> (host: core.Transform_Handle, lid: core.Local_ID) {
	if _override_provider.object_context == nil do return {}, 0
	return _override_provider.object_context(tH)
}
