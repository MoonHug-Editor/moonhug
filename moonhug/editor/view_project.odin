package editor

import "base:runtime"

import "core:c"
import "core:fmt"
import "core:mem"
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

// What every Project copy shares: the selection's active path (the
// selection is editor-wide, selection.odin) and the assets root.
ProjectViewData :: struct {
    selectedFile: string,
    rootPath: string,
}

projectViewData: ProjectViewData

PROJECT :: "Project"

// One Project copy's own state. The first copy's lives in _pv_plain and
// outlives its window, a copy opened from Add Tab has its own in its
// wnd.Window.
Project_View :: struct {
    current_path: string, // the folder the list shows, owned (_project_set_current)
    // Keyboard navigation works like the hierarchy's: rows visible this frame
    // are collected in draw order, then keys are handled after drawing (so
    // index math matches what's on screen). Each pane only reacts while its
    // child window has focus.
    tree_rows: [dynamic]Project_Tree_Row,
    // Folder open state, keyed by full path (persistent, owned clones).
    // Written after each TreeNodeEx, read next frame to pick the open/closed
    // folder icon.
    tree_open_state: map[string]bool,
    list_rows: [dynamic]Project_Row,
    // One-shot fold command for a tree node (applied next frame via SetNextItemOpen).
    tree_set_open_path: string, // owned clone; "" = no pending command
    tree_set_open_val: bool,
    // When the right pane navigates, open the ancestor chain in the tree so
    // the highlighted folder is visible.
    tree_reveal: bool,
    scroll_to_tree_sel: bool,
    scroll_to_list_sel: bool,
    // Which pane keyboard input routes to, set when a pane is clicked or
    // hovered, toggled by Tab.
    active_pane: Project_Pane,
    // Search over ALL files and folders under the assets root (not the
    // current folder). Non-empty query swaps the file list for asset-DB
    // search results; keyboard nav follows whichever rows are drawn.
    search_buf: [256]byte,
    // Ping flash: fading row highlight WITHOUT changing selection.
    ping_path: string, // owned; "" = no active ping
    ping_deadline_ns: i64,
    scroll_to_ping: bool,
    rename_active: bool,
    rename_path: string,   // owned clone of the full path being renamed
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
    search_hits: [dynamic]Project_Search_Hit,
}

// A search hit: an asset path and whether it is a folder.
Project_Search_Hit :: struct {
    path:   string, // owned
    is_dir: bool,
}

@(private = "file")
_pv_plain: Project_View

// The copy being drawn, and outside a draw the copy clicked in last, which
// menu actions and asset requests act on.
_pv: ^Project_View = &_pv_plain

// A copy's state: the first copy's is _pv_plain, another is made on its
// first frame, showing the assets root.
@(private = "file")
_project_view :: proc(w: ^wnd.Window) -> ^Project_View {
    if w.key == PROJECT do return &_pv_plain
    if w.data == nil {
        pv := new(Project_View, runtime.default_allocator())
        _project_view_init(pv)
        w.data = pv
    }
    return (^Project_View)(w.data)
}

// current_path is on the default allocator (_project_set_current), the rest
// on the caller's, as the draw that grows it.
@(private = "file")
_project_view_init :: proc(pv: ^Project_View) {
    pv.current_path = strings.clone("assets", runtime.default_allocator())
    pv.active_pane = .List
    pv.path_hovered = -1
    pv.split_ratio = 0.5
    // Start with the root folder expanded (one-shot; consumed on first draw).
    pv.tree_set_open_path = strings.clone("assets")
    pv.tree_set_open_val = true
}

@(private = "file")
_project_view_free :: proc(pv: ^Project_View) {
    delete(pv.current_path, runtime.default_allocator())
    delete(pv.tree_rows)
    delete(pv.list_rows)
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

project_view_closed :: proc(w: ^wnd.Window) {
    if w.key == PROJECT do return
    pv := (^Project_View)(w.data)
    if pv == nil do return
    if _pv == pv do _pv = &_pv_plain
    _project_view_free(pv)
    free(pv, runtime.default_allocator())
    w.data = nil
}

// Keyboard navigation works like the hierarchy's: rows visible this frame are
// collected in draw order, then keys are handled after drawing (so index math
// matches what's on screen). Each pane only reacts while its child window has
// focus.
Project_Tree_Row :: struct {
    path: string, // full path, temp-allocated, rebuilt each frame
    open: bool,   // imgui tree node open state this frame
}
Project_Row :: struct {
    name:   string, // display text, temp-allocated, rebuilt each frame
    path:   string, // full path; drives selection/rename/activation (display
                    // names collide across folders in search results)
    is_dir: bool,
}

// Which pane keyboard input routes to. Tracked ourselves rather than via imgui
// child focus (SetWindowFocus/IsWindowFocused are unreliable for child windows).
// Set when a pane is clicked/hovered; toggled by Tab.
Project_Pane :: enum { Tree, List }

_PROJECT_PING_NS :: i64(800_000_000)

init_project_view :: proc() {
    // The asset DB is rooted at "assets" (relative to the normalized moonhug/
    // cwd); the project window mirrors it so paths line up with asset lookups.
    projectViewData.rootPath = strings.clone("assets")
    _project_view_init(&_pv_plain)
}

shutdown_project_view :: proc() {
    project_file_ops_shutdown()
    project_package_samples_shutdown()
    project_dir_cache_shutdown()
    delete(projectViewData.rootPath)
    if projectViewData.selectedFile != "" {
        delete(projectViewData.selectedFile, runtime.default_allocator()) // see _project_set_active
    }
    _project_view_free(&_pv_plain)
}

// Platform file-manager conventions: macOS renames on Enter, opens with
// Cmd+Down and goes up with Cmd+Up (Finder); elsewhere F2 renames, Enter
// opens, Backspace goes up (Explorer).
// imgui swaps Cmd<>Ctrl on macOS at AddKeyEvent time (ConfigMacOSXBehaviors is
// on by default for __APPLE__), so the physical Cmd key reads as io.KeyCtrl.
_project_cmd_down :: proc() -> bool {
    when ODIN_OS == .Darwin {
        return im.GetIO().KeyCtrl
    } else {
        return im.GetIO().KeySuper
    }
}

_project_key_rename :: proc() -> bool {
    when ODIN_OS == .Darwin {
        return im.IsKeyPressed(im.Key.Enter) && !_project_cmd_down()
    } else {
        return im.IsKeyPressed(im.Key.F2)
    }
}

_project_key_open :: proc() -> bool {
    when ODIN_OS == .Darwin {
        return _project_cmd_down() && im.IsKeyPressed(im.Key.DownArrow)
    } else {
        return im.IsKeyPressed(im.Key.Enter)
    }
}

_project_key_up_level :: proc() -> bool {
    when ODIN_OS == .Darwin {
        return _project_cmd_down() && im.IsKeyPressed(im.Key.UpArrow)
    } else {
        return im.IsKeyPressed(im.Key.Backspace)
    }
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
    delete(projectViewData.selectedFile)
    projectViewData.selectedFile = new_path
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
    anchor := projectViewData.selectedFile
    a_idx, t_idx := -1, -1
    for r, i in _pv.list_rows {
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
        sel_proj_add(_pv.list_rows[i].path)
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
    sel := projectViewData.selectedFile
    if sel != "" && os.exists(sel) {
        parent := filepath.dir(sel) // slice into sel — don't delete
        if parent == "" {
            parent = projectViewData.rootPath
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
    return strings.has_suffix(path, ".asset") || strings.has_suffix(path, ".mat")
}

// Selection-driven inspector routing — the ONE code path shared by mouse
// clicks and keyboard navigation in both panes: package roots open the
// package inspector, JSON assets the asset inspector, importables their
// import settings. Anything else leaves the inspector as it is.
_project_inspect_path :: proc(full_path: string) {
    // Every unlocked Project Inspector instance shows the selection. A locked
    // one keeps its asset, unsaved edits included.
    for data in inspector.route_targets() {
        inspector.inspectorData = data
        _project_inspect_one(full_path)
    }
    inspector.inspector_data_reset()
}

// Shows `full_path` in the Project Inspector instance inspector.inspectorData
// points at.
@(private = "file")
_project_inspect_one :: proc(full_path: string) {
    if project_path_is_package_root(full_path) {
        inspector.load_package(project_package_root_name(full_path), full_path, _project_package_asset_count(full_path))
        return
    }
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
    _project_inspect_path(full_path)
    _project_open_file(full_path)
}

// Opens a file's document: a scene in the scene view, any other asset in the
// editor its package registered for the extension (asset_open_handler_add).
_project_open_file :: proc(full_path: string) {
    if strings.has_suffix(full_path, ".scene") {
        editor_open_scene(full_path)
        return
    }
    _ = asset_pipeline.asset_open(full_path)
}

_project_open_selected :: proc() {
    sel := projectViewData.selectedFile
    if sel == "" do return
    for r in _pv.list_rows {
        if r.path != sel do continue
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
    _pv.rename_active = true
    _pv.rename_in_tree = in_tree
    _pv.rename_focus = true
    _pv.rename_focus_tries = 0
    if _pv.rename_path != "" do delete(_pv.rename_path)
    _pv.rename_path = strings.clone(full_path)
    mem.zero(&_pv.rename_buf, len(_pv.rename_buf))
    copy_len := min(len(name), len(_pv.rename_buf) - 1)
    mem.copy(&_pv.rename_buf[0], raw_data(name), copy_len)
}

_project_begin_rename_selected :: proc() {
    sel := projectViewData.selectedFile
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
    if !_pv.rename_active || _pv.rename_path != full_path do return false
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
        append(&_pv.tree_rows, Project_Tree_Row{path = full_path, open = false})
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
    append(&_pv.tree_rows, Project_Tree_Row{path = full_path, open = open})
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

    // Handle selection (a package root also opens the package inspector).
    if im.IsItemClicked() {
        _project_set_current(full_path)
        _project_inspect_path(full_path)
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

_project_handle_tree_keys :: proc() {
    // The frame a rename closes, its Enter/Escape press is still down — swallow
    // it so it doesn't immediately re-trigger a rename or navigation.
    if _pv.rename_just_finished {
        _pv.rename_just_finished = false
        return
    }
    if _pv.rename_active do return

    if im.IsKeyPressed(im.Key.Tab) {
        _pv.active_pane = .List
        _project_list_ensure_selection()
        return
    }
    if _project_key_rename() {
        _project_begin_rename(_pv.current_path, true)
        return
    }
    n := len(_pv.tree_rows)
    if n == 0 do return
    if _project_cmd_down() do return // cmd+arrows belong to the file list pane

    cur := -1
    for r, i in _pv.tree_rows {
        if r.path == _pv.current_path {
            cur = i
            break
        }
    }

    _tree_select :: proc(idx: int) {
        _project_set_current(_pv.tree_rows[idx].path)
        _project_inspect_path(_pv.tree_rows[idx].path)
        _pv.scroll_to_tree_sel = true
    }

    if im.IsKeyPressed(im.Key.DownArrow) {
        if cur == -1 {
            _tree_select(0)
        } else if cur + 1 < n {
            _tree_select(cur + 1)
        }
        return
    }
    if im.IsKeyPressed(im.Key.UpArrow) {
        if cur == -1 {
            _tree_select(0)
        } else if cur - 1 >= 0 {
            _tree_select(cur - 1)
        }
        return
    }

    if cur == -1 do return
    sel := _pv.tree_rows[cur].path
    open := _pv.tree_rows[cur].open
    has_child_rows := cur + 1 < n && _project_path_is_ancestor(sel, _pv.tree_rows[cur+1].path)

    if im.IsKeyPressed(im.Key.RightArrow) {
        if open && has_child_rows {
            _tree_select(cur + 1) // step into first child
        } else {
            _project_tree_request_open(sel, true)
        }
        return
    }
    if im.IsKeyPressed(im.Key.LeftArrow) {
        // An open folder collapses first — even one that shows no subfolders
        // (imgui still tracks its open state). Only when already collapsed does
        // Left jump to the parent (package roots jump to the Packages node,
        // roots themselves stay put — _project_parent_dir knows the shape).
        if open {
            _project_tree_request_open(sel, false)
        } else if parent, pok := _project_parent_dir(sel); pok {
            _project_set_current(parent)
            _pv.scroll_to_tree_sel = true
        }
        return
    }
}

// A fresh Tab into the list pane with no valid selection lands on the first
// row (rows persist from the last draw — same folder). Only called on the Tab
// transition: running it every frame auto-selected the first file whenever a
// folder click cleared the selection, polluting selection undo history.
_project_list_ensure_selection :: proc() {
    n := len(_pv.list_rows)
    if n == 0 do return
    for r in _pv.list_rows {
        if r.path == projectViewData.selectedFile do return // already valid
    }
    _project_set_selected(_pv.list_rows[0].path)
    _pv.scroll_to_list_sel = true
}

_project_handle_list_keys :: proc() {
    // The frame a rename closes, its Enter/Escape press is still down — don't
    // let it immediately re-trigger navigation or another rename.
    if _pv.rename_just_finished {
        _pv.rename_just_finished = false
        return
    }
    if _pv.rename_active do return

    if im.IsKeyPressed(im.Key.Tab) {
        _pv.active_pane = .Tree
        return
    }

    if _project_key_up_level() {
        _project_go_up()
        return
    }
    if _project_key_open() {
        _project_open_selected()
        return
    }
    if _project_key_rename() {
        _project_begin_rename_selected()
        return
    }

    if _project_cmd_down() {
        if im.IsKeyPressed(im.Key.C) do project_ops_copy()
        if im.IsKeyPressed(im.Key.X) do project_ops_cut()
        if im.IsKeyPressed(im.Key.V) do project_ops_paste()
        if im.IsKeyPressed(im.Key.D) do project_ops_duplicate()
        if im.IsKeyPressed(im.Key.Backspace) || im.IsKeyPressed(im.Key.Delete) do project_ops_delete()
        return
    }
    n := len(_pv.list_rows)
    if n == 0 do return

    cur := -1
    for r, i in _pv.list_rows {
        if r.path == projectViewData.selectedFile {
            cur = i
            break
        }
    }

    // Plain arrows move the (single) selection; shift+arrows EXTEND it — the
    // stepped-onto row joins the selection and becomes active.
    shift := im.GetIO().KeyShift

    _list_select :: proc(idx: int, extend: bool) {
        path := _pv.list_rows[idx].path
        if extend {
            sel_proj_add(path)
            _project_set_active(path)
        } else {
            _project_set_selected(path)
        }
        _project_inspect_path(path)
        _pv.scroll_to_list_sel = true
    }

    if im.IsKeyPressed(im.Key.DownArrow) {
        if cur == -1 {
            _list_select(0, false)
        } else if cur + 1 < n {
            _list_select(cur + 1, shift)
        }
        return
    }
    if im.IsKeyPressed(im.Key.UpArrow) {
        if cur == -1 {
            _list_select(0, false)
        } else if cur - 1 >= 0 {
            _list_select(cur - 1, shift)
        }
        return
    }
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
    if im.Selectable("##subcell", is_selected, {.AllowDoubleClick}, im.Vec2{cell, cell + label_h}) {
        _project_sub_asset_clicked(parent_path, guid, s, provider)
    }
    _project_sub_asset_drag(guid, s, fmt.ctprintf("%s%s", icons.ICON_MD_IMAGE, s.name))

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
    // label treatment.
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
    append(&_pv.list_rows, Project_Row{name = display, path = full_path, is_dir = is_dir})

    label_h := im.GetTextLineHeightWithSpacing()
    im.PushIDStr(strings.clone_to_cstring(full_path, context.temp_allocator), nil)
    defer im.PopID()

    // In-place rename: the art block, then the input where the label goes.
    if !_pv.rename_in_tree && _pv.rename_active && _pv.rename_path == full_path {
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

// " *" for a file with unsaved changes, the same mark its view's tab shows.
@(private = "file")
_project_dirty_star :: proc(path: string) -> string {
    if len(_project_dirty_paths) == 0 do return ""
    clean, _ := filepath.clean(path, context.temp_allocator)
    return " *" if clean in _project_dirty_paths else ""
}

// One list row. `listed`: the caller already put it in list_rows, the
// keyboard navigation list (_project_draw_rows).
_project_draw_list_row :: proc(display: string, full_path: string, is_dir: bool, is_link := false, listed := false) {
    if !listed do append(&_pv.list_rows, Project_Row{name = display, path = full_path, is_dir = is_dir})
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
// editor/subassets registry — packages register theirs, the project view
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
    _project_inspect_path(parent_path)
    if im.IsMouseDoubleClicked(.Left) && provider.open != nil {
        provider.open(parent_path, guid, s.id)
    }
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
        selected := sel_proj_is_sub(parent_path, s.id)
        label := fmt.ctprintf("%s%s", icons.ICON_MD_IMAGE, s.name)
        if im.Selectable(label, selected, {.AllowDoubleClick}) {
            _project_sub_asset_clicked(parent_path, guid, s, provider)
        }
        _project_sub_asset_drag(guid, s, label)
        if tid, uv0, uv1, tok := thumbnails.get_sub(parent_path, s); tok {
            _project_row_preview(tid, uv0, uv1, s.size.x, s.size.y)
        }
        im.PopID()
    }
    im.PopID()
    im.Unindent(indent * 2)
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
        _project_inspect_path(full_path)
        if im.IsMouseDoubleClicked(.Left) do _project_open_file(full_path)
    }
}

// Ping flash: fading highlight over the LAST item, selection untouched.
_project_item_ping_flash :: proc(full_path: string) {
    if _pv.ping_path == "" || full_path != _pv.ping_path do return
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
    if im.IsItemHovered() && im.IsMouseClicked(.Right) {
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

// Search results: every file/folder under the assets root whose NAME contains
// the query (case-insensitive), shown as root-relative paths. The asset DB
// indexes all of them (folders included) and refreshes on rename/create, so
// it's both the cheapest and the freshest source — no directory re-walk.
// Returns the match count for the status line.
_project_draw_search_results :: proc(query: string) -> int {
    hits := _project_search_hits(query)
    prefix := strings.concatenate({projectViewData.rootPath, "/"}, context.temp_allocator)
    items := make([]_Project_List_Item, len(hits), context.temp_allocator)
    for h, i in hits {
        display := h.path
        if strings.has_prefix(h.path, prefix) do display = h.path[len(prefix):]
        items[i] = {display = display, path = h.path, is_dir = h.is_dir}
    }
    _project_draw_rows(items)
    return len(hits)
}

// The assets whose names match `query`, sorted by path. Found once per query
// and kept while the files stay the same, since a search draws every frame.
// Finding them touches no file: the asset db knows which entries are folders.
@(private = "file")
_project_search_hits :: proc(query: string) -> []Project_Search_Hit {
    gen := project_dir_cache_gen()
    count := len(assets.asset_db.path_to_guid)
    if query == _pv.search_for && gen == _pv.search_gen && count == _pv.search_count {
        return _pv.search_hits[:]
    }
    delete(_pv.search_for)
    _pv.search_for = strings.clone(query)
    _pv.search_gen = gen
    _pv.search_count = count
    for h in _pv.search_hits do delete(h.path)
    clear(&_pv.search_hits)

    terms := widgets.search_terms(query)
    for path in assets.asset_db.path_to_guid {
        if widgets.search_match(filepath.base(path), terms) {
            append(&_pv.search_hits, Project_Search_Hit{path = strings.clone(path), is_dir = assets.asset_db_is_dir(path)})
        }
    }
    // Map iteration order is unstable: sorted, rows keep their places.
    slice.sort_by(_pv.search_hits[:], proc(a, b: Project_Search_Hit) -> bool { return a.path < b.path })
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
    for it in items do append(&_pv.list_rows, Project_Row{name = it.display, path = it.path, is_dir = it.is_dir})
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
// only needs the project view to show it.
_project_reveal_keep_selection :: proc(path: string) {
    mem.zero(&_pv.search_buf, len(_pv.search_buf))
    parent := filepath.dir(path) // slice into path — not owned
    if parent == "" {
        parent = projectViewData.rootPath
    }
    _project_set_current(parent)
    _pv.scroll_to_list_sel = true
    _pv.tree_reveal = true
}

_project_reveal_path :: proc(path: string, select: bool) {
    mem.zero(&_pv.search_buf, len(_pv.search_buf))
    parent := filepath.dir(path) // slice into path — not owned
    if parent == "" {
        parent = projectViewData.rootPath
    }
    // A package root's row is under the Packages node, not its own folder.
    if project_path_is_package_root(path) do parent = _PROJECT_PACKAGES_PATH
    _project_set_current(parent)
    if select {
        _project_set_selected(path)
        // Same as clicking the row: selecting a file in this view loads it into
        // the inspector, and a reveal that skipped that left the panel showing
        // whatever was there before.
        _project_inspect_path(path)
        _pv.scroll_to_list_sel = true
    } else {
        if _pv.ping_path != "" do delete(_pv.ping_path)
        _pv.ping_path = strings.clone(path)
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
    if ping_guid, ok := core.inspector_take_pending_ping_asset(); ok {
        if path, pok := assets.asset_db_get_path(uuid.Identifier(ping_guid)); pok {
            _project_reveal_path(path, select = false)
        }
    }
    if sel_guid, ok := core.inspector_take_pending_select_asset(); ok {
        if path, pok := assets.asset_db_get_path(uuid.Identifier(sel_guid)); pok {
            _project_reveal_path(path, select = true)
        }
    }
    if open_guid, ok := core.inspector_take_pending_open_asset(); ok {
        if path, pok := assets.asset_db_get_path(uuid.Identifier(open_guid)); pok {
            _project_reveal_path(path, select = true)
            _project_activate_file(path)
        }
    }

    // Files with unsaved changes get a star after their name, read once per
    // frame (session/documents.odin).
    _project_dirty_paths = session.documents_dirty_paths()
}

@(editor_window={id="Project", title="Project", icon="FOLDER", closed=project_view_closed})
project_view_draw :: proc(w: ^wnd.Window) {
    _pv = _project_view(w)
    defer {
        last := wnd.last(PROJECT)
        _pv = _project_view(last) if last != nil else &_pv_plain
    }
    // Search toolbar across the whole window, above both panes. While the
    // box has keyboard focus, list/tree key handling below is skipped
    // (IsAnyItemActive guard). A non-empty query shows an "x" beside it.
    query := strings.trim_space(string(cstring(raw_data(_pv.search_buf[:]))))
    clear_btn_w := im.GetFrameHeight()
    im.SetNextItemWidth(-(clear_btn_w + im.GetStyle().ItemSpacing.x) if query != "" else -1)
    // NoTabStop: Tab must switch panes (handled below), never tab-focus the
    // search box. Clicking into it still works.
    im.PushItemFlag({.NoTabStop}, true)
    im.InputTextWithHint("##prj_search", "Search", cstring(raw_data(_pv.search_buf[:])), c.size_t(len(_pv.search_buf)), {})
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

    // Keyboard routes to a pane we track ourselves (imgui child focus is
    // unreliable), but only while the Project window as a whole is focused.
    window_focused := im.IsWindowFocused(im.FocusedFlags_RootAndChildWindows)

    // Left pane: Tree view
    im.BeginChild("TreeView", im.Vec2{tree_w, 0}, {.Borders})
    // Clicking anywhere in the tree makes it the active pane.
    if im.IsWindowHovered({}) && im.IsMouseClicked(.Left) {
        _pv.active_pane = .Tree
    }

    clear(&_pv.tree_rows)

    // The real assets root folder is the top node (it recurses into its own
    // contents). It's a genuine on-disk folder, but renaming it is blocked in
    // the rename entry points (it's the project root).
    _project_draw_tree_node(projectViewData.rootPath, filepath.base(projectViewData.rootPath))
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
        menu.draw_menu_subtree("Assets")
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

    // Esc cancels an active search from EITHER pane (a rename's Esc wins;
    // Esc in the search box itself reverts the input first, then this clears).
    if window_focused && query != "" && !_pv.rename_active && im.IsKeyPressed(im.Key.Escape) {
        _project_cancel_search()
    }

    // Handle keys once, after both panes are drawn (nav lists are populated),
    // routing to the active pane. Not while a text input (search, rename) is
    // active — those own the keyboard.
    if window_focused && !im.IsAnyItemActive() {
        switch _pv.active_pane {
        case .Tree: _project_handle_tree_keys()
        case .List: _project_handle_list_keys()
        }
    }
}
