package editor

import "core:c"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:path/filepath"
import "core:encoding/uuid"
import "core:time"
import im "../../external/odin-imgui"
import "inspector"
import "menu"
import "../engine"
import "undo"

ProjectViewData :: struct {
    currentPath: string,
    selectedFile: string,
    rootPath: string,
}

projectViewData: ProjectViewData

// Keyboard navigation works like the hierarchy's: rows visible this frame are
// collected in draw order, then keys are handled after drawing (so index math
// matches what's on screen). Each pane only reacts while its child window has
// focus.
Project_Tree_Row :: struct {
    path: string, // full path, temp-allocated, rebuilt each frame
    open: bool,   // imgui tree node open state this frame
}
_project_tree_rows: [dynamic]Project_Tree_Row
// Folder open state, keyed by full path (persistent, owned clones). Written
// after each TreeNodeEx, read next frame to pick the open/closed folder icon.
_project_tree_open_state: map[string]bool
Project_Row :: struct {
    name:   string, // display text, temp-allocated, rebuilt each frame
    path:   string, // full path; drives selection/rename/activation (display
                    // names collide across folders in search results)
    is_dir: bool,
}
_project_list_rows: [dynamic]Project_Row

// One-shot fold command for a tree node (applied next frame via SetNextItemOpen).
_project_tree_set_open_path: string // owned clone; "" = no pending command
_project_tree_set_open_val: bool
// When the right pane navigates, open the ancestor chain in the tree so the
// highlighted folder is visible.
_project_tree_reveal: bool
_project_scroll_to_tree_sel: bool
_project_scroll_to_list_sel: bool

// Which pane keyboard input routes to. Tracked ourselves rather than via imgui
// child focus (SetWindowFocus/IsWindowFocused are unreliable for child windows).
// Set when a pane is clicked/hovered; toggled by Tab.
Project_Pane :: enum { Tree, List }
_project_active_pane: Project_Pane = .List

// Search over ALL files and folders under the assets root (not the current
// folder). Non-empty query swaps the file list for asset-DB search results;
// keyboard nav follows whichever rows are drawn.
_project_search_buf: [256]byte

// Ping flash (Unity-style): fading row highlight WITHOUT changing selection.
_PROJECT_PING_NS :: i64(800_000_000)
_project_ping_path: string // owned; "" = no active ping
_project_ping_deadline_ns: i64
_project_scroll_to_ping: bool

_project_rename_active: bool
_project_rename_path: string // owned clone of the full path being renamed
_project_rename_in_tree: bool // which pane opened the rename (for selection restore)
_project_rename_buf: [256]byte
_project_rename_focus: bool
_project_rename_just_opened: bool
_project_rename_just_finished: bool

init_project_view :: proc() {
    // The asset DB is rooted at "assets" (relative to the normalized moonhug/
    // cwd); the project window mirrors it so paths line up with asset lookups.
    projectViewData.rootPath = strings.clone("assets")
    projectViewData.currentPath = strings.clone("assets")
    // Start with the root folder expanded (one-shot; consumed on first draw).
    _project_tree_request_open(projectViewData.rootPath, true)
}

shutdown_project_view :: proc() {
    delete(projectViewData.rootPath)
    delete(projectViewData.currentPath)
    if projectViewData.selectedFile != "" {
        delete(projectViewData.selectedFile)
    }
    delete(_project_tree_rows)
    delete(_project_list_rows)
    for k in _project_tree_open_state {
        delete(k)
    }
    delete(_project_tree_open_state)
    if _project_tree_set_open_path != "" {
        delete(_project_tree_set_open_path)
    }
    if _project_rename_path != "" {
        delete(_project_rename_path)
    }
    if _project_ping_path != "" {
        delete(_project_ping_path)
    }
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
    // Clone before delete: callers may pass a slice of the current string.
    new_path := strings.clone(path)
    delete(projectViewData.currentPath)
    projectViewData.currentPath = new_path
}

// Selection holds the FULL path (search results from different folders can
// share a base name).
_project_set_selected :: proc(path: string) {
    new_path := strings.clone(path)
    delete(projectViewData.selectedFile)
    projectViewData.selectedFile = new_path
}

_project_path_is_ancestor :: proc(ancestor, path: string) -> bool {
    if ancestor == path do return false
    return strings.has_prefix(path, ancestor) && len(path) > len(ancestor) && path[len(ancestor)] == '/'
}

_project_tree_request_open :: proc(path: string, open: bool) {
    if _project_tree_set_open_path != "" {
        delete(_project_tree_set_open_path)
    }
    _project_tree_set_open_path = strings.clone(path)
    _project_tree_set_open_val = open
}

// Cancel an active search: clear the query and navigate to the selected item —
// its containing folder opens with the item still selected and revealed in the
// tree, so the highlighted hit doesn't vanish.
_project_cancel_search :: proc() {
    mem.zero(&_project_search_buf, len(_project_search_buf))
    sel := projectViewData.selectedFile
    if sel != "" && os.exists(sel) {
        parent := filepath.dir(sel) // slice into sel — don't delete
        if parent == "" {
            parent = projectViewData.rootPath
        }
        _project_set_current(parent)
        _project_tree_reveal = true
        _project_scroll_to_list_sel = true
    }
}

_project_enter_dir :: proc(full_path: string) {
    _project_set_current(full_path)
    _project_set_selected("")
    // Navigating to a folder leaves search mode — the list shows the folder now.
    mem.zero(&_project_search_buf, len(_project_search_buf))
    _project_tree_reveal = true
}

_project_go_up :: proc() {
    if projectViewData.currentPath == projectViewData.rootPath do return
    // Select the folder we're leaving (full path == the old currentPath).
    // filepath.dir returns a SLICE into currentPath — read it before
    // _project_set_current frees the string, and never delete it.
    came_from := projectViewData.currentPath
    parent := filepath.dir(came_from)
    // dir of a first-level folder ("foo") is "" — that's the assets root.
    if parent == "" {
        parent = projectViewData.rootPath
    }
    _project_set_selected(came_from)
    _project_set_current(parent)
    _project_tree_reveal = true
    _project_scroll_to_list_sel = true
}

// JSON asset files the project inspector opens directly (serialized
// __type_guid instances): generic .asset plus typed extensions (.mat).
_is_inspector_asset :: proc(path: string) -> bool {
    return strings.has_suffix(path, ".asset") || strings.has_suffix(path, ".mat")
}

// Same side effects as clicking/double-clicking the file row.
_project_activate_file :: proc(full_path: string) {
    if _is_inspector_asset(full_path) {
        undo.clear(undo.get())
        inspector.load_from_file(full_path)
    }
    if engine.is_importable_extension(filepath.ext(full_path)) {
        undo.clear(undo.get())
        inspector.load_import_settings(full_path)
    }
    if strings.has_suffix(full_path, ".scene") {
        undo.clear(undo.get())
        // Fresh navigation — reset the nested-scene edit stack.
        hierarchy_edit_stack_clear()
        scene := engine.scene_load_single_path(full_path)
        engine.sm_scene_set_active(scene)
    }
}

_project_open_selected :: proc() {
    sel := projectViewData.selectedFile
    if sel == "" do return
    for r in _project_list_rows {
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
    if full_path == "" || full_path == projectViewData.rootPath do return
    name := filepath.base(full_path)
    _project_rename_active = true
    _project_rename_in_tree = in_tree
    _project_rename_focus = true
    if _project_rename_path != "" do delete(_project_rename_path)
    _project_rename_path = strings.clone(full_path)
    mem.zero(&_project_rename_buf, len(_project_rename_buf))
    copy_len := min(len(name), len(_project_rename_buf) - 1)
    mem.copy(&_project_rename_buf[0], raw_data(name), copy_len)
}

_project_begin_rename_selected :: proc() {
    sel := projectViewData.selectedFile
    if sel == "" do return
    for r in _project_list_rows {
        if r.path == sel {
            _project_begin_rename(sel, false)
            return
        }
    }
}

_project_apply_rename :: proc() {
    if !_project_rename_active do return
    _project_rename_active = false
    _project_rename_just_finished = true

    new_name := string(cstring(raw_data(_project_rename_buf[:])))
    old_path := _project_rename_path
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
    if _project_rename_in_tree {
        // Renamed folder: if it was the current path, follow it.
        if projectViewData.currentPath == old_path {
            _project_set_current(new_path)
        }
    } else {
        _project_set_selected(new_path)
    }
    engine.asset_db_refresh()
}

// Draws the rename InputText in place of the row/node whose full path is being
// renamed. Returns true if it did (caller skips the normal row).
_project_draw_rename_row :: proc(full_path: string) -> bool {
    if !_project_rename_active || _project_rename_path != full_path do return false

    if _project_rename_focus {
        im.SetKeyboardFocusHere(0)
        _project_rename_focus = false
        _project_rename_just_opened = true
    }
    im.SetNextItemWidth(im.GetContentRegionAvail().x)
    buf_cstr := cstring(raw_data(_project_rename_buf[:]))
    if im.InputText("##prj_rename", buf_cstr, c.size_t(len(_project_rename_buf)), {.EnterReturnsTrue, .AutoSelectAll}) {
        _project_apply_rename()
    }
    if _project_rename_just_opened {
        _project_rename_just_opened = false
    } else if !im.IsItemActive() {
        if im.IsItemDeactivatedAfterEdit() {
            _project_apply_rename()
        } else {
            // Escape / clicked away without editing — cancel.
            _project_rename_active = false
            _project_rename_just_finished = true
        }
    }
    return true
}

// Material icon glyph for a file (full path). Icons are merged into the base
// font, so the returned string is drawn inline as part of a label.
_project_file_icon :: proc(path: string) -> string {
    switch filepath.ext(path) {
    case ".scene":
        // Variant assets get the variant glyph — detection is a reliable
        // AssetDB root-info lookup (file inherits a base), not a name check.
        if guid, ok := engine.asset_db_get_guid(path); ok {
            if info, iok := engine.asset_db_get_root_info(engine.Asset_GUID(guid)); iok && info.is_variant {
                return ICON_MD_STACKS_VARIANT
            }
        }
        return ICON_MD_STACKS // scene/prefab = stack group
    case ".png", ".jpg", ".jpeg", ".bmp", ".tga", ".gif":
        return ICON_MD_IMAGE
    case ".asset":
        return ICON_MD_SETTINGS
    case ".mat":
        return ICON_MD_PALETTE
    case ".glsl":
        return ICON_MD_CODE
    case:
        return ICON_MD_DESCRIPTION
    }
}

// Draw one folder node (icon, selection, keyboard row, open-state) and, if
// open, recurse into its subfolders. `name` is the label; `full_path` its path.
_project_draw_tree_node :: proc(full_path: string, name: string) {
    // Scope the imgui ID to this path so the "###node" constant IDs below stay
    // unique per folder (and never shift with the display label / icon).
    im.PushID(strings.clone_to_cstring(full_path, context.temp_allocator))
    defer im.PopID()

    // Folder being renamed: swap the node for an inline input. Still recorded in
    // the nav list so keyboard indices stay consistent; children are hidden for
    // the duration of the edit.
    if _project_rename_active && _project_rename_path == full_path {
        append(&_project_tree_rows, Project_Tree_Row{path = full_path, open = false})
        im.Indent(im.GetTreeNodeToLabelSpacing())
        _project_draw_rename_row(full_path)
        im.Unindent(im.GetTreeNodeToLabelSpacing())
        return
    }

    // Selection highlight only shows while the tree is the active pane, so focus
    // visibly moves with Tab. currentPath still drives the file list.
    is_selected := _project_active_pane == .Tree && projectViewData.currentPath == full_path
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
    expanded := !is_leaf && _project_tree_open_state[full_path]
    folder_icon := ICON_MD_FOLDER_OPEN if expanded else ICON_MD_FOLDER
    node_label := strings.clone_to_cstring(fmt.tprintf("%s%s###node", folder_icon, name), context.temp_allocator)

    node_flags: im.TreeNodeFlags = {.OpenOnArrow, .OpenOnDoubleClick}
    if is_selected {
        node_flags += {.Selected}
    }
    if is_leaf {
        node_flags += {.Leaf, .NoTreePushOnOpen}
    }

    if !is_leaf {
        if _project_tree_set_open_path != "" && _project_tree_set_open_path == full_path {
            im.SetNextItemOpen(_project_tree_set_open_val)
            delete(_project_tree_set_open_path)
            _project_tree_set_open_path = ""
        } else if _project_tree_reveal && _project_path_is_ancestor(full_path, projectViewData.currentPath) {
            im.SetNextItemOpen(true)
        }
    }

    node_open := im.TreeNodeEx(node_label, node_flags)
    // A leaf reports open==true but can't be collapsed; record it as closed so
    // Left-arrow skips straight to the parent.
    open := node_open && !is_leaf
    append(&_project_tree_rows, Project_Tree_Row{path = full_path, open = open})
    // Remember open state for next frame's folder icon. Keys are cloned once and
    // overwritten in place (freed on shutdown); the map is bounded by the number
    // of folders ever drawn.
    if _, seen := _project_tree_open_state[full_path]; seen {
        _project_tree_open_state[full_path] = open
    } else {
        _project_tree_open_state[strings.clone(full_path)] = open
    }
    if is_selected && _project_scroll_to_tree_sel {
        im.SetScrollHereY()
        _project_scroll_to_tree_sel = false
    }

    // Handle selection
    if im.IsItemClicked() {
        _project_set_current(full_path)
    }

    if node_open && !is_leaf {
        draw_directory_tree(full_path)
        im.TreePop()
    }
}

// Draw the subfolders of `path` as tree nodes (sorted). Does not draw `path`
// itself — the caller decides whether the parent gets a node.
draw_directory_tree :: proc(path: string, level: int = 0) {
    handle, err := os.open(path)
    if err != nil {
        return
    }
    defer os.close(handle)

    entries, read_err := os.read_dir(handle, -1, context.temp_allocator)
    if read_err != nil {
        return
    }
    defer os.file_info_slice_delete(entries, context.temp_allocator)

    slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {
        return strings.to_lower(a.name, context.temp_allocator) < strings.to_lower(b.name, context.temp_allocator)
    })

    for entry in entries {
        if entry.type != .Directory {
            continue
        }
        full_path, _ := filepath.join({path, entry.name}, context.temp_allocator)
        _project_draw_tree_node(full_path, entry.name)
    }
}

// True if `dir` contains at least one subdirectory.
_project_dir_has_subdir :: proc(dir: string) -> bool {
    handle, err := os.open(dir)
    if err != nil do return false
    defer os.close(handle)
    entries, read_err := os.read_dir(handle, -1, context.temp_allocator)
    if read_err != nil do return false
    defer os.file_info_slice_delete(entries, context.temp_allocator)
    for entry in entries {
        if entry.type == .Directory do return true
    }
    return false
}

_project_handle_tree_keys :: proc() {
    // The frame a rename closes, its Enter/Escape press is still down — swallow
    // it so it doesn't immediately re-trigger a rename or navigation.
    if _project_rename_just_finished {
        _project_rename_just_finished = false
        return
    }
    if _project_rename_active do return

    if im.IsKeyPressed(im.Key.Tab) {
        _project_active_pane = .List
        return
    }
    if _project_key_rename() {
        _project_begin_rename(projectViewData.currentPath, true)
        return
    }
    n := len(_project_tree_rows)
    if n == 0 do return
    if _project_cmd_down() do return // cmd+arrows belong to the file list pane

    cur := -1
    for r, i in _project_tree_rows {
        if r.path == projectViewData.currentPath {
            cur = i
            break
        }
    }

    _tree_select :: proc(idx: int) {
        _project_set_current(_project_tree_rows[idx].path)
        _project_scroll_to_tree_sel = true
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
    sel := _project_tree_rows[cur].path
    open := _project_tree_rows[cur].open
    has_child_rows := cur + 1 < n && _project_path_is_ancestor(sel, _project_tree_rows[cur+1].path)

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
        // Left jump to the parent.
        if open {
            _project_tree_request_open(sel, false)
        } else if sel != projectViewData.rootPath {
            parent := filepath.dir(sel) // slice into sel — not owned, don't delete
            // filepath.dir of a first-level folder ("foo") is "" — that's the
            // fake "Assets" root, so select rootPath rather than an empty path
            // (which matches no tree row and blanks the selection).
            if parent == "" {
                parent = projectViewData.rootPath
            }
            _project_set_current(parent)
            _project_scroll_to_tree_sel = true
        }
        return
    }
}

// When the list pane is active but nothing valid is selected, select the first
// row. Called after the list is drawn (rows populated) so a fresh Tab into the
// pane lands on the first file.
_project_list_ensure_selection :: proc() {
    n := len(_project_list_rows)
    if n == 0 do return
    for r in _project_list_rows {
        if r.path == projectViewData.selectedFile do return // already valid
    }
    _project_set_selected(_project_list_rows[0].path)
    _project_scroll_to_list_sel = true
}

_project_handle_list_keys :: proc() {
    // The frame a rename closes, its Enter/Escape press is still down — don't
    // let it immediately re-trigger navigation or another rename.
    if _project_rename_just_finished {
        _project_rename_just_finished = false
        return
    }
    if _project_rename_active do return

    if im.IsKeyPressed(im.Key.Tab) {
        _project_active_pane = .Tree
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

    if _project_cmd_down() do return
    n := len(_project_list_rows)
    if n == 0 do return

    cur := -1
    for r, i in _project_list_rows {
        if r.path == projectViewData.selectedFile {
            cur = i
            break
        }
    }

    _list_select :: proc(idx: int) {
        _project_set_selected(_project_list_rows[idx].path)
        _project_scroll_to_list_sel = true
    }

    if im.IsKeyPressed(im.Key.DownArrow) {
        if cur == -1 {
            _list_select(0)
        } else if cur + 1 < n {
            _list_select(cur + 1)
        }
        return
    }
    if im.IsKeyPressed(im.Key.UpArrow) {
        if cur == -1 {
            _list_select(0)
        } else if cur - 1 >= 0 {
            _list_select(cur - 1)
        }
        return
    }
}

is_known_extension :: proc(filename: string) -> bool {
    ext := filepath.ext(filename)
    if ext == ".prefab" || ext == ".asset" || ext == ".mat" || ext == ".scene" do return true
    return engine.is_importable_extension(ext)
}

draw_file_list :: proc(path: string) {
    handle, err := os.open(path)
    if err != nil {
        im.Text("Failed to open directory")
        return
    }
    defer os.close(handle)

    entries, read_err := os.read_dir(handle, -1, context.temp_allocator)
    if read_err != nil {
        im.Text("Failed to read directory")
        return
    }
    defer os.file_info_slice_delete(entries, context.temp_allocator)

    slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {
        return strings.to_lower(a.name, context.temp_allocator) < strings.to_lower(b.name, context.temp_allocator)
    })

    // Draw directories first
    for entry in entries {
        if entry.type != .Directory {
            continue
        }
        entry_path, _ := filepath.join({path, entry.name}, context.temp_allocator)
        _project_draw_list_row(entry.name, entry_path, is_dir = true)
    }

    // Draw files below directories
    for entry in entries {
        if strings.has_prefix(entry.name, ".") {
            continue
        }
        if entry.type == .Directory {
            continue
        }
        if filepath.ext(entry.name) == ".meta" {
            continue
        }
        entry_path, _ := filepath.join({path, entry.name}, context.temp_allocator)
        _project_draw_list_row(entry.name, entry_path, is_dir = false)
    }
}

// One row of the right pane, shared by the folder listing and search results.
// `display` is the shown text; `full_path` drives selection, rename,
// activation, and the drag payload.
_project_draw_list_row :: proc(display: string, full_path: string, is_dir: bool) {
    append(&_project_list_rows, Project_Row{name = display, path = full_path, is_dir = is_dir})
    if _project_draw_rename_row(full_path) do return

    icon := ICON_MD_FOLDER if is_dir else _project_file_icon(full_path)
    label := strings.clone_to_cstring(fmt.tprintf("%s%s", icon, display), context.temp_allocator)

    is_selected := _project_active_pane == .List && projectViewData.selectedFile == full_path

    dim_unknown := !is_dir && !is_known_extension(full_path)
    if dim_unknown {
        text_col := im.GetStyleColorVec4(im.Col.Text)
        dimmed: im.Vec4 = {text_col[0] * 0.6, text_col[1] * 0.6, text_col[2] * 0.6, text_col[3]}
        im.PushStyleColorImVec4(im.Col.Text, dimmed)
    }

    // Single click selects (and loads .asset/import settings for files);
    // double click enters folders / opens scenes.
    if im.Selectable(label, is_selected, {.AllowDoubleClick}) {
        _project_set_selected(full_path)
        if is_dir {
            if im.IsMouseDoubleClicked(.Left) {
                _project_enter_dir(full_path)
            }
        } else {
            if _is_inspector_asset(full_path) {
                undo.clear(undo.get())
                inspector.load_from_file(full_path)
            }
            if engine.is_importable_extension(filepath.ext(full_path)) {
                undo.clear(undo.get())
                inspector.load_import_settings(full_path)
            }
            if strings.has_suffix(full_path, ".scene") && im.IsMouseDoubleClicked(.Left) {
                undo.clear(undo.get())
                // Fresh navigation — reset the nested-scene edit stack.
                hierarchy_edit_stack_clear()
                scene := engine.scene_load_single_path(full_path)
                engine.sm_scene_set_active(scene)
            }
        }
    }
    if is_selected && _project_scroll_to_list_sel {
        im.SetScrollHereY()
        _project_scroll_to_list_sel = false
    }
    // Ping flash: fading highlight over the row, selection untouched.
    if _project_ping_path != "" && full_path == _project_ping_path {
        remaining := _project_ping_deadline_ns - time.now()._nsec
        if remaining <= 0 {
            delete(_project_ping_path)
            _project_ping_path = ""
        } else {
            if _project_scroll_to_ping {
                im.SetScrollHereY()
                _project_scroll_to_ping = false
            }
            alpha := 0.45 * f32(remaining) / f32(_PROJECT_PING_NS)
            flash := im.GetColorU32ImVec4(im.Vec4{1.0, 0.8, 0.2, alpha})
            im.DrawList_AddRectFilled(im.GetWindowDrawList(), im.GetItemRectMin(), im.GetItemRectMax(), flash)
        }
    }
    if !is_dir {
        // Right-click also selects, so the context menu (which acts on the
        // selected asset) targets the row under the cursor, not whatever was
        // previously selected.
        if im.IsItemHovered() && im.IsMouseClicked(.Right) {
            _project_set_selected(full_path)
        }
        if im.BeginDragDropSource({}) {
            im.SetDragDropPayload("ASSET_PATH", raw_data(full_path), len(full_path))
            im.Text(label)
            im.EndDragDropSource()
        }
    }
    if dim_unknown {
        im.PopStyleColor()
    }
}

// Search results: every file/folder under the assets root whose NAME contains
// the query (case-insensitive), shown as root-relative paths. The asset DB
// indexes all of them (folders included) and refreshes on rename/create, so
// it's both the cheapest and the freshest source — no directory re-walk.
// Returns the match count for the status line.
_project_draw_search_results :: proc(query: string) -> int {
    q := strings.to_lower(query, context.temp_allocator)

    matches := make([dynamic]string, context.temp_allocator)
    for path in engine.asset_db.path_to_guid {
        name := filepath.base(path)
        if strings.contains(strings.to_lower(name, context.temp_allocator), q) {
            append(&matches, path)
        }
    }
    // Map iteration order is unstable — sort so rows don't jump between frames.
    slice.sort(matches[:])

    prefix := strings.concatenate({projectViewData.rootPath, "/"}, context.temp_allocator)
    for path in matches {
        display := path
        if strings.has_prefix(path, prefix) {
            display = path[len(prefix):]
        }
        _project_draw_list_row(display, path, os.is_dir(path))
    }
    return len(matches)
}

// Create a prefab variant of the scene at `base_path`, written alongside it as
// "<name>_Variant.scene", then open it. The variant's root is a NestedScene
// over the base (empty overrides); editing it captures overrides against the base.
create_scene_variant :: proc(base_path: string) {
    dir := filepath.dir(base_path) // slice into base_path — not owned, don't delete
    stem := filepath.stem(base_path)
    variant_name := strings.concatenate({stem, "_Variant.scene"}, context.temp_allocator)
    variant_path, _ := filepath.join({dir, variant_name}, context.temp_allocator)

    if !engine.scene_create_variant_file(base_path, variant_path) {
        fmt.printf("[Editor] Failed to create scene variant from %s\n", base_path)
        return
    }
    // Mint the variant's .meta and register it so it can be loaded by GUID.
    engine.asset_db_refresh()

    undo.clear(undo.get())
    hierarchy_edit_stack_clear()
    scene := engine.scene_load_single_path(variant_path)
    engine.sm_scene_set_active(scene)
}

// Leave search mode and open the asset's folder, revealed in the tree.
// select=true: select the row (open semantics). select=false: ping — a
// fading flash on the row, selection untouched.
_project_reveal_path :: proc(path: string, select: bool) {
    mem.zero(&_project_search_buf, len(_project_search_buf))
    parent := filepath.dir(path) // slice into path — not owned
    if parent == "" {
        parent = projectViewData.rootPath
    }
    _project_set_current(parent)
    if select {
        _project_set_selected(path)
        _project_scroll_to_list_sel = true
    } else {
        if _project_ping_path != "" do delete(_project_ping_path)
        _project_ping_path = strings.clone(path)
        _project_ping_deadline_ns = time.now()._nsec + _PROJECT_PING_NS
        _project_scroll_to_ping = true
    }
    _project_tree_reveal = true
    _project_active_pane = .List
}

draw_project_view :: proc() {
    // Drain cross-package asset requests (inspector value-button clicks):
    // ping = reveal + flash; open = reveal + select + activate (double click).
    if ping_guid, ok := engine.inspector_take_pending_ping_asset(); ok {
        if path, pok := engine.asset_db_get_path(uuid.Identifier(ping_guid)); pok {
            _project_reveal_path(path, select = false)
        }
    }
    if open_guid, ok := engine.inspector_take_pending_open_asset(); ok {
        if path, pok := engine.asset_db_get_path(uuid.Identifier(open_guid)); pok {
            _project_reveal_path(path, select = true)
            _project_activate_file(path)
        }
    }

    if im.Begin("Project", nil, {.NoCollapse}) {
        // Create two columns
        im.Columns(2, "ProjectColumns", true)

        // Keyboard routes to a pane we track ourselves (imgui child focus is
        // unreliable), but only while the Project window as a whole is focused.
        window_focused := im.IsWindowFocused(im.FocusedFlags_RootAndChildWindows)

        // Left pane: Tree view
        im.BeginChild("TreeView", im.Vec2{0, 0}, {.Borders})
        // Clicking anywhere in the tree makes it the active pane.
        if im.IsWindowHovered({}) && im.IsMouseClicked(.Left) {
            _project_active_pane = .Tree
        }

        clear(&_project_tree_rows)

        // The real assets root folder is the top node (it recurses into its own
        // contents). It's a genuine on-disk folder, but renaming it is blocked in
        // the rename entry points (it's the project root).
        _project_draw_tree_node(projectViewData.rootPath, filepath.base(projectViewData.rootPath))
        // Reveal requests from the right pane were consumed by this draw.
        _project_tree_reveal = false

        im.EndChild()

        im.NextColumn()

        // Right pane: File list
        im.BeginChild("FileList", im.Vec2{0, 0}, {.Borders})
        // ChildWindows: the rows live in a nested scroll child below.
        if im.IsWindowHovered(im.HoveredFlags_ChildWindows) && im.IsMouseClicked(.Left) {
            _project_active_pane = .List
        }

        clear(&_project_list_rows)

        // Search box above the list. While it has keyboard focus, list/tree key
        // handling below is skipped (IsAnyItemActive guard). A non-empty query
        // shows an "x" clear button beside the input.
        query := strings.trim_space(string(cstring(raw_data(_project_search_buf[:]))))
        clear_btn_w := im.GetFrameHeight()
        im.SetNextItemWidth(-(clear_btn_w + im.GetStyle().ItemSpacing.x) if query != "" else -1)
        // NoTabStop: Tab must switch panes (handled below), never tab-focus the
        // search box. Clicking into it still works.
        im.PushItemFlag({.NoTabStop}, true)
        im.InputTextWithHint("##prj_search", "Search", cstring(raw_data(_project_search_buf[:])), c.size_t(len(_project_search_buf)), {})
        im.PopItemFlag()
        if query != "" {
            im.SameLine()
            if im.Button(ICON_MD_CLOSE + "###prj_search_clear", im.Vec2{clear_btn_w, 0}) {
                _project_cancel_search()
                query = ""
            }
        }

        // Rows scroll in their own child so the status line below stays fixed
        // at the bottom of the pane.
        result_count := 0
        im.BeginChild("FileRows", im.Vec2{0, -im.GetFrameHeightWithSpacing()}, {})
        if query != "" {
            result_count = _project_draw_search_results(query)
        } else {
            draw_file_list(projectViewData.currentPath)
        }
        if im.BeginPopupContextWindow("ProjectFileListContext", im.PopupFlags_MouseButtonRight) {
            menu.draw_menu_subtree("Assets")
            im.EndPopup()
        }
        im.EndChild()

        // Status line at the bottom of the right pane.
        im.Separator()
        if query != "" {
            im.Text(strings.clone_to_cstring(fmt.tprintf("%d found", result_count), context.temp_allocator))
        } else {
            im.Text(strings.clone_to_cstring(fmt.tprintf("Path: %s", projectViewData.currentPath), context.temp_allocator))
        }

        im.EndChild()

        im.Columns(1)

        // Entering the right pane with no valid selection lands on the first file.
        if _project_active_pane == .List {
            _project_list_ensure_selection()
        }

        // Esc cancels an active search from EITHER pane (a rename's Esc wins;
        // Esc in the search box itself reverts the input first, then this clears).
        if window_focused && query != "" && !_project_rename_active && im.IsKeyPressed(im.Key.Escape) {
            _project_cancel_search()
        }

        // Handle keys once, after both panes are drawn (nav lists are populated),
        // routing to the active pane. Not while a text input (search, rename) is
        // active — those own the keyboard.
        if window_focused && !im.IsAnyItemActive() {
            switch _project_active_pane {
            case .Tree: _project_handle_tree_keys()
            case .List: _project_handle_list_keys()
            }
        }
    }
    im.End()
}
