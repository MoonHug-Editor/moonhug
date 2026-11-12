package editor

import "base:runtime"

import "core:c"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "core:path/filepath"
import "core:encoding/uuid"
import "core:time"
import im "moonhug:external/odin-imgui"
import "inspector"
import "menu"
import asset_pipeline "moonhug:editor/assets"
import "subassets"
import "moonhug:editor/thumbnails"
import "undo"
import "moonhug:editor/widgets"
import "moonhug:editor/icons"
import assets "moonhug:libs/assets"
import core "moonhug:libs/core"
import "moonhug:editor/session"
import wnd "moonhug:editor/window"
import "moonhug:editor/keymap"

// What every Project copy shares: the selection's active path (the
// selection is editor-wide, selection.odin) and the assets root.
ProjectWindowData :: struct {
    selectedFile: string,
    rootPath: string,
}

projectWindowData: ProjectWindowData

PROJECT :: "Project"

// One Project copy's own state. The first copy's lives in _pv_plain and
// outlives its window, a copy opened from Add Tab has its own in its
// wnd.Window.
Project_Window :: struct {
    current_path: string, // the folder the list shows, owned (_project_set_current)
    // Keyboard navigation works like the hierarchy's: the draw collects the
    // visible rows in draw order, and the keymap's commands walk them before
    // the next draw, so index math matches what is on screen.
    tree_rows: [dynamic]Project_Tree_Row,
    // Folder open state, keyed by full path (persistent, owned clones).
    // Written after each TreeNodeEx, read next frame to pick the open/closed
    // folder icon.
    tree_open_state: map[string]bool,
    list_rows: [dynamic]Project_Row,
    // The rows' strings. Each arena resets when its list is rebuilt, so the
    // rows stay valid between draws, where the keymap's commands read them.
    tree_arena: virtual.Arena,
    list_arena: virtual.Arena,
    // One-shot fold command for a tree node (applied next frame via SetNextItemOpen).
    tree_set_open_path: string, // owned clone; "" = no pending command
    tree_set_open_val: bool,
    // When the right pane navigates, open the ancestor chain in the tree so
    // the highlighted folder is visible.
    tree_reveal: bool,
    scroll_to_tree_sel: bool,
    scroll_to_list_sel: bool,
    // The list pane drew a grid at its last draw, this many cells in a row:
    // the arrow keys then move between cells, Up and Down by a row of them.
    // 0: it drew rows.
    grid_cols: int,
    // Which pane keyboard input routes to, set when a pane is clicked or
    // hovered, toggled by Tab.
    active_pane: Project_Pane,
    // Search over ALL files and folders under the assets root (not the
    // current folder). Non-empty query swaps the file list for asset-DB
    // search results; keyboard nav follows whichever rows are drawn.
    search_buf: [256]byte,
    // Ping flash: fading row highlight WITHOUT changing selection.
    ping_path: string, // owned; "" = no active ping
    ping_sub: core.Local_ID, // not 0: the ping is on this sub-asset of ping_path
    ping_deadline_ns: i64,
    scroll_to_ping: bool,
    rename_active: bool,
    rename_path: string,   // owned clone of the full path being renamed
    rename_sub: core.Local_ID, // not 0: the sub-asset of rename_path being renamed
    rename_in_tree: bool,  // which pane opened the rename (for selection restore)
    rename_buf: [256]byte,
    rename_focus: bool,
    rename_focus_tries: int,
    rename_just_finished: bool,
    // Shift-click range target, processed after the list is drawn, because
    // the range spans list_rows, which is still being built at click time.
    range_pending: string, // owned
    expanded: map[string]bool, // asset path (owned clone) -> sub-assets unfolded
    // Search hit count from the previous frame: the header line draws BEFORE
    // the rows that count them, so it reports the last completed draw.
    result_count: int,
    // Path-bar segment under the pointer, so it can be drawn in the bright
    // text color. The color is chosen BEFORE the item exists, so it uses
    // last frame's answer.
    path_hovered: int,
    split_ratio: f32, // the tree pane's share of the window width
    // The search hits for search_for, found once per query and kept until
    // the files change (_project_search_hits).
    search_for: string, // owned
    search_gen: u64,    // project_dir_cache_gen when they were found
    search_count: int,  // assets in the db then: an import or a delete changes it
    search_subs: u64,   // the db's sub-asset lists then (asset_db.sub_assets_gen)
    search_hits: [dynamic]Project_Search_Hit,
}

// A search hit: an asset path and whether it is a folder, or a sub-asset of
// the file at the path.
Project_Search_Hit :: struct {
    path:     string, // owned
    is_dir:   bool,
    sub:      core.Local_ID, // not 0: the sub-asset with this id
    sub_name: string,        // owned
    sub_kind: string,        // owned
}

@(private = "file")
_pv_plain: Project_Window

// The copy being drawn, and outside a draw the copy clicked in last, which
// menu actions and asset requests act on.
_pv: ^Project_Window = &_pv_plain

// A copy's state: the first copy's is _pv_plain, another is made on its
// first frame, showing the assets root.
@(private = "file")
_project_window :: proc(w: ^wnd.Window) -> ^Project_Window {
    if w.key == PROJECT do return &_pv_plain
    if w.data == nil {
        pv := new(Project_Window, runtime.default_allocator())
        _project_window_init(pv)
        w.data = pv
    }
    return (^Project_Window)(w.data)
}

// current_path is on the default allocator (_project_set_current), the rest
// on the caller's, as the draw that grows it.
@(private = "file")
_project_window_init :: proc(pv: ^Project_Window) {
    pv.current_path = strings.clone("assets", runtime.default_allocator())
    pv.active_pane = .List
    pv.path_hovered = -1
    pv.split_ratio = 0.5
    // Start with the root folder expanded (one-shot; consumed on first draw).
    pv.tree_set_open_path = strings.clone("assets")
    pv.tree_set_open_val = true
}

@(private = "file")
_project_window_free :: proc(pv: ^Project_Window) {
    delete(pv.current_path, runtime.default_allocator())
    delete(pv.tree_rows)
    delete(pv.list_rows)
    virtual.arena_destroy(&pv.tree_arena)
    virtual.arena_destroy(&pv.list_arena)
    for k in pv.tree_open_state do delete(k)
    delete(pv.tree_open_state)
    for k in pv.expanded do delete(k)
    delete(pv.expanded)
    delete(pv.tree_set_open_path)
    delete(pv.rename_path)
    delete(pv.ping_path)
    delete(pv.range_pending)
    delete(pv.search_for)
    for h in pv.search_hits do delete(h.path)
    delete(pv.search_hits)
    pv^ = {}
}

project_window_closed :: proc(w: ^wnd.Window) {
    if w.key == PROJECT do return
    pv := (^Project_Window)(w.data)
    if pv == nil do return
    if _pv == pv do _pv = &_pv_plain
    _project_window_free(pv)
    free(pv, runtime.default_allocator())
    w.data = nil
}

// The rows each draw collects for keyboard navigation (Project_Window.tree_rows
// and list_rows). Their strings live in the window's row arenas until the next
// draw rebuilds them.
Project_Tree_Row :: struct {
    path: string, // full path
    open: bool,   // imgui tree node open state at the last draw
}
Project_Row :: struct {
    name:   string, // display text
    path:   string, // full path; drives selection/rename/activation (display
                    // names collide across folders in search results)
    is_dir: bool,
    sub:    core.Local_ID, // not 0: the sub-asset of the file at `path` with this id
}

// Which pane the keymap's commands act on. Tracked here rather than through
// imgui child focus (SetWindowFocus/IsWindowFocused are unreliable for child
// windows). Set when a pane is clicked, toggled by Tab.
Project_Pane :: enum { Tree, List }

_PROJECT_PING_NS :: i64(800_000_000)

init_project_window :: proc() {
    // The asset DB is rooted at "assets" (relative to the normalized moonhug/
    // cwd); the project window mirrors it so paths line up with asset lookups.
    projectWindowData.rootPath = strings.clone("assets")
    _project_window_init(&_pv_plain)
}

shutdown_project_window :: proc() {
    project_file_ops_shutdown()
    project_package_samples_shutdown()
    project_dir_cache_shutdown()
    delete(projectWindowData.rootPath)
    if projectWindowData.selectedFile != "" {
        delete(projectWindowData.selectedFile, runtime.default_allocator()) // see _project_set_active
    }
    _project_window_free(&_pv_plain)
}

_project_set_current :: proc(path: string) {
    // Editor-wide state: allocated and freed under one allocator, whoever calls.
    context.allocator = runtime.default_allocator()
    // Clone before delete: callers may pass a slice of the current string.
    new_path := strings.clone(path)
    delete(_pv.current_path)
    _pv.current_path = new_path
}

// Selection holds the FULL path (search results from different folders can
// share a base name). selectedFile is the ACTIVE path (what the project
// inspector and single-target actions use); the multi-selection set in
// selection.odin follows it.

// Re-point the active path WITHOUT touching the multi-selection set
// (cmd-click toggles, range ends).
_project_set_active :: proc(path: string) {
    // Editor-wide state: allocated and freed under one allocator, whoever calls.
    context.allocator = runtime.default_allocator()
    new_path := strings.clone(path)
    delete(projectWindowData.selectedFile)
    projectWindowData.selectedFile = new_path
}

// Select only `path` (the pre-multiselect behavior — all existing callers
// keep this semantics).
_project_set_selected :: proc(path: string) {
    _project_set_active(path)
    sel_proj_only(path)
}


// Range from the active row to `target` over the visible rows, REPLACING the
// selection; `target` becomes active.
_project_apply_range :: proc(target: string) {
    anchor := projectWindowData.selectedFile
    a_idx, t_idx := -1, -1
    // The range runs between file rows. A sub-asset's row between them joins it.
    for r, i in _pv.list_rows {
        if r.sub != 0 do continue
        if r.path == anchor do a_idx = i
        if r.path == target do t_idx = i
    }
    if a_idx == -1 || t_idx == -1 {
        _project_set_selected(target)
        return
    }
    sel_proj_clear()
    step := 1 if a_idx <= t_idx else -1
    for i := a_idx; ; i += step {
        sel_proj_add(_pv.list_rows[i].path, _pv.list_rows[i].sub)
        if i == t_idx do break
    }
    _project_set_active(target)
}

_project_path_is_ancestor :: proc(ancestor, path: string) -> bool {
    if ancestor == path do return false
    return strings.has_prefix(path, ancestor) && len(path) > len(ancestor) && path[len(ancestor)] == '/'
}

_project_tree_request_open :: proc(path: string, open: bool) {
    if _pv.tree_set_open_path != "" {
        delete(_pv.tree_set_open_path)
    }
    _pv.tree_set_open_path = strings.clone(path)
    _pv.tree_set_open_val = open
}

// Cancel an active search: clear the query and navigate to the selected item —
// its containing folder opens with the item still selected and revealed in the
// tree, so the highlighted hit doesn't vanish.
_project_cancel_search :: proc() {
    mem.zero(&_pv.search_buf, len(_pv.search_buf))
    sel := projectWindowData.selectedFile
    if sel != "" && os.exists(sel) {
        parent := filepath.dir(sel) // slice into sel — don't delete
        if parent == "" {
            parent = projectWindowData.rootPath
        }
        _project_set_current(parent)
        _pv.tree_reveal = true
        _pv.scroll_to_list_sel = true
    }
}

// Navigation, not a selection change: what is selected stays selected, the
// way a file manager keeps it while you browse, and nothing lands in the
// history.
_project_enter_dir :: proc(full_path: string) {
    _project_set_current(full_path)
    // Navigating to a folder leaves search mode — the list shows the folder now.
    mem.zero(&_pv.search_buf, len(_pv.search_buf))
    _pv.tree_reveal = true
}

_project_go_up :: proc() {
    // Select the folder we're leaving (full path == the old currentPath).
    // _project_parent_dir returns a SLICE into currentPath — read it before
    // _project_set_current frees the string, and never delete it. Package
    // roots go up to the Packages node, roots themselves stop.
    came_from := _pv.current_path
    parent, ok := _project_parent_dir(came_from)
    if !ok do return
    _project_set_selected(came_from)
    _project_set_current(parent)
    _pv.tree_reveal = true
    _pv.scroll_to_list_sel = true
}

// JSON asset files the project inspector opens directly (serialized
// __type_guid instances): generic .asset plus typed extensions (.mat).
//
// A .anim is NOT here: it is importer-backed, so it routes to the import
// settings panel below and its wrap, frame rate, cycle offset and trim are
// edited there — in the .meta, which survives re-extracting the model.
_is_inspector_asset :: proc(path: string) -> bool {
    return strings.has_suffix(path, ".asset") || strings.has_suffix(path, ".mat") || strings.has_suffix(path, ".noise")
}

// Brings every Project Inspector instance in line with what it should show
// now (project_inspectors_follow), at once rather than next frame: called
// right after a click changed the selection.
_project_inspectors_refresh :: proc() {
    project_inspectors_follow()
}

// Every Project Inspector instance shows what session.window_asset names for
// it, as every window with a lock reads its target (window_lock.odin): its lock's
// asset while it is locked, else the project selection, the assets kept while
// objects are selected included. Nothing named, or nothing an inspector can
// show (a plain folder), and it shows nothing. A target is loaded once, when
// it changes, so a path no inspector can show is not retried every frame.
// Once per frame before the windows draw, and at once after a click
// (_project_inspectors_refresh).
project_inspectors_follow :: proc() {
    context.allocator = runtime.default_allocator()
    keys := make([dynamic]string, context.temp_allocator)
    append(&keys, inspector.PROJECT_INSPECTOR)
    for w in wnd.instances(inspector.PROJECT_INSPECTOR) do if w.key != inspector.PROJECT_INSPECTOR do append(&keys, w.key)
    for key in keys {
        data := inspector.project_inspector_data(key)
        if data == nil do continue
        // Each instance remembers the target it was last given, so a target
        // that loads no file is not loaded again every frame.
        shown := session.window_asset(key)
        target := shown.path
        if data.given_set && data.given == target && data.given_sub == shown.sub_id do continue
        same_file := data.given_set && data.given == target
        delete(data.given)
        data.given = strings.clone(target)
        data.given_set = true
        // Another sub-asset of the same file is another thing to show when
        // the file's sub-assets are documents (a scene's).
        sub_changed := same_file && data.given_sub != shown.sub_id && _project_sub_assets_are_documents(target)
        data.given_sub = shown.sub_id
        if target == data.filePath && target != "" && !sub_changed do continue
        inspector.inspectorData = data
        inspector.unload()
        if target != "" do _project_inspect_one(target, shown.sub_id)
        inspector.inspector_data_reset()
    }
}

// Whether the sub-assets of the file at `path` are edited as documents
// (subassets.Provider.text).
@(private = "file")
_project_sub_assets_are_documents :: proc(path: string) -> bool {
    provider, ok := subassets.find(strings.to_lower(filepath.ext(path), context.temp_allocator))
    return ok && provider.text != nil
}

// Shows `full_path` in the Project Inspector instance inspector.inspectorData
// points at: the file, or its sub-asset `sub_id` when that is a document.
@(private = "file")
_project_inspect_one :: proc(full_path: string, sub_id: core.Local_ID = 0) {
    if project_path_is_package_root(full_path) {
        inspector.load_package(project_package_root_name(full_path), full_path, _project_package_asset_count(full_path))
        return
    }
    if sub_id != 0 && inspector.load_from_file(full_path, sub_id) do return
    if _is_inspector_asset(full_path) {
        inspector.load_from_file(full_path)
        return
    }
    // A scene is not a document and no importer claims it, so it would fall
    // through and leave the inspector on the previously selected asset. Name
    // it instead, which is also what makes its Preview drawer reachable.
    if strings.has_suffix(full_path, ".scene") {
        inspector.load_file_only(full_path)
        return
    }
    if asset_pipeline.is_importable_extension(filepath.ext(full_path)) {
        inspector.load_import_settings(full_path)
    }
}

// Same side effects as clicking/double-clicking the file row.
_project_activate_file :: proc(full_path: string) {
    _project_inspectors_refresh()
    _project_open_file(full_path)
}

// Opens a file's document: a scene in the Scene window, any other asset in the
// editor its package registered for the extension (asset_open_handler_add).
_project_open_file :: proc(full_path: string) {
    if strings.has_suffix(full_path, ".scene") {
        editor_open_scene(full_path)
        return
    }
    _ = asset_pipeline.asset_open(full_path)
}

_project_open_selected :: proc() {
    sel := projectWindowData.selectedFile
    if sel == "" do return
    for r in _pv.list_rows {
        if r.path != sel || r.sub != 0 do continue
        if r.is_dir {
            _project_enter_dir(r.path)
        } else {
            _project_activate_file(r.path)
        }
        return
    }
}

// Begin renaming the file/folder at `full_path`. Rename is keyed off the full
// path so both panes (right list = files, left tree = folders) share one flow.
_project_begin_rename :: proc(full_path: string, in_tree: bool) {
    // Roots (Assets, Packages, package roots) are structural — renaming a
    // package is a disk operation (imports depend on the folder name).
    if full_path == "" || project_path_is_protected(full_path) do return
    name := filepath.base(full_path)
    _project_rename_open(full_path, 0, name, in_tree)
}

// Begin renaming the sub-asset `sub` of the file at `path`, where the file
// lets the user name its sub-assets (subassets.Provider.rename).
_project_begin_rename_sub :: proc(path: string, sub: core.Local_ID) {
    ref, provider, ok := _project_sub_ref(path, sub)
    if !ok || provider.rename == nil do return
    s, found := subassets.get(ref)
    if !found do return
    _project_rename_open(path, sub, s.name, false)
}

@(private = "file")
_project_rename_open :: proc(path: string, sub: core.Local_ID, name: string, in_tree: bool) {
    _pv.rename_active = true
    _pv.rename_in_tree = in_tree
    _pv.rename_focus = true
    _pv.rename_focus_tries = 0
    // Before the path: `name` may be a part of the path replaced here.
    mem.zero(&_pv.rename_buf, len(_pv.rename_buf))
    copy_len := min(len(name), len(_pv.rename_buf) - 1)
    mem.copy(&_pv.rename_buf[0], raw_data(name), copy_len)
    fresh := strings.clone(path)
    if _pv.rename_path != "" do delete(_pv.rename_path)
    _pv.rename_path = fresh
    _pv.rename_sub = sub
}

// Unfolds the file's sub-asset rows, in the Project window clicked last.
_project_unfold_sub_assets :: proc(path: string) {
    if path in _pv.expanded {
        _pv.expanded[path] = true
    } else {
        _pv.expanded[strings.clone(path)] = true
    }
}

// The reference to the sub-asset `sub` of the file at `path`, and the file's
// provider.
_project_sub_ref :: proc(path: string, sub: core.Local_ID) -> (ref: core.PPtr, provider: subassets.Provider, ok: bool) {
    guid := assets.asset_db_get_guid(path) or_return
    provider = subassets.find(strings.to_lower(filepath.ext(path), context.temp_allocator)) or_return
    return core.PPtr{guid = core.Asset_GUID(guid), local_id = sub}, provider, true
}

// The sub-asset the selection's last entry names: (its file's path, its id).
_project_selected_sub :: proc() -> (path: string, sub: core.Local_ID, ok: bool) {
    entries := sel_proj_entries()
    if len(entries) == 0 do return
    last := entries[len(entries) - 1]
    return last.path, last.sub_id, last.sub_id != 0
}

_project_begin_rename_selected :: proc() {
    if path, sub, is_sub := _project_selected_sub(); is_sub {
        _project_begin_rename_sub(path, sub)
        return
    }
    sel := projectWindowData.selectedFile
    if sel == "" do return
    for r in _pv.list_rows {
        if r.path == sel {
            _project_begin_rename(sel, false)
            return
        }
    }
}

_project_apply_rename :: proc() {
    if !_pv.rename_active do return
    _pv.rename_active = false
    _pv.rename_just_finished = true

    new_name := string(cstring(raw_data(_pv.rename_buf[:])))
    if _pv.rename_sub != 0 {
        ref, provider, ok := _project_sub_ref(_pv.rename_path, _pv.rename_sub)
        if ok && provider.rename != nil && len(new_name) > 0 do provider.rename(ref, new_name)
        return
    }
    old_path := _pv.rename_path
    old_name := filepath.base(old_path)
    if len(new_name) == 0 || new_name == old_name do return

    parent := filepath.dir(old_path)
    new_path, _ := filepath.join({parent, new_name}, context.temp_allocator)
    if os.exists(new_path) {
        fmt.printf("[Editor] Rename: %s already exists\n", new_path)
        return
    }
    if err := os.rename(old_path, new_path); err != nil {
        fmt.printf("[Editor] Rename %s -> %s failed: %v\n", old_path, new_path, err)
        return
    }
    // The .meta must move with the asset — an orphaned meta is deleted on
    // refresh and the asset gets a fresh guid, breaking every reference to it.
    // (Folders have no .meta; os.exists guards it.)
    old_meta := strings.concatenate({old_path, ".meta"}, context.temp_allocator)
    if os.exists(old_meta) {
        new_meta := strings.concatenate({new_path, ".meta"}, context.temp_allocator)
        os.rename(old_meta, new_meta)
    }
    project_dir_cache_invalidate()
    if _pv.rename_in_tree {
        // Renamed folder: if it was the current path, follow it.
        if _pv.current_path == old_path {
            _project_set_current(new_path)
        }
    } else {
        _project_set_selected(new_path)
    }
    asset_pipeline.asset_db_refresh()
}

// Draws the rename InputText in place of the row/node whose full path is being
// renamed. Returns true if it did (caller skips the normal row).
_project_draw_rename_row :: proc(full_path: string) -> bool {
    if !_pv.rename_active || _pv.rename_sub != 0 || _pv.rename_path != full_path do return false
    _project_rename_input(im.GetContentRegionAvail().x)
    return true
}

// The rename InputText plus its focus/commit/cancel state machine, at the
// given width — the row form and the grid cell form share it.
_project_rename_input :: proc(width: f32) {
    // Keep requesting focus until it actually LANDS: a rename begun from a
    // context-menu item races the closing popup for focus — a single request
    // can lose it, and the frame after would read !IsItemActive as "clicked
    // away" and cancel (nameplate flashed for one frame).
    if _pv.rename_focus {
        im.SetKeyboardFocusHere(0)
    }
    im.SetNextItemWidth(width)
    buf_cstr := cstring(raw_data(_pv.rename_buf[:]))
    if im.InputText("##prj_rename", buf_cstr, c.size_t(len(_pv.rename_buf)), {.EnterReturnsTrue, .AutoSelectAll}) {
        _project_apply_rename()
    }
    if _pv.rename_focus {
        if im.IsItemActive() {
            _pv.rename_focus = false // focus landed; watch deactivation from here on
        } else {
            _pv.rename_focus_tries += 1
            if _pv.rename_focus_tries > 10 {
                _pv.rename_active = false // give up instead of stealing focus forever
                _pv.rename_just_finished = true
            }
        }
    } else if !im.IsItemActive() {
        if im.IsItemDeactivatedAfterEdit() {
            _project_apply_rename()
        } else {
            // Escape / clicked away without editing — cancel.
            _pv.rename_active = false
            _pv.rename_just_finished = true
        }
    }
}

// Material icon glyph for a file (full path). Icons are merged into the base
// font, so the returned string is drawn inline as part of a label.
// A folder's icon: a linked folder shows the link glyph in every state, so a
// plugin link in packages/ reads as a link wherever it appears.
_project_dir_icon :: proc(is_link: bool, expanded := false) -> string {
	if is_link do return icons.ICON_MD_FOLDER_LINK
	return icons.ICON_MD_FOLDER_OPEN if expanded else icons.ICON_MD_FOLDER
}

_project_file_icon :: proc(path: string) -> string {
    switch filepath.ext(path) {
    case ".scene":
        // Variant assets get the variant glyph — detection is a reliable
        // AssetDB root-info lookup (file inherits a base), not a name check.
        if guid, ok := assets.asset_db_get_guid(path); ok {
            if info, iok := assets.asset_db_get_root_info(core.Asset_GUID(guid)); iok && info.is_variant {
                return icons.ICON_MD_STACKS_VARIANT
            }
        }
        return icons.ICON_MD_STACKS // scene/prefab = stack group
    case ".png", ".jpg", ".jpeg", ".bmp", ".tga", ".gif":
        return icons.ICON_MD_IMAGE
    case ".asset":
        return icons.ICON_MD_SETTINGS
    case ".mat":
        return icons.ICON_MD_PALETTE
    case ".anim":
        return icons.ICON_MD_ANIMATION
    case ".glsl":
        return icons.ICON_MD_CODE
    case:
        return icons.ICON_MD_DESCRIPTION
    }
}

// Draw one folder node (icon, selection, keyboard row, open-state) and, if
// open, recurse into its subfolders. `name` is the label; `full_path` its path.
_project_draw_tree_node :: proc(full_path: string, name: string, is_link := false) {
    // Scope the imgui ID to this path so the "###node" constant IDs below stay
    // unique per folder (and never shift with the display label / icon).
    im.PushID(strings.clone_to_cstring(full_path, context.temp_allocator))
    defer im.PopID()

    // Folder being renamed: swap the node for an inline input. Still recorded in
    // the nav list so keyboard indices stay consistent; children are hidden for
    // the duration of the edit.
    if _pv.rename_active && _pv.rename_in_tree && _pv.rename_path == full_path {
        _project_tree_row_add(full_path, false)
        im.Indent(im.GetTreeNodeToLabelSpacing())
        _project_draw_rename_row(full_path)
        im.Unindent(im.GetTreeNodeToLabelSpacing())
        return
    }

    // Selection highlight only shows while the tree is the active pane, so focus
    // visibly moves with Tab. currentPath still drives the file list.
    is_selected := _pv.active_pane == .Tree && _pv.current_path == full_path
    // No fold toggle for folders with no subfolders (only dirs are shown in the
    // tree, so an empty subfolder set means nothing to expand).
    is_leaf := !_project_dir_has_subdir(full_path)

    // Folder icon (open when expanded) prefixed to the label; merged icon font
    // draws it inline. Open state is from last frame (see map below).
    // CRITICAL: the icon glyph is part of the label, and TreeNodeEx derives the
    // node ID from the label text. If the ID changed with the icon, imgui would
    // lose the open state every frame and the node would strobe open/closed.
    // Append a stable "##<full_path>" so the ID stays fixed while the icon varies.
    // Icon + name shown in the label. The icon glyph changes with open state,
    // but this imgui build derives the node ID from the WHOLE label string
    // (the "##id" split isn't honored the way it is in stock Dear ImGui) — so a
    // changing icon would change the ID, imgui would drop the open state, and
    // the node would strobe. Pin the ID explicitly with PushIDStr(full_path) and
    // give TreeNodeEx a constant display+id via "###" so the icon can vary freely.
    expanded := !is_leaf && _pv.tree_open_state[full_path]
    folder_icon := _project_dir_icon(is_link, expanded)
    node_label := strings.clone_to_cstring(fmt.tprintf("%s%s###node", folder_icon, name), context.temp_allocator)

    node_flags: im.TreeNodeFlags = {.OpenOnArrow, .OpenOnDoubleClick}
    if is_selected {
        node_flags += {.Selected}
    }
    if is_leaf {
        node_flags += {.Leaf, .NoTreePushOnOpen}
    }

    if !is_leaf {
        if _pv.tree_set_open_path != "" && _pv.tree_set_open_path == full_path {
            im.SetNextItemOpen(_pv.tree_set_open_val)
            delete(_pv.tree_set_open_path)
            _pv.tree_set_open_path = ""
        } else if _pv.tree_reveal && _project_path_is_ancestor(full_path, _pv.current_path) {
            im.SetNextItemOpen(true)
        }
    }

    node_open := im.TreeNodeEx(node_label, node_flags)
    // A leaf reports open==true but can't be collapsed; record it as closed so
    // Left-arrow skips straight to the parent.
    open := node_open && !is_leaf
    _project_tree_row_add(full_path, open)
    // Remember open state for next frame's folder icon. Keys are cloned once and
    // overwritten in place (freed on shutdown); the map is bounded by the number
    // of folders ever drawn.
    if _, seen := _pv.tree_open_state[full_path]; seen {
        _pv.tree_open_state[full_path] = open
    } else {
        _pv.tree_open_state[strings.clone(full_path)] = open
    }
    if is_selected && _pv.scroll_to_tree_sel {
        im.SetScrollHereY()
        _pv.scroll_to_tree_sel = false
    }

    // A click in the tree selects the folder and shows it, as a click on a
    // file row selects the file. The Project Inspector shows the selection,
    // so a package root opens the package inspector.
    if im.IsItemClicked() {
        _project_set_current(full_path)
        _project_set_selected(full_path)
        _project_inspectors_refresh()
    }

    if node_open && !is_leaf {
        draw_directory_tree(full_path)
        im.TreePop()
    }
}

// The current folder as a clickable path bar: each segment navigates there,
// the last one is the folder itself and is drawn plain. Separators are inert.
@(private = "file")
_project_draw_path_bar :: proc() {
    segments := project_path_segments(_pv.current_path)
    style := im.GetStyle()
    // No frame padding between the segments: the bar reads as one path, not
    // as a row of buttons.
    im.PushStyleVarImVec2(.ItemSpacing, im.Vec2{0, style.ItemSpacing.y})
    defer im.PopStyleVar()

    for c, i in segments {
        if i > 0 {
            im.TextDisabled(" " + icons.ICON_MD_CHEVRON_RIGHT + " ")
            im.SameLine(0, 0)
        }
        label := strings.clone_to_cstring(c.label, context.temp_allocator)
        if i == len(segments) - 1 {
            im.TextUnformatted(label) // the current folder
        } else {
            // A link, not a button: no frame. Hover brightens the text to the
            // normal color and shows the hand cursor.
            hovered_last := _pv.path_hovered == i
            im.PushStyleColorImVec4(.Text, im.GetStyleColorVec4(hovered_last ? .Text : .TextDisabled)^)
            im.TextUnformatted(label)
            im.PopStyleColor()
            if im.IsItemHovered({}) {
                _pv.path_hovered = i
                im.SetMouseCursor(.Hand)
                if im.IsMouseClicked(.Left) do _project_enter_dir(c.path)
            } else if hovered_last {
                _pv.path_hovered = -1
            }
        }
        if i < len(segments) - 1 do im.SameLine(0, 0)
    }
}

// Draw the subfolders of `path` as tree nodes (sorted). Does not draw `path`
// itself — the caller decides whether the parent gets a node.
draw_directory_tree :: proc(path: string, level: int = 0) {
    entries, ok := project_dir_listing(path)
    if !ok do return
    for entry in entries {
        if !entry.is_dir do continue
        full_path, _ := filepath.join({path, entry.name}, context.temp_allocator)
        _project_draw_tree_node(full_path, entry.name, entry.is_link)
    }
}

// True if `dir` contains at least one subdirectory.
_project_dir_has_subdir :: proc(dir: string) -> bool {
    entries, _ := project_dir_listing(dir)
    for entry in entries {
        if entry.is_dir do return true
    }
    return false
}

// A fresh Tab into the list pane with no valid selection lands on the first
// row (rows persist from the last draw — same folder). Only called on the Tab
// transition: running it every frame auto-selected the first file whenever a
// folder click cleared the selection, polluting selection undo history.
_project_list_ensure_selection :: proc() {
    n := len(_pv.list_rows)
    if n == 0 do return
    for r in _pv.list_rows {
        if r.path == projectWindowData.selectedFile do return // already valid
    }
    if _pv.list_rows[0].sub != 0 {
        _project_list_select(0, false)
        return
    }
    _project_set_selected(_pv.list_rows[0].path)
    _pv.scroll_to_list_sel = true
}

is_known_extension :: proc(filename: string) -> bool {
    ext := filepath.ext(filename)
    if ext == ".prefab" || ext == ".asset" || ext == ".mat" || ext == ".scene" do return true
    return asset_pipeline.is_importable_extension(ext)
}

draw_file_list :: proc(path: string) {
    entries, ok := project_dir_listing(path)
    if !ok {
        im.Text("Failed to read directory")
        return
    }

    // Directories first, files below them.
    items := make([dynamic]_Project_List_Item, 0, len(entries), context.temp_allocator)
    for entry in entries {
        if !entry.is_dir do continue
        entry_path, _ := filepath.join({path, entry.name}, context.temp_allocator)
        append(&items, _Project_List_Item{display = entry.name, path = entry_path, is_dir = true, is_link = entry.is_link})
    }
    for entry in entries {
        if entry.is_dir do continue
        if strings.has_prefix(entry.name, ".") do continue
        if filepath.ext(entry.name) == ".meta" do continue
        entry_path, _ := filepath.join({path, entry.name}, context.temp_allocator)
        append(&items, _Project_List_Item{display = entry.name, path = entry_path})
    }
    _project_draw_rows(items[:])
}

// Unity's grid mode: a cell per item — thumbnail or scaled type glyph with the
// name below — laid out in columns. Same order (directories first) and same
// row list as the list form, so keyboard navigation and range select carry
// over unchanged.
_project_draw_grid :: proc(path: string, cell: f32) {
    entries, ok := project_dir_listing(path)
    if !ok {
        im.Text("Failed to read directory")
        return
    }
    pad := im.GetStyle().ItemSpacing.x
    // Selectables expand their rect by half the item spacing on both sides —
    // lead each row by that much so the first column's highlight and art stay
    // inside the pane instead of clipping on its left border.
    lead := pad * 0.5
    cols := max(int((im.GetContentRegionAvail().x - lead + pad) / (cell + pad)), 1)
    _pv.grid_cols = cols
    col := 0
    for pass in 0 ..< 2 {
        for entry in entries {
            if entry.is_dir != (pass == 0) do continue
            if !entry.is_dir {
                if strings.has_prefix(entry.name, ".") do continue
                if filepath.ext(entry.name) == ".meta" do continue
            }
            if col > 0 do im.SameLine()
            else do im.SetCursorPosX(im.GetCursorPosX() + lead)
            entry_path, _ := filepath.join({path, entry.name}, context.temp_allocator)
            _project_draw_grid_cell(entry.name, entry_path, entry.is_dir, cell, entry.is_link)
            col = (col + 1) % cols

            // Unity's expander strip: an unfolded asset's sub-assets follow
            // as their own cells.
            if !entry.is_dir && _pv.expanded[entry_path] {
                sub, provider := _project_sub_assets(entry_path, false)
                if len(sub) > 0 {
                    if raw_guid, gok := assets.asset_db_get_guid(entry_path); gok {
                        guid := core.Asset_GUID(raw_guid)
                        _project_list_rows_add_subs(entry_path, sub)
                        for s, si in sub {
                            if col > 0 do im.SameLine()
                            else do im.SetCursorPosX(im.GetCursorPosX() + lead)
                            _project_draw_grid_sub_cell(entry_path, guid, s, si, provider, cell)
                            col = (col + 1) % cols
                        }
                    }
                }
            }
        }
    }
}

_project_draw_grid_sub_cell :: proc(parent_path: string, guid: core.Asset_GUID, s: subassets.Sub_Asset, index: int, provider: subassets.Provider, cell: f32) {
    label_h := im.GetTextLineHeightWithSpacing()
    // ID scope by parent + INDEX — the sub-asset id is data (pre-heal metas
    // carry id 0 on every slice).
    im.PushIDStr(fmt.ctprintf("sub_%s_%d", parent_path, index), nil)
    defer im.PopID()

    is_selected := _pv.active_pane == .List && sel_proj_is_sub(parent_path, s.id)
    rect_min := im.GetCursorScreenPos()
    renaming := _project_renaming_sub(parent_path, s.id)
    if renaming {
        im.Dummy(im.Vec2{cell, cell})
    } else {
        if im.Selectable("##subcell", is_selected, {.AllowDoubleClick}, im.Vec2{cell, cell + label_h}) {
            _project_sub_asset_clicked(parent_path, guid, s, provider)
        }
        _project_sub_asset_right_click(parent_path, s)
        _project_sub_asset_drag(guid, s, fmt.ctprintf("%s%s", icons.ICON_MD_IMAGE, s.name))
        _project_item_ping_flash(parent_path, s.id)
        _project_sub_scroll_to_selection(is_selected)
    }

    dl := im.GetWindowDrawList()
    if tid, uv0, uv1, tok := thumbnails.get_sub(parent_path, s); tok {
        // Aspect-fit: crops know their pixel size, rendered thumbs are square.
        w := s.size.x > 0 ? s.size.x : 1
        h := s.size.y > 0 ? s.size.y : 1
        inset := cell * 0.08
        avail := cell - inset * 2
        scale := min(avail / w, avail / h)
        dw, dh := w * scale, h * scale
        p0 := im.Vec2{rect_min.x + (cell - dw) * 0.5, rect_min.y + (cell - dh) * 0.5}
        im.DrawList_AddImage(dl,
            im.TextureRef{_TexID = im.TextureID(uintptr(tid))},
            p0, im.Vec2{p0.x + dw, p0.y + dh},
            im.Vec2{uv0.x, uv0.y}, im.Vec2{uv1.x, uv1.y})
    } else {
        cglyph := strings.clone_to_cstring(icons.ICON_MD_IMAGE, context.temp_allocator)
        im.PushFontFloat(nil, cell * 0.55)
        gsize := im.CalcTextSize(cglyph)
        im.DrawList_AddText(dl,
            im.Vec2{rect_min.x + (cell - gsize.x) * 0.5, rect_min.y + (cell - gsize.y) * 0.5},
            im.GetColorU32(.Text), cglyph)
        im.PopFont()
    }

    // Name centered under the art, clipped to the cell — the parent cell's
    // label treatment. In-place rename: the input where the label goes.
    if renaming {
        im.SetCursorScreenPos(im.Vec2{rect_min.x, rect_min.y + cell})
        _project_rename_input(cell)
        return
    }
    cdisplay := strings.clone_to_cstring(s.name, context.temp_allocator)
    tsize := im.CalcTextSize(cdisplay)
    im.DrawList_PushClipRect(dl,
        rect_min, im.Vec2{rect_min.x + cell, rect_min.y + cell + label_h}, true)
    im.DrawList_AddText(dl,
        im.Vec2{rect_min.x + max((cell - tsize.x) * 0.5, 0), rect_min.y + cell},
        im.GetColorU32(.Text), cdisplay)
    im.DrawList_PopClipRect(dl)
}

_project_draw_grid_cell :: proc(display: string, full_path: string, is_dir: bool, cell: f32, is_link := false) {
    _project_list_row_add(display, full_path, is_dir)

    label_h := im.GetTextLineHeightWithSpacing()
    im.PushIDStr(strings.clone_to_cstring(full_path, context.temp_allocator), nil)
    defer im.PopID()

    // In-place rename: the art block, then the input where the label goes.
    if !_pv.rename_in_tree && _pv.rename_active && _pv.rename_sub == 0 && _pv.rename_path == full_path {
        pos := im.GetCursorScreenPos()
        im.Dummy(im.Vec2{cell, cell})
        _project_grid_cell_art(full_path, is_dir, pos, cell, false)
        im.SetCursorScreenPos(im.Vec2{pos.x, pos.y + cell})
        _project_rename_input(cell)
        return
    }

    is_selected := _pv.active_pane == .List && sel_proj_is(full_path)
    dim := (!is_dir && !is_known_extension(full_path)) || project_file_is_cut(full_path)

    // Sub-asset fold arrow (Unity's grid expander): drawn on the art's right
    // edge via the draw list — an overlay ITEM would become the layout
    // anchor and break the grid's SameLine flow — and resolved against the
    // cell click below.
    sub, _ := _project_sub_assets(full_path, is_dir)
    open := len(sub) > 0 && _pv.expanded[full_path]

    // The cell origin is the CURSOR, not the Selectable's item rect — imgui
    // expands a Selectable's rect by half the item spacing on both sides, so
    // anchoring content on GetItemRectMin draws everything left of center.
    rect_min := im.GetCursorScreenPos()
    arrow_size := im.GetFontSize() + 6
    arrow_min := im.Vec2{rect_min.x + cell - arrow_size, rect_min.y + (cell - arrow_size) * 0.5}
    arrow_max := im.Vec2{arrow_min.x + arrow_size, arrow_min.y + arrow_size}
    mouse := im.GetMousePos()
    arrow_hovered := len(sub) > 0 &&
        mouse.x >= arrow_min.x && mouse.x <= arrow_max.x &&
        mouse.y >= arrow_min.y && mouse.y <= arrow_max.y

    if im.Selectable("##cell", is_selected, {.AllowDoubleClick}, im.Vec2{cell, cell + label_h}) {
        if arrow_hovered {
            if full_path in _pv.expanded {
                _pv.expanded[full_path] = !open
            } else {
                _pv.expanded[strings.clone(full_path)] = true
            }
        } else {
            _project_item_clicked(full_path, is_dir)
        }
    }
    if is_selected && _pv.scroll_to_list_sel {
        im.SetScrollHereY()
        _pv.scroll_to_list_sel = false
    }
    _project_item_ping_flash(full_path)
    icon := _project_dir_icon(is_link) if is_dir else _project_file_icon(full_path)
    drag_label := strings.clone_to_cstring(fmt.tprintf("%s%s", icon, display), context.temp_allocator)
    _project_item_extras(full_path, is_dir, drag_label)

    _project_grid_cell_art(full_path, is_dir, rect_min, cell, dim, is_link)

    if len(sub) > 0 {
        dl_arrow := im.GetWindowDrawList()
        im.DrawList_AddRectFilled(dl_arrow, arrow_min, arrow_max,
            im.GetColorU32(.FrameBg, arrow_hovered ? 0.9 : 0.55), 3)
        aglyph := strings.clone_to_cstring(open ? icons.ICON_MD_EXPAND_MORE : icons.ICON_MD_CHEVRON_RIGHT, context.temp_allocator)
        asize := im.CalcTextSize(aglyph)
        im.DrawList_AddText(dl_arrow,
            im.Vec2{arrow_min.x + (arrow_size - asize.x) * 0.5, arrow_min.y + (arrow_size - asize.y) * 0.5},
            im.GetColorU32(.Text), aglyph)
    }

    // Name centered under the art, clipped to the cell.
    dl := im.GetWindowDrawList()
    cdisplay := strings.clone_to_cstring(fmt.tprintf("%s%s", display, _project_dirty_star(full_path)), context.temp_allocator)
    tsize := im.CalcTextSize(cdisplay)
    text_col := im.GetStyleColorVec4(im.Col.Text)^
    if dim do text_col = {text_col.x * 0.6, text_col.y * 0.6, text_col.z * 0.6, text_col.w}
    im.DrawList_PushClipRect(dl,
        rect_min, im.Vec2{rect_min.x + cell, rect_min.y + cell + label_h}, true)
    im.DrawList_AddText(dl,
        im.Vec2{rect_min.x + max((cell - tsize.x) * 0.5, 0), rect_min.y + cell},
        im.GetColorU32ImVec4(text_col), cdisplay)
    im.DrawList_PopClipRect(dl)
}

// The cell's art: the asset's thumbnail when the service has one, the type
// glyph scaled to the cell otherwise.
_project_grid_cell_art :: proc(full_path: string, is_dir: bool, rect_min: im.Vec2, cell: f32, dim: bool, is_link := false) {
    dl := im.GetWindowDrawList()
    if !is_dir {
        if id, ok := thumbnails.get(full_path); ok {
            inset := cell * 0.04
            im.DrawList_AddImage(dl,
                im.TextureRef{_TexID = im.TextureID(uintptr(id))},
                im.Vec2{rect_min.x + inset, rect_min.y + inset},
                im.Vec2{rect_min.x + cell - inset, rect_min.y + cell - inset})
            return
        }
    }
    glyph := _project_dir_icon(is_link) if is_dir else _project_file_icon(full_path)
    cglyph := strings.clone_to_cstring(glyph, context.temp_allocator)
    text_col := im.GetStyleColorVec4(im.Col.Text)^
    if dim do text_col = {text_col.x * 0.6, text_col.y * 0.6, text_col.z * 0.6, text_col.w}
    im.PushFontFloat(nil, cell * 0.55)
    gsize := im.CalcTextSize(cglyph)
    im.DrawList_AddText(dl,
        im.Vec2{rect_min.x + (cell - gsize.x) * 0.5, rect_min.y + (cell - gsize.y) * 0.5},
        im.GetColorU32ImVec4(text_col), cglyph)
    im.PopFont()
}

// One row of the right pane, shared by the folder listing and search results.
// `display` is the shown text; `full_path` drives selection, rename,
// activation, and the drag payload.
// The cleaned paths of the files with unsaved changes this frame. Temp-allocated,
// set before the window draws.
@(private = "file")
_project_dirty_paths: map[string]bool

// " *" for a file with unsaved changes, the same mark its window's tab shows.
@(private = "file")
_project_dirty_star :: proc(path: string) -> string {
    if len(_project_dirty_paths) == 0 do return ""
    clean, _ := filepath.clean(path, context.temp_allocator)
    return " *" if clean in _project_dirty_paths else ""
}

// One list row. `listed`: the caller already put it in list_rows, the
// keyboard navigation list (_project_draw_rows).
_project_draw_list_row :: proc(display: string, full_path: string, is_dir: bool, is_link := false, listed := false) {
    if !listed do _project_list_row_add(display, full_path, is_dir)
    if !_pv.rename_in_tree && _project_draw_rename_row(full_path) do return

    icon := _project_dir_icon(is_link) if is_dir else _project_file_icon(full_path)
    label := strings.clone_to_cstring(fmt.tprintf("%s%s%s", icon, display, _project_dirty_star(full_path)), context.temp_allocator)

    is_selected := _pv.active_pane == .List && sel_proj_is(full_path)

    // Sub-asset gutter: every row reserves the expander column so names align
    // (Unity's layout); rows with sub-assets put the fold arrow in it.
    sub, sub_provider := _project_sub_assets(full_path, is_dir)
    arrow_w := im.GetFontSize() + 4
    if len(sub) > 0 {
        open := _pv.expanded[full_path]
        im.PushStyleColorImVec4(.Button, {})
        im.PushStyleVarImVec2(.FramePadding, {0, 0})
        arrow: cstring = open ? icons.ICON_MD_EXPAND_MORE : icons.ICON_MD_CHEVRON_RIGHT
        if im.Button(fmt.ctprintf("%s##exp_%s", arrow, full_path), {arrow_w, 0}) {
            // Keys are owned clones; collapsing keeps the entry (key reused on
            // the next unfold) instead of freeing through delete_key.
            if full_path in _pv.expanded {
                _pv.expanded[full_path] = !open
            } else {
                _pv.expanded[strings.clone(full_path)] = true
            }
        }
        im.PopStyleVar()
        im.PopStyleColor()
    } else {
        im.Dummy({arrow_w, 0})
    }
    im.SameLine(0, 0)

    dim_unknown := (!is_dir && !is_known_extension(full_path)) || project_file_is_cut(full_path)
    if dim_unknown {
        text_col := im.GetStyleColorVec4(im.Col.Text)
        dimmed: im.Vec4 = {text_col[0] * 0.6, text_col[1] * 0.6, text_col[2] * 0.6, text_col[3]}
        im.PushStyleColorImVec4(im.Col.Text, dimmed)
    }

    if im.Selectable(label, is_selected, {.AllowDoubleClick}) {
        _project_item_clicked(full_path, is_dir)
    }
    if is_selected && _pv.scroll_to_list_sel {
        im.SetScrollHereY()
        _pv.scroll_to_list_sel = false
    }
    _project_item_ping_flash(full_path)
    _project_item_extras(full_path, is_dir, label)
    if !is_dir {
        if tid, tok := thumbnails.get(full_path); tok {
            _project_row_preview(tid, {0, 0}, {1, 1}, 1, 1)
        }
    }
    if dim_unknown {
        im.PopStyleColor()
    }

    if len(sub) > 0 && _pv.expanded[full_path] {
        if !listed do _project_list_rows_add_subs(full_path, sub)
        _project_draw_sub_asset_rows(full_path, sub, sub_provider, arrow_w)
    }
}

// Small preview drawn over the LAST row item's icon glyph (Unity's list mini
// thumbnails). The label keeps its glyph underneath, so a row's imgui ID is
// the same whether or not the preview has arrived yet.
_project_row_preview :: proc(id: rawptr, uv0, uv1: [2]f32, w, h: f32) {
    rmin := im.GetItemRectMin()
    box := im.GetTextLineHeight()
    scale := min(box / max(w, 1), box / max(h, 1))
    dw, dh := w * scale, h * scale
    if w <= 1 && h <= 1 do dw, dh = box, box // square thumbs fill the box
    p0 := im.Vec2{rmin.x + (box - dw) * 0.5, rmin.y + (box - dh) * 0.5}
    p1 := im.Vec2{p0.x + dw, p0.y + dh}
    dl := im.GetWindowDrawList()
    im.DrawList_AddRectFilled(dl, im.Vec2{rmin.x, rmin.y}, im.Vec2{rmin.x + box, rmin.y + box}, im.GetColorU32(.WindowBg))
    im.DrawList_AddImage(dl, im.TextureRef{_TexID = im.TextureID(uintptr(id))}, p0, p1, im.Vec2{uv0.x, uv0.y}, im.Vec2{uv1.x, uv1.y})
}

// --- Sub-assets -----------------------------------------------------------------
// Unity's project window: an asset with sub-assets folds open to show them as
// child rows (a sliced texture's sprites). Providers come from the
// editor/subassets registry — packages register theirs, the Project window
// never names a package. Rows are selectable (the owning asset's import
// settings inspect), double click opens the provider's editor on the
// sub-asset, and each row drags as an ASSET_PPTR payload
// (PPtr{asset guid, sub-asset id}) into reference fields.


_project_sub_assets :: proc(path: string, is_dir: bool) -> ([]subassets.Sub_Asset, subassets.Provider) {
    if is_dir do return nil, {}
    ext := strings.to_lower(filepath.ext(path), context.temp_allocator)
    provider, ok := subassets.find(ext)
    if !ok do return nil, {}
    return provider.list(path, context.temp_allocator), provider
}

// Sub-asset click: a REAL selection entry {path, sub_id} — one set, one undo
// path with the rest of the selection. The active file stays the owning
// asset (its import settings inspect).
_project_sub_asset_clicked :: proc(parent_path: string, guid: core.Asset_GUID, s: subassets.Sub_Asset, provider: subassets.Provider) {
    sel_proj_only(parent_path, s.id)
    _project_set_active(parent_path)
    _project_inspectors_refresh()
    if im.IsMouseDoubleClicked(.Left) && provider.open != nil {
        provider.open(parent_path, guid, s.id)
    }
}

// Right-click selects the sub-asset, on the LAST item, so the context menu
// acts on the row under the cursor. One already selected keeps the set.
_project_sub_asset_right_click :: proc(parent_path: string, s: subassets.Sub_Asset) {
    if !im.IsItemHovered(im.HoveredFlags_AllowWhenBlockedByPopup) || !im.IsMouseClicked(.Right) do return
    if sel_proj_is_sub(parent_path, s.id) do return
    sel_proj_only(parent_path, s.id)
    _project_set_active(parent_path)
    _project_inspectors_refresh()
}

// Whether the sub-asset `sub` of the file at `path` is the one being renamed.
_project_renaming_sub :: proc(path: string, sub: core.Local_ID) -> bool {
    return _pv.rename_active && _pv.rename_sub != 0 && _pv.rename_sub == sub && _pv.rename_path == path
}

_project_sub_asset_drag :: proc(guid: core.Asset_GUID, s: subassets.Sub_Asset, drag_label: cstring) {
    if im.BeginDragDropSource({}) {
        payload := core.PPtr{guid = guid, local_id = s.id}
        im.SetDragDropPayload("ASSET_PPTR", &payload, size_of(core.PPtr))
        im.Text(drag_label)
        im.EndDragDropSource()
    }
}

_project_draw_sub_asset_rows :: proc(parent_path: string, sub: []subassets.Sub_Asset, provider: subassets.Provider, indent: f32) {
    raw_guid, gok := assets.asset_db_get_guid(parent_path)
    if !gok do return
    guid := core.Asset_GUID(raw_guid)

    im.Indent(indent * 2)
    // ID scope by parent + list INDEX — never by the sub-asset id, which is
    // data (pre-heal metas carry id 0 on every slice).
    im.PushIDStr(strings.clone_to_cstring(parent_path, context.temp_allocator), nil)
    for s, i in sub {
        im.PushIDInt(c.int(i))
        _project_draw_sub_asset_row(parent_path, guid, s, provider, fmt.ctprintf("%s%s", icons.ICON_MD_IMAGE, s.name))
        im.PopID()
    }
    im.PopID()
    im.Unindent(indent * 2)
}

// After a sub-asset's row or cell, the LAST item: the keys moved the selection
// onto it, so it scrolls into view, as a file's row does.
@(private = "file")
_project_sub_scroll_to_selection :: proc(selected: bool) {
    if !selected || !_pv.scroll_to_list_sel do return
    im.SetScrollHereY()
    _pv.scroll_to_list_sel = false
}

// One sub-asset's row: under its unfolded file, or as a search hit. The
// caller pushes an id of its own around it.
_project_draw_sub_asset_row :: proc(parent_path: string, guid: core.Asset_GUID, s: subassets.Sub_Asset, provider: subassets.Provider, label: cstring) {
    if _project_renaming_sub(parent_path, s.id) {
        _project_rename_input(im.GetContentRegionAvail().x)
        return
    }
    selected := sel_proj_is_sub(parent_path, s.id)
    pressed := im.Selectable(label, selected, {.AllowDoubleClick})
    if pressed do _project_sub_asset_clicked(parent_path, guid, s, provider)
    _project_sub_scroll_to_selection(_pv.active_pane == .List && selected)
    _project_sub_asset_right_click(parent_path, s)
    _project_sub_asset_drag(guid, s, label)
    _project_item_ping_flash(parent_path, s.id)
    if tid, uv0, uv1, tok := thumbnails.get_sub(parent_path, s); tok {
        _project_row_preview(tid, uv0, uv1, s.size.x, s.size.y)
    }
}

// Single click selects (and loads .asset/import settings for files); double
// click enters folders / opens scenes. cmd/ctrl-click toggles the item in/out
// of the multi-selection, shift-click ranges from the active item (deferred —
// the row list is mid-build); toggling OFF skips the activation side effects.
// Shared by list rows and grid cells.
_project_item_clicked :: proc(full_path: string, is_dir: bool) {
    io := im.GetIO()
    toggled_off := false
    if io.KeyCtrl || io.KeySuper {
        if sel_proj_is(full_path) {
            sel_proj_remove(full_path)
            _project_set_active(sel_proj_last())
            toggled_off = true
        } else {
            sel_proj_add(full_path)
            _project_set_active(full_path)
        }
    } else if io.KeyShift {
        if _pv.range_pending != "" do delete(_pv.range_pending)
        _pv.range_pending = strings.clone(full_path)
    } else {
        _project_set_selected(full_path)
    }
    if !toggled_off && is_dir {
        if im.IsMouseDoubleClicked(.Left) {
            _project_enter_dir(full_path)
        }
    } else if !toggled_off {
        _project_inspectors_refresh()
        if im.IsMouseDoubleClicked(.Left) do _project_open_file(full_path)
    }
}

// Ping flash: fading highlight over the LAST item, selection untouched. The
// item is the file's row, or with `sub` the row of that sub-asset.
_project_item_ping_flash :: proc(full_path: string, sub: core.Local_ID = 0) {
    if _pv.ping_path == "" || full_path != _pv.ping_path || sub != _pv.ping_sub do return
    remaining := _pv.ping_deadline_ns - time.now()._nsec
    if remaining <= 0 {
        delete(_pv.ping_path)
        _pv.ping_path = ""
        return
    }
    if _pv.scroll_to_ping {
        im.SetScrollHereY()
        _pv.scroll_to_ping = false
    }
    alpha := 0.45 * f32(remaining) / f32(_PROJECT_PING_NS)
    flash := im.GetColorU32ImVec4(im.Vec4{1.0, 0.8, 0.2, alpha})
    im.DrawList_AddRectFilled(im.GetWindowDrawList(), im.GetItemRectMin(), im.GetItemRectMax(), flash)
}

// Right-click select and the drag source, on the LAST item (files only).
_project_item_extras :: proc(full_path: string, is_dir: bool, drag_label: cstring) {
    if is_dir do return
    // Right-click also selects, so the context menu (which acts on the
    // selected asset) targets the item under the cursor, not whatever was
    // previously selected. Inside an existing multi-selection it only
    // re-points the active file, keeping the set.
    // Also with a context menu open: that click closes the menu and opens
    // it again, and the new one has to be about this row.
    if im.IsItemHovered(im.HoveredFlags_AllowWhenBlockedByPopup) && im.IsMouseClicked(.Right) {
        if sel_proj_is(full_path) {
            _project_set_active(full_path)
        } else {
            _project_set_selected(full_path)
        }
    }
    if im.BeginDragDropSource({}) {
        im.SetDragDropPayload("ASSET_PATH", raw_data(full_path), len(full_path))
        im.Text(drag_label)
        im.EndDragDropSource()
    }
}

// Search results, shown as root-relative paths: what asset_search finds
// (asset_search.odin has the query's words), files first, then sub-assets.
// Returns the match count for the status line.
_project_draw_search_results :: proc(query: string) -> int {
    hits := _project_search_hits(query)
    prefix := strings.concatenate({projectWindowData.rootPath, "/"}, context.temp_allocator)
    items := make([dynamic]_Project_List_Item, 0, len(hits), context.temp_allocator)
    for h in hits {
        if h.sub != 0 do continue
        display := h.path
        if strings.has_prefix(h.path, prefix) do display = h.path[len(prefix):]
        append(&items, _Project_List_Item{display = display, path = h.path, is_dir = h.is_dir})
    }
    _project_draw_rows(items[:])

    // Sub-asset hits: the row a file's unfolded sub-asset has, with its file
    // beside its name. Every one joins the keyboard navigation list, and only
    // the ones on screen are drawn: a row asks its file's provider for the
    // sub-asset, which may load the file (a texture's sprites).
    subs := make([dynamic]Project_Search_Hit, 0, len(hits), context.temp_allocator)
    for h in hits do if h.sub != 0 {
        append(&subs, h)
        // Once in the navigation list: an unfolded file hit listed it already.
        listed := false
        if _pv.expanded[h.path] {
            for r in _pv.list_rows do if r.sub == h.sub && r.path == h.path {
                listed = true
                break
            }
        }
        if !listed do _project_list_row_add(h.sub_name, h.path, false, h.sub)
    }
    if len(subs) == 0 do return len(hits)
    im.PushIDStr("##sub_hits", nil)
    clipper: im.ListClipper
    im.ListClipper_Begin(&clipper, i32(len(subs)))
    if _pv.scroll_to_list_sel && _pv.active_pane == .List {
        for h, i in subs do if sel_proj_is_sub(h.path, h.sub) do im.ListClipper_IncludeItemByIndex(&clipper, i32(i))
    }
    for im.ListClipper_Step(&clipper) {
        for i in clipper.DisplayStart ..< clipper.DisplayEnd {
            h := subs[i]
            raw_guid, known := assets.asset_db_get_guid(h.path)
            provider, has := subassets.find(strings.to_lower(filepath.ext(h.path), context.temp_allocator))
            display := h.path
            if strings.has_prefix(h.path, prefix) do display = h.path[len(prefix):]
            label := fmt.ctprintf("%s%s  (%s)", icons.ICON_MD_IMAGE, h.sub_name, display)
            if !known || !has {
                im.TextDisabled("%s", label)
                continue
            }
            // The provider's own entry, with its preview. The database's when
            // the provider does not list it now.
            entry := subassets.Sub_Asset{id = h.sub, name = h.sub_name, kind = h.sub_kind}
            for s in provider.list(h.path, context.temp_allocator) do if s.id == h.sub {
                entry = s
                break
            }
            im.PushIDInt(c.int(i))
            _project_draw_sub_asset_row(h.path, core.Asset_GUID(raw_guid), entry, provider, label)
            im.PopID()
        }
    }
    im.PopID()
    return len(hits)
}

// The assets that match `query`, files sorted by path and then sub-assets.
// Found once per query and kept while the files and the sub-asset lists stay
// the same, since a search draws every frame.
@(private = "file")
_project_search_hits :: proc(query: string) -> []Project_Search_Hit {
    gen := project_dir_cache_gen()
    count := len(assets.asset_db.path_to_guid)
    subs := assets.asset_db.sub_assets_gen
    if query == _pv.search_for && gen == _pv.search_gen && count == _pv.search_count && subs == _pv.search_subs {
        return _pv.search_hits[:]
    }
    delete(_pv.search_for)
    _pv.search_for = strings.clone(query)
    _pv.search_gen = gen
    _pv.search_count = count
    _pv.search_subs = subs
    for h in _pv.search_hits {
        delete(h.path)
        delete(h.sub_name)
        delete(h.sub_kind)
    }
    clear(&_pv.search_hits)

    found := make([dynamic]Asset_Hit, context.temp_allocator)
    asset_search(query, widgets.search_match, &found)
    for h in found {
        append(&_pv.search_hits, Project_Search_Hit{path = strings.clone(h.path), is_dir = h.is_dir, sub = h.sub, sub_name = strings.clone(h.sub_name), sub_kind = strings.clone(h.sub_kind)})
    }
    // Map iteration order is unstable: sorted, rows keep their places.
    slice.sort_by(_pv.search_hits[:], proc(a, b: Project_Search_Hit) -> bool {
        if (a.sub != 0) != (b.sub != 0) do return a.sub == 0
        if a.path != b.path do return a.path < b.path
        return a.sub_name < b.sub_name
    })
    return _pv.search_hits[:]
}

// A row of the list pane, for _project_draw_rows.
@(private = "file")
_Project_List_Item :: struct {
    display: string,
    path:    string,
    is_dir:  bool,
    is_link: bool,
}

// Draws the list pane's rows, the ones on screen only. Every row joins the
// keyboard navigation list (list_rows), but a row off screen costs nothing
// more: drawing a row asks for its thumbnail and its sub-assets, which may
// load the asset, so a long folder or result list costs what its visible rows
// cost. A row that has to scroll into view (the selection, a ping) draws
// wherever it is. Rows of different heights (one unfolded to its sub-assets,
// one being renamed) all draw.
@(private = "file")
_project_draw_rows :: proc(items: []_Project_List_Item) {
    for it in items {
        _project_list_row_add(it.display, it.path, it.is_dir)
        if _pv.expanded[it.path] {
            sub, _ := _project_sub_assets(it.path, it.is_dir)
            _project_list_rows_add_subs(it.path, sub)
        }
    }
    uneven := _pv.rename_active && !_pv.rename_in_tree
    if !uneven {
        for it in items do if _pv.expanded[it.path] {
            uneven = true
            break
        }
    }
    if uneven {
        for it in items do _project_draw_list_row(it.display, it.path, it.is_dir, it.is_link, listed = true)
        return
    }
    clipper: im.ListClipper
    im.ListClipper_Begin(&clipper, i32(len(items)))
    for it, i in items {
        scroll_sel := _pv.scroll_to_list_sel && _pv.active_pane == .List && sel_proj_is(it.path)
        scroll_ping := _pv.scroll_to_ping && it.path == _pv.ping_path
        if scroll_sel || scroll_ping do im.ListClipper_IncludeItemByIndex(&clipper, i32(i))
    }
    for im.ListClipper_Step(&clipper) {
        for i in clipper.DisplayStart ..< clipper.DisplayEnd {
            it := items[i]
            _project_draw_list_row(it.display, it.path, it.is_dir, it.is_link, listed = true)
        }
    }
}

// Create a prefab variant of the scene at `base_path`, written alongside it as
// "<name>_Variant.scene", then open it. The variant's root is a NestedScene
// over the base (empty overrides); editing it captures overrides against the base.
create_scene_variant :: proc(base_path: string) {
    dir := filepath.dir(base_path) // slice into base_path — not owned, don't delete
    stem := filepath.stem(base_path)
    variant_name := strings.concatenate({stem, "_Variant.scene"}, context.temp_allocator)
    variant_path, _ := filepath.join({dir, variant_name}, context.temp_allocator)

    if !asset_pipeline.asset_create_variant(base_path, variant_path) {
        fmt.printf("[Editor] Failed to create scene variant from %s\n", base_path)
        return
    }
    // Mint the variant's .meta and register it so it can be loaded by GUID.
    asset_pipeline.asset_db_refresh()

    undo.purge_scenes(undo.get())
    session.edit_stack_clear()
    asset_pipeline.asset_open(variant_path)
}

// Leave search mode and open the asset's folder, revealed in the tree.
// select=true: select the row (open semantics). select=false: ping — a
// fading flash on the row, selection untouched.
// Navigate to the file's folder and scroll its row into view WITHOUT
// touching the selection set — selection undo restores the set itself and
// only needs the Project window to show it.
_project_reveal_keep_selection :: proc(path: string) {
    mem.zero(&_pv.search_buf, len(_pv.search_buf))
    parent := filepath.dir(path) // slice into path — not owned
    if parent == "" {
        parent = projectWindowData.rootPath
    }
    _project_set_current(parent)
    _pv.scroll_to_list_sel = true
    _pv.tree_reveal = true
}

// What a double click on a sub-asset's row does, for a request from another
// window: the folder is shown, the file unfolds, the sub-asset is selected and
// its provider's `open` runs. The file itself is not opened.
_project_open_sub_asset :: proc(path: string, ref: core.PPtr) {
    _project_reveal_keep_selection(path)
    _project_unfold_sub_assets(path)
    sel_proj_only(path, ref.local_id)
    _project_set_active(path)
    _project_inspectors_refresh()
    if _, provider, ok := _project_sub_ref(path, ref.local_id); ok && provider.open != nil {
        provider.open(path, ref.guid, ref.local_id)
    }
}

// `sub`: the ping is on that sub-asset's row, and the file unfolds to show it.
_project_reveal_path :: proc(path: string, select: bool, sub: core.Local_ID = 0) {
    mem.zero(&_pv.search_buf, len(_pv.search_buf))
    parent := filepath.dir(path) // slice into path — not owned
    if parent == "" {
        parent = projectWindowData.rootPath
    }
    // A package root's row is under the Packages node, not its own folder.
    if project_path_is_package_root(path) do parent = _PROJECT_PACKAGES_PATH
    _project_set_current(parent)
    if select {
        _project_set_selected(path)
        // Same as clicking the row: selecting a file in this window loads it into
        // the inspector, and a reveal that skipped that left the panel showing
        // whatever was there before.
        _project_inspectors_refresh()
        _pv.scroll_to_list_sel = true
    } else {
        if _pv.ping_path != "" do delete(_pv.ping_path)
        _pv.ping_path = strings.clone(path)
        _pv.ping_sub = sub
        if sub != 0 do _project_unfold_sub_assets(path)
        _pv.ping_deadline_ns = time.now()._nsec + _PROJECT_PING_NS
        _pv.scroll_to_ping = true
    }
    _pv.tree_reveal = true
    _pv.active_pane = .List
}

_PROJECT_MIN_PANE :: f32(120)

// The asset requests and the dirty files, once per frame whether or not a
// Project copy is visible. A request acts on the copy clicked in last.
project_frame_begin :: proc() {
    // Drain cross-package asset requests (inspector value-button clicks):
    // ping = reveal + flash; open = reveal + select + activate (double click).
    if ping, ok := core.inspector_take_pending_ping_asset(); ok {
        if path, pok := assets.asset_db_get_path(uuid.Identifier(ping.guid)); pok {
            _project_reveal_path(path, select = false, sub = ping.local_id)
        }
    }
    if sel_guid, ok := core.inspector_take_pending_select_asset(); ok {
        if path, pok := assets.asset_db_get_path(uuid.Identifier(sel_guid)); pok {
            _project_reveal_path(path, select = true)
        }
    }
    if open, ok := core.inspector_take_pending_open_asset(); ok {
        if path, pok := assets.asset_db_get_path(uuid.Identifier(open.guid)); pok {
            if open.local_id != 0 {
                _project_open_sub_asset(path, open)
            } else {
                _project_reveal_path(path, select = true)
                _project_activate_file(path)
            }
        }
    }

    // Files with unsaved changes get a star after their name, read once per
    // frame (session/documents.odin).
    _project_dirty_paths = session.documents_dirty_paths()
}

@(editor_window={id="Project", title="Project", icon="FOLDER", closed=project_window_closed})
project_window_draw :: proc(w: ^wnd.Window) {
    _pv = _project_window(w)
    defer {
        last := wnd.last(PROJECT)
        _pv = _project_window(last) if last != nil else &_pv_plain
    }
    if _pv.rename_just_finished do _pv.rename_just_finished = false
    // Search toolbar across the whole window, above both panes. While the
    // box has keyboard focus, the keymap's plain keys do not resolve. A
    // non-empty query shows an "x" beside it.
    query := strings.trim_space(string(cstring(raw_data(_pv.search_buf[:]))))
    clear_btn_w := im.GetFrameHeight()
    im.SetNextItemWidth(-(clear_btn_w + im.GetStyle().ItemSpacing.x) if query != "" else -1)
    // NoTabStop: Tab must switch panes (the keymap), never tab-focus the
    // search box. Clicking into it still works.
    im.PushItemFlag({.NoTabStop}, true)
    im.InputTextWithHint("##prj_search", "Search: name, t:Type, c:Component", cstring(raw_data(_pv.search_buf[:])), c.size_t(len(_pv.search_buf)), {})
    im.PopItemFlag()
    if query != "" {
        im.SameLine()
        if im.Button(icons.ICON_MD_CLOSE + "###prj_search_clear", im.Vec2{clear_btn_w, 0}) {
            _project_cancel_search()
            query = ""
        }
    }

    // Tree | files, split by a draggable splitter, under the toolbar.
    split_avail := im.GetContentRegionAvail()
    split_total := split_avail.x - widgets.SPLITTER_SIZE
    tree_w := split_total * _pv.split_ratio
    if tree_w < _PROJECT_MIN_PANE do tree_w = _PROJECT_MIN_PANE
    if tree_w > split_total - _PROJECT_MIN_PANE do tree_w = split_total - _PROJECT_MIN_PANE
    list_w := split_total - tree_w


    // Left pane: Tree view
    im.BeginChild("TreeView", im.Vec2{tree_w, 0}, {.Borders})
    // Clicking anywhere in the tree makes it the active pane.
    if im.IsWindowHovered({}) && im.IsMouseClicked(.Left) {
        _pv.active_pane = .Tree
    }

    clear(&_pv.tree_rows)
    virtual.arena_free_all(&_pv.tree_arena)

    // The real assets root folder is the top node (it recurses into its own
    // contents). It's a genuine on-disk folder, but renaming it is blocked in
    // the rename entry points (it's the project root).
    _project_draw_tree_node(projectWindowData.rootPath, filepath.base(projectWindowData.rootPath))
    // Installed packages: additional roots under a Packages node
    // (docs/core/Plugins.md — label = package name, path = its assets dir).
    _project_draw_packages_tree()
    // Reveal requests from the right pane were consumed by this draw.
    _pv.tree_reveal = false

    im.EndChild()

    im.SameLine(0, 0)
    if widgets.splitter("##project_split", true, &tree_w, &list_w, _PROJECT_MIN_PANE, _PROJECT_MIN_PANE) {
        _pv.split_ratio = tree_w / split_total
    }
    im.SameLine(0, 0)

    // Right pane: File list
    im.BeginChild("FileList", im.Vec2{0, 0}, {.Borders})
    // ChildWindows: the rows live in a nested scroll child below.
    if im.IsWindowHovered(im.HoveredFlags_ChildWindows) && im.IsMouseClicked(.Left) {
        _pv.active_pane = .List
    }

    clear(&_pv.list_rows)
    virtual.arena_free_all(&_pv.list_arena)
    _pv.grid_cols = 0

    // Where the list is, or what the selection is: above the rows, where
    // the search box used to sit. Text height, not frame height — nothing
    // here is a widget, so the bar stays as thin as one line.
    if query != "" {
        im.Text(strings.clone_to_cstring(fmt.tprintf("%d found", _pv.result_count), context.temp_allocator))
    } else if sel_proj_count() > 1 {
        im.Text(strings.clone_to_cstring(fmt.tprintf("%d selected", sel_proj_count()), context.temp_allocator))
    } else {
        _project_draw_path_bar()
    }

    // Rows scroll in their own child so the zoom strip below stays fixed
    // at the bottom of the pane.
    result_count := 0
    // Reserve exactly the strip: the slider's own height (text plus the
    // trimmed 1px frame padding, top and bottom) and one item spacing.
    zoom_h := im.GetTextLineHeight() + 2 + im.GetStyle().ItemSpacing.y
    im.BeginChild("FileRows", im.Vec2{0, -zoom_h}, {})
    // The child insets its contents on the left by the window padding;
    // match it above the first row, so the list does not touch the top
    // edge (imgui applies no padding on the scrolling axis).
    im.Dummy({0, im.GetStyle().WindowPadding.y - im.GetStyle().ItemSpacing.y})
    if query != "" {
        result_count = _project_draw_search_results(query)
    } else if _pv.current_path == _PROJECT_PACKAGES_PATH {
        // The Packages node lists package roots, never the raw packages/
        // folder (which would expose code to the file list).
        _project_draw_packages_list()
    } else if editor_settings.project_zoom > 0 {
        // Unity's zoom model: the slider's low end is the list, anything
        // above it a thumbnail grid scaling with the value.
        cell := 40 + editor_settings.project_zoom * 56
        _project_draw_grid(_pv.current_path, cell)
    } else {
        draw_file_list(_pv.current_path)
    }
    if im.BeginPopupContextWindow("ProjectFileListContext", im.PopupFlags_MouseButtonRight) {
        // The Assets menu up to its database band: what acts on the selected
        // assets and the open folder.
        menu.draw_menu_sections({menu.section("Assets", max_order = menu.ASSETS_SECTION_DATABASE - 1)})
        im.EndPopup()
    }
    im.EndChild()

    // Shift-click range, now that the visible rows are complete.
    if _pv.range_pending != "" {
        _project_apply_range(_pv.range_pending)
        delete(_pv.range_pending)
        _pv.range_pending = ""
    }

    // Bottom strip: the zoom slider, right-aligned. 0 = list view, above
    // it a thumbnail grid whose cell scales with the value. Trimmed frame
    // padding keeps the strip close to the track's own height.
    im.PushStyleVarImVec2(.FramePadding, im.Vec2{im.GetStyle().FramePadding.x, 1})
    zoom_w := widgets.slider_width_for_track(90)
    im.SetCursorPosX(max(im.GetCursorPosX(), im.GetWindowWidth() - zoom_w - im.GetStyle().WindowPadding.x))
    widgets.slider_float("##prj_zoom", &editor_settings.project_zoom, 0, 1, "%.2f", zoom_w)
    im.PopStyleVar()
    // The row count the header shows, from THIS frame's draw.
    _pv.result_count = result_count

    im.EndChild()

    // The keys are the "Project" keymap's commands (the end of this file).
    // The frame a rename closes, its Enter or Escape press is still down: the
    // keymap is off that frame (project_keys_active), and the flag clears in
    // the next draw.
}

// --- Commands and keymap -------------------------------------------------------
//
// The keymap resolver runs these before the windows draw (editor/keymap). They
// act on _pv, which is the last clicked copy outside a draw, and on its active
// pane (Tree or List). The row lists are the ones the last draw built.

// Adds a navigation row, its strings in the window's row arena.
@(private = "file")
_project_tree_row_add :: proc(path: string, open: bool) {
    a := virtual.arena_allocator(&_pv.tree_arena)
    append(&_pv.tree_rows, Project_Tree_Row{path = strings.clone(path, a), open = open})
}

@(private = "file")
_project_list_row_add :: proc(name, path: string, is_dir: bool, sub: core.Local_ID = 0) {
    a := virtual.arena_allocator(&_pv.list_arena)
    append(&_pv.list_rows, Project_Row{name = strings.clone(name, a), path = strings.clone(path, a), is_dir = is_dir, sub = sub})
}

// The rows of an unfolded file's sub-assets join the keyboard navigation
// list after their file's row, in the order they are drawn.
@(private = "file")
_project_list_rows_add_subs :: proc(path: string, sub: []subassets.Sub_Asset) {
    for s in sub do _project_list_row_add(s.name, path, false, s.id)
}

// The row index of the shown folder in the tree, -1 for none.
@(private = "file")
_project_tree_index :: proc() -> int {
    for r, i in _pv.tree_rows do if r.path == _pv.current_path do return i
    return -1
}

// The row index of the active selection in the list, -1 for none.
@(private = "file")
_project_list_index :: proc() -> int {
    _, sub, _ := _project_selected_sub()
    for r, i in _pv.list_rows do if r.path == projectWindowData.selectedFile && r.sub == sub do return i
    return -1
}

@(private = "file")
_project_tree_select :: proc(idx: int) {
    _project_set_current(_pv.tree_rows[idx].path)
    _project_set_selected(_pv.tree_rows[idx].path)
    _project_inspectors_refresh()
    _pv.scroll_to_tree_sel = true
}

// Plain arrows move the (single) selection, Shift+arrows EXTEND it: the
// stepped-onto row joins the selection and becomes active.
@(private = "file")
_project_list_select :: proc(idx: int, extend: bool) {
    path, sub := _pv.list_rows[idx].path, _pv.list_rows[idx].sub
    switch {
    case extend:
        sel_proj_add(path, sub)
        _project_set_active(path)
    case sub != 0:
        // A sub-asset's row: the entry is {file, sub-asset}, and the active
        // file stays its file, as a click on the row does.
        sel_proj_only(path, sub)
        _project_set_active(path)
    case:
        _project_set_selected(path)
    }
    _project_inspectors_refresh()
    _pv.scroll_to_list_sel = true
}

// Up and Down step through the active pane's rows. With nothing selected
// both land on the first row. In the grid they move by a row of cells: to
// the cell above or below, or to the last cell from the row above it.
@(private = "file")
_project_nav_step :: proc(step: int, extend: bool) {
    switch _pv.active_pane {
    case .Tree:
        n := len(_pv.tree_rows)
        if n == 0 do return
        cur := _project_tree_index()
        if cur == -1 {
            _project_tree_select(0)
        } else if cur + step >= 0 && cur + step < n {
            _project_tree_select(cur + step)
        }
    case .List:
        _project_list_step(step * max(_pv.grid_cols, 1), extend)
    }
}

// Moves the list pane's selection by `by` rows or cells.
@(private = "file")
_project_list_step :: proc(by: int, extend: bool) {
    n := len(_pv.list_rows)
    if n == 0 do return
    cur := _project_list_index()
    if cur == -1 {
        _project_list_select(0, false)
        return
    }
    to := cur + by
    // Down from the row above the grid's last, shorter row: its last cell.
    if to >= n && by > 1 && cur / by < (n - 1) / by do to = n - 1
    if to >= 0 && to < n do _project_list_select(to, extend)
}

// The selected row of the list pane when it is a file with sub-assets, or a
// sub-asset: the file, and whether its sub-assets are unfolded.
@(private = "file")
_project_list_foldable :: proc() -> (cur: int, path: string, on_sub: bool, open: bool, ok: bool) {
    cur = _project_list_index()
    if cur == -1 do return
    row := _pv.list_rows[cur]
    if row.is_dir do return
    sub, _ := _project_sub_assets(row.path, false)
    if len(sub) == 0 do return
    return cur, row.path, row.sub != 0, _pv.expanded[row.path], true
}

// Unfolds the selected file's sub-assets. False when there is nothing to
// unfold: the row is a folder, a sub-asset, a file without sub-assets, or a
// file already unfolded.
@(private = "file")
_project_list_unfold :: proc() -> bool {
    _, path, on_sub, open, ok := _project_list_foldable()
    if !ok || on_sub || open do return false
    _project_unfold_sub_assets(path)
    return true
}

// Folds the selected file's sub-assets, or from a sub-asset selects its
// file. False when the row is neither: a folder, a file without sub-assets,
// or a file already folded.
@(private = "file")
_project_list_fold :: proc() -> bool {
    _, path, on_sub, open, ok := _project_list_foldable()
    if !ok do return false
    if on_sub {
        _project_set_selected(path)
        _project_inspectors_refresh()
        _pv.scroll_to_list_sel = true
        return true
    }
    if !open do return false
    _pv.expanded[path] = false
    return true
}

@(command={name="Project/Select Down", palette=false, help="Selects the next row"})
project_select_down :: proc() { _project_nav_step(1, false) }

@(command={name="Project/Select Up", palette=false, help="Selects the previous row"})
project_select_up :: proc() { _project_nav_step(-1, false) }

// Extend grows the list's selection by the stepped-onto row.
@(command={name="Project/Extend Selection Down", palette=false, help="Adds the next row to the selection"})
project_extend_down :: proc() { _project_nav_step(1, true) }

@(command={name="Project/Extend Selection Up", palette=false, help="Adds the previous row to the selection"})
project_extend_up :: proc() { _project_nav_step(-1, true) }

// Right, by where the keyboard is:
//   - the folder tree: opens a closed folder and steps into an open one
//   - the list's rows: unfolds the selected file's sub-assets. With nothing
//     to unfold, the next row, as in the Hierarchy
//   - the grid: the next cell
@(command={name="Project/Expand", palette=false, help="Opens the selected folder, or steps into an open one. In the file list, unfolds the selected file's sub-assets, or selects the next row. In the grid, selects the next cell"})
project_expand :: proc() {
    if _pv.active_pane == .List {
        if _pv.grid_cols > 0 do _project_list_step(1, false)
        else if !_project_list_unfold() do _project_list_step(1, false)
        return
    }
    cur := _project_tree_index()
    if cur == -1 do return
    row := _pv.tree_rows[cur]
    has_child_rows := cur + 1 < len(_pv.tree_rows) && _project_path_is_ancestor(row.path, _pv.tree_rows[cur + 1].path)
    if row.open && has_child_rows {
        _project_tree_select(cur + 1)
    } else {
        _project_tree_request_open(row.path, true)
    }
}

// Left, by where the keyboard is:
//   - the folder tree: collapses an open folder first, even one that shows
//     no subfolders (imgui still tracks its open state). A closed folder
//     steps to its parent: package roots go to the Packages node, roots stay
//     (_project_parent_dir)
//   - the list's rows: from a sub-asset to its file, then folds the file.
//     With nothing to fold, the previous row
//   - the grid: the previous cell
@(command={name="Project/Collapse", palette=false, help="Closes the selected folder, or steps to its parent. In the file list, folds the selected file's sub-assets, or selects the previous row. In the grid, selects the previous cell"})
project_collapse :: proc() {
    if _pv.active_pane == .List {
        if _pv.grid_cols > 0 do _project_list_step(-1, false)
        else if !_project_list_fold() do _project_list_step(-1, false)
        return
    }
    cur := _project_tree_index()
    if cur == -1 do return
    row := _pv.tree_rows[cur]
    if row.open {
        _project_tree_request_open(row.path, false)
    } else if parent, ok := _project_parent_dir(row.path); ok {
        _project_set_current(parent)
        _pv.scroll_to_tree_sel = true
    }
}

// In the grid Left and Right move between cells, so the sub-assets of the
// selected file unfold and fold on these two. They work on the list's rows too.
@(command={name="Project/Unfold Sub-assets", enabled=project_list_active, palette=false, help="Shows the selected file's sub-assets"})
project_unfold :: proc() { _project_list_unfold() }

@(command={name="Project/Fold Sub-assets", enabled=project_list_active, palette=false, help="Hides the selected file's sub-assets. On a sub-asset, selects its file"})
project_fold :: proc() { _project_list_fold() }

// Shift with Left and Right grows the grid's selection by the next cell.
@(command={name="Project/Extend Selection Right", enabled=project_grid_active, palette=false, help="Adds the next cell to the selection"})
project_extend_right :: proc() { _project_list_step(1, true) }

@(command={name="Project/Extend Selection Left", enabled=project_grid_active, palette=false, help="Adds the previous cell to the selection"})
project_extend_left :: proc() { _project_list_step(-1, true) }

project_grid_active :: proc() -> bool {
    return (_pv.active_pane == .List && _pv.grid_cols > 0) || keymap.disabled("Works in the file grid only")
}

// Tab into the list selects its first row when nothing there is selected.
@(command={name="Project/Switch Pane", palette=false, help="Moves the keyboard between the folder tree and the file list"})
project_switch_pane :: proc() {
    switch _pv.active_pane {
    case .Tree:
        _pv.active_pane = .List
        _project_list_ensure_selection()
    case .List:
        _pv.active_pane = .Tree
    }
}

// The tree renames the shown folder, the list the selected row.
@(command={name="Project/Rename", help="Renames the selected file, or the folder the tree shows"})
project_rename :: proc() {
    switch _pv.active_pane {
    case .Tree: _project_begin_rename(_pv.current_path, true)
    case .List: _project_begin_rename_selected()
    }
}

@(command={name="Project/Open", enabled=project_list_active, help="Opens the selected folder or asset"})
project_open :: proc() { _project_open_selected() }

@(command={name="Project/Up Level", enabled=project_list_active, help="Shows the parent folder"})
project_up_level :: proc() { _project_go_up() }

// Escape ends a search from either pane, and opens the selected hit's
// folder (_project_cancel_search). Escape in the search box reverts its text
// first.
@(command={name="Project/Cancel Search", enabled=project_has_search, palette=false, help="Ends the search and shows the selected result's folder"})
project_cancel_search :: proc() { _project_cancel_search() }

project_has_search :: proc() -> bool {
    return strings.trim_space(string(cstring(raw_data(_pv.search_buf[:])))) != "" || keymap.disabled("The Project window has no search")
}

project_list_active :: proc() -> bool { return _pv.active_pane == .List || keymap.disabled("Works in the file list only") }

// Not while a row is being renamed, nor the frame the rename closed.
project_keys_active :: proc() -> bool {
    return !_pv.rename_active && !_pv.rename_just_finished
}

// Platform file-manager conventions: macOS renames on Enter, opens with
// Cmd+Down and goes up with Cmd+Up, elsewhere F2 renames, Enter opens and
// Backspace goes up. imgui reads the physical Cmd key as Ctrl on macOS, so
// Ctrl in a chord is Cmd there.
@(keymap={name="Project", window="Project", active=project_keys_active})
project_keymap :: proc(km: ^keymap.Keymap) {
    keymap.bind(km, "Down", "Project/Select Down", repeat = true)
    keymap.bind(km, "Shift+Down", "Project/Extend Selection Down", repeat = true)
    keymap.bind(km, "Up", "Project/Select Up", repeat = true)
    keymap.bind(km, "Shift+Up", "Project/Extend Selection Up", repeat = true)
    keymap.bind(km, "Right", "Project/Expand", repeat = true)
    keymap.bind(km, "Left", "Project/Collapse", repeat = true)
    keymap.bind(km, "Ctrl+Right", "Project/Unfold Sub-assets")
    keymap.bind(km, "Ctrl+Left", "Project/Fold Sub-assets")
    keymap.bind(km, "Shift+Right", "Project/Extend Selection Right", repeat = true)
    keymap.bind(km, "Shift+Left", "Project/Extend Selection Left", repeat = true)
    keymap.bind(km, "Tab", "Project/Switch Pane")
    // macOS renames on Enter and opens on Cmd+Down, as its file browser does.
    keymap.bind(km, "F2", "Project/Rename", mac = "Enter")
    keymap.bind(km, "Enter", "Project/Open", mac = "Ctrl+Down")
    keymap.bind(km, "Backspace", "Project/Up Level", mac = "Ctrl+Up")
    // The Edit menu's commands act on the project selection when it is the
    // active one (edit_menu.odin), so the window binds them instead of its own.
    keymap.bind(km, "Ctrl+C", "Edit/Copy")
    keymap.bind(km, "Ctrl+X", "Edit/Cut")
    keymap.bind(km, "Ctrl+V", "Edit/Paste")
    keymap.bind(km, "Ctrl+D", "Edit/Duplicate")
    keymap.bind(km, "Ctrl+Backspace", "Edit/Delete")
    keymap.bind(km, "Ctrl+Delete", "Edit/Delete")
    keymap.bind(km, "Escape", "Project/Cancel Search")
}
