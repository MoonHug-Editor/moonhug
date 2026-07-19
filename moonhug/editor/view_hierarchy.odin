package editor

import "core:fmt"
import "core:strings"
import "core:mem"
import "core:c"
import "core:path/filepath"
import "core:encoding/uuid"
import "core:time"
import im "../../external/odin-imgui"
import engine "../engine"
import clip "clipboard"
import "menu"
import "undo"

HIERARCHY_DRAG_TYPE :: "HIERARCHY_TRANSFORM"

_HANDLE_NONE :: engine.Transform_Handle{}

@(private)
_paste_subtree_with_undo :: proc(data: []byte, parent: engine.Transform_Handle) -> engine.Transform_Handle {
	tH := engine.scene_paste_subtree(data, parent)
	if tH != {} {
		undo.record_create(tH, parent)
	}
	return tH
}

@(private)
_duplicate_with_undo :: proc(tH: engine.Transform_Handle) -> engine.Transform_Handle {
	result := engine.scene_duplicate_subtree(tH)
	if result != {} {
		w := engine.ctx_world()
		t := engine.pool_get(&w.transforms, engine.Handle(result))
		if t != nil {
			undo.record_create(result, engine.Transform_Handle(t.parent.handle))
		}
	}
	return result
}

// Selection lives in selection.odin (ordered set + active). This view owns
// the interaction: plain click = select only, cmd-click = toggle, shift-click
// = range over the visible rows.

// Shift-click range target — processed AFTER the tree is drawn, because the
// range spans _hierarchy_nav_list which is still being built at click time.
@(private)
_hierarchy_range_pending: engine.Transform_Handle

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

// Name filter (substring, case-insensitive). Non-empty: each scene's tree
// flattens to just the matching rows.
@(private)
_hierarchy_filter_buf: [256]byte

// Scroll the selected row into view next frame (set by ping requests).
@(private)
_hierarchy_scroll_to_sel: bool

// Ping flash (Unity-style): reveal + fading row highlight WITHOUT changing
// the selection.
_HIER_PING_NS :: i64(800_000_000)
@(private)
_hierarchy_ping_tH: engine.Transform_Handle
@(private)
_hierarchy_ping_deadline_ns: i64
@(private)
_hierarchy_scroll_to_ping: bool

// --- Scene edit stack (Unity prefab-mode style) ----------------------------
// Entering a nested scene opens its SOURCE .scene asset (replacing the open
// scene). Each frame records the scene that was open before entering, so `<`
// can reload it. Editor-only state; the engine is unchanged.

Scene_Edit_Frame :: struct {
	path: string,             // owned; cloned on push, freed on pop/clear
	guid: engine.Asset_GUID,
}

// Hierarchy table columns. Today: a stretchy name column and a fixed right-side
// actions column (the ">" enter button). To add Unity-style left toggles later,
// insert a left column at index 0, bump the indices and count, and add a
// matching TableSetupColumn in _draw_scene_section.
_HIER_COL_NAME :: 0
_HIER_COL_ACTIONS_R :: 1
_HIER_COL_COUNT :: 2

@(private)
_edit_stack: [dynamic]Scene_Edit_Frame

// Reset the edit stack (fresh navigation, e.g. opening a scene from the project
// panel). Frees owned paths.
hierarchy_edit_stack_clear :: proc() {
	for &f in _edit_stack do delete(f.path)
	clear(&_edit_stack)
}

// Make a button paint no background (transparent in its resting state), keeping
// only the hover/active tints. Caller must PopStyleColor(3).
@(private)
_push_transparent_button_bg :: proc() {
	transparent := im.Vec4{0, 0, 0, 0}
	hover := im.GetStyleColorVec4(im.Col.ButtonHovered)^
	active := im.GetStyleColorVec4(im.Col.ButtonActive)^
	im.PushStyleColorImVec4(im.Col.Button, transparent)
	im.PushStyleColorImVec4(im.Col.ButtonHovered, hover)
	im.PushStyleColorImVec4(im.Col.ButtonActive, active)
}

@(private)
_edit_stack_guid_present :: proc(guid: engine.Asset_GUID) -> bool {
	if guid == (engine.Asset_GUID{}) do return false
	cur := engine.sm_scene_get_active()
	if cur != nil && cur.asset_guid == guid do return true
	for f in _edit_stack {
		if f.guid == guid do return true
	}
	return false
}

// Enter a nested scene: open its source asset, pushing the current scene so `<`
// can return. Cycle guard: if `source_guid` is already open or on the stack,
// reload it WITHOUT pushing (a prefab can't contain itself; keep finite).
@(private)
_hierarchy_enter_scene :: proc(source_path: string, source_guid: engine.Asset_GUID) {
	push := !_edit_stack_guid_present(source_guid)
	if push {
		cur := engine.sm_scene_get_active()
		if cur != nil && len(cur.path) > 0 {
			frame := Scene_Edit_Frame{ path = strings.clone(cur.path), guid = cur.asset_guid }
			append(&_edit_stack, frame)
		}
	}
	undo.purge_scenes(undo.get())
	sel_scene_clear()
	scene := engine.scene_load_single_path(source_path)
	engine.sm_scene_set_active(scene)
}

// Exit one level: reload the parent scene recorded on the stack top.
@(private)
_hierarchy_exit_scene :: proc() {
	if len(_edit_stack) == 0 do return
	frame := pop(&_edit_stack)
	defer delete(frame.path)
	undo.purge_scenes(undo.get())
	sel_scene_clear()
	scene := engine.scene_load_single_path(frame.path)
	engine.sm_scene_set_active(scene)
}

@(private)
_save_as_buf: [512]byte
@(private)
_save_as_open: bool
@(private)
_save_as_pending: bool

draw_hierarchy_view :: proc() {
	// Drain cross-package selection requests (e.g. inspector "ping" button).
	// Force-open every ancestor so the target is visible after the selection.
	if pending, ok := engine.inspector_take_pending_select(); ok {
		sel_scene_only(pending)
		_hierarchy_scroll_to_sel = true
		_hierarchy_open_ancestors(pending)
	}
	// Ping requests: reveal + flash, selection untouched.
	if pending, ok := engine.inspector_take_pending_ping(); ok {
		_hierarchy_ping_tH = pending
		_hierarchy_ping_deadline_ns = time.now()._nsec + _HIER_PING_NS
		_hierarchy_scroll_to_ping = true
		_hierarchy_open_ancestors(pending)
	}

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

	// Filter row (drawn before the compact style vars so it matches the
	// project view's search box). "x" or Esc clears it.
	filter_query := strings.trim_space(string(cstring(raw_data(_hierarchy_filter_buf[:]))))
	clear_btn_w := im.GetFrameHeight()
	im.SetNextItemWidth(-(clear_btn_w + im.GetStyle().ItemSpacing.x) if filter_query != "" else -1)
	// NoTabStop: keyboard tabbing must never land in the filter box.
	im.PushItemFlag({.NoTabStop}, true)
	im.InputTextWithHint("##hier_filter", "Filter", cstring(raw_data(_hierarchy_filter_buf[:])), c.size_t(len(_hierarchy_filter_buf)), {})
	im.PopItemFlag()
	if filter_query != "" {
		im.SameLine()
		if im.Button(ICON_MD_CLOSE + "###hier_filter_clear", im.Vec2{clear_btn_w, 0}) {
			mem.zero(&_hierarchy_filter_buf, len(_hierarchy_filter_buf))
			filter_query = ""
		}
	}
	filter := strings.to_lower(filter_query, context.temp_allocator)

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
	sel_scene_prune()

	for i in 0..<sm.count {
		scene := sm.loaded[i]
		if scene == nil || !engine.sm_scene_is_valid(scene) do continue
		has_any = true
		_draw_scene_section(scene, is_last = i == last_valid_idx, filter = filter)
	}

	if !has_any {
		im.TextDisabled("No loaded scenes")
	}

	// Shift-click range: active row → clicked row over the visible rows,
	// REPLACING the selection (Unity); the clicked row becomes active. Runs
	// here because _hierarchy_nav_list is only complete after drawing.
	if _hierarchy_range_pending != _HANDLE_NONE {
		target := _hierarchy_range_pending
		_hierarchy_range_pending = _HANDLE_NONE
		anchor := sel_scene_active()
		a_idx, t_idx := -1, -1
		for h, i in _hierarchy_nav_list {
			if h == anchor do a_idx = i
			if h == target do t_idx = i
		}
		if a_idx == -1 || t_idx == -1 {
			sel_scene_only(target)
		} else {
			sel_scene_clear()
			step := 1 if a_idx <= t_idx else -1
			for i := a_idx; ; i += step {
				sel_scene_add(_hierarchy_nav_list[i])
				if i == t_idx do break
			}
		}
	}

	if _hierarchy_rename_just_finished {
		_hierarchy_rename_just_finished = false
	} else {
		is_not_renaming := _hierarchy_rename_target == _HANDLE_NONE
		active_sel := sel_scene_active()
		// Not while a text input (filter box) owns the keyboard.
		if is_not_renaming && im.IsWindowFocused({}) && !im.IsAnyItemActive() {
			if filter != "" && im.IsKeyPressed(im.Key.Escape) {
				mem.zero(&_hierarchy_filter_buf, len(_hierarchy_filter_buf))
			}
			if active_sel != _HANDLE_NONE {
				if im.IsKeyPressed(im.Key.Enter) || im.IsKeyPressed(im.Key.F2) {
					_begin_rename(active_sel)
				}
			}
			_handle_hierarchy_keyboard_nav(sm)
		}
	}
}

@(private)
_draw_scene_section :: proc(scene: ^engine.Scene, is_last := false, filter := "") {
	scene_name := "Untitled"
	if len(scene.path) > 0 {
		scene_name = filepath.stem(scene.path)
	}

	im.PushIDPtr(scene)
	defer im.PopID()

	// "<" up button: when inside an entered nested scene, go back to the parent.
	if len(_edit_stack) > 0 {
		_push_transparent_button_bg()
		if im.Button(ICON_MD_CHEVRON_LEFT, im.Vec2{20, 0}) {
			_hierarchy_exit_scene()
		}
		im.PopStyleColor(3)
		im.SameLine()
	}

	im.Text(strings.clone_to_cstring(scene_name, context.temp_allocator))
	btn_size := im.Vec2{24, 0}
	im.SameLine(im.GetContentRegionAvail().x + im.GetCursorPosX() - btn_size.x)
	if im.Button(ICON_MD_MENU + "###SceneHeaderMenuBtn", btn_size) {
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
			undo.purge_scene(undo.get(), scene)
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

	im.Separator()

	root_tH := engine.Transform_Handle(scene.root.handle)

	// Each scene's tree is laid out in a table so per-row action widgets (the ">"
	// enter button today; visibility/lock toggles later) get their own columns
	// instead of being manually positioned over the row. Column layout is the
	// stretchy name column plus a fixed right-actions column. A left-actions
	// column can be added later (see _HIER_COL_* and the row code in
	// _draw_hierarchy_node) without touching the recursion.
	// Host->NS resolved once per frame from the NS side (deterministic; the
	// per-row reverse scan could cross-match look-alike lids in variant
	// namespaces and flip icons/enter targets with record order).
	host_ns := engine.scene_nested_hosts_map(scene)

	if im.BeginTable("##HierTable", _HIER_COL_COUNT, im.TableFlags_NoBordersInBody) {
		im.TableSetupColumn("##name", {.WidthStretch})
		im.TableSetupColumn("##actions_r", {.WidthFixed}, 24)
		_draw_hierarchy_node(root_tH, scene, host_ns, is_root = true, filter = filter)
		im.EndTable()
	}

	if is_last {
		_draw_drop_target_empty_space(scene)
	}

	// Unity model: the hierarchy's background context menu IS the GameObject
	// menu (Create Empty + registered @(menu_item) items, plugin ones
	// included). Items create under the ACTIVE scene's root.
	if im.BeginPopupContextWindow("##HierarchyContextBg", im.PopupFlags_MouseButtonRight | im.PopupFlags_NoOpenOverItems) {
		menu.draw_menu_subtree("GameObject")
		im.EndPopup()
	}
}

@(menu_item={path="GameObject/Create Empty", order=-100, shortcut=""})
hierarchy_create_empty_menu :: proc() {
	scene := engine.sm_scene_get_active()
	if scene == nil do return
	undo.record_create_child("Transform", engine.Transform_Handle(scene.root.handle))
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
				undo.purge_scene(undo.get(), scene)
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
_draw_hierarchy_node :: proc(tH: engine.Transform_Handle, scene: ^engine.Scene, host_ns: map[engine.Transform_Handle]^engine.NestedScene, is_root := false, parent_inactive := false, parent_nested := false, filter := "") {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return

	sc := scene
	if t.scene != nil {
		sc = t.scene
	}

	is_nested := t.nested_owned || parent_nested
	inactive := parent_inactive || !t.is_active

	// Filtered mode: matching nodes draw as FLAT leaf rows (selection, rename,
	// context menu and the ">" enter button all work as usual); non-matching
	// nodes draw nothing and only recurse to find deeper matches.
	filtered := filter != ""
	if filtered && !strings.contains(strings.to_lower(t.name, context.temp_allocator), filter) {
		children_copy := make([]engine.Ref, len(t.children), context.temp_allocator)
		copy(children_copy, t.children[:])
		for child in children_copy {
			ch, ok := engine.scene_ref_resolve_transform(sc, child, tH)
			if !ok do continue
			_draw_hierarchy_node(ch, sc, host_ns, parent_inactive = inactive, parent_nested = is_nested, filter = filter)
		}
		return
	}

	has_children := len(t.children) > 0 && !filtered
	is_selected := sel_scene_is(tH)
	is_renaming := _hierarchy_rename_target == tH

	pushed_dim := !t.is_active && !parent_inactive

	// SpanAllColumns makes the row's frame (hover highlight + hit box) cover the
	// full table width including the indent and the actions column, so hover
	// highlights the whole row and clicks register anywhere on it. The ">" button
	// still takes its own clicks because it's a later widget in its own column.
	row_ns, is_ns_host := host_ns[tH]
	flags := im.TreeNodeFlags{.OpenOnArrow, .SpanAllColumns}
	// The row frame spans all columns (incl. the actions column), so let the ">"
	// button — a later, overlapping item — take its own clicks. AllowOverlap in
	// this imgui version is non-swallowing hit-testing, safe to keep on host rows.
	if is_ns_host {
		flags += {.AllowOverlap}
	}
	if is_selected {
		flags += {.Selected}
	}
	if is_root && !filtered {
		flags += {.DefaultOpen}
	}
	if !has_children {
		flags += {.Leaf, .NoTreePushOnOpen}
	}

	im.PushIDInt(c.int(engine.Handle(tH).index))

	// This node occupies one table row: the tree node lives in the name column,
	// the ">" button in the right actions column.
	im.TableNextRow()
	im.TableSetColumnIndex(_HIER_COL_NAME)

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
	// Cursor x BEFORE the node is the indented content start within the name
	// column. SpanAllColumns moves the node's ItemRect min to the table's left
	// edge, so we can't derive the label/arrow x from it — capture it here.
	content_x := im.GetCursorScreenPos().x
	node_open := im.TreeNodeEx("##n", flags)

	if is_selected && _hierarchy_scroll_to_sel {
		im.SetScrollHereY()
		_hierarchy_scroll_to_sel = false
	}

	// Capture the ROW's click/hover state now, before drawing the ">" button —
	// IsItemClicked() refers to the last item, which becomes the button below.
	node_clicked := im.IsItemClicked(.Left)
	node_hovered := im.IsItemHovered({})

	append(&_hierarchy_nav_list, tH)

	node_toggled := has_children && im.IsItemToggledOpen()
	if node_toggled {
		if im.GetIO().KeyAlt {
			_populate_alt_open_pending(tH, t, node_open)
		}
	}
	node_rect_min := im.GetItemRectMin()
	node_rect_max := im.GetItemRectMax()

	// In a multi-selection, outline the ACTIVE row — the one the inspector
	// shows and single-target actions (rename, gizmo) operate on.
	if is_selected && sel_scene_count() > 1 && sel_scene_active() == tH {
		im.DrawList_AddRect(im.GetWindowDrawList(), node_rect_min, node_rect_max,
			im.GetColorU32ImVec4(im.Vec4{1, 0.8, 0.2, 0.6}))
	}

	// Ping flash: fading highlight over the whole row (SpanAllColumns rect).
	if tH == _hierarchy_ping_tH {
		remaining := _hierarchy_ping_deadline_ns - time.now()._nsec
		if remaining <= 0 {
			_hierarchy_ping_tH = _HANDLE_NONE
		} else {
			if _hierarchy_scroll_to_ping {
				im.SetScrollHereY()
				_hierarchy_scroll_to_ping = false
			}
			alpha := 0.45 * f32(remaining) / f32(_HIER_PING_NS)
			flash := im.GetColorU32ImVec4(im.Vec4{1.0, 0.8, 0.2, alpha})
			im.DrawList_AddRectFilled(im.GetWindowDrawList(), node_rect_min, node_rect_max, flash)
		}
	}

	text_x := content_x + im.GetTreeNodeToLabelSpacing()
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
		// Every row has an icon slot: stacks for nested-scene hosts (Unity's
		// prefab icon equivalent), the variant glyph when the source asset is a
		// variant (one AssetDB root-info lookup), stat_0 as the plain default.
		row_icon: cstring = ICON_MD_STAT_0
		if is_ns_host && row_ns != nil {
			row_icon = ICON_MD_STACKS
			// Root-variant host: the OPEN SCENE is the variant — its NS points
			// at the BASE, so checking source_prefab would say "not a variant".
			// The row is the variant itself.
			if engine.nested_scene_is_root_variant(sc, row_ns) {
				row_icon = ICON_MD_STACKS_VARIANT
			} else if info, ok := engine.asset_db_get_root_info(row_ns.source_prefab); ok && info.is_variant {
				row_icon = ICON_MD_STACKS_VARIANT
			}
		}
		// Icons draw from the LARGE icon font a couple px above text size —
		// at 13px the variant glyph's star detail rasterizes away and variants
		// become indistinguishable from plain stacks.
		HIER_ICON_SIZE :: f32(FONT_SIZE + 3)
		im.PushFontFloat(editor_icon_font_lg, HIER_ICON_SIZE)
		icon_w := im.CalcTextSize(ICON_MD_STACKS).x
		icon_pos := im.Vec2{label_pos.x, label_pos.y - (HIER_ICON_SIZE - FONT_SIZE) * 0.5}
		im.DrawList_AddText(draw_list, icon_pos, text_color, row_icon)
		im.PopFont()
		name_pos := im.Vec2{label_pos.x + icon_w, label_pos.y}
		// The name column clips its own contents, so the label can't bleed into
		// the actions column — no manual clip rect needed.
		im.DrawList_AddText(draw_list, name_pos, text_color, strings.clone_to_cstring(t.name, context.temp_allocator))

		// ">" enter button on a nested-scene host: opens its source .scene asset.
		// Lives in its own table column, so it never overlaps the name/row.
		if is_ns_host {
			if ns := row_ns; ns != nil && ns.source_prefab != (engine.Asset_GUID{}) {
				if src_path, ok := engine.asset_db_get_path(uuid.Identifier(ns.source_prefab)); ok {
					im.TableSetColumnIndex(_HIER_COL_ACTIONS_R)
					// Right-align the button within its cell, against the edge.
					btn_w := im.CalcTextSize(ICON_MD_CHEVRON_RIGHT).x + im.GetStyle().FramePadding.x * 2
					avail := im.GetContentRegionAvail().x
					if avail > btn_w {
						im.SetCursorPosX(im.GetCursorPosX() + avail - btn_w)
					}
					_push_transparent_button_bg()
					defer im.PopStyleColor(3)
					if im.SmallButton(ICON_MD_CHEVRON_RIGHT) {
						// Enter replaces the open scene; this row's tH is now
						// invalid — bail out of the rest of the node draw, undoing
						// the same stack state the normal exit path would.
						_hierarchy_enter_scene(src_path, ns.source_prefab)
						if node_open && has_children do im.TreePop()
						if pushed_dim do im.PopStyleColor()
						im.PopID()
						return
					}
				}
			}
		}
	}

	// Click handling: a click in the indent/arrow strip (left of the label) is a
	// FOLD action and must never select; a click on the label/body selects.
	// Widening the toggle to the whole strip avoids needing a pixel-perfect hit on
	// the tiny arrow glyph.
	if node_clicked {
		io := im.GetIO()
		in_arrow_zone := has_children && io.MousePos.x < text_x
		if in_arrow_zone {
			// If imgui's own arrow hit-test didn't already toggle, do it ourselves.
			if !node_toggled {
				_hierarchy_alt_open_pending[tH] = !node_open
			}
			// Either way this was a fold, not a selection.
		} else if !is_renaming {
			// cmd/ctrl toggles membership; shift ranges from the active row
			// (deferred — the visible-row list is mid-build); plain replaces.
			if io.KeyCtrl || io.KeySuper {
				sel_scene_toggle(tH)
			} else if io.KeyShift {
				_hierarchy_range_pending = tH
			} else {
				sel_scene_only(tH)
			}
		}
	}

	// Double-click frames the object in the scene view (Unity). Rename moved
	// to the context menu only — it used to live here and blocked framing.
	// Skipped when the interaction toggled the fold (arrow double-clicks).
	if node_hovered && im.IsMouseDoubleClicked(.Left) && !is_renaming && !node_toggled {
		scene_frame_selected()
	}

	im.OpenPopupOnItemClick("##NodeContext", im.PopupFlags_MouseButtonRight)
	if !is_root && !is_nested {
		_draw_drag_source(tH)
	}

	if im.BeginPopup("##NodeContext") {
		// Right-click on an unselected row selects just it; on an already
		// selected row it keeps the multi-selection (Unity) — Duplicate and
		// Delete below then act on the whole selection.
		if !sel_scene_is(tH) do sel_scene_only(tH)
		multi := sel_scene_count() > 1
		if im.MenuItem("Create Empty Child", nil, false, !is_nested) {
			sel_scene_only(undo.record_create_child("Transform", tH))
			_hierarchy_force_open = tH
		}
		if !is_root && !is_nested {
			if im.MenuItem("Create Empty Parent", nil, false, true) {
				_create_empty_parent(tH, sc)
			}
		}
		if im.MenuItem("Rename", nil, false, !is_nested) {
			_begin_rename(tH)
		}
		im.Separator()
		if im.MenuItem("Copy", nil, false, true) {
			clip.copy_hierarchy(engine.scene_copy_subtree(tH))
		}
		if im.MenuItem("Paste", nil, false, clip.has_hierarchy() && !is_nested) {
			result := _paste_subtree_with_undo(clip.paste_hierarchy(), tH)
			engine._transform_append_name_suffix(result, "_copy")
			_hierarchy_force_open = tH
		}
		if im.MenuItem(multi ? "Duplicate Selected" : "Duplicate", nil, false, !is_root && !is_nested) {
			_duplicate_selected()
		}
		if !is_root && !is_nested {
			im.Separator()
			if im.MenuItem(multi ? "Delete Selected" : "Delete", nil, false, true) {
				if _hierarchy_rename_target != _HANDLE_NONE && sel_scene_is(_hierarchy_rename_target) {
					_hierarchy_rename_target = _HANDLE_NONE
				}
				im.EndPopup()
				_delete_selected()
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

	// No drop targets while filtered: rows are a flat excerpt, so the
	// before/after reorder zones would be meaningless.
	if !is_root && !is_nested && !filtered {
		_draw_drop_target_on_node(tH, sc, node_rect_min, node_rect_max)
	}

	if node_open && has_children {
		children_copy := make([]engine.Ref, len(t.children), context.temp_allocator)
		copy(children_copy, t.children[:])
		child_parent_nested := is_nested || t.nested_owned
		for child in children_copy {
			ch, ok := engine.scene_ref_resolve_transform(sc, child, tH)
			if !ok do continue
			_draw_hierarchy_node(ch, sc, host_ns, parent_inactive = inactive, parent_nested = child_parent_nested)
		}
		im.TreePop()
	} else if filtered && len(t.children) > 0 {
		// Matched row in filtered mode: children were not drawn under it
		// (forced leaf) — keep recursing for further matches at the same depth.
		children_copy := make([]engine.Ref, len(t.children), context.temp_allocator)
		copy(children_copy, t.children[:])
		child_parent_nested := is_nested || t.nested_owned
		for child in children_copy {
			ch, ok := engine.scene_ref_resolve_transform(sc, child, tH)
			if !ok do continue
			_draw_hierarchy_node(ch, sc, host_ns, parent_inactive = inactive, parent_nested = child_parent_nested, filter = filter)
		}
	}

	if pushed_dim {
		im.PopStyleColor(1)
	}

	im.PopID()
}

// Handle-based equivalents of the row draw's is_root / is_nested guards, for
// selection members that aren't the clicked row.
@(private)
_hierarchy_handle_is_root :: proc(tH: engine.Transform_Handle) -> bool {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return false
	return !engine.pool_valid(&w.transforms, t.parent.handle)
}

@(private)
_hierarchy_handle_is_nested :: proc(tH: engine.Transform_Handle) -> bool {
	w := engine.ctx_world()
	cur := tH
	for engine.pool_valid(&w.transforms, engine.Handle(cur)) {
		t := engine.pool_get(&w.transforms, engine.Handle(cur))
		if t == nil do break
		if t.nested_owned do return true
		cur = engine.Transform_Handle(t.parent.handle)
	}
	return false
}

// Delete every deletable selected object (not a scene root, not inside a
// nested-scene instance) as ONE undo step. Children of selected ancestors
// are skipped — deleting the ancestor removes them anyway.
@(private)
_delete_selected :: proc() {
	targets := sel_scene_top_level()
	w := engine.ctx_world()
	g := undo.group_begin("Delete Selected")
	defer undo.group_end(&g)
	undo.record_selection_snapshot()
	deleted := 0
	for h in targets {
		if !engine.pool_valid(&w.transforms, engine.Handle(h)) do continue
		if _hierarchy_handle_is_root(h) || _hierarchy_handle_is_nested(h) do continue
		undo.record_delete(h)
		deleted += 1
	}
	if deleted > 0 do undo.group_commit(&g)
	sel_scene_clear()
}

// Duplicate every duplicable selected object as ONE undo step; the copies
// become the new selection.
@(private)
_duplicate_selected :: proc() {
	targets := sel_scene_top_level()
	w := engine.ctx_world()
	g := undo.group_begin("Duplicate Selected")
	defer undo.group_end(&g)
	undo.record_selection_snapshot()
	results := make([dynamic]engine.Transform_Handle, context.temp_allocator)
	for h in targets {
		if !engine.pool_valid(&w.transforms, engine.Handle(h)) do continue
		if _hierarchy_handle_is_root(h) || _hierarchy_handle_is_nested(h) do continue
		result := _duplicate_with_undo(h)
		if result == {} do continue
		engine._transform_append_name_suffix(result, "_copy")
		append(&results, result)
	}
	if len(results) > 0 do undo.group_commit(&g)
	sel_scene_clear()
	for r in results do sel_scene_add(r)
}

@(private)
_hierarchy_open_ancestors :: proc(tH: engine.Transform_Handle) {
	w := engine.ctx_world()
	cur := tH
	for engine.pool_valid(&w.transforms, engine.Handle(cur)) {
		t := engine.pool_get(&w.transforms, engine.Handle(cur))
		if t == nil do break
		if !engine.pool_valid(&w.transforms, t.parent.handle) do break
		cur = engine.Transform_Handle(t.parent.handle)
		_hierarchy_alt_open_pending[cur] = true
	}
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
	if len(new_name) > 0 && new_name != t.name {
		w := engine.ctx_world()
		tH: engine.Transform_Handle
		for i in 0 ..< len(w.transforms.slots) {
			slot := &w.transforms.slots[i]
			if slot.alive && &slot.data == t {
				tH = engine.Transform_Handle(engine.Handle{index = u32(i), generation = slot.generation, type_key = .Transform})
				break
			}
		}

		e := undo.edit_begin(tH, &t.name, typeid_of(string))
		defer undo.edit_end(&e)
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

	g := undo.group_begin("Create Empty Parent")
	defer undo.group_end(&g)

	new_parent := undo.record_create_child("Transform", old_parent)
	if new_parent == {} do return
	undo.record_reparent_to(new_parent, old_parent, sibling_idx)
	undo.record_reparent_to(tH, new_parent)
	undo.group_commit(&g)

	sel_scene_only(new_parent)
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
				undo.record_reparent_to(dragged, target_parent, target_idx)
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
				undo.record_reparent_to(dragged, tH)
			}
		}
		asset_payload := im.AcceptDragDropPayload("ASSET_PATH", {})
		if asset_payload != nil && asset_payload.Data != nil {
			path := string(([^]byte)(asset_payload.Data)[:asset_payload.DataSize])
			_hierarchy_drop_asset_as_child(path, tH)
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
				undo.record_reparent_to(dragged, target_parent, target_idx)
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
					undo.record_reparent_to(dragged, root_tH)
				}
			}
			asset_payload := im.AcceptDragDropPayload("ASSET_PATH", {})
			if asset_payload != nil && asset_payload.Data != nil {
				path := string(([^]byte)(asset_payload.Data)[:asset_payload.DataSize])
				root_tH := engine.Transform_Handle(scene.root.handle)
				_hierarchy_drop_asset_as_child(path, root_tH)
			}
			im.EndDragDropTarget()
		}
	}
}

@(private)
_hierarchy_drop_asset_as_child :: proc(path: string, parent_tH: engine.Transform_Handle) {
	if !strings.has_suffix(path, ".scene") do return
	guid, ok := engine.asset_db_get_guid(path)
	if !ok do return

	new_tH := engine.scene_instantiate_guid_nested(engine.Asset_GUID(guid), parent_tH)
	if new_tH == {} do return

	undo.record_create(new_tH, parent_tH)
	sel_scene_only(new_tH)
	_hierarchy_force_open = parent_tH
}

@(private)
_populate_alt_open_pending :: proc(parent_tH: engine.Transform_Handle, t: ^engine.Transform, open: bool) {
	w := engine.ctx_world()
	s := t.scene
	if s == nil do return
	for child_ref in t.children {
		ch, ok := engine.scene_ref_resolve_transform(s, child_ref, parent_tH)
		if !ok do continue
		ct := engine.pool_get(&w.transforms, engine.Handle(ch))
		if ct == nil do continue
		_hierarchy_alt_open_pending[ch] = open
		if len(ct.children) > 0 {
			_populate_alt_open_pending(ch, ct, open)
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
		_populate_alt_open_pending(tH, t, true)
	}
}

@(private)
_hierarchy_node_collapse :: proc(tH: engine.Transform_Handle, t: ^engine.Transform, deep: bool) {
	_hierarchy_alt_open_pending[tH] = false
	if deep {
		_populate_alt_open_pending(tH, t, false)
	}
}

@(private)
_handle_hierarchy_keyboard_nav :: proc(_: ^engine.SceneManager) {
	w := engine.ctx_world()

	nav_count := len(_hierarchy_nav_list)
	if nav_count == 0 do return

	active := sel_scene_active()
	cur_idx := -1
	if active != _HANDLE_NONE {
		for i in 0..<nav_count {
			if _hierarchy_nav_list[i] == active {
				cur_idx = i
				break
			}
		}
	}

	_nav_select_first :: proc(nav_count: int) {
		if nav_count > 0 {
			sel_scene_only(_hierarchy_nav_list[0])
		}
	}

	// Plain arrows move the (single) selection; shift+arrows EXTEND it — the
	// stepped-onto row joins the selection and becomes active.
	shift := im.GetIO().KeyShift

	if im.IsKeyPressed(im.Key.DownArrow) {
		if cur_idx == -1 {
			_nav_select_first(nav_count)
		} else if cur_idx + 1 < nav_count {
			next := _hierarchy_nav_list[cur_idx + 1]
			if shift {
				sel_scene_add(next)
			} else {
				sel_scene_only(next)
			}
		}
		return
	}

	if im.IsKeyPressed(im.Key.UpArrow) {
		if cur_idx == -1 {
			_nav_select_first(nav_count)
		} else if cur_idx - 1 >= 0 {
			prev := _hierarchy_nav_list[cur_idx - 1]
			if shift {
				sel_scene_add(prev)
			} else {
				sel_scene_only(prev)
			}
		}
		return
	}

	// F frames the selection in the scene view (Unity), from here too so the
	// hierarchy doesn't need a mouse trip to the scene panel.
	if im.IsKeyPressed(im.Key.F) {
		scene_frame_selected()
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
			sel_scene_only(_hierarchy_nav_list[cur_idx + 1])
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
			sel_scene_only(parent_tH)
		}
		return
	}
}

// The ACTIVE selected object (inspector target, gizmo target). With a
// multi-selection this is the most recently selected item.
hierarchy_get_selected :: proc() -> engine.Transform_Handle {
	return sel_scene_active()
}

@(menu_item={path="Edit/Toggle Transform Active", order=0, shortcut="Alt+Shift+A"})
hierarchy_toggle_active_menu :: proc() {
	w := engine.ctx_world()
	if w == nil do return
	sel_scene_prune()
	targets := sel_scene_items()
	if len(targets) == 0 do return
	g := undo.group_begin("Toggle Active")
	defer undo.group_end(&g)
	toggled := 0
	for tH in targets {
		t := engine.pool_get(&w.transforms, engine.Handle(tH))
		if t == nil do continue
		e := undo.edit_begin(tH, &t.is_active, typeid_of(bool), "Toggle Active")
		defer undo.edit_end(&e)
		t.is_active = !t.is_active
		toggled += 1
	}
	if toggled > 0 do undo.group_commit(&g)
}

shutdown_hierarchy_views :: proc() {
	delete(_hierarchy_nav_list)
	delete(_hierarchy_alt_open_pending)
	delete(_inspector_comp_open)
	selection_shutdown()
}
