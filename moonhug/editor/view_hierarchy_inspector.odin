package editor

import "core:strings"
import "core:mem"
import "core:c"
import "core:fmt"
import "core:encoding/uuid"
import im "../../external/odin-imgui"
import engine "../engine"
import "inspector"
import "menu"
import clip "clipboard"
import "undo"

@(private)
_inspector_name_buf: [256]byte

@(private)
_inspector_transform_open: bool = true

@(private)
_inspector_comp_open: map[engine.TypeKey]bool

draw_hierarchy_inspector :: proc() {
	if !im.Begin("Inspector", nil, {.NoCollapse}) {
		im.End()
		return
	}
	defer im.End()

	tH := hierarchy_get_selected()
	if tH == _HANDLE_NONE {
		im.TextDisabled("No object selected")
		return
	}

	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil {
		im.TextDisabled("Invalid selection")
		return
	}

	is_host := engine.scene_find_nested_scene_for_host(t.scene, tH) != nil
	is_nested := t.nested_owned || is_host
	if is_nested {
		host_tH := tH if is_host else engine.transform_nested_enclosing_host(tH)
		prev_host := engine.inspector_set_nested_host(host_tH)
		defer engine.inspector_set_nested_host(prev_host)
		prev_lid := engine.inspector_set_nested_local_id(t.local_id)
		defer engine.inspector_set_nested_local_id(prev_lid)

		_draw_nested_banner(host_tH)

		undo.push_transform_owner(tH)
		defer undo.pop_owner()

		_draw_header(t, tH)
		im.Separator()
		_draw_transform_section(t, tH)
		_draw_components_section_nested(t, tH, host_tH)
		return
	}

	undo.push_transform_owner(tH)
	defer undo.pop_owner()

	_draw_header(t, tH)
	im.Separator()
	_draw_transform_section(t, tH)
	_draw_components_section(t, tH)
	_draw_add_component_button(t, tH)
}

@(private)
_draw_nested_banner :: proc(host_tH: engine.Transform_Handle) {
	w := engine.ctx_world()
	source_path := ""
	ht_for_scene := engine.pool_get(&w.transforms, engine.Handle(host_tH))
	if ns := engine.scene_find_nested_scene_for_host(ht_for_scene != nil ? ht_for_scene.scene : nil, host_tH); ns != nil {
		empty_guid := engine.Asset_GUID{}
		if ns.source_prefab != empty_guid {
			if path, ok := engine.asset_db_get_path(uuid.Identifier(ns.source_prefab)); ok {
				source_path = path
			}
		}
	}
	host_name := "?"
	ht := engine.pool_get(&w.transforms, engine.Handle(host_tH))
	if ht != nil {
		host_name = ht.name
	}
	label: string
	if source_path != "" {
		label = fmt.tprintf("Nested from %s  -  host: %s", source_path, host_name)
	} else {
		label = fmt.tprintf("Nested  -  host: %s", host_name)
	}
	im.TextColored(im.Vec4{1.0, 0.75, 0.3, 1.0}, strings.clone_to_cstring(label, context.temp_allocator))
	im.Separator()
}

@(private)
_draw_header :: proc(t: ^engine.Transform, tH: engine.Transform_Handle) {
	active := t.is_active
	if im.Checkbox("##active", &active) {
		e := undo.edit_begin(tH, &t.is_active, typeid_of(bool))
		t.is_active = active
		undo.edit_end(&e)
	}

	im.SameLine()

	name_bytes := transmute([]u8)t.name
	mem.zero(&_inspector_name_buf, len(_inspector_name_buf))
	copy_len := min(len(name_bytes), len(_inspector_name_buf) - 1)
	mem.copy(&_inspector_name_buf[0], raw_data(name_bytes), copy_len)

	im.SetNextItemWidth(-1)
	buf_cstr := cstring(raw_data(_inspector_name_buf[:]))
	if im.InputText("##name", buf_cstr, c.size_t(len(_inspector_name_buf)), {.EnterReturnsTrue}) {
		new_name := string(buf_cstr)
		if len(new_name) > 0 {
			e := undo.edit_begin(tH, &t.name, typeid_of(string))
			delete(t.name)
			t.name = strings.clone(new_name)
			undo.edit_end(&e)
		}
	}
}

@(private)
_inspector_euler_cache: [3]f32

@(private)
_inspector_euler_quat_src: [4]f32

@(private)
_draw_transform_section :: proc(t: ^engine.Transform, tH: engine.Transform_Handle) {
	im.SetNextItemOpen(_inspector_transform_open, .Once)
	if im.CollapsingHeader("Transform", {.DefaultOpen}) {
		_inspector_transform_open = true
		drawer := inspector.resolve_property_drawer(typeid_of(^[3]f32))

		_wrap_transform_field_override(tH, t, &t.position, "position", typeid_of([3]f32), drawer, typeid_of(^[3]f32), "Position")
		_wrap_transform_rotation_override(tH, t, drawer)
		_wrap_transform_field_override(tH, t, &t.scale, "scale", typeid_of([3]f32), drawer, typeid_of(^[3]f32), "Scale")
	} else {
		_inspector_transform_open = false
	}
}

@(private)
_nested_scene_for_host :: proc(host_tH: engine.Transform_Handle) -> ^engine.NestedScene {
	w := engine.ctx_world()
	ht := engine.pool_get(&w.transforms, engine.Handle(host_tH))
	if ht == nil do return nil
	return engine.scene_find_nested_scene_for_host(ht.scene, host_tH)
}

@(private)
_override_color := im.Vec4{0.4, 0.8, 1.0, 1.0}

@(private)
_push_override_style :: proc(is_overridden: bool) -> bool {
	if is_overridden {
		im.PushStyleColorImVec4(im.Col.Text, _override_color)
	}
	return is_overridden
}

@(private)
_pop_override_style :: proc(pushed: bool) {
	if pushed do im.PopStyleColor(1)
}

@(private)
_resolve_override_target_id :: proc(t: ^engine.Transform, host_tH: engine.Transform_Handle) -> engine.Local_ID {
	if t.nested_owned do return t.local_id
	ns := _nested_scene_for_host(host_tH)
	if ns != nil && ns.source_root_id != 0 do return ns.source_root_id
	return t.local_id
}

@(private)
_wrap_transform_field_override :: proc(tH: engine.Transform_Handle, t: ^engine.Transform, field_ptr: rawptr, prop_path: string, field_tid: typeid, drawer: proc(ptr: rawptr, tid: typeid, label: cstring), drawer_tid: typeid, label: cstring) {
	host_tH := engine.inspector_get_nested_host()
	is_in_nested_ctx := host_tH != {} && (t.nested_owned || engine.scene_find_nested_scene_for_host(t.scene, tH) != nil)

	ns: ^engine.NestedScene
	target_id: engine.Local_ID
	is_overridden := false
	if is_in_nested_ctx {
		ns = _nested_scene_for_host(host_tH)
		target_id = _resolve_override_target_id(t, host_tH)
		is_overridden = engine.nested_scene_has_override(ns, target_id, prop_path)
	}

	pushed := _push_override_style(is_overridden)
	_wrap_transform_field(tH, field_ptr, 0, field_tid, drawer, drawer_tid, label)
	_pop_override_style(pushed)

	prev_nested_lid := engine.inspector_get_nested_local_id()
	if is_in_nested_ctx {
		engine.inspector_set_nested_local_id(target_id)
	}
	inspector.draw_field_context_menu(field_ptr, field_tid, prop_path)
	if is_in_nested_ctx {
		engine.inspector_set_nested_local_id(prev_nested_lid)
	}
}

@(private)
_wrap_transform_rotation_override :: proc(tH: engine.Transform_Handle, t: ^engine.Transform, drawer: proc(ptr: rawptr, tid: typeid, label: cstring)) {
	host_tH := engine.inspector_get_nested_host()
	is_in_nested_ctx := host_tH != {} && (t.nested_owned || engine.scene_find_nested_scene_for_host(t.scene, tH) != nil)

	ns: ^engine.NestedScene
	target_id: engine.Local_ID
	is_overridden := false
	if is_in_nested_ctx {
		ns = _nested_scene_for_host(host_tH)
		target_id = _resolve_override_target_id(t, host_tH)
		is_overridden = engine.nested_scene_has_override(ns, target_id, "rotation")
	}

	pushed := _push_override_style(is_overridden)
	_wrap_transform_rotation(tH, t, drawer)
	_pop_override_style(pushed)

	prev_nested_lid := engine.inspector_get_nested_local_id()
	if is_in_nested_ctx {
		engine.inspector_set_nested_local_id(target_id)
	}
	inspector.draw_field_context_menu(&t.rotation, typeid_of([4]f32), "rotation")
	if is_in_nested_ctx {
		engine.inspector_set_nested_local_id(prev_nested_lid)
	}
}

@(private)
_inspector_rot_drag: undo.Field_Drag

@(private)
_wrap_transform_rotation :: proc(tH: engine.Transform_Handle, t: ^engine.Transform, drawer: proc(ptr: rawptr, tid: typeid, label: cstring)) {
	if _inspector_euler_quat_src != t.rotation {
		_inspector_euler_cache = engine.quat_to_euler_xyz(t.rotation)
		_inspector_euler_quat_src = t.rotation
	}
	prev_euler := _inspector_euler_cache
	prev_changed := inspector.consume_inspector_changed()

	drawer(&_inspector_euler_cache, typeid_of(^[3]f32), "Rotation")

	if im.IsItemActivated() && !_inspector_rot_drag.active {
		_inspector_rot_drag = undo.field_drag_begin(tH, &t.rotation, typeid_of([4]f32), "Rotation")
	}

	if _inspector_euler_cache != prev_euler {
		t.rotation = engine.quat_from_euler_xyz(_inspector_euler_cache.x, _inspector_euler_cache.y, _inspector_euler_cache.z)
		_inspector_euler_quat_src = t.rotation
		inspector.mark_inspector_changed()
	}

	if im.IsItemDeactivatedAfterEdit() && _inspector_rot_drag.active {
		undo.field_drag_end(&_inspector_rot_drag)
	}

	if prev_changed do inspector.mark_inspector_changed()
}

@(private)
_wrap_transform_field :: proc(tH: engine.Transform_Handle, field_ptr: rawptr, offset: uintptr, field_tid: typeid, drawer: proc(ptr: rawptr, tid: typeid, label: cstring), drawer_tid: typeid, label: cstring) {
	prev_changed := inspector.consume_inspector_changed()
	undo.begin_field(field_ptr, field_tid)

	drawer(field_ptr, drawer_tid, label)

	if im.IsItemActivated() {
		undo.promote_to_pending()
	}
	if im.IsItemDeactivatedAfterEdit() && undo.pending_matches(field_ptr) {
		undo.pending_commit()
		undo.end_field(false)
	} else if inspector.is_changed_flag_set() && !im.IsItemActive() && !undo.pending_is_active() {
		undo.end_field(true)
	} else {
		undo.end_field(false)
	}

	if prev_changed do inspector.mark_inspector_changed()
}

@(private)
_comp_pending_remove: engine.Handle

@(private)
_comp_pending_move_from: int = -1

@(private)
_comp_pending_move_to: int = -1

@(private)
_draw_component_overflow_menu :: proc(
	t: ^engine.Transform,
	tH: engine.Transform_Handle,
	comp: ^engine.Owned,
	comp_ptr: rawptr,
	comp_tid: typeid,
	comp_idx: int,
	comp_count: int,
) {
	popup_id := strings.clone_to_cstring(fmt.tprintf("##CompCtx_%v_%v", comp.handle.type_key, comp.handle.index), context.temp_allocator)
	im.SameLine(im.GetCursorPosX() + im.GetContentRegionAvail().x - 20)
	btn_label := strings.clone_to_cstring(fmt.tprintf("\u22ee##btn_%v_%v", comp.handle.type_key, comp.handle.index), context.temp_allocator)
	if im.SmallButton(btn_label) {
		im.OpenPopup(popup_id)
	}
	if im.BeginPopup(popup_id) {
		if engine.type_reset_procs[comp.handle.type_key] != nil {
			if im.MenuItem("Reset") {
				e := undo.edit_begin(comp.handle, comp_tid)
				engine.type_reset(comp.handle.type_key, comp_ptr)
				undo.edit_end(&e)
			}
			im.Separator()
		}

		if im.MenuItem("Copy Component") {
			clip.copy(any{comp_ptr, comp_tid})
		}

		clip_tid := clip.target_typeid()
		clip_key, clip_key_ok := engine.get_type_key_by_typeid(clip_tid)
		can_paste_as_new := clip.has() && clip_key_ok
		if im.MenuItem("Paste Component as New", nil, false, can_paste_as_new) {
			new_owned, new_ptr := engine.transform_add_comp(tH, clip_key)
			if new_ptr != nil {
				saved_base := (cast(^engine.CompData)new_ptr)^
				if clip.paste(any{new_ptr, clip_tid}) {
					base := cast(^engine.CompData)new_ptr
					base.owner = saved_base.owner
					base.local_id = saved_base.local_id
					base.enabled = saved_base.enabled
				}
				list_idx := len(t.components) - 1
				undo.record_add_component(tH, new_owned.handle, list_idx)
			}
		}

		can_paste_values := clip.can_paste(comp_tid)
		if im.MenuItem("Paste Component Values", nil, false, can_paste_values) {
			e := undo.edit_begin(comp.handle, comp_tid)
			saved_base := (cast(^engine.CompData)comp_ptr)^
			if clip.paste(any{comp_ptr, comp_tid}) {
				base := cast(^engine.CompData)comp_ptr
				base.owner = saved_base.owner
				base.local_id = saved_base.local_id
				base.enabled = saved_base.enabled
			}
			undo.edit_end(&e)
		}

		im.Separator()

		shift_held := im.IsKeyDown(im.Key.LeftShift) || im.IsKeyDown(im.Key.RightShift)

		if comp_idx > 0 {
			move_up_label := shift_held ? "Move to Top" : "Move Up"
			if im.MenuItem(strings.clone_to_cstring(move_up_label, context.temp_allocator)) {
				_comp_pending_move_from = comp_idx
				_comp_pending_move_to = shift_held ? 0 : comp_idx - 1
			}
		}
		if comp_idx < comp_count - 1 {
			move_down_label := shift_held ? "Move to Bottom" : "Move Down"
			if im.MenuItem(strings.clone_to_cstring(move_down_label, context.temp_allocator)) {
				_comp_pending_move_from = comp_idx
				_comp_pending_move_to = shift_held ? comp_count - 1 : comp_idx + 1
			}
		}

		im.Separator()

		if im.MenuItem("Remove Component") {
			_comp_pending_remove = comp.handle
		}
		ctx_entries := _get_context_menu_entries(comp.handle.type_key)
		if len(ctx_entries) > 0 {
			im.Separator()
		}
		for entry in ctx_entries {
			c_label := strings.clone_to_cstring(entry.label, context.temp_allocator)
			if im.MenuItem(c_label) {
				entry.action(comp_ptr)
			}
		}
		im.EndPopup()
	}
}

@(private)
_draw_components_section :: proc(t: ^engine.Transform, tH: engine.Transform_Handle) {
	w := engine.ctx_world()
	if len(t.components) == 0 do return

	_comp_pending_remove = {}
	_comp_pending_move_from = -1
	_comp_pending_move_to = -1

	comp_count := len(t.components)

	for &comp, comp_idx in t.components {
		if comp.handle.type_key == engine.INVALID_TYPE_KEY do continue

		comp_ptr := engine.world_pool_get(w, comp.handle)
		if comp_ptr == nil do continue

		comp_tid := engine.get_typeid_by_type_key(comp.handle.type_key)
		type_name := fmt.tprintf("%v", comp_tid)
		c_type_name := strings.clone_to_cstring(type_name, context.temp_allocator)

		checkbox_size := im.GetFrameHeight()
		checkbox_pos := im.GetCursorScreenPos()
		im.Indent(checkbox_size + im.GetStyle().ItemSpacing.x)

		is_open := _inspector_comp_open[comp.handle.type_key] or_else true
		im.SetNextItemOpen(is_open, .Once)

		header_open := im.CollapsingHeader(c_type_name, {.DefaultOpen, .AllowOverlap})
		_inspector_comp_open[comp.handle.type_key] = header_open

		im.Unindent(checkbox_size + im.GetStyle().ItemSpacing.x)

		im.SetCursorScreenPos(checkbox_pos)
		comp_base := cast(^engine.CompData)comp_ptr
		enabled := comp_base.enabled
		enabled_id := strings.clone_to_cstring(fmt.tprintf("##enabled_%v_%v", comp.handle.type_key, comp.handle.index), context.temp_allocator)
		if im.Checkbox(enabled_id, &enabled) {
			e := undo.edit_begin(comp.handle, comp_tid)
			comp_base.enabled = enabled
			undo.edit_end(&e)
		}

		_draw_component_overflow_menu(t, tH, &comp, comp_ptr, comp_tid, comp_idx, comp_count)

		if header_open {
			inspector.consume_inspector_changed()
			defer if inspector.consume_inspector_changed() {
				engine.component_on_validate(comp.handle.type_key, comp_ptr)
			}
			undo.push_component_owner(comp.handle)
			defer undo.pop_owner()
			drawer := inspector.resolve_property_drawer(comp_tid)
			drawer(comp_ptr, comp_tid, c_type_name)
		}
	}

	if _comp_pending_remove.type_key != engine.INVALID_TYPE_KEY {
		undo.record_remove_component(tH, _comp_pending_remove)
	}

	if _comp_pending_move_from >= 0 && _comp_pending_move_to >= 0 && _comp_pending_move_from != _comp_pending_move_to {
		entry := t.components[_comp_pending_move_from]
		ordered_remove(&t.components, _comp_pending_move_from)
		inject_at(&t.components, _comp_pending_move_to, entry)
		undo.record_reorder_components(tH, _comp_pending_move_from, _comp_pending_move_to)
	}
}

@(private)
_draw_components_section_nested :: proc(t: ^engine.Transform, tH: engine.Transform_Handle, host_tH: engine.Transform_Handle) {
	w := engine.ctx_world()
	if len(t.components) == 0 do return

	_comp_pending_remove = {}
	_comp_pending_move_from = -1
	_comp_pending_move_to = -1
	comp_count := len(t.components)

	for &comp, comp_idx in t.components {
		if comp.handle.type_key == engine.INVALID_TYPE_KEY do continue

		comp_ptr := engine.world_pool_get(w, comp.handle)
		if comp_ptr == nil do continue

		comp_base := cast(^engine.CompData)comp_ptr
		comp_tid := engine.get_typeid_by_type_key(comp.handle.type_key)
		type_name := fmt.tprintf("%v", comp_tid)
		c_type_name := strings.clone_to_cstring(type_name, context.temp_allocator)

		ns := _nested_scene_for_host(host_tH)
		comp_has_any_override := false
		if ns != nil {
			for &ov in ns.overrides {
				if ov.target == comp_base.local_id {
					comp_has_any_override = true
					break
				}
			}
		}

		checkbox_size := im.GetFrameHeight()
		checkbox_pos := im.GetCursorScreenPos()
		im.Indent(checkbox_size + im.GetStyle().ItemSpacing.x)

		is_open := _inspector_comp_open[comp.handle.type_key] or_else true
		im.SetNextItemOpen(is_open, .Once)

		if comp_has_any_override {
			im.PushStyleColorImVec4(im.Col.Text, _override_color)
		}
		header_open := im.CollapsingHeader(c_type_name, {.DefaultOpen, .AllowOverlap})
		if comp_has_any_override {
			im.PopStyleColor(1)
		}
		_inspector_comp_open[comp.handle.type_key] = header_open

		im.Unindent(checkbox_size + im.GetStyle().ItemSpacing.x)

		im.SetCursorScreenPos(checkbox_pos)
		enabled := comp_base.enabled
		enabled_id := strings.clone_to_cstring(fmt.tprintf("##enabled_%v_%v", comp.handle.type_key, comp.handle.index), context.temp_allocator)
		if im.Checkbox(enabled_id, &enabled) {
			e := undo.edit_begin(comp.handle, comp_tid)
			comp_base.enabled = enabled
			undo.edit_end(&e)
		}

		_draw_component_overflow_menu(t, tH, &comp, comp_ptr, comp_tid, comp_idx, comp_count)

		if header_open {
			inspector.consume_inspector_changed()
			defer if inspector.consume_inspector_changed() {
				engine.component_on_validate(comp.handle.type_key, comp_ptr)
			}
			undo.push_component_owner(comp.handle)
			defer undo.pop_owner()

			prev_lid := engine.inspector_set_nested_local_id(comp_base.local_id)
			defer engine.inspector_set_nested_local_id(prev_lid)

			drawer := inspector.resolve_property_drawer(comp_tid)
			drawer(comp_ptr, comp_tid, c_type_name)
		}
	}

	if _comp_pending_remove.type_key != engine.INVALID_TYPE_KEY {
		undo.record_remove_component(tH, _comp_pending_remove)
	}

	if _comp_pending_move_from >= 0 && _comp_pending_move_to >= 0 && _comp_pending_move_from != _comp_pending_move_to {
		entry := t.components[_comp_pending_move_from]
		ordered_remove(&t.components, _comp_pending_move_from)
		inject_at(&t.components, _comp_pending_move_to, entry)
		undo.record_reorder_components(tH, _comp_pending_move_from, _comp_pending_move_to)
	}
}

@(private)
_draw_add_component_button :: proc(t: ^engine.Transform, tH: engine.Transform_Handle) {
	im.Spacing()
	im.Separator()
	im.Spacing()

	avail := im.GetContentRegionAvail().x
	btn_w: f32 = 220
	im.SetCursorPosX((avail - btn_w) * 0.5 + im.GetCursorPosX())
	if im.Button("Add Component", im.Vec2{btn_w, 0}) {
		im.OpenPopup("##AddComponentPopup")
	}

	if im.BeginPopup("##AddComponentPopup") {
		menu.draw_menu_subtree("Component")
		im.EndPopup()
	}
}
