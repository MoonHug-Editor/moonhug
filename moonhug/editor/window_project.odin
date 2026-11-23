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
import "drag"
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
    // When the tree's rows were built, and what makes them stale
    // (_project_tree_build).
    tree_dirty: bool,
    tree_gen: u64,
    tree_built_ns: i64,
    // Folder open state, keyed by full path (persistent, owned clones).
    // Written after each TreeNodeEx, read next frame to pick the open/closed
    // folder icon.
    tree_open_state: map[string]bool,
    list_rows: [dynamic]Project_Row,
    // The rows' strings. Each arena resets when its list is rebuilt, so the
    // rows stay valid between draws, where the keymap's commands read them.
    tree_arena: virtual.Arena,
    list_arena: virtual.Arena,
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
    // The search box filters in place instead of searching the project: the
    // folder the list shows keeps its folders and shows the files that match.
    filter_mode: bool,
    filtering: bool, // this frame: filter_mode with words in the box
    // What the hits say for a filter: the files that match, a file that
    // holds a matching sub-asset among them, and every folder with one of
    // them somewhere under it. The keys are parts of the hits' own paths.
    filter_files: map[string]bool,
    filter_dirs: map[string]bool,
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
    delete(pv.rename_path)
    delete(pv.ping_path)
    delete(pv.range_pending)
    delete(pv.search_for)
    for h in pv.search_hits do delete(h.path)
    delete(pv.search_hits)
    delete(pv.filter_files)
    delete(pv.filter_dirs)
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
    path:    string, // full path
    name:    string, // what the row shows: the folder's name, a package's
    depth:   int,
    has_sub: bool,   // it has subfolders: a fold arrow
    is_link: bool,
    open:    bool,   // it shows its subfolders
}
Project_Row :: struct {
    name:    string, // display text
    path:    string, // full path; drives selection/rename/activation (display
                     // names collide across folders in search results)
    is_dir:  bool,
    is_link: bool,
    sub:     core.Local_ID, // not 0: the sub-asset of the file at `path` with this id
    hit:     bool,          // a sub-asset found by a search: its file is beside its name
    faded:   bool,          // a folder with no file that passes the filter under it
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
    project_file_ops_init()
    _project_window_init(&_pv_plain)
}

shutdown_project_window :: proc() {
    project_file_ops_shutdown()
    os_drop_shutdown()
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
    _project_tree_set_open(path, open)
}

// Cancel an active search: clear the query and navigate to the selected item —
// its containing folder opens with the item still selected and revealed in the
// tree, so the highlighted hit doesn't vanish.
_project_cancel_search :: proc() {
    mem.zero(&_pv.search_buf, len(_pv.search_buf))
    // A filter never left the folder: nothing to go to.
    if _pv.filter_mode do return
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
    // Navigating to a folder leaves search mode: the list shows the folder
    // now. A filter stays, it is about whatever folder is shown.
    if !_pv.filter_mode do mem.zero(&_pv.search_buf, len(_pv.search_buf))
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
// __type_guid instances): generic .asset, .mat, and the file of every
// @(asset) type no importer reads (.noise, .renderpipeline, .mixer).
//
// A .anim is NOT here: it is importer-backed, so it routes to the import
// settings panel below and its wrap, frame rate, cycle offset and trim are
// edited there — in the .meta, which survives re-extracting the model.
_is_inspector_asset :: proc(path: string) -> bool {
    if strings.has_suffix(path, ".asset") || strings.has_suffix(path, ".mat") do return true
    // The file of an @(asset) type no importer reads: its document.
    kind := strings.trim_prefix(strings.to_lower(filepath.ext(path), context.temp_allocator), ".")
    if kind == "" do return false
    for c in subassets.creatables() do if c.kind == kind do return subassets.can_live_inside(kind)
    return false
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
    project_record_moves({{old_path, new_path}}, "Rename")
    project_pins_moved(old_path, new_path)
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
            // A folder above the shown one, as a place for a drag.
            _project_folder_drop_target(c.path)
        }
        if i < len(segments) - 1 do im.SameLine(0, 0)
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

// The grid: a cell per row of the list pane, a thumbnail or the scaled type
// glyph with the name below (_project_list_draw_grid).

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
        _project_sub_asset_drag(parent_path, guid, s, fmt.ctprintf("%s%s", icons.ICON_MD_IMAGE, s.name))
        _project_item_ping_flash(parent_path, s.id)
        if is_selected && _pv.scroll_to_list_sel {
            im.SetScrollHereY()
            _pv.scroll_to_list_sel = false
        }
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
    cdisplay, cut := _project_fit_name(s.name, cell)
    tsize := im.CalcTextSize(cdisplay)
    im.DrawList_AddText(dl,
        im.Vec2{rect_min.x + max((cell - tsize.x) * 0.5, 0), rect_min.y + cell},
        im.GetColorU32(.Text), cdisplay)
    if cut && im.IsItemHovered({}) && drag.items() == nil do _project_name_tooltip(s.name)
}

// One grid cell: a folder's or a file's.
_project_draw_grid_cell :: proc(display: string, full_path: string, is_dir: bool, cell: f32, is_link := false, faded := false) {
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
    dim := faded || (!is_dir && !is_known_extension(full_path)) || project_file_is_cut(full_path)

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
    if is_dir && im.IsItemHovered({}) && _project_os_drag() do _project_os_place(full_path, rect_min, im.Vec2{rect_min.x + cell, rect_min.y + cell + label_h})
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

    // Name centered under the art. One too long for the cell is cut in the
    // middle, and the whole name shows when the pointer rests on the cell.
    dl := im.GetWindowDrawList()
    star := _project_dirty_star(full_path)
    cdisplay, cut := _project_fit_name(display, cell - im.CalcTextSize(strings.clone_to_cstring(star, context.temp_allocator)).x)
    if star != "" do cdisplay = fmt.ctprintf("%s%s", cdisplay, star)
    tsize := im.CalcTextSize(cdisplay)
    text_col := im.GetStyleColorVec4(im.Col.Text)^
    if dim do text_col = {text_col.x * 0.6, text_col.y * 0.6, text_col.z * 0.6, text_col.w}
    im.DrawList_AddText(dl,
        im.Vec2{rect_min.x + max((cell - tsize.x) * 0.5, 0), rect_min.y + cell},
        im.GetColorU32ImVec4(text_col), cdisplay)
    if cut && mouse.x >= rect_min.x && mouse.x < rect_min.x + cell && mouse.y >= rect_min.y && mouse.y < rect_min.y + cell + label_h && im.IsWindowHovered({}) && drag.items() == nil {
        _project_name_tooltip(display)
    }
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
_project_dirty_star :: proc(path: string) -> string {
    if len(_project_dirty_paths) == 0 do return ""
    clean, _ := filepath.clean(path, context.temp_allocator)
    return " *" if clean in _project_dirty_paths else ""
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

_project_sub_asset_drag :: proc(parent_path: string, guid: core.Asset_GUID, s: subassets.Sub_Asset, drag_label: cstring) {
    if im.BeginDragDropSource({}) {
        items := _project_drag_items(parent_path, s.id, core.PPtr{guid = guid, local_id = s.id})
        drag.source(items, len(items) > 1 ? fmt.tprintf("%d assets", len(items)) : string(drag_label))
        im.EndDragDropSource()
    }
}

// What a drag from a Project row carries: the selection's files, folders and
// sub-assets when the row is selected, else the row's own item `own`.
@(private = "file")
_project_drag_items :: proc(path: string, sub_id: core.Local_ID, own: drag.Item) -> []drag.Item {
    out := make([dynamic]drag.Item, context.temp_allocator)
    selected := sub_id == 0 ? sel_proj_is(path) : sel_proj_is_sub(path, sub_id)
    if selected && len(_sel_proj) > 1 {
        for e in _sel_proj {
            if e.sub_id == 0 && assets.asset_db_is_dir(e.path) {
                if !project_path_is_protected(e.path) do append(&out, drag.Item(drag.Folder{path = e.path}))
                continue
            }
            guid, ok := assets.asset_db_get_guid(e.path)
            if !ok do continue
            append(&out, drag.Item(core.PPtr{guid = core.Asset_GUID(guid), local_id = e.sub_id}))
        }
    }
    if len(out) == 0 && own != nil do append(&out, own)
    return out[:]
}


// A folder of the Project window as a drop target: the drag's items go to
// the rules for a Project folder.
_project_folder_drop_target :: proc(folder: string) {
    if folder == "" || folder == _PROJECT_PACKAGES_PATH do return
    if drag.items() == nil || !im.BeginDragDropTarget() do return
    drag.target(drag.Project_Place{folder = folder})
    im.EndDragDropTarget()
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

// Right-click select and the drag source, on the LAST item, and the item as
// a drop place: a folder, or the folder of a file.
_project_item_extras :: proc(full_path: string, is_dir: bool, drag_label: cstring) {
    _project_folder_drop_target(full_path if is_dir else filepath.dir(full_path))
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
        _project_inspectors_refresh()
    }
    if project_path_is_protected(full_path) do return
    if im.BeginDragDropSource({}) {
        items := _project_drag_items(full_path, 0, _project_drag_item(full_path, is_dir))
        if len(items) > 0 do drag.source(items, len(items) > 1 ? fmt.tprintf("%d items", len(items)) : string(drag_label))
        im.EndDragDropSource()
    }
}

// What a file or a folder drags as: a file its asset, a folder itself. nil
// for a file the database does not know.
@(private = "file")
_project_drag_item :: proc(path: string, is_dir: bool) -> drag.Item {
    if is_dir do return drag.Folder{path = path}
    if guid, ok := assets.asset_db_get_guid(path); ok do return core.PPtr{guid = core.Asset_GUID(guid)}
    return nil
}


// The assets that match `query`, files sorted by path and then sub-assets.
// Found once per query and kept while the files and the sub-asset lists stay
// the same, since a search draws every frame.
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
    // For a filter: the files that match and the folders above them. One
    // pass over the hits, here where they change, never per frame.
    {
        context.allocator = runtime.default_allocator()
        clear(&_pv.filter_files)
        clear(&_pv.filter_dirs)
        for h in _pv.search_hits {
            if h.is_dir {
                _pv.filter_dirs[h.path] = true
            } else {
                _pv.filter_files[h.path] = true
            }
            above := h.path
            for {
                i := strings.last_index(above, "/")
                if i <= 0 do break
                above = above[:i]
                if above in _pv.filter_dirs do break
                _pv.filter_dirs[above] = true
            }
        }
    }
    return _pv.search_hits[:]
}

// The path of the one selected item, for the list pane's footer: a file or a
// folder, or a sub-asset as its file's path and its own name. "" with none or
// several selected.
@(private = "file")
_project_selected_where :: proc() -> string {
    entries := sel_proj_entries()
    if len(entries) != 1 do return ""
    e := entries[0]
    if e.sub_id == 0 do return e.path
    if ref, _, ok := _project_sub_ref(e.path, e.sub_id); ok {
        if s, found := subassets.get(ref); found do return fmt.tprintf("%s / %s", e.path, s.name)
    }
    return e.path
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

// The window menu's setting for the filter: a folder with no match under it
// is left out of the list instead of faded.
@(window_menu={window="Project", label="Filter Hides Folders Without Matches", checked=project_filter_hides_checked})
project_filter_hides_toggle :: proc(window: session.Window_Ref) {
    editor_settings.project_filter_hides = !editor_settings.project_filter_hides
}

project_filter_hides_checked :: proc(window: session.Window_Ref) -> bool {
    return editor_settings.project_filter_hides
}

// The menu of a right click in either pane: the Edit menu's selection band
// (Cut, Copy, Paste, Duplicate, Rename, Delete), which acts on the selected
// files here, then the Assets menu up to its database band.
_project_context_menu :: proc() {
    menu.draw_menu_sections({
        menu.section("Edit", min_order = menu.EDIT_SECTION_SELECTION_MIN, max_order = menu.EDIT_SECTION_SELECTION_MAX),
        menu.section("Assets", max_order = menu.ASSETS_SECTION_DATABASE - 1),
    })
}

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
    // "+" creates an asset in the folder the list shows.
    if im.Button(icons.ICON_MD_ADD + "###prj_create", im.Vec2{clear_btn_w, 0}) do im.OpenPopup("##ProjectCreate")
    widgets.tooltip("Create an asset in the open folder")
    if im.BeginPopup("##ProjectCreate") {
        menu.draw_menu_sections({menu.section("Assets/Create")})
        im.EndPopup()
    }
    im.SameLine()
    // Right of the box: "x" while it has words, then the mode. Searching
    // lists the hits of the whole project. Filtering uses the same words in
    // place: the folder shown keeps its folders and shows the files that match.
    right := clear_btn_w + im.GetStyle().ItemSpacing.x
    im.SetNextItemWidth(-(right * 2) if query != "" else -right)
    // NoTabStop: Tab must switch panes (the keymap), never tab-focus the
    // search box. Clicking into it still works.
    im.PushItemFlag({.NoTabStop}, true)
    hint := cstring("Filter: name, t:Type, c:Component") if _pv.filter_mode else cstring("Search: name, t:Type, c:Component")
    im.InputTextWithHint("##prj_search", hint, cstring(raw_data(_pv.search_buf[:])), c.size_t(len(_pv.search_buf)), {})
    im.PopItemFlag()
    if query != "" {
        im.SameLine()
        if im.Button(icons.ICON_MD_CLOSE + "###prj_search_clear", im.Vec2{clear_btn_w, 0}) {
            _project_cancel_search()
            query = ""
        }
    }
    im.SameLine()
    if _pv.filter_mode do im.PushStyleColorImVec4(.Button, im.GetStyleColorVec4(.ButtonActive)^)
    toggle := im.Button(icons.ICON_MD_FILTER_LIST + "###prj_filter_mode", im.Vec2{clear_btn_w, 0})
    if _pv.filter_mode do im.PopStyleColor()
    widgets.tooltip("Filter in place: the folder shown keeps its folders and shows only the files that match the words. Off: the words search the whole project")
    if toggle do _pv.filter_mode = !_pv.filter_mode
    searching := query != "" && !_pv.filter_mode
    _pv.filtering = query != "" && _pv.filter_mode

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

    _project_tree_build()
    _project_tree_draw()
    // Files dragged in from the OS land on the folder under the pointer.
    _project_os_drop("", im.GetWindowPos(), im.GetWindowPos() + im.GetWindowSize())

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

    _pv.grid_cols = 0
    result_count := _project_list_build(query if searching else "", query if _pv.filtering else "")

    // Where the list is, or what the selection is: above the rows, where
    // the search box used to sit. Text height, not frame height — nothing
    // here is a widget, so the bar stays as thin as one line.
    if searching {
        im.TextUnformatted(strings.clone_to_cstring(fmt.tprintf("%d found", _pv.result_count), context.temp_allocator))
    } else if sel_proj_count() > 1 {
        im.TextUnformatted(strings.clone_to_cstring(fmt.tprintf("%d selected", sel_proj_count()), context.temp_allocator))
    } else {
        _project_draw_path_bar()
    }

    // Rows scroll in their own child so the zoom strip below stays fixed
    // at the bottom of the pane.
    // Reserve exactly the strip: the slider's own height (text plus the
    // trimmed 1px frame padding, top and bottom) and one item spacing.
    zoom_h := im.GetTextLineHeight() + 2 + im.GetStyle().ItemSpacing.y
    // No background of its own: the pane's shows through, as in the tree.
    im.PushStyleColorImVec4(.ChildBg, {})
    im.BeginChild("FileRows", im.Vec2{0, -zoom_h}, {})
    im.PopStyleColor()
    // The child insets its contents on the left by the window padding;
    // match it above the first row, so the list does not touch the top
    // edge (imgui applies no padding on the scrolling axis).
    im.Dummy({0, im.GetStyle().WindowPadding.y - im.GetStyle().ItemSpacing.y})
    // The zoom slider's low end is rows, anything above it a grid of
    // thumbnails scaling with the value. The packages are always rows.
    if editor_settings.project_zoom > 0 && (searching || _pv.current_path != _PROJECT_PACKAGES_PATH) {
        _project_list_draw_grid(40 + editor_settings.project_zoom * 56)
    } else {
        _project_list_draw_rows()
    }
    // Files dragged in from the OS land on the folder under the pointer, or
    // in the folder the list shows.
    _project_os_drop(_pv.current_path if !searching else "", im.GetWindowPos(), im.GetWindowPos() + im.GetWindowSize())
    // The rest of the pane is the open folder, as a drop target. A rect of
    // its own, no item: clicks there stay the pane's.
    if !searching && drag.items() != nil && _pv.current_path != _PROJECT_PACKAGES_PATH {
        if avail := im.GetContentRegionAvail(); avail.y > 8 && avail.x > 8 {
            from := im.GetCursorScreenPos()
            if im.BeginDragDropTargetCustom({from, from + avail}, im.GetID("##prj_open_folder_drop")) {
                drag.target(drag.Project_Place{folder = _pv.current_path})
                im.EndDragDropTarget()
            }
        }
    }
    if im.BeginPopupContextWindow("ProjectFileListContext", im.PopupFlags_MouseButtonRight) {
        _project_context_menu()
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
    zoom_x := max(im.GetCursorPosX(), im.GetWindowWidth() - zoom_w - im.GetStyle().WindowPadding.x)
    // Left of it, where the selected item is: its path, or its file's and
    // its own name for a sub-asset.
    if where_ := _project_selected_where(); where_ != "" {
        shown, cut := _project_fit_name(where_, zoom_x - im.GetCursorPosX() - im.GetStyle().ItemSpacing.x)
        im.AlignTextToFramePadding()
        im.TextDisabled("%s", shown)
        if cut && im.IsItemHovered({}) do _project_name_tooltip(where_)
        im.SameLine()
    }
    im.SetCursorPosX(zoom_x)
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

// Adds a row to the list pane's rows, its strings in the window's row arena.
_project_list_row_add :: proc(name, path: string, is_dir: bool, sub: core.Local_ID = 0, is_link := false, hit := false, faded := false) {
    a := virtual.arena_allocator(&_pv.list_arena)
    append(&_pv.list_rows, Project_Row{name = strings.clone(name, a), path = strings.clone(path, a), is_dir = is_dir, sub = sub, is_link = is_link, hit = hit, faded = faded})
}

// The rows of an unfolded file's sub-assets follow their file's row.
_project_list_rows_add_subs :: proc(path: string, sub: []subassets.Sub_Asset) {
    for s in sub do _project_list_row_add(s.name, path, false, s.id)
}

// The row index of the shown folder in the tree, -1 for none.
_project_tree_index :: proc() -> int {
    for r, i in _pv.tree_rows do if r.path == _pv.current_path do return i
    return -1
}

// The row index of the active selection in the list, -1 for none.
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
    // Cut, Copy, Paste, Duplicate and Delete are the Edit menu's, with its
    // keys: they act on the selection wherever it is (edit_menu.odin). The
    // Delete key is bound per window, since other windows have a Delete of
    // their own.
    keymap.bind(km, "Delete", "Edit/Delete")
    keymap.bind(km, "Ctrl+Delete", "Edit/Delete")
    keymap.bind(km, "Escape", "Project/Cancel Search")
}
