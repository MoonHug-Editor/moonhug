package inspector

import "core:fmt"
import "core:reflect"
import "core:strings"
import im "../../../external/odin-imgui"
import "../../engine"
import "../undo"

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

	im.AlignTextToFramePadding()
	im.Text(label)
	im.SameLine(0, 8)

	avail := im.GetContentRegionAvail().x
	clear_w: f32 = 0
	has_value := ref_ptr.local_id != 0 || ref_ptr.handle != {}
	if has_value do clear_w = 24

	popup_id := strings.clone_to_cstring(
		fmt.tprintf("ref_local_picker##%s", label), context.temp_allocator,
	)
	btn_label := strings.clone_to_cstring(
		fmt.tprintf("%s##%s", display, label), context.temp_allocator,
	)
	if im.Button(btn_label, {avail - clear_w, 0}) {
		im.OpenPopup(popup_id)
	}

	if has_value {
		im.SameLine(0, 0)
		clear_label := strings.clone_to_cstring(
			fmt.tprintf("X##clear_%s", label), context.temp_allocator,
		)
		if im.Button(clear_label, {clear_w, 0}) {
			ref_ptr^ = {}
			mark_inspector_changed()
		}
	}

	if im.BeginPopup(popup_id) {
		if target_key == engine.INVALID_TYPE_KEY {
			im.TextDisabled("Add `ref:\"TypeName\"` field tag to enable picker")
		} else {
			if im.Selectable("None") {
				ref_ptr^ = {}
				mark_inspector_changed()
			}
			im.Separator()
			objects := engine.sm_find_objects_of_type(target_key, owner_root_scene)
			if len(objects) == 0 {
				im.TextDisabled("(no objects in loaded scenes)")
			}
			for obj in objects {
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
		}
		im.EndPopup()
	}
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
