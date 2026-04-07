package editor

import "core:fmt"
import "core:strings"
import "core:mem"
import "core:c"
import "core:path/filepath"
import im "../../external/odin-imgui"
import engine "../engine"
import clip "clipboard"

HIERARCHY_DRAG_TYPE :: "HIERARCHY_TRANSFORM"

_HANDLE_NONE :: engine.Transform_Handle{}

@(private)
_hierarchy_selected: engine.Transform_Handle

@(private)
_hierarchy_rename_target: engine.Transform_Handle
@(private)
_hierarchy_rename_buf: [256]byte
@(private)
_hierarchy_rename_focus: bool
@(private)
_hierarchy_rename_just_opened: bool
@(private)
_hierarchy_rename_just_finished: bool

@(private)
_hierarchy_dimmed_color: im.Vec4

@(private)
_hierarchy_force_open: engine.Transform_Handle

@(private)
_hierarchy_alt_open_pending: map[engine.Transform_Handle]bool

@(private)
_hierarchy_nav_list: [dynamic]engine.Transform_Handle

@(private)
_save_as_buf: [512]byte
@(private)
_save_as_open: bool
@(private)
_save_as_pending: bool

draw_hierarchy_view :: proc() {
	open := im.Begin("Hierarchy", nil, {.NoCollapse})

	if im.BeginDragDropTarget() {
		payload := im.AcceptDragDropPayload("ASSET_PATH", {})
		if payload != nil && payload.Data != nil {
			path := string(([^]byte)(payload.Data)[:payload.DataSize])
			if strings.has_suffix(path, ".scene") {
				engine.scene_load_additive_path(path)
			}
		}
		im.EndDragDropTarget()
	}

	if !open {
		im.End()
		return
	}
	defer im.End()

	text_col := im.GetStyleColorVec4(im.Col.Text)
	_hierarchy_dimmed_color = {text_col[0] * 0.5, text_col[1] * 0.5, text_col[2] * 0.5, text_col[3]}

	im.PushStyleVarY(im.StyleVar.ItemSpacing, 1)
	im.PushStyleVarY(im.StyleVar.FramePadding, 1)
	defer im.PopStyleVar(2)

	sm := engine.ctx_scene_manager()
	has_any := false
	last_valid_idx := -1
	for i in 0..<sm.count {
		if sm.loaded[i] != nil && engine.sm_scene_is_valid(sm.loaded[i]) {
			last_valid_idx = i
		}
	}

	clear(&_hierarchy_nav_list)

	for i in 0..<sm.count {
		scene := sm.loaded[i]
		if scene == nil || !engine.sm_scene_is_valid(scene) do continue
		has_any = true
		_draw_scene_section(scene, is_last = i == last_valid_idx)
	}

	if !has_any {
		im.TextDisabled("No loaded scenes")
	}

	if _hierarchy_rename_just_finished {
		_hierarchy_rename_just_finished = false
	} else {
		is_not_renaming := _hierarchy_rename_target == _HANDLE_NONE
		has_selected := _hierarchy_selected != _HANDLE_NONE
		if is_not_renaming && im.IsWindowFocused({}) {
			if has_selected {
				is_root_selected := false
				for i in 0..<sm.count {
					scene := sm.loaded[i]
					if scene == nil || !engine.sm_scene_is_valid(scene) do continue
					if engine.Transform_Handle(scene.root.handle) == _hierarchy_selected {
						is_root_selected = true
						break
					}
				}
				if !is_root_selected {
					if im.IsKeyPressed(im.Key.Enter) || im.IsKeyPressed(im.Key.F2) {
						_begin_rename(_hierarchy_selected)
					}
				}
			}
			_handle_hierarchy_keyboard_nav(sm)
		}
	}
}

@(private)
_draw_scene_section :: proc(scene: ^engine.Scene, is_last := false) {
	scene_name := "Untitled"
	if len(scene.path) > 0 {
		scene_name = filepath.stem(scene.path)
	}

	im.PushIDPtr(scene)
	defer im.PopID()

	im.Separator()

	im.Text(strings.clone_to_cstring(scene_name, context.temp_allocator))
	btn_size := im.Vec2{24, 0}
	im.SameLine(im.GetContentRegionAvail().x + im.GetCursorPosX() - btn_size.x)
	if im.Button("...", btn_size) {
		im.OpenPopup("##SceneHeaderMenu")
	}
	if im.BeginPopup("##SceneHeaderMenu") {
		if im.MenuItem("Save") {
			if len(scene.path) > 0 {
				engine.scene_save(scene, scene.path)
			} else {
				_save_as_open = true
				_save_as_pending = true
				mem.zero(&_save_as_buf, len(_save_as_buf))
			}
		}
		if im.MenuItem("Save As") {
			_save_as_open = true
			_save_as_pending = true
			mem.zero(&_save_as_buf, len(_save_as_buf))
			current_path := scene.path
			path_bytes := transmute([]u8)current_path
			copy_len := min(len(path_bytes), len(_save_as_buf) - 1)
			mem.copy(&_save_as_buf[0], raw_data(path_bytes), copy_len)
		}
		im.Separator()
		if im.MenuItem("Unload") {
			engine.sm_scene_unload(scene)
			im.EndPopup()
			return
		}
		im.EndPopup()
	}
	if _save_as_pending {
		im.OpenPopup("Save Scene As")
		_save_as_pending = false
	}
	_draw_save_as_popup(scene)

	root_tH := engine.Transform_Handle(scene.root.handle)
	_draw_hierarchy_node(root_tH, scene, is_root = true)

	if is_last {
		_draw_drop_target_empty_space(scene)
	}

	if im.BeginPopupContextWindow("##HierarchyContextBg", im.PopupFlags_MouseButtonRight | im.PopupFlags_NoOpenOverItems) {
		if im.MenuItem("Create Empty", nil, false, true) {
			engine.transform_new("Transform", root_tH)
		}
		im.EndPopup()
	}
}

@(private)
_draw_save_as_popup :: proc(scene: ^engine.Scene) {
	center := im.GetMainViewport().WorkPos
	center.x += im.GetMainViewport().WorkSize.x * 0.5
	center.y += im.GetMainViewport().WorkSize.y * 0.5
	im.SetNextWindowPos(center, .Appearing, im.Vec2{0.5, 0.5})
	im.SetNextWindowSize(im.Vec2{450, 0}, .Appearing)
	if im.BeginPopupModal("Save Scene As", &_save_as_open, {}) {
		im.Text("File path:")
		im.SetNextItemWidth(-1)
		buf_cstr := cstring(raw_data(_save_as_buf[:]))
		im.InputText("##save_as_path", buf_cstr, c.size_t(len(_save_as_buf)), {})

		if im.Button("Save", im.Vec2{120, 0}) {
			path := string(buf_cstr)
			if len(path) > 0 {
				engine.scene_save(scene, path)
			}
			_save_as_open = false
			im.CloseCurrentPopup()
		}
		im.SameLine()
		if im.Button("Cancel", im.Vec2{120, 0}) {
			_save_as_open = false
			im.CloseCurrentPopup()
		}
		im.EndPopup()
	}
}

@(private)
_draw_hierarchy_node :: proc(tH: engine.Transform_Handle, scene: ^engine.Scene, is_root := false, parent_inactive := false) {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return

	has_children := len(t.children) > 0
	is_selected := _hierarchy_selected == tH
	is_renaming := !is_root && _hierarchy_rename_target == tH

	pushed_dim := !t.is_active && !parent_inactive
	inactive := parent_inactive || !t.is_active

	flags := im.TreeNodeFlags{.OpenOnArrow, .OpenOnDoubleClick, .SpanAvailWidth}
	if is_selected {
		flags += {.Selected}
	}
	if is_root {
		flags += {.DefaultOpen}
	}
	if !has_children {
		flags += {.Leaf, .NoTreePushOnOpen}
	}

	im.PushIDInt(c.int(engine.Handle(tH).index))

	if pushed_dim {
		im.PushStyleColorImVec4(im.Col.Text, _hierarchy_dimmed_color)
	}

	if _hierarchy_force_open == tH {
		im.SetNextItemOpen(true)
		_hierarchy_force_open = _HANDLE_NONE
	} else if v, ok := _hierarchy_alt_open_pending[tH]; ok {
		im.SetNextItemOpen(v)
		delete_key(&_hierarchy_alt_open_pending, tH)
	}
	node_open := im.TreeNodeEx("##n", flags)

	append(&_hierarchy_nav_list, tH)

	if has_children && im.IsItemToggledOpen() {
		if im.GetIO().KeyAlt {
			_populate_alt_open_pending(t, node_open)
		}
	}
	node_rect_min := im.GetItemRectMin()
	node_rect_max := im.GetItemRectMax()

	text_x := node_rect_min.x + im.GetTreeNodeToLabelSpacing()
	if is_renaming {
		input_width := node_rect_max.x - text_x
		im.SetCursorScreenPos(im.Vec2{text_x, node_rect_min.y})
		if _hierarchy_rename_focus {
			im.SetKeyboardFocusHere(0)
			_hierarchy_rename_focus = false
			_hierarchy_rename_just_opened = true
		}
		im.SetNextItemWidth(input_width)
		buf_cstr := cstring(raw_data(_hierarchy_rename_buf[:]))
		if im.InputText("##rename", buf_cstr, c.size_t(len(_hierarchy_rename_buf)), {.EnterReturnsTrue, .AutoSelectAll}) {
			_apply_rename(t)
		}
		if _hierarchy_rename_just_opened {
			_hierarchy_rename_just_opened = false
		} else if !im.IsItemActive() {
			if im.IsItemDeactivatedAfterEdit() {
				_apply_rename(t)
			} else {
				_hierarchy_rename_target = _HANDLE_NONE
			}
		}
	} else {
		draw_list := im.GetWindowDrawList()
		text_color := im.GetColorU32ImVec4(im.GetStyleColorVec4(im.Col.Text)^)
		if pushed_dim {
			text_color = im.GetColorU32ImVec4(_hierarchy_dimmed_color)
		}
		label_pos := im.Vec2{text_x, node_rect_min.y + im.GetStyle().FramePadding.y}
		im.DrawList_AddText(draw_list, label_pos, text_color, strings.clone_to_cstring(t.name, context.temp_allocator))
	}

	if im.IsItemClicked(.Left) && !is_renaming {
		_hierarchy_selected = tH
	}

	if !is_root && im.IsItemHovered({}) && im.IsMouseDoubleClicked(.Left) && !is_renaming {
		_begin_rename(tH)
	}

	im.OpenPopupOnItemClick("##NodeContext", im.PopupFlags_MouseButtonRight)
	if !is_root {
		_draw_drag_source(tH)
	}

	if im.BeginPopup("##NodeContext") {
		_hierarchy_selected = tH
		if im.MenuItem("Create Empty Child", nil, false, true) {
			_hierarchy_selected = engine.transform_new("Transform", tH)
			_hierarchy_force_open = tH
		}
		if !is_root {
			if im.MenuItem("Create Empty Parent", nil, false, true) {
				_create_empty_parent(tH, scene)
			}
			if im.MenuItem("Rename", nil, false, true) {
				_begin_rename(tH)
			}
		}
		im.Separator()
		if im.MenuItem("Copy", nil, false, true) {
			clip.copy_hierarchy(engine.scene_copy_subtree(tH))
		}
		if im.MenuItem("Paste", nil, false, clip.has_hierarchy()) {
			result := engine.scene_paste_subtree(clip.paste_hierarchy(), tH)
			engine._transform_append_name_suffix(result, "_copy")
			_hierarchy_force_open = tH
		}
		if im.MenuItem("Duplicate", nil, false, !is_root) {
			result := engine.scene_duplicate_subtree(tH)
			engine._transform_append_name_suffix(result, "_copy")
			_hierarchy_selected = result
		}
		if !is_root {
			im.Separator()
			if im.MenuItem("Delete", nil, false, true) {
				if _hierarchy_selected == tH {
					_hierarchy_selected = _HANDLE_NONE
				}
				if _hierarchy_rename_target == tH {
					_hierarchy_rename_target = _HANDLE_NONE
				}
				im.EndPopup()
				engine.transform_destroy(tH)
				if node_open && has_children {
					im.TreePop()
				}
				if pushed_dim {
					im.PopStyleColor(1)
				}
				im.PopID()
				return
			}
		}
		im.EndPopup()
	}

	if !is_root {
		_draw_drop_target_on_node(tH, scene, node_rect_min, node_rect_max)
	}

	if node_open && has_children {
		children_copy := make([]engine.Ref, len(t.children), context.temp_allocator)
		copy(children_copy, t.children[:])
		for child in children_copy {
			_draw_hierarchy_node(engine.Transform_Handle(child.handle), scene, parent_inactive = inactive)
		}
		im.TreePop()
	}

	if pushed_dim {
		im.PopStyleColor(1)
	}

	im.PopID()
}

@(private)
_begin_rename :: proc(tH: engine.Transform_Handle) {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return

	_hierarchy_rename_target = tH
	_hierarchy_rename_focus = true
	mem.zero(&_hierarchy_rename_buf, len(_hierarchy_rename_buf))
	name_bytes := transmute([]u8)t.name
	copy_len := min(len(name_bytes), len(_hierarchy_rename_buf) - 1)
	mem.copy(&_hierarchy_rename_buf[0], raw_data(name_bytes), copy_len)
}

@(private)
_apply_rename :: proc(t: ^engine.Transform) {
	buf_cstr := cstring(raw_data(_hierarchy_rename_buf[:]))
	new_name := string(buf_cstr)
	if len(new_name) > 0 {
		delete(t.name)
		t.name = strings.clone(new_name)
	}
	_hierarchy_rename_target = _HANDLE_NONE
	_hierarchy_rename_just_finished = true
}

@(private)
_create_empty_parent :: proc(tH: engine.Transform_Handle, scene: ^engine.Scene) {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return

	sibling_idx := engine.transform_get_sibling_index(tH)
	old_parent := engine.Transform_Handle(t.parent.handle)

	new_parent := engine.transform_new("Transform", old_parent)
	engine.transform_set_parent(new_parent, old_parent, sibling_idx)
	engine.transform_set_parent(tH, new_parent)
	_hierarchy_selected = new_parent
	_hierarchy_force_open = new_parent
}

@(private)
_draw_drag_source :: proc(tH: engine.Transform_Handle) {
	if im.BeginDragDropSource({}) {
		payload_data := tH
		im.SetDragDropPayload(HIERARCHY_DRAG_TYPE, &payload_data, size_of(engine.Transform_Handle))
		w := engine.ctx_world()
		t := engine.pool_get(&w.transforms, engine.Handle(tH))
		if t != nil {
			im.Text(strings.clone_to_cstring(t.name, context.temp_allocator))
		}
		im.EndDragDropSource()
	}
}

@(private)
_draw_drop_target_on_node :: proc(tH: engine.Transform_Handle, scene: ^engine.Scene, rect_min: im.Vec2, rect_max: im.Vec2) {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return

	item_height := rect_max.y - rect_min.y
	zone_h := max(4.0, item_height * 0.15)
	item_spacing_y := im.GetStyle().ItemSpacing.y
	half_spacing := item_spacing_y * 0.5
	width := rect_max.x - rect_min.x
	indicator_color := im.GetColorU32ImVec4(im.Vec4{1, 0.8, 0, 1})
	draw_list := im.GetWindowDrawList()

	before_h := zone_h + half_spacing
	im.SetCursorScreenPos(im.Vec2{rect_min.x, rect_min.y - half_spacing})
	id_before := fmt.tprintf("##drop_before_%v_%v", engine.Handle(tH).index, engine.Handle(tH).generation)
	im.InvisibleButton(strings.clone_to_cstring(id_before, context.temp_allocator), im.Vec2{width, before_h})
	root_tH := engine.Transform_Handle(scene.root.handle)

	if im.BeginDragDropTarget() {
		im.DrawList_AddLine(draw_list, im.Vec2{rect_min.x, rect_min.y}, im.Vec2{rect_max.x, rect_min.y}, indicator_color, 3.0)
		payload := im.AcceptDragDropPayload(HIERARCHY_DRAG_TYPE, {.AcceptNoDrawDefaultRect})
		if payload != nil && payload.Data != nil {
			dragged := (^engine.Transform_Handle)(payload.Data)^
			if dragged != tH && dragged != root_tH && !_is_ancestor(dragged, tH) {
				target_parent := engine.Transform_Handle(t.parent.handle)
				if !engine.pool_valid(&w.transforms, engine.Handle(target_parent)) {
					target_parent = root_tH
				}
				target_idx := engine.transform_get_sibling_index(tH)
				dt := engine.pool_get(&w.transforms, engine.Handle(dragged))
				if dt != nil && dt.parent.handle == t.parent.handle {
					dragged_idx := engine.transform_get_sibling_index(dragged)
					if dragged_idx < target_idx {
						target_idx -= 1
					}
				}
				engine.transform_set_parent(dragged, target_parent, target_idx)
			}
		}
		im.EndDragDropTarget()
	}

	im.SetCursorScreenPos(im.Vec2{rect_min.x, rect_min.y + zone_h})
	id_child := fmt.tprintf("##drop_child_%v_%v", engine.Handle(tH).index, engine.Handle(tH).generation)
	im.InvisibleButton(strings.clone_to_cstring(id_child, context.temp_allocator), im.Vec2{width, item_height - 2 * zone_h})
	if im.BeginDragDropTarget() {
		payload := im.AcceptDragDropPayload(HIERARCHY_DRAG_TYPE, {})
		if payload != nil && payload.Data != nil {
			dragged := (^engine.Transform_Handle)(payload.Data)^
			if dragged != tH && dragged != root_tH && !_is_ancestor(dragged, tH) {
				engine.transform_set_parent(dragged, tH)
			}
		}
		im.EndDragDropTarget()
	}

	after_h := zone_h + half_spacing
	im.SetCursorScreenPos(im.Vec2{rect_min.x, rect_max.y - zone_h})
	id_after := fmt.tprintf("##drop_after_%v_%v", engine.Handle(tH).index, engine.Handle(tH).generation)
	im.InvisibleButton(strings.clone_to_cstring(id_after, context.temp_allocator), im.Vec2{width, after_h})
	if im.BeginDragDropTarget() {
		im.DrawList_AddLine(draw_list, im.Vec2{rect_min.x, rect_max.y}, im.Vec2{rect_max.x, rect_max.y}, indicator_color, 3.0)
		payload := im.AcceptDragDropPayload(HIERARCHY_DRAG_TYPE, {.AcceptNoDrawDefaultRect})
		if payload != nil && payload.Data != nil {
			dragged := (^engine.Transform_Handle)(payload.Data)^
			if dragged != tH && dragged != root_tH && !_is_ancestor(dragged, tH) {
				target_parent := engine.Transform_Handle(t.parent.handle)
				if !engine.pool_valid(&w.transforms, engine.Handle(target_parent)) {
					target_parent = root_tH
				}
				target_idx := engine.transform_get_sibling_index(tH) + 1
				dt := engine.pool_get(&w.transforms, engine.Handle(dragged))
				if dt != nil && dt.parent.handle == t.parent.handle {
					dragged_idx := engine.transform_get_sibling_index(dragged)
					if dragged_idx < target_idx {
						target_idx -= 1
					}
				}
				engine.transform_set_parent(dragged, target_parent, target_idx)
			}
		}
		im.EndDragDropTarget()
	}
}

@(private)
_draw_drop_target_empty_space :: proc(scene: ^engine.Scene) {
	avail := im.GetContentRegionAvail()
	if avail.y > 8 {
		im.InvisibleButton("##drop_empty_space", im.Vec2{avail.x, avail.y})
		if im.BeginDragDropTarget() {
			payload := im.AcceptDragDropPayload(HIERARCHY_DRAG_TYPE, {})
			if payload != nil && payload.Data != nil {
				dragged := (^engine.Transform_Handle)(payload.Data)^
				root_tH := engine.Transform_Handle(scene.root.handle)
				if dragged != root_tH {
					engine.transform_set_parent(dragged, root_tH)
				}
			}
			im.EndDragDropTarget()
		}
	}
}

@(private)
_populate_alt_open_pending :: proc(t: ^engine.Transform, open: bool) {
	w := engine.ctx_world()
	for child_ref in t.children {
		ct := engine.pool_get(&w.transforms, child_ref.handle)
		if ct == nil do continue
		child_tH := engine.Transform_Handle(child_ref.handle)
		_hierarchy_alt_open_pending[child_tH] = open
		if len(ct.children) > 0 {
			_populate_alt_open_pending(ct, open)
		}
	}
}

@(private)
_is_ancestor :: proc(potential_ancestor: engine.Transform_Handle, node: engine.Transform_Handle) -> bool {
	w := engine.ctx_world()
	n := engine.pool_get(&w.transforms, engine.Handle(node))
	if n == nil do return false
	current := n.parent
	for engine.pool_valid(&w.transforms, current.handle) {
		if current.handle == engine.Handle(potential_ancestor) do return true
		ct := engine.pool_get(&w.transforms, current.handle)
		current = ct.parent
	}
	return false
}

@(private)
_hierarchy_node_expand :: proc(tH: engine.Transform_Handle, t: ^engine.Transform, deep: bool) {
	_hierarchy_force_open = tH
	if deep {
		_populate_alt_open_pending(t, true)
	}
}

@(private)
_hierarchy_node_collapse :: proc(tH: engine.Transform_Handle, t: ^engine.Transform, deep: bool) {
	_hierarchy_alt_open_pending[tH] = false
	if deep {
		_populate_alt_open_pending(t, false)
	}
}

@(private)
_handle_hierarchy_keyboard_nav :: proc(_: ^engine.SceneManager) {
	w := engine.ctx_world()

	nav_count := len(_hierarchy_nav_list)
	if nav_count == 0 do return

	cur_idx := -1
	if _hierarchy_selected != _HANDLE_NONE {
		for i in 0..<nav_count {
			if _hierarchy_nav_list[i] == _hierarchy_selected {
				cur_idx = i
				break
			}
		}
	}

	_nav_select_first :: proc(nav_count: int) {
		if nav_count > 0 {
			_hierarchy_selected = _hierarchy_nav_list[0]
		}
	}

	if im.IsKeyPressed(im.Key.DownArrow) {
		if cur_idx == -1 {
			_nav_select_first(nav_count)
		} else if cur_idx + 1 < nav_count {
			_hierarchy_selected = _hierarchy_nav_list[cur_idx + 1]
		}
		return
	}

	if im.IsKeyPressed(im.Key.UpArrow) {
		if cur_idx == -1 {
			_nav_select_first(nav_count)
		} else if cur_idx - 1 >= 0 {
			_hierarchy_selected = _hierarchy_nav_list[cur_idx - 1]
		}
		return
	}

	if cur_idx == -1 do return

	selected_tH := _hierarchy_nav_list[cur_idx]
	t := engine.pool_get(&w.transforms, engine.Handle(selected_tH))
	if t == nil do return

	alt := im.GetIO().KeyAlt

	if im.IsKeyPressed(im.Key.RightArrow) {
		has_children := len(t.children) > 0
		if has_children {
			is_expanded := cur_idx + 1 < nav_count && _is_ancestor(selected_tH, _hierarchy_nav_list[cur_idx + 1])
			if !is_expanded {
				_hierarchy_node_expand(selected_tH, t, deep = alt)
				return
			}
		}
		if cur_idx + 1 < nav_count {
			_hierarchy_selected = _hierarchy_nav_list[cur_idx + 1]
		}
		return
	}

	if im.IsKeyPressed(im.Key.LeftArrow) {
		has_children := len(t.children) > 0
		if has_children {
			is_expanded := cur_idx + 1 < nav_count && _is_ancestor(selected_tH, _hierarchy_nav_list[cur_idx + 1])
			if is_expanded {
				_hierarchy_node_collapse(selected_tH, t, deep = alt)
				return
			}
		}
		parent_tH := engine.Transform_Handle(t.parent.handle)
		if engine.pool_valid(&w.transforms, engine.Handle(parent_tH)) {
			_hierarchy_selected = parent_tH
		}
		return
	}
}

hierarchy_get_selected :: proc() -> engine.Transform_Handle {
	w := engine.ctx_world()
	if w == nil do return {}
	if !engine.pool_valid(&w.transforms, engine.Handle(_hierarchy_selected)) do return {}
	return _hierarchy_selected
}
