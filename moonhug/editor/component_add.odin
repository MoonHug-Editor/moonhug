package editor

// Adding a component from the Component menu / Add Component button.
// Called by menu_component_generated.odin's per-type menu items.
//
// On PREFAB-INSTANCE content the component is an addition the prefab doesn't
// have, so it is recorded on the instance's NestedScene as an added_component
// (docs/PrefabsSpec.md §4.2) — otherwise the next resolve, which rebuilds the
// instance from its prefab, would drop it.

import "core:encoding/json"
import "core:encoding/uuid"
import engine "../engine"
import "undo"

// Adds `key` to the hierarchy selection. No-op when nothing is selected or the
// component is already present (components are one-per-transform).
component_add_to_selected :: proc(key: engine.TypeKey) {
	tH := hierarchy_get_selected()
	if tH == _HANDLE_NONE do return
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return
	_, existing_idx := engine.transform_find_comp(t, key)
	if existing_idx >= 0 do return

	owned, ptr := engine.transform_add_comp(tH, key)
	if ptr == nil do return
	undo.record_add_component(tH, owned.handle, len(t.components) - 1)

	// Prefab-instance content: record the addition so it survives resolve.
	is_host := engine.scene_find_nested_scene_for_host(t.scene, tH) != nil
	if !t.nested_owned && !is_host do return

	host_tH := tH if is_host else engine.transform_immediate_nested_host(tH)
	if host_tH == {} do return
	comp_lid := (cast(^engine.CompData)ptr).local_id
	if comp_lid == 0 do return
	type_guid, guid_ok := _component_type_guid(key)
	if !guid_ok do return
	comp_tid := engine.get_typeid_by_type_key(key)
	if comp_tid == nil do return

	if _, ok := engine.nested_scene_record_component_added(
		t.scene, host_tH, t.local_id, comp_lid, type_guid, ptr, comp_tid,
	); ok {
		payload, merr := json.marshal(any{ptr, comp_tid}, {spec = .JSON}, context.temp_allocator)
		if merr == nil {
			undo.record_component_added_on_instance(
				t.scene, host_tH, t.local_id, comp_lid, type_guid, string(payload),
			)
		}
	}
}

// The registered type guid for `key`, as component records carry it in
// "__type". Added components are serialized as records on the NestedScene, so
// they need the same tag the loader keys on.
@(private = "file")
_component_type_guid :: proc(key: engine.TypeKey) -> (string, bool) {
	guid := engine.get_guid_by_type_key(key)
	if guid == {} do return "", false
	return uuid.to_string(guid, context.temp_allocator), true
}
