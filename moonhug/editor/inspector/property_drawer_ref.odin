package inspector

import "core:fmt"
import "core:reflect"
import "core:strings"
import "core:encoding/uuid"
import im "../../../external/odin-imgui"
import "../../engine"

// engine.Ref (PPtr): local OR cross-asset reference — both picker tabs are
// assignable. A Scene pick stores {local_id, guid: 0} + live handle; a Project
// pick stores {root component local_id, asset guid} with an UNRESOLVED handle:
// the target asset isn't loaded, game code must treat the handle as optional
// (Unity's model). `pick:"scene"` / `pick:"project"` field tags limit which
// tab is assignable. See docs/ObjectPicker.md.
@(property_drawer={type = engine.Ref, priority = 0})
draw_ref_property :: proc(ptr: rawptr, tid: typeid, label: cstring) {
	ref_ptr := cast(^engine.Ref)ptr
	target_type_name := current_field_ref_target

	target_key := engine.INVALID_TYPE_KEY
	if target_type_name != "" {
		if v, ok := reflect.enum_from_name(engine.TypeKey, target_type_name); ok {
			target_key = v
		}
	}

	allow_scene := current_field_pick_mode != "project"
	allow_project := current_field_pick_mode != "scene"

	is_asset_ref := !engine.asset_guid_is_empty(ref_ptr.pptr.guid)
	has_value := ref_ptr.pptr.local_id != 0 || ref_ptr.handle != {} || is_asset_ref

	owner_root_scene := _ref_local_owner_root_scene()
	display := _ref_display(ref_ptr^, target_key)

	popup_id := strings.clone_to_cstring(
		fmt.tprintf("ref_picker##%s", label), context.temp_allocator,
	)

	value_clicked, value_double, cleared: bool
	if _picker_field_row(label, display, has_value, &value_clicked, &cleared, &value_double) {
		im.OpenPopup(popup_id)
	}
	// Single click pings, double click opens/selects — routed by what the ref
	// points at (asset vs scene object).
	if value_double {
		if is_asset_ref {
			engine.inspector_request_open_asset(ref_ptr.pptr.guid)
		} else if tH, ok := _ref_local_target_transform({ref_ptr.pptr.local_id, ref_ptr.handle}); ok {
			engine.inspector_request_select(tH)
		}
	} else if value_clicked {
		if is_asset_ref {
			engine.inspector_request_ping_asset(ref_ptr.pptr.guid)
		} else if tH, ok := _ref_local_target_transform({ref_ptr.pptr.local_id, ref_ptr.handle}); ok {
			engine.inspector_request_ping(tH)
		}
	}
	if cleared {
		ref_ptr^ = {}
		mark_inspector_changed()
	}

	if im.BeginPopup(popup_id) {
		if target_key == engine.INVALID_TYPE_KEY {
			im.TextDisabled("Add `ref:\"TypeName\"` field tag to enable picker")
		} else {
			search := _picker_search_bar()
			if im.Selectable("None") {
				ref_ptr^ = {}
				mark_inspector_changed()
			}
			im.Separator()
			if im.BeginTabBar("##picker_tabs") {
				if im.BeginTabItem("Scene") {
					if !allow_scene {
						im.TextDisabled("pick:\"project\" — this field takes assets only")
					} else {
						objects := engine.sm_find_objects_of_type(target_key, owner_root_scene)
						shown := 0
						for obj in objects {
							if search != "" && !strings.contains(strings.to_lower(obj.name, context.temp_allocator), search) {
								continue
							}
							shown += 1
							row := strings.clone_to_cstring(
								fmt.tprintf("%s##%d_%d", obj.name, obj.handle.index, obj.handle.generation),
								context.temp_allocator,
							)
							if im.Selectable(row) {
								ref_ptr.handle = obj.handle
								ref_ptr.pptr = {
									local_id = engine.sm_local_id_get_or_mint(owner_root_scene, obj.handle),
									guid     = {},
								}
								mark_inspector_changed()
							}
						}
						if shown == 0 {
							im.TextDisabled("(no matches in loaded scenes)")
						}
					}
					im.EndTabItem()
				}
				// Project is the applicable tab for pick:"project" — select it
				// on open (Scene is imgui's default first tab otherwise).
				proj_flags: im.TabItemFlags
				if !allow_scene && im.IsWindowAppearing() {
					proj_flags = {.SetSelected}
				}
				if im.BeginTabItem("Project", nil, proj_flags) {
					if !allow_project {
						im.TextDisabled("pick:\"scene\" — this field takes scene objects only")
					} else {
						picked: engine.PPtr
						if _picker_asset_rows(target_key, search, &picked) {
							// The pick IS the persistent pointer; the handle
							// stays unresolved until the asset is loaded.
							ref_ptr.pptr = picked
							ref_ptr.handle = {}
							mark_inspector_changed()
						}
					}
					im.EndTabItem()
				}
				im.EndTabBar()
			}
		}
		im.EndPopup()
	}
}

@(private)
_ref_display :: proc(r: engine.Ref, key: engine.TypeKey) -> string {
	if !engine.asset_guid_is_empty(r.pptr.guid) {
		// Cross-asset: name it from the AssetDB (never requires the asset
		// to be loaded).
		path, has_path := engine.asset_db_get_path(uuid.Identifier(r.pptr.guid))
		if !has_path {
			return "[missing asset]"
		}
		if info, ok := engine.asset_db_get_root_info(r.pptr.guid); ok && info.root_name != "" {
			return fmt.tprintf("%s (%s)", info.root_name, filepath_base(path))
		}
		return filepath_base(path)
	}
	// Local: same rules as Ref_Local.
	return _ref_local_display({r.pptr.local_id, r.handle}, key)
}
