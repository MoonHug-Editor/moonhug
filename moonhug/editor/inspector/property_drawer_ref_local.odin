package inspector

import "core:fmt"
import "core:mem"
import "core:reflect"
import "core:strings"
import im "../../../external/odin-imgui"
import "../../engine"
import "../undo"

// Material icon codepoints, duplicated from editor/material_icons.odin — the
// inspector package cannot import editor (editor imports inspector).
ICON_MD_CLOSE  :: "\ue5cd"
ICON_MD_SEARCH :: "\uef7a"

// Shared picker-popup search state. One popup is open at a time, so a single
// buffer serves all pickers; it resets when a popup (re)opens.
@(private)
_picker_search_buf: [128]byte

// Draw the popup's search input (focused on open) and return the lowercase
// query (temp-allocated).
_picker_search_bar :: proc() -> string {
	if im.IsWindowAppearing() {
		mem.zero(&_picker_search_buf, len(_picker_search_buf))
		im.SetKeyboardFocusHere()
	}
	im.SetNextItemWidth(220)
	im.InputTextWithHint("##picker_search", "Search", cstring(raw_data(_picker_search_buf[:])), uint(len(_picker_search_buf)))
	return strings.to_lower(strings.trim_space(string(cstring(raw_data(_picker_search_buf[:])))), context.temp_allocator)
}

// Unity-like reference field row: Label [value][x][pick]. Clicking the value
// pings the target; [x] clears (shown before [pick] only when set); [pick]
// opens the picker popup. Returns true when the popup should open. When
// dropped_asset is non-nil, the value button accepts ASSET_PATH drag-drops and
// writes the dropped path (temp-allocated) there.
_picker_field_row :: proc(label: cstring, display: string, has_value: bool, value_clicked: ^bool, cleared: ^bool, dropped_asset: ^string = nil) -> bool {
	im.AlignTextToFramePadding()
	im.Text(label)
	im.SameLine(0, 8)

	BTN_W :: f32(24)
	avail := im.GetContentRegionAvail().x
	value_w := avail - BTN_W
	if has_value do value_w -= BTN_W

	value_label := strings.clone_to_cstring(
		fmt.tprintf("%s##val_%s", display, label), context.temp_allocator,
	)
	if im.Button(value_label, {value_w, 0}) {
		value_clicked^ = true
	}
	if dropped_asset != nil && im.BeginDragDropTarget() {
		if payload := im.AcceptDragDropPayload("ASSET_PATH"); payload != nil && payload.Data != nil {
			path := string((cast([^]u8)payload.Data)[:payload.DataSize])
			dropped_asset^ = strings.clone(path, context.temp_allocator)
		}
		im.EndDragDropTarget()
	}

	if has_value {
		im.SameLine(0, 0)
		clear_label := strings.clone_to_cstring(
			fmt.tprintf("%s##clear_%s", ICON_MD_CLOSE, label), context.temp_allocator,
		)
		if im.Button(clear_label, {BTN_W, 0}) {
			cleared^ = true
		}
	}

	im.SameLine(0, 0)
	pick_label := strings.clone_to_cstring(
		fmt.tprintf("%s##pick_%s", ICON_MD_SEARCH, label), context.temp_allocator,
	)
	return im.Button(pick_label, {BTN_W, 0})
}

@(property_drawer={type = engine.Ref_Local, priority = 0})
draw_ref_local_property :: proc(ptr: rawptr, tid: typeid, label: cstring) {
	ref_ptr := cast(^engine.Ref_Local)ptr
	target_type_name := current_field_ref_target

	target_key := engine.INVALID_TYPE_KEY
	if target_type_name != "" {
		if v, ok := reflect.enum_from_name(engine.TypeKey, target_type_name); ok {
			target_key = v
		}
	}

	owner_root_scene := _ref_local_owner_root_scene()
	display := _ref_local_display(ref_ptr^, target_key)
	has_value := ref_ptr.local_id != 0 || ref_ptr.handle != {}

	popup_id := strings.clone_to_cstring(
		fmt.tprintf("ref_local_picker##%s", label), context.temp_allocator,
	)

	value_clicked, cleared: bool
	if _picker_field_row(label, display, has_value, &value_clicked, &cleared) {
		im.OpenPopup(popup_id)
	}
	if value_clicked {
		_ref_local_ping(ref_ptr^)
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
			if im.BeginTabBar("##picker_tabs") {
				if im.BeginTabItem("Scene") {
					if im.Selectable("None") {
						ref_ptr^ = {}
						mark_inspector_changed()
					}
					im.Separator()
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
							ref_ptr.local_id = engine.sm_local_id_get_or_mint(owner_root_scene, obj.handle)
							mark_inspector_changed()
						}
					}
					if shown == 0 {
						im.TextDisabled("(no matches in loaded scenes)")
					}
					im.EndTabItem()
				}
				if im.BeginTabItem("Project") {
					// Shown for parity with Unity, but not assignable: a
					// Ref_Local is a same-file local_id — referencing an asset
					// needs an engine.Ref (PPtr) field.
					im.TextDisabled("Ref_Local is scene-only (assets need engine.Ref)")
					im.Separator()
					im.BeginDisabled()
					_picker_asset_rows(target_key, search, nil)
					im.EndDisabled()
					im.EndTabItem()
				}
				im.EndTabBar()
			}
		}
		im.EndPopup()
	}
}

// Ping: select the target's transform in the hierarchy (via the cross-package
// pending-select channel the hierarchy drains each frame).
@(private)
_ref_local_ping :: proc(r: engine.Ref_Local) {
	w := engine.ctx_world()
	if !engine.world_pool_valid(w, r.handle) do return
	tH: engine.Transform_Handle
	if r.handle.type_key == .Transform {
		tH = engine.Transform_Handle(r.handle)
	} else {
		raw := engine.world_pool_get(w, r.handle)
		if raw == nil do return
		tH = (cast(^engine.CompData)raw).owner
	}
	engine.inspector_request_select(tH)
}

@(private)
_ref_local_owner_root_scene :: proc() -> ^engine.Scene {
	o, ok := undo.current_owner()
	if !ok || o.kind != .Pooled do return nil
	w := engine.ctx_world()
	owner_tH: engine.Transform_Handle
	if o.handle.type_key == .Transform {
		owner_tH = engine.Transform_Handle(o.handle)
	} else {
		raw := engine.world_pool_get(w, o.handle)
		if raw == nil do return nil
		base := cast(^engine.CompData)raw
		owner_tH = base.owner
	}
	return engine.sm_get_root_scene_of_transform(owner_tH)
}

@(private)
_ref_local_display :: proc(r: engine.Ref_Local, key: engine.TypeKey) -> string {
	if r.local_id == 0 && r.handle == {} {
		return "None"
	}
	w := engine.ctx_world()
	if engine.world_pool_valid(w, r.handle) {
		// For component types: handle points at the component, owner is on CompData.
		// For .Transform: handle points at the Transform itself.
		if r.handle.type_key == .Transform {
			t := engine.pool_get(&w.transforms, r.handle)
			if t != nil && t.name != "" do return t.name
		} else {
			raw := engine.world_pool_get(w, r.handle)
			if raw != nil {
				base := cast(^engine.CompData)raw
				t := engine.pool_get(&w.transforms, engine.Handle(base.owner))
				if t != nil && t.name != "" {
					return fmt.tprintf("%s (%v)", t.name, r.handle.type_key)
				}
			}
		}
	}
	if r.local_id != 0 {
		return fmt.tprintf("[unresolved local_id=%d]", r.local_id)
	}
	return "[invalid]"
}
