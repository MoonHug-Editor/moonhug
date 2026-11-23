package scene_windows

import "moonhug:editor/session"
import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:mem"
import "core:c"
import "core:time"
import im "moonhug:external/odin-imgui"
import engine "moonhug:packages/engine"
import core "moonhug:libs/core"
import "moonhug:editor/menu"
import undo "moonhug:packages/engine/editor/undo"
import "moonhug:editor/drag"
import "moonhug:editor/simulate"
import "moonhug:editor/widgets"
import "moonhug:editor/icons"
import wnd "moonhug:editor/window"
import "moonhug:editor/keymap"

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
_duplicate_with_undo :: proc(tH: engine.Transform_Handle, suffix := "") -> engine.Transform_Handle {
	result := engine.scene_duplicate_subtree(tH)
	if result != {} {
		// Named before the create is recorded, so a redo brings the name back.
		if suffix != "" do engine._transform_append_name_suffix(result, suffix)
		w := engine.ctx_world()
		t := engine.pool_get(&w.transforms, engine.Handle(result))
		if t != nil {
			undo.record_create(result, engine.Transform_Handle(t.parent.handle))
		}
	}
	return result
}

// Selection lives in the shell (editor/selection.odin: ordered set + active),
// reached through session.Selection_Source. This window owns
// the interaction: plain click = select only, cmd-click = toggle, shift-click
// = range over the visible rows.

// One Hierarchy copy's own state. A request every copy follows (a reveal, a
// ping, scrolling to the selection) goes to all of them (_hierarchy_windows).
Hierarchy_Window :: struct {
	// The rows shown, built each frame (hierarchy_rows.odin).
	rows:                 [dynamic]Hier_Row,
	// The rows the copy has seen, and whether each shows its children.
	open:                 map[engine.Transform_Handle]bool,
	// The scenes whose header is folded.
	scenes_closed:        map[^engine.Scene]bool,
	// A press on a row of a multi-selection: it becomes the only selected
	// row when the button goes up with nothing dragged.
	click_pending:        engine.Transform_Handle,
	// A right click asked for the row menu.
	ctx_open:             bool,
	// The folded row a drag hovers, and since when: it opens after a moment.
	drag_hover:           engine.Transform_Handle,
	drag_hover_since:     f64,
	rename_target:        engine.Transform_Handle,
	rename_buf:           [256]byte,
	rename_focus:         bool,
	rename_just_opened:   bool,
	rename_just_finished: bool,
	// Bring the renamed row into view.
	rename_scroll:        bool,
	// Name filter (substring, case-insensitive). Non-empty: the rows are the
	// matching objects as a flat list.
	filter_buf:           [256]byte,
	// Scroll the selected row into view next frame (set by ping requests).
	scroll_to_sel:        bool,
	// The same after a key moved the selection, and only when the row is out
	// of view.
	keys_scroll:          bool,
	// Ping flash: reveal + fading row highlight WITHOUT changing the selection.
	ping_tH:              engine.Transform_Handle,
	ping_deadline_ns:     i64,
	scroll_to_ping:       bool,
}


_HIER_PING_NS :: i64(800_000_000)

// The copy being drawn, and outside a draw the copy clicked in last, which
// menu actions and the shell's queries act on. With no copy open it points
// at a spare state, so a write lands nowhere.
@(private)
_hv: ^Hierarchy_Window = &_hv_none

@(private = "file")
_hv_none: Hierarchy_Window

@(private)
_hierarchy_dimmed_color: im.Vec4

// A copy's state, made on its first frame. On the default allocator: it
// outlives frames.
@(private = "file")
_hierarchy_window :: proc(w: ^wnd.Window) -> ^Hierarchy_Window {
	if w.data == nil {
		hv := new(Hierarchy_Window, runtime.default_allocator())
		_hierarchy_state_make(hv)
		w.data = hv
	}
	return (^Hierarchy_Window)(w.data)
}

// Every open copy's state, for a request they all follow.
@(private)
_hierarchy_windows :: proc() -> []^Hierarchy_Window {
	out := make([dynamic]^Hierarchy_Window, context.temp_allocator)
	for w in wnd.instances(HIERARCHY) do append(&out, _hierarchy_window(w))
	return out[:]
}

// Unfolds `tH` in every copy, to show a child just made or pasted under it.
@(private)
_hierarchy_reveal_open :: proc(tH: engine.Transform_Handle) {
	for hv in _hierarchy_windows() do _hierarchy_set_open(hv, tH, true)
}

hierarchy_window_closed :: proc(w: ^wnd.Window) {
	hv := (^Hierarchy_Window)(w.data)
	if hv == nil do return
	if _hv == hv do _hv = &_hv_none
	_hierarchy_window_free(hv)
	free(hv, runtime.default_allocator())
	w.data = nil
}

@(private = "file")
_hierarchy_window_free :: proc(hv: ^Hierarchy_Window) {
	context.allocator = runtime.default_allocator()
	delete(hv.rows)
	delete(hv.open)
	delete(hv.scenes_closed)
	hv^ = {}
}


// --- Scene edit stack (Unity prefab-mode style) ----------------------------
// Entering a nested scene opens its SOURCE .scene asset (replacing the open
// scene). Each frame records the scene that was open before entering, so `<`
// can reload it. Editor-only state; the engine is unchanged.

Scene_Edit_Frame :: struct {
	path: string,             // owned; cloned on push, freed on pop/clear
	guid: engine.Asset_GUID,
}

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
	session.select_clear()
	scene := engine.scene_load(source_path)
	engine.sm_scene_set_active(scene)
}

// Exit one level: reload the parent scene recorded on the stack top.
@(private)
_hierarchy_exit_scene :: proc() {
	if len(_edit_stack) == 0 do return
	frame := pop(&_edit_stack)
	defer delete(frame.path)
	undo.purge_scenes(undo.get())
	session.select_clear()
	scene := engine.scene_load(frame.path)
	engine.sm_scene_set_active(scene)
}

// Discard: reload one scene from its file, dropping every unsaved edit. Enter
// and Exit above replace the whole set of loaded scenes; this replaces ONE in
// place, so its slot, its active status and every other loaded scene stay as
// they are.
//
// Undo records go first: they address objects the reload destroys, so an undo
// step replayed afterwards would work on dead handles. The selection is dropped
// for the same reason.
//
// The Scene POINTER does not survive — callers must not touch `scene` after
// this returns.
@(private)
_hierarchy_discard_scene :: proc(scene: ^engine.Scene) {
	if scene == nil || len(scene.path) == 0 do return
	path := strings.clone(scene.path, context.temp_allocator)
	undo.purge_scene(undo.get(), scene)
	session.select_clear()
	if engine.scene_reload_in_place_path(scene, path) == nil {
		fmt.printf("[Editor] Discard: %s did not reload — the scene is gone from the hierarchy\n", path)
	}
}

@(private)
_save_as_buf: [512]byte
@(private)
_save_as_open: bool
@(private)
_save_as_pending: bool

// Drains a cross-package selection request (a package menu that created an
// object, the inspector's select button). Force-opens every ancestor so the
// target is visible after the selection. The Hierarchy window and the
// selection tracker both call it, whichever runs first in the frame.
hierarchy_apply_pending_select :: proc() {
	if pending, ok := engine.inspector_take_pending_select(); ok {
		session.select_only(pending)
		hierarchy_scroll_to_selection()
		_hierarchy_open_ancestors(pending)
	}
}

// Scrolls every copy to the selection next frame.
hierarchy_scroll_to_selection :: proc() {
	for hv in _hierarchy_windows() do hv.scroll_to_sel = true
}

// The requests every copy follows, once per frame whether or not a copy is
// visible: a select posted from elsewhere, and a ping (reveal + flash,
// selection untouched).
hierarchy_frame_begin :: proc() {
	hierarchy_apply_pending_select()
	if pending, ok := engine.inspector_take_pending_ping(); ok {
		deadline := time.now()._nsec + _HIER_PING_NS
		for hv in _hierarchy_windows() {
			hv.ping_tH = pending
			hv.ping_deadline_ns = deadline
			hv.scroll_to_ping = true
		}
		_hierarchy_open_ancestors(pending)
	}
}

HIERARCHY :: "Hierarchy"

@(editor_window={id="Hierarchy", title="Hierarchy", icon="ACCOUNT_TREE", closed=hierarchy_window_closed})
hierarchy_window_draw :: proc(w: ^wnd.Window) {
	_hv = _hierarchy_window(w)
	defer {
		last := wnd.last(HIERARCHY)
		_hv = _hierarchy_window(last) if last != nil else &_hv_none
	}

	// The window's background: no parent, beside the loaded scenes.
	if im.BeginDragDropTarget() {
		drag.target(drag.Hierarchy_Place{index = -1})
		im.EndDragDropTarget()
	}

	// The toolbar: "+" creates an object under the active scene's root, then
	// the filter. "x" or Esc clears it. A word is part of a name, or "c:" and
	// part of a component type (scene_object_has_components).
	button_w := im.GetFrameHeight()
	if im.Button(icons.ICON_MD_ADD + "###hier_create", im.Vec2{button_w, 0}) do im.OpenPopup("##HierarchyCreate")
	widgets.tooltip("Create an object")
	if im.BeginPopup("##HierarchyCreate") {
		menu.draw_menu_sections({menu.section("GameObject", max_order = menu.GO_SECTION_PARENTING - 1)})
		im.EndPopup()
	}
	im.SameLine()
	filter_query := strings.trim_space(string(cstring(raw_data(_hv.filter_buf[:]))))
	im.SetNextItemWidth(-(button_w + im.GetStyle().ItemSpacing.x) if filter_query != "" else -1)
	// NoTabStop: keyboard tabbing must never land in the filter box.
	im.PushItemFlag({.NoTabStop}, true)
	im.InputTextWithHint("##hier_filter", "Filter: name, c:Component", cstring(raw_data(_hv.filter_buf[:])), c.size_t(len(_hv.filter_buf)), {})
	im.PopItemFlag()
	if filter_query != "" {
		im.SameLine()
		if im.Button(icons.ICON_MD_CLOSE + "###hier_filter_clear", im.Vec2{button_w, 0}) {
			mem.zero(&_hv.filter_buf, len(_hv.filter_buf))
			filter_query = ""
		}
	}
	filter := widgets.search_terms(filter_query)

	session.prune()
	_hierarchy_rows_build(_hv, filter)

	// A filtered list has no tree, so the selected object's place is told
	// under it.
	footer := ""
	if len(filter) > 0 {
		if path, ok := _hierarchy_object_path(session.active()); ok do footer = path
	}
	footer_h := im.GetFrameHeightWithSpacing() if footer != "" else 0
	_hierarchy_rows_draw(_hv, len(filter) > 0, footer_h)
	if footer != "" {
		im.Separator()
		im.TextDisabled("%s", strings.clone_to_cstring(footer, context.temp_allocator))
	}

	// The keys are the "Hierarchy" keymap's commands (the end of this file).
	// The frame a rename closes, its Enter press is still down: the keymap is
	// off that frame (hierarchy_keys_active), and the flag clears here.
	if _hv.rename_just_finished do _hv.rename_just_finished = false
}

// The names from the scene's root down to the object, "Root/Parent/Object".
@(private = "file")
_hierarchy_object_path :: proc(tH: engine.Transform_Handle) -> (string, bool) {
	w := engine.ctx_world()
	names := make([dynamic]string, context.temp_allocator)
	cur := tH
	for engine.pool_valid(&w.transforms, engine.Handle(cur)) {
		t := engine.pool_get(&w.transforms, engine.Handle(cur))
		if t == nil do break
		inject_at(&names, 0, t.name)
		cur = engine.Transform_Handle(t.parent.handle)
	}
	if len(names) == 0 do return "", false
	return strings.join(names[:], "/", context.temp_allocator), true
}

@(private)
_scene_is_simulating :: proc(scene: ^engine.Scene) -> bool {
	return scene.session_id == simulate.scene().id
}

// Unloads a scene, with the undo steps that address it and the fold state
// the copies keep for it.
@(private)
_hierarchy_unload_scene :: proc(scene: ^engine.Scene) {
	for hv in _hierarchy_windows() do delete_key(&hv.scenes_closed, scene)
	undo.purge_scene(undo.get(), scene)
	engine.sm_scene_unload(scene)
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

// The glyph before an object's name, in the Hierarchy and the command
// palette: a cube for a plain object, stacks for one that hosts a nested
// scene, the variant glyph when that scene is a variant (one AssetDB root-info
// lookup). `sc` is the scene the object is in, `ns` the nested scene it hosts
// (engine.scene_nested_hosts_map), nil for none.
@(private)
hierarchy_row_icon :: proc(sc: ^engine.Scene, tH: engine.Transform_Handle, ns: ^engine.NestedScene) -> cstring {
	if ns == nil do return icons.ICON_MD_DEPLOYED_CODE
	// Root-variant host: the open scene is the variant. Its nested scene
	// points at the base, so source_prefab would say "not a variant": the
	// row is the variant itself.
	if engine.nested_scene_is_root_variant(sc, ns) do return icons.ICON_MD_STACKS_VARIANT
	if info, ok := engine.asset_db_get_root_info(ns.source_prefab); ok && info.is_variant do return icons.ICON_MD_STACKS_VARIANT
	return icons.ICON_MD_STACKS
}

// Whether the object has the components a query's tagged words name. The
// Hierarchy's filter and the command palette's Scene Objects mode both ask
// here, so a word means the same in both:
//   - "c:sprite" is a component whose type name has "sprite" in it: Sprite,
//     SpriteRenderer
//   - "c:sprite$" is the whole type name: Sprite only. The "$" marks the end
//     of the name
// A tag an object does not have ("t:") matches no object. The Project
// window's search has the same "c:" for a scene file's root object.
scene_object_has_components :: proc(t: ^engine.Transform, tagged: []string) -> bool {
	for term in tagged {
		type, exact, by_component := widgets.search_tag(term, "c:")
		if !by_component do return false
		has := false
		for c in t.components {
			tid := engine.get_typeid_by_type_key(c.handle.type_key)
			if tid == nil do continue
			named, is_named := type_info_of(tid).variant.(runtime.Type_Info_Named)
			if is_named && widgets.search_tag_match(named.name, type, exact) {
				has = true
				break
			}
		}
		if !has do return false
	}
	return true
}

// The rows of each scene left open in the Hierarchy, by the scene's guid: a
// row is its object's local id, stable in the scene's file. Kept per
// developer while the scene exists (core.Per_Asset). A scene never saved has
// no guid and keeps nothing.
@(user_settings={name="Hierarchy Folds"})
hierarchy_folds: core.Per_Asset([dynamic]engine.Local_ID)

@(private)
_fold_is_open :: proc(folds: ^[dynamic]engine.Local_ID, lid: engine.Local_ID) -> bool {
	for f in folds do if f == lid do return true
	return false
}

// Keeps the open state of the row of `lid` in its scene's entry.
@(private)
_fold_record :: proc(scene_guid: engine.Asset_GUID, lid: engine.Local_ID, open: bool) {
	if scene_guid == {} do return
	folds := core.per_asset_get(&hierarchy_folds, scene_guid)
	if folds == nil {
		if !open do return
		folds = core.per_asset_entry(&hierarchy_folds, scene_guid)
	}
	if open == _fold_is_open(folds, lid) do return
	context.allocator = runtime.default_allocator()
	if open {
		append(folds, lid)
	} else {
		for f, i in folds do if f == lid {
			unordered_remove(folds, i)
			break
		}
	}
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
	targets := session.top_level()
	w := engine.ctx_world()
	g := undo.group_begin("Delete Selected")
	defer undo.group_end(&g)
	undo.record_selection_snapshot()
	deleted := 0
	for h in targets {
		if !engine.pool_valid(&w.transforms, engine.Handle(h)) do continue
		if _hierarchy_handle_is_root(h) do continue
		// Deleting PREFAB content is a structural override: the subtree is
		// destroyed AND recorded as removed, so the next resolve (which
		// rebuilds the instance from its prefab) doesn't bring it back. Both
		// steps ride this group's single undo entry.
		nested_host, obj_lid, scene, is_prefab_content := _nested_removal_target(h)
		undo.record_delete(h)
		if is_prefab_content {
			if _, ok := engine.nested_scene_record_object_removed(scene, nested_host, obj_lid); ok {
				undo.record_object_removed_on_instance(scene, nested_host, obj_lid)
			}
		}
		deleted += 1
	}
	if deleted > 0 do undo.group_commit(&g)
	session.select_clear()
}

// The NS bookkeeping a delete of `tH` needs, when `tH` is prefab content of a
// nested instance. Returns is_prefab_content=false for ordinary host objects
// (nothing to record) and for host ADDITIONS living under prefab content —
// those are retracted by the record proc itself, which needs the same host.
@(private)
_nested_removal_target :: proc(tH: engine.Transform_Handle) -> (host: engine.Transform_Handle, obj_lid: engine.Local_ID, scene: ^engine.Scene, ok: bool) {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return {}, 0, nil, false
	// Prefab content, or a host object grafted under prefab content.
	parent_nested := false
	if pt := engine.pool_get(&w.transforms, t.parent.handle); pt != nil {
		parent_nested = pt.nested_owned || engine.scene_find_nested_scene_for_host(pt.scene, engine.Transform_Handle(t.parent.handle)) != nil
	}
	if !t.nested_owned && !parent_nested do return {}, 0, nil, false
	h := engine.transform_immediate_nested_host(tH)
	if h == {} do return {}, 0, nil, false
	return h, t.local_id, t.scene, true
}

// Duplicate every duplicable selected object as ONE undo step; the copies
// become the new selection.
@(private)
_duplicate_selected :: proc() {
	targets := session.top_level()
	w := engine.ctx_world()
	g := undo.group_begin("Duplicate Selected")
	defer undo.group_end(&g)
	undo.record_selection_snapshot()
	results := make([dynamic]engine.Transform_Handle, context.temp_allocator)
	for h in targets {
		if !engine.pool_valid(&w.transforms, engine.Handle(h)) do continue
		if _hierarchy_handle_is_root(h) || _hierarchy_handle_is_nested(h) do continue
		result := _duplicate_with_undo(h, "_copy")
		if result == {} do continue
		append(&results, result)
	}
	if len(results) > 0 do undo.group_commit(&g)
	session.select_clear()
	for r in results do session.select_add(r)
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
		for hv in _hierarchy_windows() {
			_hierarchy_set_open(hv, cur, true)
			if t.scene != nil do delete_key(&hv.scenes_closed, t.scene)
		}
	}
}

@(private)
_begin_rename :: proc(tH: engine.Transform_Handle) {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return

	_hv.rename_target = tH
	_hv.rename_focus = true
	_hv.rename_scroll = true
	mem.zero(&_hv.rename_buf, len(_hv.rename_buf))
	name_bytes := transmute([]u8)t.name
	copy_len := min(len(name_bytes), len(_hv.rename_buf) - 1)
	mem.copy(&_hv.rename_buf[0], raw_data(name_bytes), copy_len)
}

@(private)
_apply_rename :: proc(tH: engine.Transform_Handle, t: ^engine.Transform) {
	new_name := string(cstring(raw_data(_hv.rename_buf[:])))
	if len(new_name) > 0 && new_name != t.name {
		e := undo.edit_begin(tH, &t.name, typeid_of(string), "Rename")
		defer undo.edit_end(&e)
		delete(t.name)
		t.name = strings.clone(new_name)
	}
	_hv.rename_target = _HANDLE_NONE
	_hv.rename_just_finished = true
}

@(private)
_create_empty_parent :: proc(tH: engine.Transform_Handle) {
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

	session.select_only(new_parent)
	_hierarchy_reveal_open(new_parent)
}

// Whether `node` is under `potential_ancestor`.
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

// --- Commands and keymap -------------------------------------------------------
//
// The keymap resolver runs these before the windows draw (editor/keymap). They
// act on _hv, which is the last clicked instance outside a draw. The rows are
// the ones the last draw built.

// Select moves the (single) selection, Extend Selection grows it: the
// stepped-onto row joins the selection and becomes active. A scene's header
// is stepped over.
@(private = "file")
_hierarchy_nav_step :: proc(step: int, extend: bool) {
	cur := _hierarchy_row_index(_hv, session.active())
	next := cur + step
	if cur == -1 do next = 0
	for next >= 0 && next < len(_hv.rows) && _hv.rows[next].kind != .Object do next += step if cur != -1 else 1
	if next < 0 || next >= len(_hv.rows) do return
	if extend && cur != -1 {
		session.select_add(_hv.rows[next].tH)
	} else {
		session.select_only(_hv.rows[next].tH)
	}
	_hv.keys_scroll = true
}

@(command={name="Hierarchy/Select Down", palette=false, help="Selects the next row"})
hierarchy_select_down :: proc() { _hierarchy_nav_step(1, false) }

@(command={name="Hierarchy/Select Up", palette=false, help="Selects the previous row"})
hierarchy_select_up :: proc() { _hierarchy_nav_step(-1, false) }

@(command={name="Hierarchy/Extend Selection Down", palette=false, help="Adds the next row to the selection"})
hierarchy_extend_down :: proc() { _hierarchy_nav_step(1, true) }

@(command={name="Hierarchy/Extend Selection Up", palette=false, help="Adds the previous row to the selection"})
hierarchy_extend_up :: proc() { _hierarchy_nav_step(-1, true) }

// Expand opens a closed row, Expand Subtree its whole subtree, and both step
// into an open one.
@(command={name="Hierarchy/Expand", palette=false, help="Opens the selected object's children, or steps into them"})
hierarchy_expand :: proc() { _hierarchy_expand(false) }

@(command={name="Hierarchy/Expand Subtree", palette=false, help="Opens every descendant of the selected object"})
hierarchy_expand_subtree :: proc() { _hierarchy_expand(true) }

@(private = "file")
_hierarchy_expand :: proc(deep: bool) {
	cur := _hierarchy_row_index(_hv, session.active())
	if cur == -1 do return
	row := _hv.rows[cur]
	if row.has_children && !row.open {
		_hierarchy_set_open(_hv, row.tH, true)
		if deep do _hierarchy_set_open_deep(_hv, row.tH, true)
		return
	}
	if deep && row.has_children do _hierarchy_set_open_deep(_hv, row.tH, true)
	if row.open && cur + 1 < len(_hv.rows) && _hv.rows[cur + 1].kind == .Object do session.select_only(_hv.rows[cur + 1].tH)
}

// Collapse closes an open row, Collapse Subtree its whole subtree, and both
// step to the parent of a closed one.
@(command={name="Hierarchy/Collapse", palette=false, help="Closes the selected object's children, or steps to its parent"})
hierarchy_collapse :: proc() { _hierarchy_collapse(false) }

@(command={name="Hierarchy/Collapse Subtree", palette=false, help="Closes every descendant of the selected object"})
hierarchy_collapse_subtree :: proc() { _hierarchy_collapse(true) }

@(private = "file")
_hierarchy_collapse :: proc(deep: bool) {
	cur := _hierarchy_row_index(_hv, session.active())
	if cur == -1 do return
	row := _hv.rows[cur]
	if row.has_children && row.open {
		_hierarchy_set_open(_hv, row.tH, false)
		if deep do _hierarchy_set_open_deep(_hv, row.tH, false)
		return
	}
	if engine.pool_valid(&engine.ctx_world().transforms, engine.Handle(row.parent)) do session.select_only(row.parent)
}

@(command={name="Hierarchy/Rename", enabled=hierarchy_can_rename, help="Renames the selected object"})
hierarchy_rename :: proc() { _begin_rename(session.active()) }

hierarchy_can_rename :: proc() -> bool { return session.active() != _HANDLE_NONE || keymap.disabled("Nothing is selected") }

@(command={name="Hierarchy/Clear Filter", enabled=hierarchy_has_filter, palette=false, help="Clears the Hierarchy's search"})
hierarchy_clear_filter :: proc() { mem.zero(&_hv.filter_buf, len(_hv.filter_buf)) }

hierarchy_has_filter :: proc() -> bool { return _hv.filter_buf[0] != 0 || keymap.disabled("The Hierarchy has no search") }

// Not while a row is being renamed, nor the frame the rename closed.
hierarchy_keys_active :: proc() -> bool {
	return _hv.rename_target == _HANDLE_NONE && !_hv.rename_just_finished
}

@(keymap={name="Hierarchy", window="Hierarchy", active=hierarchy_keys_active})
hierarchy_keymap :: proc(km: ^keymap.Keymap) {
	keymap.bind(km, "Down", "Hierarchy/Select Down", repeat = true)
	keymap.bind(km, "Shift+Down", "Hierarchy/Extend Selection Down", repeat = true)
	keymap.bind(km, "Up", "Hierarchy/Select Up", repeat = true)
	keymap.bind(km, "Shift+Up", "Hierarchy/Extend Selection Up", repeat = true)
	keymap.bind(km, "Right", "Hierarchy/Expand", repeat = true)
	keymap.bind(km, "Alt+Right", "Hierarchy/Expand Subtree")
	keymap.bind(km, "Left", "Hierarchy/Collapse", repeat = true)
	keymap.bind(km, "Alt+Left", "Hierarchy/Collapse Subtree")
	// The Edit menu's Frame Selected, from here too, so the hierarchy needs
	// no mouse trip to the scene panel.
	keymap.bind(km, "F", "Edit/Frame Selected")
	keymap.bind(km, "Enter", "Hierarchy/Rename")
	keymap.bind(km, "F2", "Hierarchy/Rename")
	keymap.bind(km, "Escape", "Hierarchy/Clear Filter")
	// The Edit menu's Delete on the Delete key too. Its Ctrl+Backspace, and
	// the keys of Cut, Copy, Paste and Duplicate, are editor-wide.
	keymap.bind(km, "Delete", "Edit/Delete")
}

// The ACTIVE selected object (inspector target, gizmo target). With a
// multi-selection this is the most recently selected item.
hierarchy_get_selected :: proc() -> engine.Transform_Handle {
	return session.active()
}

@(menu_item={path="Edit/Toggle Transform Active", order=0, shortcut="Alt+Shift+A", help="Turns the selected objects off, or back on"})
hierarchy_toggle_active_menu :: proc() {
	w := engine.ctx_world()
	if w == nil do return
	session.prune()
	targets := session.selection()
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

shutdown_hierarchy_windows :: proc() {
	delete(_hierarchy_cut)
	_hierarchy_window_free(&_hv_none)
	delete(_inspector_comp_open)
}
