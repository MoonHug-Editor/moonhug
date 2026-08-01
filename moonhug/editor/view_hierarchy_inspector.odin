package editor

import "core:strings"
import "core:mem"
import "core:c"
import "core:fmt"
import "core:encoding/json"
import "core:encoding/uuid"
import im "moonhug:external/odin-imgui"
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
	if !im.Begin("Inspector", &menu.show_inspector, {.NoCollapse}) {
		im.End()
		return
	}
	defer im.End()

	tH := hierarchy_get_selected()
	if tH == _HANDLE_NONE {
		im.TextDisabled("No object selected")
		return
	}

	// Multi-selection shows the ACTIVE object only (no multiedit yet).
	if n := sel_scene_count(); n > 1 {
		im.TextDisabled(strings.clone_to_cstring(fmt.tprintf("%d selected — editing the active object", n), context.temp_allocator))
		im.Separator()
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
		// Immediate host (may itself be nested-owned for chains 2+ levels deep)
		// — this is the NS record that holds overrides about THIS transform's
		// prefab-level content. Picking the outermost native host instead would
		// miss overrides distributed onto inner NS records during resolve.
		host_tH := tH if is_host else engine.transform_immediate_nested_host(tH)
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
	_draw_missing_components(t, tH)
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
	_draw_overrides_button(host_tH)
	im.Separator()
}

// Unity's Overrides dropdown: every override on this instance in one list,
// multi-selectable, with Revert All / Revert Selected. Per-field revert still
// lives on the property context menu — this is the aggregate view for seeing
// what an instance has diverged on without hunting field by field.
//
// Shown on the instance ROOT only (Unity puts it on the root GameObject), and
// only for a NATIVE NS: inner NSs never hold records (docs/NestedPrefabs.md),
// so a nested-owned row deeper in the chain has nothing of its own to list.
@(private)
_draw_overrides_button :: proc(host_tH: engine.Transform_Handle) {
	w := engine.ctx_world()
	ht := engine.pool_get(&w.transforms, engine.Handle(host_tH))
	if ht == nil do return
	ns := engine.scene_find_nested_scene_for_host(ht.scene, host_tH)
	if ns == nil || ns.expand_parent != {} do return

	entries := engine.nested_scene_list_overrides(ht.scene, ns)
	if len(entries) == 0 {
		im.TextDisabled("No overrides")
		return
	}

	// Selection is keyed by list index, so it is dropped whenever the set of
	// rows changes underneath it (a revert, or another edit while open).
	if _overrides_popup_host != host_tH {
		_overrides_popup_host = host_tH
		clear(&_overrides_selected)
	}

	label := fmt.tprintf("Overrides (%d)", len(entries))
	if im.Button(strings.clone_to_cstring(label, context.temp_allocator)) {
		clear(&_overrides_selected)
		im.OpenPopup("##OverridesList")
	}

	if im.BeginPopup("##OverridesList") {
		im.TextDisabled("Click to select, ctrl/cmd or shift for multiple")
		im.Separator()

		nodes_for_revert := engine.nested_scene_override_tree(ht.scene, ns, host_tH, entries)
		if im.BeginChild("##OverridesRows", im.Vec2{460, 260}, {}, {}) {
			nodes := nodes_for_revert

			// Every element is separately selectable. Object elements use a
			// NEGATIVE key (-1 - node_index) so they share one selection map
			// with the rows without colliding.
			for node, ni in nodes {
				im.PushIDInt(c.int(ni))
				if node.depth > 0 do im.Indent(f32(node.depth) * 12)

				obj_key := -1 - ni
				// Dimmed when the TRANSFORM itself has no overrides — the object
				// may still be listed for its components or for a descendant, and
				// stays selectable either way.
				obj_dim := len(node.own_rows) == 0
				if obj_dim do im.PushStyleColorImVec4(im.Col.Text, _hierarchy_dimmed_color)
				if im.Selectable(
					strings.clone_to_cstring(
						fmt.tprintf("%s %s##o", _overrides_object_icon(ht.scene, node.tH), node.label),
						context.temp_allocator),
					obj_key in _overrides_selected,
					{.NoAutoClosePopups},
				) {
					_overrides_apply_click(obj_key)
				}
				if obj_dim do im.PopStyleColor(1)

				// One element per COMPONENT (or the transform), not per field —
				// three position/rotation/scale changes read as one "Transform".
				// The group's first row is its selection key.
				for g in node.groups {
					if len(g.rows) == 0 do continue
					key := g.rows[0]
					im.Indent(14)
					if im.Selectable(
						strings.clone_to_cstring(
							fmt.tprintf("%s##g%d", g.label, key), context.temp_allocator),
						key in _overrides_selected,
						{.NoAutoClosePopups},
					) {
						_overrides_apply_click(key)
					}
					im.Unindent(14)
				}

				if node.depth > 0 do im.Unindent(f32(node.depth) * 12)
				im.PopID()
			}
		}
		im.EndChild()

		// Detail panel for a SINGLE selected element (Unity): the source prefab
		// it came from, and what this element overrides. A multi-selection has
		// no single subject, so the panel is hidden and only the bulk buttons
		// below apply.
		if len(_overrides_selected) == 1 {
			for key in _overrides_selected {
				im.Separator()
				_draw_override_detail(ht.scene, ns, nodes_for_revert, entries, key)
			}
		}

		im.Separator()
		// An object element stands for its OWN rows when reverting (selecting
		// it and hitting Revert should do something), but it is still a
		// separate element for selection — clicking it does not select them.
		sel_rows := _overrides_selected_rows(nodes_for_revert)
		n_sel := len(sel_rows)

		if im.Button("Revert All") {
			_overrides_revert(ht.scene, ns, host_tH, entries, nil)
			im.CloseCurrentPopup()
		}
		im.SameLine()

		sel_label := n_sel > 0 \
			? fmt.tprintf("Revert Selected (%d)", n_sel) \
			: "Revert Selected"
		im.BeginDisabled(n_sel == 0)
		if im.Button(strings.clone_to_cstring(sel_label, context.temp_allocator)) {
			_overrides_revert(ht.scene, ns, host_tH, entries, &sel_rows)
			im.CloseCurrentPopup()
		}
		im.EndDisabled()

		im.EndPopup()
	}
}

// The same glyph the hierarchy row uses (view_hierarchy.odin): stacks for a
// nested-scene host, the variant glyph when its source asset is a variant,
// stat_0 for a plain object — so an object reads the same in both views.
@(private)
_overrides_object_icon :: proc(s: ^engine.Scene, tH: engine.Transform_Handle) -> cstring {
	if tH == _HANDLE_NONE do return ICON_MD_STAT_0
	ns := engine.scene_find_nested_scene_for_host(s, tH)
	if ns == nil do return ICON_MD_STAT_0
	if engine.nested_scene_is_root_variant(s, ns) do return ICON_MD_STACKS_VARIANT
	if info, ok := engine.asset_db_get_root_info(ns.source_prefab); ok && info.is_variant {
		return ICON_MD_STACKS_VARIANT
	}
	return ICON_MD_STACKS
}

// Click handling: ctrl/cmd toggles, shift ranges from the anchor, plain click
// replaces. `key` is a row index, or -1 - node_index for an object element.
// A shift range only spans keys of the SAME kind — objects and rows interleave
// in the display but not in the key space, so a mixed range would select
// arbitrary unrelated elements.
@(private)
_overrides_apply_click :: proc(key: int) {
	io := im.GetIO()
	ri := key
	if io.KeyCtrl || io.KeySuper {
		if ri in _overrides_selected {
			delete_key(&_overrides_selected, ri)
		} else {
			_overrides_selected[ri] = true
		}
	} else if io.KeyShift && _overrides_anchor_valid &&
	          (_overrides_anchor < 0) == (ri < 0) {
		clear(&_overrides_selected)
		lo := min(_overrides_anchor, ri)
		hi := max(_overrides_anchor, ri)
		for k in lo ..= hi do _overrides_selected[k] = true
	} else {
		clear(&_overrides_selected)
		_overrides_selected[ri] = true
		_overrides_anchor = ri
		_overrides_anchor_valid = true
	}
}

// Reverts `which` (nil = all). Iterates in REVERSE so each removal cannot
// shift the index of a row not yet processed — the entries are positional
// snapshots of the record arrays.
@(private)
_overrides_revert :: proc(
	s: ^engine.Scene,
	ns: ^engine.NestedScene,
	host_tH: engine.Transform_Handle,
	entries: []engine.Override_Entry,
	which: ^map[int]bool,
) {
	// One undo step for the whole action, however many rows it touched — the
	// group is opened first so each row's record lands inside it.
	u := undo.get()
	undo.begin_group_command(u)

	reverted := false
	for i := len(entries) - 1; i >= 0; i -= 1 {
		if which != nil && !(i in which^) do continue
		e := entries[i]

		if e.kind == .Modified_Property {
			// Exactly the property menu's Revert (view_inspector.odin): wrap the
			// live field in a Value_Command so undo AND redo restore the value,
			// then fold the record removal into that same step. Rebuilding this
			// by hand is what left redo broken — the record round-tripped but
			// the value did not.
			fp, ftid, owner, found := engine.nested_scene_find_revert_target(s, ns, e.target, e.property_path)
			snap := undo.override_removal_snapshot(ns, e.target, e.property_path)
			// The Value_Command is keyed by the object that CONTAINS the field,
			// which is the row's target, not the inspected object.
			if found do undo.push_pooled_owner(owner)
			scope := undo.edit_inspector_field_begin(fp, ftid, "Revert Override") if found else undo.Edit_Scope{}
			engine.nested_scene_revert_override(s, ns, e.target, e.property_path, fp)
			if found {
				undo.edit_end(&scope)
				undo.pop_owner()
			}
			undo.record_override_removed(s, host_tH, e.target.local_id, e.property_path, snap)
			reverted = true
			continue
		}

		// Structural kinds have no live field to snapshot — the record IS the
		// edit, and the instance rebuilds from the prefab on the next resolve.
		snap := engine.nested_override_snapshot(ns, e)
		if engine.nested_override_entry_revert(s, ns, e) {
			reverted = true
			undo.record_dropdown_revert(s, host_tH, e.kind, e.target, e.property_path, nil, snap)
		} else {
			engine.nested_override_snapshot_destroy(&snap)
		}
	}

	if reverted {
		undo.end_group_command(u, "Revert Override")
	} else {
		undo.abort_group_command(u)
	}

	if reverted {
		clear(&_overrides_selected)
		_overrides_anchor_valid = false
		// Field reverts restore the live value themselves. The structural kinds
		// only drop the record — the instance rebuilds from the prefab on the
		// next resolve, which is how the undo paths handle them too.
		inspector.mark_inspector_changed()
	}
}

@(private)
_overrides_selected: map[int]bool
@(private)
_overrides_anchor: int
@(private)
_overrides_anchor_valid: bool
@(private)
_overrides_popup_host: engine.Transform_Handle

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
_resolve_override_target_id :: proc(tH: engine.Transform_Handle, t: ^engine.Transform, host_tH: engine.Transform_Handle) -> engine.Local_ID {
	// When the inspected transform IS the NS host, the override targets the
	// prefab's source root id (in the inner prefab's namespace). For descendants,
	// the live local_id IS the inner-prefab local_id and matches override targets
	// directly. Discriminating by tH==host_tH (rather than t.nested_owned) is
	// what lets this work for chains 2+ levels deep where the host transform is
	// itself nested-owned (it lives inside an outer prefab's expansion).
	if tH == host_tH {
		ns := _nested_scene_for_host(host_tH)
		if ns != nil && ns.source_root_id != 0 do return ns.source_root_id
	}
	return t.local_id
}

@(private)
_wrap_transform_field_override :: proc(tH: engine.Transform_Handle, t: ^engine.Transform, field_ptr: rawptr, prop_path: string, field_tid: typeid, drawer: proc(ptr: rawptr, tid: typeid, label: cstring), drawer_tid: typeid, label: cstring) {
	host_tH := engine.inspector_get_nested_host()
	is_in_nested_ctx := host_tH != {} && (t.nested_owned || engine.scene_find_nested_scene_for_host(t.scene, tH) != nil)

	target_id: engine.Local_ID
	is_overridden := false
	if is_in_nested_ctx {
		target_id = _resolve_override_target_id(tH, t, host_tH)
		is_overridden = engine.nested_scene_has_root_override(t.scene, host_tH, target_id, prop_path)
	}

	pushed := _push_override_style(is_overridden)
	committed := _wrap_transform_field(tH, field_ptr, 0, field_tid, drawer, drawer_tid, label)
	_pop_override_style(pushed)

	prev_nested_lid := engine.inspector_get_nested_local_id()
	if is_in_nested_ctx {
		engine.inspector_set_nested_local_id(target_id)
		// Transform fields go through _wrap_transform_field, not the generic
		// field loop, so they pass that wrapper's own commit signal.
		inspector.record_nested_override(field_ptr, field_tid, prop_path, committed)
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

	target_id: engine.Local_ID
	is_overridden := false
	if is_in_nested_ctx {
		target_id = _resolve_override_target_id(tH, t, host_tH)
		is_overridden = engine.nested_scene_has_root_override(t.scene, host_tH, target_id, "rotation")
	}

	pushed := _push_override_style(is_overridden)
	committed := _wrap_transform_rotation(tH, t, drawer)
	_pop_override_style(pushed)

	prev_nested_lid := engine.inspector_get_nested_local_id()
	if is_in_nested_ctx {
		engine.inspector_set_nested_local_id(target_id)
		// The euler widget writes t.rotation, so the override records the
		// quaternion — the same field the diff and revert use.
		inspector.record_nested_override(&t.rotation, typeid_of([4]f32), "rotation", committed)
	}
	inspector.draw_field_context_menu(&t.rotation, typeid_of([4]f32), "rotation")
	if is_in_nested_ctx {
		engine.inspector_set_nested_local_id(prev_nested_lid)
	}
}

@(private)
_inspector_rot_drag: undo.Field_Drag

// `committed`: see _wrap_transform_field. The euler widget writes through to
// t.rotation, so the commit point is the drag release.
@(private)
_wrap_transform_rotation :: proc(tH: engine.Transform_Handle, t: ^engine.Transform, drawer: proc(ptr: rawptr, tid: typeid, label: cstring)) -> (committed: bool) {
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

	// This widget edits a CACHE (euler) that writes through to t.rotation, so
	// its change signal is the cache delta, not the package changed flag, and
	// a release only ends the undo entry when a drag actually opened one.
	// Commit either way — inspector.Field_Commit's two events, with the drag
	// close attached to the first.
	euler_changed := _inspector_euler_cache != prev_euler
	if im.IsItemDeactivatedAfterEdit() && _inspector_rot_drag.active {
		undo.field_drag_end(&_inspector_rot_drag)
		committed = true
	} else if inspector.field_commit_state_of(euler_changed) != .None {
		committed = true
	}

	if prev_changed do inspector.mark_inspector_changed()
	return
}

// `committed` reports that this frame closed an edit of the field — the moment
// a prefab-instance override must be recorded. The caller can't re-derive it:
// the changed flag is consumed here, so reading it afterwards would miss
// typed-in edits. Commit DETECTION is inspector.field_commit_state (one
// predicate for every field widget); this wrapper only chooses which undo API
// each kind commits through.
@(private)
_wrap_transform_field :: proc(tH: engine.Transform_Handle, field_ptr: rawptr, offset: uintptr, field_tid: typeid, drawer: proc(ptr: rawptr, tid: typeid, label: cstring), drawer_tid: typeid, label: cstring) -> (committed: bool) {
	prev_changed := inspector.consume_inspector_changed()
	undo.begin_field(field_ptr, field_tid)

	drawer(field_ptr, drawer_tid, label)

	if im.IsItemActivated() {
		undo.promote_to_pending()
	}
	// A released drag commits the pending entry it opened; otherwise a value
	// that landed while the widget isn't holding focus ends the field as
	// changed. `pending_matches` failing on release falls through to the
	// value case, exactly as the original chained conditions did.
	state := inspector.field_commit_state_of(inspector.is_changed_flag_set())
	if state == .Drag_Released && undo.pending_matches(field_ptr) {
		undo.pending_commit()
		undo.end_field(false)
		committed = true
	} else if inspector.is_changed_flag_set() && !im.IsItemActive() && !undo.pending_is_active() {
		undo.end_field(true)
		committed = true
	} else {
		undo.end_field(false)
	}

	if prev_changed do inspector.mark_inspector_changed()
	return
}

@(private)
_comp_pending_remove: engine.Handle

@(private)
_comp_pending_move_from: int = -1

@(private)
_comp_pending_move_to: int = -1

// `nested`: the component belongs to a nested prefab instance. Remove and Add
// are recorded as removed_components / added_components on the instance's
// NestedScene, so they survive save and the next resolve. Reorder has no
// representation (component order is prefab content) and stays disabled.
@(private)
_draw_component_overflow_menu :: proc(
	t: ^engine.Transform,
	tH: engine.Transform_Handle,
	comp: ^engine.Owned,
	comp_ptr: rawptr,
	comp_tid: typeid,
	comp_idx: int,
	comp_count: int,
	nested := false,
) {
	popup_id := strings.clone_to_cstring(fmt.tprintf("##CompCtx_%v_%v", comp.handle.type_key, comp.handle.index), context.temp_allocator)
	im.SameLine(im.GetCursorPosX() + im.GetContentRegionAvail().x - 20)
	btn_label := strings.clone_to_cstring(fmt.tprintf("%s##btn_%v_%v", ICON_MD_MENU, comp.handle.type_key, comp.handle.index), context.temp_allocator)
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
			if im.MenuItem(strings.clone_to_cstring(move_up_label, context.temp_allocator), nil, false, !nested) {
				_comp_pending_move_from = comp_idx
				_comp_pending_move_to = shift_held ? 0 : comp_idx - 1
			}
		}
		if comp_idx < comp_count - 1 {
			move_down_label := shift_held ? "Move to Bottom" : "Move Down"
			if im.MenuItem(strings.clone_to_cstring(move_down_label, context.temp_allocator), nil, false, !nested) {
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
			// Scope widget IDs per component: different component types can
			// share field names (SpriteRenderer.sorting_layer vs
			// SpriteSortingGroup.sorting_layer) and would collide otherwise.
			im.PushID(c_type_name)
			defer im.PopID()
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

// Preserved unknown-component records owned by this transform (the component's
// package isn't compiled into this binary — Unity's missing-script row). The
// data has no live pool instance or typeid: header-only, not editable, and it
// re-emits verbatim on save. The overflow menu sits where the live components'
// menu sits, but only offers Remove — reset/copy/paste/reorder all need a
// typed instance. Own-file transforms only: nested content's unknowns live in
// the PREFAB's file (stash skips them at load), so nested rows never match.
@(private)
_draw_missing_components :: proc(t: ^engine.Transform, tH: engine.Transform_Handle) {
	s := t.scene
	if s == nil do return

	pending_remove := engine.Local_ID(0)
	for &uc in s.unknown_components {
		if uc.owner_lid != t.local_id do continue

		guid_str := "?"
		if obj, is_obj := uc.value.(json.Object); is_obj {
			if gs, gok := obj[engine.EXT_TYPE_KEY].(json.String); gok do guid_str = string(gs)
		}

		header := strings.clone_to_cstring(
			fmt.tprintf("%s Missing Component (%s)##missing_%d", ICON_MD_WARNING, guid_str, uc.local_id),
			context.temp_allocator,
		)
		header_open := im.CollapsingHeader(header, {.AllowOverlap})

		// Overflow menu in the same spot as live components'.
		popup_id := strings.clone_to_cstring(fmt.tprintf("##MissCtx_%d", uc.local_id), context.temp_allocator)
		im.SameLine(im.GetCursorPosX() + im.GetContentRegionAvail().x - 20)
		btn_label := strings.clone_to_cstring(fmt.tprintf("%s##mbtn_%d", ICON_MD_MENU, uc.local_id), context.temp_allocator)
		if im.SmallButton(btn_label) {
			im.OpenPopup(popup_id)
		}
		if im.BeginPopup(popup_id) {
			if im.MenuItem("Remove Component") {
				pending_remove = uc.local_id
			}
			im.EndPopup()
		}

		if header_open {
			// The preserved record as read-only (selectable) JSON.
			opts := json.Marshal_Options{spec = .JSON, pretty = true, use_spaces = true, spaces = 2, sort_maps_by_key = true}
			if data, merr := json.marshal(uc.value, opts, context.temp_allocator); merr == nil {
				text := string(data)
				lines := strings.count(text, "\n") + 1
				height := f32(min(lines, 16)) * im.GetTextLineHeight() + im.GetStyle().FramePadding.y * 2
				buf := strings.clone_to_cstring(text, context.temp_allocator)
				field_id := strings.clone_to_cstring(fmt.tprintf("##missing_json_%d", uc.local_id), context.temp_allocator)
				im.InputTextMultiline(field_id, buf, uint(len(text) + 1), im.Vec2{-1, height}, {.ReadOnly})
			}
		}
	}

	if pending_remove != 0 {
		undo.record_remove_unknown_component(tH, pending_remove)
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

		// Per docs/NestedPrefabs.md, only root scene's overrides should color
		// the component header. Walk up to the root NS and check if it has
		// any override targeting this component (directly via lid for native
		// hosts, or via a breadcrumb for deep ones).
		comp_has_any_override := engine.nested_scene_has_any_root_override_for_target(t.scene, host_tH, comp_base.local_id)

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

		// "enabled" lives on CompData.enabled which is at base.enabled. Mark
		// it overridden if root scene has the matching override; the field
		// context menu uses this for revert.
		enabled_overridden := engine.nested_scene_has_root_override(t.scene, host_tH, comp_base.local_id, "base.enabled")
		enabled_pushed := _push_override_style(enabled_overridden)
		if im.Checkbox(enabled_id, &enabled) {
			e := undo.edit_begin(comp.handle, comp_tid)
			comp_base.enabled = enabled
			undo.edit_end(&e)
		}
		_pop_override_style(enabled_pushed)

		prev_enabled_lid := engine.inspector_set_nested_local_id(comp_base.local_id)
		inspector.draw_field_context_menu(&comp_base.enabled, typeid_of(bool), "base.enabled")
		engine.inspector_set_nested_local_id(prev_enabled_lid)

		_draw_component_overflow_menu(t, tH, &comp, comp_ptr, comp_tid, comp_idx, comp_count, nested = true)

		if header_open {
			inspector.consume_inspector_changed()
			defer if inspector.consume_inspector_changed() {
				engine.component_on_validate(comp.handle.type_key, comp_ptr)
			}
			undo.push_component_owner(comp.handle)
			defer undo.pop_owner()

			prev_lid := engine.inspector_set_nested_local_id(comp_base.local_id)
			defer engine.inspector_set_nested_local_id(prev_lid)

			// Per-component ID scope — same reason as _draw_components_section.
			im.PushID(c_type_name)
			defer im.PopID()
			drawer := inspector.resolve_property_drawer(comp_tid)
			drawer(comp_ptr, comp_tid, c_type_name)
		}
	}

	if _comp_pending_remove.type_key != engine.INVALID_TYPE_KEY {
		// Removing PREFAB content is a structural override: the component is
		// destroyed AND recorded as removed, so the next resolve doesn't bring
		// it back. Both steps ride one undo entry.
		comp_lid: engine.Local_ID
		if raw := engine.world_pool_get(w, _comp_pending_remove); raw != nil {
			comp_lid = (cast(^engine.CompData)raw).local_id
		}
		undo.record_remove_component(tH, _comp_pending_remove)
		if comp_lid != 0 {
			if _, ok := engine.nested_scene_record_component_removed(t.scene, host_tH, comp_lid); ok {
				undo.record_component_removed_on_instance(t.scene, host_tH, comp_lid)
			}
		}
	}

	if _comp_pending_move_from >= 0 && _comp_pending_move_to >= 0 && _comp_pending_move_from != _comp_pending_move_to {
		entry := t.components[_comp_pending_move_from]
		ordered_remove(&t.components, _comp_pending_move_from)
		inject_at(&t.components, _comp_pending_move_to, entry)
		undo.record_reorder_components(tH, _comp_pending_move_from, _comp_pending_move_to)
	}

	_draw_add_component_button_nested(t, tH, host_tH)
}

// Add Component on prefab-instance content. The add itself is the shared path
// (component_add_to_selected records the addition on the instance's NestedScene);
// this only supplies the button, with its own popup id so it can't collide with
// the non-nested one.
@(private)
_draw_add_component_button_nested :: proc(t: ^engine.Transform, tH: engine.Transform_Handle, host_tH: engine.Transform_Handle) {
	im.Spacing()
	im.Separator()
	im.Spacing()

	avail := im.GetContentRegionAvail().x
	btn_w: f32 = 220
	im.SetCursorPosX((avail - btn_w) * 0.5 + im.GetCursorPosX())
	if im.Button("Add Component", im.Vec2{btn_w, 0}) {
		im.OpenPopup("##AddComponentPopupNested")
	}
	if im.IsItemHovered({}) {
		im.SetTooltip("Adds a component to this prefab instance only (recorded as an override)")
	}

	if im.BeginPopup("##AddComponentPopupNested") {
		menu.draw_menu_subtree("Component")
		im.EndPopup()
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

// The selected elements expanded to actual row indices: a selected row is
// itself, a selected object contributes its OWN rows. Object elements carry no
// record of their own, so they cannot be reverted directly.
@(private)
_overrides_selected_rows :: proc(nodes: []engine.Override_Node) -> map[int]bool {
	out := make(map[int]bool, 0, context.temp_allocator)
	for key in _overrides_selected {
		if key < 0 {
			// An object element covers the TRANSFORM's own rows only. Its
			// components are separate elements — selecting the object is not a
			// shorthand for selecting them (Unity treats each separately).
			ni := -1 - key
			if ni < 0 || ni >= len(nodes) do continue
			for ri in nodes[ni].own_rows do out[ri] = true
			continue
		}
		// A group element, keyed by its first row — reverting it reverts every
		// field on that component, not just the one the key names.
		found := false
		for node in nodes {
			for g in node.groups {
				if len(g.rows) == 0 || g.rows[0] != key do continue
				for ri in g.rows do out[ri] = true
				found = true
				break
			}
			if found do break
		}
		if !found do out[key] = true
	}
	return out
}

// The single-selection detail view (Unity): the object's values as the PREFAB
// defines them on the left, read-only, and the live instance on the right where
// they are editable. Both panes are real inspectors — the same property drawers
// the main inspector uses — so a comparison shows the fields, not a text
// summary of them.
//
// Prefab Source names the asset above the panes. An object with no overrides of
// its own says so rather than drawing two identical panes.
@(private)
_draw_override_detail :: proc(
	s: ^engine.Scene,
	ns: ^engine.NestedScene,
	nodes: []engine.Override_Node,
	entries: []engine.Override_Entry,
	key: int,
) {
	source := "(unknown)"
	if path, ok := engine.asset_db_get_path(uuid.Identifier(ns.source_prefab)); ok {
		source = path
	}
	im.TextDisabled("Prefab Source")
	im.BeginDisabled(true)
	im.SetNextItemWidth(-1)
	im.InputText("##PrefabSource",
		strings.clone_to_cstring(source, context.temp_allocator),
		c.size_t(len(source) + 1), {.ReadOnly})
	im.EndDisabled()

	// Which object, and which component on it, this element is about.
	obj_tH := engine.Transform_Handle{}
	target := engine.PPtr{}
	if key >= 0 {
		if key >= len(entries) do return
		obj_tH = entries[key].object_tH
		target = entries[key].target
	} else {
		ni := -1 - key
		if ni < 0 || ni >= len(nodes) do return
		if len(nodes[ni].own_rows) == 0 {
			im.Spacing()
			im.TextDisabled("No overrides")
			return
		}
		obj_tH = nodes[ni].tH
		// An object element is about the TRANSFORM, so the target must come
		// from its own rows. Taking rows[0] could hand a COMPONENT target to
		// the left pane while the right drew the transform — the two panes then
		// described different objects.
		target = entries[nodes[ni].own_rows[0]].target
	}

	// Resolve the target ONCE to the live object it names — a transform or a
	// component on it — so both panes describe the same thing.
	w := engine.ctx_world()
	live := engine.nested_override_live_handle(s, ns, target)
	is_comp := live != {} && live.type_key != .Transform

	im.Spacing()
	if im.BeginTable("##OverrideCompare", 2, im.TableFlags_BordersInner | im.TableFlags_SizingStretchSame) {
		im.TableSetupColumn("Prefab Source")
		im.TableSetupColumn("Overrides")
		im.TableHeadersRow()
		im.TableNextRow()

		// LEFT: the prefab's values, read-only. Asking for the same type_key
		// the live side draws keeps the two panes comparable.
		im.TableSetColumnIndex(0)
		base_key := live.type_key if is_comp else engine.INVALID_TYPE_KEY
		base := engine.nested_override_baseline(s, ns, target, base_key)
		if base.ok {
			// Clear the nested context for this pane: these are PREFAB values,
			// not instance content, so nothing here is an override. Leaving the
			// live context set made the left side mark the same fields bold as
			// the right, so both panes looked overridden.
			base_prev_host := engine.inspector_set_nested_host({})
			base_prev_lid := engine.inspector_set_nested_local_id(0)
			im.BeginDisabled(true)
			im.PushID("##base")
			if drawer := inspector.resolve_property_drawer(base.tid); drawer != nil {
				drawer(base.ptr, base.tid,
					strings.clone_to_cstring(base.label, context.temp_allocator))
			}
			im.PopID()
			im.EndDisabled()
			engine.inspector_set_nested_host(base_prev_host)
			engine.inspector_set_nested_local_id(base_prev_lid)
		} else {
			// An ADDED component or object has no prefab side by definition.
			im.TextDisabled("(not in prefab)")
		}

		// RIGHT: the live instance, editable — edits record overrides exactly
		// as they do in the main inspector, via the same drawers and owner.
		//
		// The nested host/local_id context is what tells a field it is prefab
		// content: without it the drawers cannot mark overrides (bold) or offer
		// Revert/Apply, and an edit here would not record an override at all.
		// The main inspector sets the same pair before drawing.
		im.TableSetColumnIndex(1)
		host_for_ctx := engine.nested_scene_resolve_host_handle(s, ns)
		prev_host := engine.inspector_set_nested_host(host_for_ctx)
		defer engine.inspector_set_nested_host(prev_host)
		if is_comp {
			if raw := engine.world_pool_get(w, live); raw != nil {
				ctid := engine.get_typeid_by_type_key(live.type_key)
				im.PushID("##live")
				undo.push_component_owner(live)
				prev_lid := engine.inspector_set_nested_local_id(
					(cast(^engine.CompData)raw).local_id)
				if drawer := inspector.resolve_property_drawer(ctid); drawer != nil {
					drawer(raw, ctid, strings.clone_to_cstring(
						fmt.tprintf("%v", live.type_key), context.temp_allocator))
				}
				engine.inspector_set_nested_local_id(prev_lid)
				undo.pop_owner()
				im.PopID()
			} else {
				im.TextDisabled("(not in instance)")
			}
		} else if lt := engine.pool_get(&w.transforms, engine.Handle(obj_tH)); lt != nil {
			im.PushID("##live")
			undo.push_transform_owner(obj_tH)
			prev_lid := engine.inspector_set_nested_local_id(lt.local_id)
			if drawer := inspector.resolve_property_drawer(typeid_of(engine.Transform)); drawer != nil {
				drawer(lt, typeid_of(engine.Transform), "Transform")
			}
			engine.inspector_set_nested_local_id(prev_lid)
			undo.pop_owner()
			im.PopID()
		} else {
			// A REMOVED object/component: gone from the instance, still in the
			// prefab — the left pane is the whole story.
			im.TextDisabled("(removed from instance)")
		}

		im.EndTable()
	}
}
