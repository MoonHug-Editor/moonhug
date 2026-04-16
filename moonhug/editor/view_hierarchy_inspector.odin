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

	is_nested := t.nested_owned
	if is_nested {
		host_tH := engine.transform_nested_enclosing_host(tH)
		prev := engine.inspector_set_nested_host(host_tH)
		defer engine.inspector_set_nested_host(prev)
		engine.inspector_push_readonly()
		defer engine.inspector_pop_readonly()

		_draw_nested_banner(host_tH)
		im.BeginDisabled(true)
		defer im.EndDisabled()

		_draw_header(t)
		im.Separator()
		_draw_transform_section(t)
		_draw_components_section(t, tH)
		return
	}

	_draw_header(t)
	im.Separator()
	_draw_transform_section(t)
	_draw_components_section(t, tH)
	_draw_add_component_button(t, tH)
}

@(private)
_draw_nested_banner :: proc(host_tH: engine.Transform_Handle) {
	w := engine.ctx_world()
	source_path := ""
	if _, ns := engine.transform_get_comp(host_tH, engine.NestedScene); ns != nil {
		empty_guid := engine.Asset_GUID{}
		if ns.scene_guid != empty_guid {
			if path, ok := engine.asset_db_get_path(uuid.Identifier(ns.scene_guid)); ok {
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
		label = fmt.tprintf("Nested (read-only) from %s  -  host: %s", source_path, host_name)
	} else {
		label = fmt.tprintf("Nested (read-only)  -  host: %s", host_name)
	}
	im.TextColored(im.Vec4{1.0, 0.75, 0.3, 1.0}, strings.clone_to_cstring(label, context.temp_allocator))
	im.Separator()
}

@(private)
_draw_header :: proc(t: ^engine.Transform) {
	active := t.is_active
	if im.Checkbox("##active", &active) {
		t.is_active = active
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
			delete(t.name)
			t.name = strings.clone(new_name)
		}
	}
}

@(private)
_inspector_euler_cache: [3]f32

@(private)
_inspector_euler_quat_src: [4]f32

@(private)
_draw_transform_section :: proc(t: ^engine.Transform) {
	im.SetNextItemOpen(_inspector_transform_open, .Once)
	if im.CollapsingHeader("Transform", {.DefaultOpen}) {
		_inspector_transform_open = true
		drawer := inspector.resolve_property_drawer(typeid_of(^[3]f32))
		drawer(&t.position, typeid_of(^[3]f32), "Position")

		if _inspector_euler_quat_src != t.rotation {
			_inspector_euler_cache = engine.quat_to_euler_xyz(t.rotation)
			_inspector_euler_quat_src = t.rotation
		}
		prev_euler := _inspector_euler_cache
		drawer(&_inspector_euler_cache, typeid_of(^[3]f32), "Rotation")
		if _inspector_euler_cache != prev_euler {
			t.rotation = engine.quat_from_euler_xyz(_inspector_euler_cache.x, _inspector_euler_cache.y, _inspector_euler_cache.z)
			_inspector_euler_quat_src = t.rotation
		}

		drawer(&t.scale, typeid_of(^[3]f32), "Scale")
	} else {
		_inspector_transform_open = false
	}
}

@(private)
_comp_pending_remove: engine.Handle

@(private)
_comp_pending_move_from: int = -1

@(private)
_comp_pending_move_to: int = -1

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
			comp_base.enabled = enabled
		}

		popup_id := strings.clone_to_cstring(fmt.tprintf("##CompCtx_%v_%v", comp.handle.type_key, comp.handle.index), context.temp_allocator)
		im.SameLine(im.GetCursorPosX() + im.GetContentRegionAvail().x - 20)
		btn_label := strings.clone_to_cstring(fmt.tprintf("\u22ee##btn_%v_%v", comp.handle.type_key, comp.handle.index), context.temp_allocator)
		if im.SmallButton(btn_label) {
			im.OpenPopup(popup_id)
		}
		if im.BeginPopup(popup_id) {
			if engine.type_reset_procs[comp.handle.type_key] != nil {
				if im.MenuItem("Reset") {
					engine.type_reset(comp.handle.type_key, comp_ptr)
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
				_, new_ptr := engine.transform_add_comp(tH, clip_key)
				if new_ptr != nil {
					saved_base := (cast(^engine.CompData)new_ptr)^
					if clip.paste(any{new_ptr, clip_tid}) {
						base := cast(^engine.CompData)new_ptr
						base.owner = saved_base.owner
						base.local_id = saved_base.local_id
						base.enabled = saved_base.enabled
					}
				}
			}

			can_paste_values := clip.can_paste(comp_tid)
			if im.MenuItem("Paste Component Values", nil, false, can_paste_values) {
				saved_base := (cast(^engine.CompData)comp_ptr)^
				if clip.paste(any{comp_ptr, comp_tid}) {
					base := cast(^engine.CompData)comp_ptr
					base.owner = saved_base.owner
					base.local_id = saved_base.local_id
					base.enabled = saved_base.enabled
				}
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

		if header_open {
			inspector.consume_inspector_changed()
			defer if inspector.consume_inspector_changed() {
				engine.component_on_validate(comp.handle.type_key, comp_ptr)
			}
			drawer := inspector.resolve_property_drawer(comp_tid)
			drawer(comp_ptr, comp_tid, c_type_name)
		}
	}

	if _comp_pending_remove.type_key != engine.INVALID_TYPE_KEY {
		engine.transform_remove_comp(tH, _comp_pending_remove)
	}

	if _comp_pending_move_from >= 0 && _comp_pending_move_to >= 0 && _comp_pending_move_from != _comp_pending_move_to {
		entry := t.components[_comp_pending_move_from]
		ordered_remove(&t.components, _comp_pending_move_from)
		inject_at(&t.components, _comp_pending_move_to, entry)
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
