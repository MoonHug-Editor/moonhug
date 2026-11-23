package editor

// The Project window's rows: the folder tree's and the list pane's, each a
// flat list built once a frame, of which only the rows on screen are drawn.
//
// - The tree's list is every open folder followed by its subfolders
//   (Project_Window.tree_rows).
// - The list pane's is what it shows: a folder's entries, the search hits, or
//   the packages, each unfolded file followed by its sub-assets
//   (Project_Window.list_rows). Rows and the grid's cells both draw from it,
//   and the keymap's commands walk it.
//
// A row is one item with its marks drawn straight into the draw list. A
// folder is a drop place for dragged files and folders.

import "core:c"
import "core:fmt"
import "core:hash"
import "core:mem/virtual"
import "core:path/filepath"
import "core:time"
import "core:strings"
import im "moonhug:external/odin-imgui"
import "drag"
import "subassets"
import "moonhug:editor/icons"
import "moonhug:editor/thumbnails"
import "moonhug:editor/widgets"
import assets "moonhug:libs/assets"
import core "moonhug:libs/core"
import "moonhug:libs/prof"

// The sizes and colours of a frame's rows, worked out once per pane.
@(private = "file")
_Rows_Look :: struct {
    row_h:    f32,
    indent:   f32,
    arrow_w:  f32,
    icon_w:   f32,
    text_pad: f32,
    pad_x:    f32,
    width:    f32,
    text:     u32,
    dim:      u32,
    selected: u32,
    hovered:  u32,
    mouse:    im.Vec2,
}

// `active`: the pane has the keyboard. The selection is grey in the other
// pane and while the window is not the focused one.
@(private = "file")
_rows_look :: proc(active: bool) -> _Rows_Look {
    text := im.GetStyleColorVec4(.Text)^
    selected := im.GetStyleColorVec4(.Header)^
    if !active || !im.IsWindowFocused(im.FocusedFlags_RootAndChildWindows) {
        g := (selected.x + selected.y + selected.z) / 3
        selected = {g, g, g, selected.w * 0.7}
    }
    hovered := im.GetStyleColorVec4(.HeaderHovered)^
    hovered.w *= 0.35
    row_h := im.GetFontSize() + 5
    return {
        row_h    = row_h,
        indent   = 14,
        arrow_w  = 16,
        icon_w   = im.GetFontSize() + 3,
        text_pad = (row_h - im.GetFontSize()) * 0.5,
        pad_x    = 4,
        width    = im.GetContentRegionAvail().x,
        text     = im.GetColorU32ImVec4(text),
        dim      = im.GetColorU32ImVec4({text.x, text.y, text.z, text.w * 0.6}),
        selected = im.GetColorU32ImVec4(selected),
        hovered  = im.GetColorU32ImVec4(hovered),
        mouse    = im.GetIO().MousePos,
    }
}

@(private = "file")
_rows_arrow :: proc(dl: ^im.DrawList, centre: im.Vec2, open: bool, col: u32) {
    r := f32(3.5)
    if open {
        im.DrawList_AddTriangleFilled(dl, {centre.x - r, centre.y - r * 0.6}, {centre.x + r, centre.y - r * 0.6}, {centre.x, centre.y + r * 0.8}, col)
    } else {
        im.DrawList_AddTriangleFilled(dl, {centre.x - r * 0.6, centre.y - r}, {centre.x + r * 0.8, centre.y}, {centre.x - r * 0.6, centre.y + r}, col)
    }
}

// An id for a row from its path, so a row keeps its id while others come and go.
@(private = "file")
_rows_id :: proc(path: string, sub: core.Local_ID = 0) -> c.int {
    return c.int(hash.fnv32a(transmute([]u8)path) ~ u32(sub) * 2654435761)
}

// Brings row `index` into view when it is outside it.
@(private = "file")
_rows_scroll_to :: proc(index: int, row_h: f32) {
    top := f32(index) * row_h
    scroll, view_h := im.GetScrollY(), im.GetWindowHeight()
    if top >= scroll && top + row_h <= scroll + view_h do return
    im.SetScrollY(max(top - (view_h - row_h) * 0.5, 0))
}

// While something is dragged: near the pane's top and bottom edges the rows
// scroll under the pointer.
@(private = "file")
_rows_drag_scroll :: proc() {
    if drag.items() == nil || !im.IsWindowHovered(im.HoveredFlags_AllowWhenBlockedByActiveItem) do return
    lo := im.GetWindowPos().y
    hi := lo + im.GetWindowHeight()
    y := im.GetIO().MousePos.y
    edge := f32(28)
    dt := im.GetIO().DeltaTime
    if y < lo + edge {
        im.SetScrollY(max(im.GetScrollY() - 500 * dt, 0))
    } else if y > hi - edge {
        im.SetScrollY(min(im.GetScrollY() + 500 * dt, im.GetScrollMaxY()))
    }
}

// `name` as it fits in `width`: cut in the middle with its extension kept
// when it does not. `cut` then says so, for a tooltip with the whole name.
_project_fit_name :: proc(name: string, width: f32) -> (shown: cstring, cut: bool) {
    whole := strings.clone_to_cstring(name, context.temp_allocator)
    if im.CalcTextSize(whole).x <= width || len(name) < 4 do return whole, false
    ext := filepath.ext(name)
    if len(ext) > 8 || len(ext) == len(name) do ext = ""
    stem := name[:len(name) - len(ext)]
    // The longest start of the name that fits before ".." and the extension.
    // Whole characters only: a name is utf-8.
    best := cstring("..")
    lo, hi := 1, len(stem)
    for lo <= hi {
        mid := (lo + hi) / 2
        cutoff := mid
        for cutoff > 0 && cutoff < len(stem) && (stem[cutoff] & 0xC0) == 0x80 do cutoff -= 1
        cand := fmt.ctprintf("%s..%s", stem[:cutoff], ext)
        if im.CalcTextSize(cand).x <= width {
            best = cand
            lo = mid + 1
        } else {
            hi = mid - 1
        }
    }
    return best, true
}

// The whole name of an item whose row or cell shows it cut.
_project_name_tooltip :: proc(name: string) {
    widgets.tooltip_unchecked(strings.clone_to_cstring(name, context.temp_allocator))
}

// --- The folder tree -----------------------------------------------------------

// Whether the folder shows its subfolders. The roots start open.
@(private = "file")
_tree_is_open :: proc(path: string) -> bool {
    if open, seen := _pv.tree_open_state[path]; seen do return open
    return path == projectWindowData.rootPath || path == _PROJECT_PACKAGES_PATH
}

// Opens or closes a folder of the tree. Keys are cloned once and overwritten
// in place, freed with the window.
_project_tree_set_open :: proc(path: string, open: bool) {
    _pv.tree_dirty = true
    if _, seen := _pv.tree_open_state[path]; seen {
        _pv.tree_open_state[path] = open
    } else {
        _pv.tree_open_state[strings.clone(path)] = open
    }
}

// Builds the tree's rows: the assets root, then the Packages node with a row
// per package root (the label is the package's name, the path its assets
// folder, so everything under it is ordinary).
//
// The rows are kept between frames. They are built again when a folder is
// opened or closed, when the list pane asks for a folder to be revealed,
// when the editor changed files (the directory cache's count), and twice a
// second for changes made outside the editor.
_project_tree_build :: proc() {
    now := time.now()._nsec
    gen := project_dir_cache_gen()
    if !_pv.tree_dirty && !_pv.tree_reveal && gen == _pv.tree_gen && now - _pv.tree_built_ns < 500_000_000 && len(_pv.tree_rows) > 0 do return
    prof.zone()
    _pv.tree_dirty = false
    _pv.tree_gen = gen
    _pv.tree_built_ns = now
    clear(&_pv.tree_rows)
    virtual.arena_free_all(&_pv.tree_arena)
    _tree_add(projectWindowData.rootPath, filepath.base(projectWindowData.rootPath), 0, false)

    pkgs := project_packages_list()
    open := len(pkgs) > 0 && _tree_is_open(_PROJECT_PACKAGES_PATH)
    if len(pkgs) > 0 && _pv.tree_reveal && _project_path_is_ancestor(_PROJECT_PACKAGES_PATH, _pv.current_path) && !open {
        open = true
        _project_tree_set_open(_PROJECT_PACKAGES_PATH, true)
    }
    a := virtual.arena_allocator(&_pv.tree_arena)
    append(&_pv.tree_rows, Project_Tree_Row{path = strings.clone(_PROJECT_PACKAGES_PATH, a), name = "packages", has_sub = len(pkgs) > 0, open = open})
    if open do for pkg in pkgs do _tree_add(pkg.assets_path, pkg.name, 1, pkg.is_link)
    // Reveal requests from the list pane are consumed by this build, and the
    // folder it went to comes into view.
    if _pv.tree_reveal do _pv.scroll_to_tree_sel = true
    _pv.tree_reveal = false
}

@(private = "file")
_tree_add :: proc(path, name: string, depth: int, is_link: bool) {
    // The list pane went somewhere: the folders above it open.
    revealed := _pv.tree_reveal && _project_path_is_ancestor(path, _pv.current_path)
    want_open := _tree_is_open(path) || revealed
    // An open folder's listing is checked for changes. A closed one only
    // needs to know whether it has subfolders, for its arrow: the listing
    // kept from before answers that, with no check.
    entries: []Project_Dir_Entry
    ok: bool
    if want_open {
        entries, ok = project_dir_listing(path)
    } else {
        entries, ok = project_dir_listing_kept(path)
    }
    has_sub := false
    if ok do for entry in entries do if entry.is_dir {
        has_sub = true
        break
    }
    open := has_sub && want_open
    if open && revealed && !_tree_is_open(path) do _project_tree_set_open(path, true)
    a := virtual.arena_allocator(&_pv.tree_arena)
    append(&_pv.tree_rows, Project_Tree_Row{path = strings.clone(path, a), name = strings.clone(name, a), depth = depth, has_sub = has_sub, is_link = is_link, open = open})
    if !open do return
    for entry in entries {
        if !entry.is_dir do continue
        full, _ := filepath.join({path, entry.name}, context.temp_allocator)
        _tree_add(full, entry.name, depth + 1, entry.is_link)
    }
}

// The folder a drag rests on in the tree, and since when: it opens after a
// moment.
@(private = "file")
_tree_drag_hover: u32
@(private = "file")
_tree_drag_since: f64

// Draws the tree pane's rows.
_project_tree_draw :: proc() {
    prof.zone()
    im.PushStyleVarImVec2(.ItemSpacing, im.Vec2{0, 0})
    look := _rows_look(_pv.active_pane == .Tree)
    dl := im.GetWindowDrawList()
    origin := im.GetCursorScreenPos()
    dragging := drag.items() != nil

    if _pv.scroll_to_tree_sel {
        _pv.scroll_to_tree_sel = false
        if i := _project_tree_index(); i != -1 do _rows_scroll_to(i, look.row_h)
    }

    clipper: im.ListClipper
    im.ListClipper_Begin(&clipper, i32(len(_pv.tree_rows)), look.row_h)
    for im.ListClipper_Step(&clipper) {
        for i in clipper.DisplayStart ..< clipper.DisplayEnd {
            if int(i) >= len(_pv.tree_rows) do break
            _tree_draw_row(&look, dl, _pv.tree_rows[i], dragging)
        }
    }
    im.ListClipper_End(&clipper)
    im.PopStyleVar()

    // While something is dragged: the folder under the pointer is the place,
    // and a folded one opens when the drag rests on it.
    hover := u32(0)
    if dragging && im.IsWindowHovered(im.HoveredFlags_AllowWhenBlockedByActiveItem) {
        index := int((look.mouse.y - origin.y) / look.row_h)
        if look.mouse.y >= origin.y && index >= 0 && index < len(_pv.tree_rows) {
            row := _pv.tree_rows[index]
            rmin := im.Vec2{origin.x, origin.y + f32(index) * look.row_h}
            rect := im.Rect{Min = rmin, Max = {rmin.x + look.width, rmin.y + look.row_h}}
            if row.path != _PROJECT_PACKAGES_PATH && im.BeginDragDropTargetCustom(rect, im.GetID("##tree_drop")) {
                drag.target(drag.Project_Place{folder = row.path})
                im.EndDragDropTarget()
            }
            if row.has_sub && !row.open {
                hover = hash.fnv32a(transmute([]u8)row.path)
                if hover == _tree_drag_hover && im.GetTime() - _tree_drag_since > 0.6 do _project_tree_set_open(row.path, true)
            }
        }
        _rows_drag_scroll()
    }
    if hover != _tree_drag_hover {
        _tree_drag_hover = hover
        _tree_drag_since = im.GetTime()
    }

    // The menu of the folder the tree shows, the same as the list pane's.
    if im.BeginPopupContextWindow("ProjectTreeContext", im.PopupFlags_MouseButtonRight) {
        _project_context_menu()
        im.EndPopup()
    }
}

@(private = "file")
_tree_draw_row :: proc(look: ^_Rows_Look, dl: ^im.DrawList, row: Project_Tree_Row, dragging: bool) {
    im.PushIDInt(_rows_id(row.path))
    defer im.PopID()

    x_at := proc(look: ^_Rows_Look, rmin: im.Vec2, depth: int) -> f32 { return rmin.x + look.pad_x + f32(depth) * look.indent }

    // Being renamed: the field where the name is.
    if _pv.rename_active && _pv.rename_in_tree && _pv.rename_sub == 0 && _pv.rename_path == row.path {
        rmin := im.GetCursorScreenPos()
        name_x := x_at(look, rmin, row.depth) + look.arrow_w + look.icon_w + 2
        im.SetCursorScreenPos(im.Vec2{name_x, rmin.y + (look.row_h - im.GetFrameHeight()) * 0.5})
        _project_rename_input(max(rmin.x + look.width - name_x, 40))
        im.SetCursorScreenPos(im.Vec2{rmin.x, rmin.y + look.row_h})
        im.Dummy(im.Vec2{0, 0})
        return
    }

    clicked := im.InvisibleButton("##row", im.Vec2{look.width, look.row_h})
    rmin := im.GetItemRectMin()
    rmax := im.Vec2{rmin.x + look.width, rmin.y + look.row_h}
    hovered := im.IsItemHovered({})

    // The folder the list pane shows is always marked.
    if _pv.current_path == row.path {
        im.DrawList_AddRectFilled(dl, rmin, rmax, look.selected)
    } else if hovered && !dragging {
        im.DrawList_AddRectFilled(dl, rmin, rmax, look.hovered)
    }

    x := x_at(look, rmin, row.depth)
    if row.has_sub do _rows_arrow(dl, im.Vec2{x + look.arrow_w * 0.5, rmin.y + look.row_h * 0.5}, row.open, look.text)
    icon_x := x + look.arrow_w
    icon := _project_dir_icon(row.is_link, row.open)
    im.DrawList_AddText(dl, im.Vec2{icon_x, rmin.y + look.text_pad}, look.text, strings.clone_to_cstring(icon, context.temp_allocator))
    name_x := icon_x + look.icon_w + 2
    label, cut := _project_fit_name(row.name, rmax.x - name_x - look.pad_x)
    im.DrawList_AddText(dl, im.Vec2{name_x, rmin.y + look.text_pad}, look.text, label)
    if cut && hovered && !dragging do _project_name_tooltip(row.name)

    // A folder drags as a folder, to move it. The roots stay where they are.
    if !project_path_is_protected(row.path) && im.BeginDragDropSource({}) {
        items := []drag.Item{drag.Folder{path = row.path}}
        drag.source(items, row.name)
        im.EndDragDropSource()
    }

    in_arrow := row.has_sub && look.mouse.x < icon_x
    if hovered && im.IsMouseClicked(.Left) && in_arrow {
        _project_tree_set_open(row.path, !row.open)
        return
    }
    // A click selects the folder and shows it, as a click on a file's row
    // selects the file. The Project Inspector shows the selection, so a
    // package root opens the package inspector.
    if clicked && !in_arrow {
        _project_set_current(row.path)
        if row.path != _PROJECT_PACKAGES_PATH {
            _project_set_selected(row.path)
            _project_inspectors_refresh()
        }
    }
    if hovered && im.IsMouseDoubleClicked(.Left) && !in_arrow && row.has_sub do _project_tree_set_open(row.path, !row.open)
    // A right click shows the folder first, so the menu is about it.
    if hovered && im.IsMouseClicked(.Right) {
        _project_set_current(row.path)
        if row.path != _PROJECT_PACKAGES_PATH {
            _project_set_selected(row.path)
            _project_inspectors_refresh()
        }
    }
}

// --- The list pane -------------------------------------------------------------

// Builds the list pane's rows for `query`, "" for the folder it shows.
// Returns the search's hit count.
_project_list_build :: proc(query: string) -> int {
    prof.zone()
    clear(&_pv.list_rows)
    virtual.arena_free_all(&_pv.list_arena)

    if query != "" {
        hits := _project_search_hits(query)
        prefix := strings.concatenate({projectWindowData.rootPath, "/"}, context.temp_allocator)
        for h in hits {
            if h.sub != 0 do continue
            display := h.path
            if strings.has_prefix(h.path, prefix) do display = h.path[len(prefix):]
            _project_list_row_add(display, h.path, h.is_dir)
            if !h.is_dir && _pv.expanded[h.path] {
                sub, _ := _project_sub_assets(h.path, false)
                _project_list_rows_add_subs(h.path, sub)
            }
        }
        // Sub-asset hits after the files. Once: an unfolded file hit listed
        // its own already.
        unfolded := len(_pv.list_rows)
        for h in hits {
            if h.sub == 0 do continue
            listed := false
            if _pv.expanded[h.path] {
                for r in _pv.list_rows[:unfolded] do if r.sub == h.sub && r.path == h.path {
                    listed = true
                    break
                }
            }
            if !listed do _project_list_row_add(h.sub_name, h.path, false, h.sub, hit = true)
        }
        return len(hits)
    }

    // The Packages node lists package roots, never the raw packages folder,
    // which would show code in the list.
    if _pv.current_path == _PROJECT_PACKAGES_PATH {
        for pkg in project_packages_list() do _project_list_row_add(pkg.name, pkg.assets_path, true, is_link = pkg.is_link)
        return 0
    }

    entries, ok := project_dir_listing(_pv.current_path)
    if !ok do return 0
    // Folders first, files below them.
    for entry in entries {
        if !entry.is_dir do continue
        path, _ := filepath.join({_pv.current_path, entry.name}, context.temp_allocator)
        _project_list_row_add(entry.name, path, true, is_link = entry.is_link)
    }
    for entry in entries {
        if entry.is_dir do continue
        if strings.has_prefix(entry.name, ".") do continue
        if filepath.ext(entry.name) == ".meta" do continue
        path, _ := filepath.join({_pv.current_path, entry.name}, context.temp_allocator)
        _project_list_row_add(entry.name, path, false)
        if _pv.expanded[path] {
            sub, _ := _project_sub_assets(path, false)
            _project_list_rows_add_subs(path, sub)
        }
    }
    return 0
}

// The index in the list of the row a ping flashes, -1 for none.
@(private = "file")
_list_ping_index :: proc() -> int {
    if _pv.ping_path == "" do return -1
    for r, i in _pv.list_rows do if r.path == _pv.ping_path && r.sub == _pv.ping_sub do return i
    return -1
}

// Draws the list pane as rows.
_project_list_draw_rows :: proc() {
    prof.zone()
    im.PushStyleVarImVec2(.ItemSpacing, im.Vec2{0, 0})
    defer im.PopStyleVar()
    look := _rows_look(_pv.active_pane == .List)
    dl := im.GetWindowDrawList()

    if _pv.scroll_to_list_sel && _pv.active_pane == .List {
        _pv.scroll_to_list_sel = false
        if i := _project_list_index(); i != -1 do _rows_scroll_to(i, look.row_h)
    }
    if _pv.scroll_to_ping {
        if i := _list_ping_index(); i != -1 {
            _pv.scroll_to_ping = false
            _rows_scroll_to(i, look.row_h)
        }
    }
    // A rename brings its row into view.
    if _pv.rename_active && !_pv.rename_in_tree && _pv.rename_focus {
        for r, i in _pv.list_rows do if r.path == _pv.rename_path && r.sub == _pv.rename_sub {
            _rows_scroll_to(i, look.row_h)
            break
        }
    }

    dragging := drag.items() != nil
    clipper: im.ListClipper
    im.ListClipper_Begin(&clipper, i32(len(_pv.list_rows)), look.row_h)
    for im.ListClipper_Step(&clipper) {
        for i in clipper.DisplayStart ..< clipper.DisplayEnd {
            if int(i) >= len(_pv.list_rows) do break
            _list_draw_row(&look, dl, _pv.list_rows[i], dragging)
        }
    }
    im.ListClipper_End(&clipper)
    _rows_drag_scroll()
}

// One row of the list pane: a folder, a file, or a file's sub-asset.
@(private = "file")
_list_draw_row :: proc(look: ^_Rows_Look, dl: ^im.DrawList, row: Project_Row, dragging: bool) {
    im.PushIDInt(_rows_id(row.path, row.sub))
    defer im.PopID()
    is_sub := row.sub != 0
    depth := 1 if is_sub && !row.hit else 0

    // Being renamed: the field where the name is.
    if _pv.rename_active && !_pv.rename_in_tree && _pv.rename_path == row.path && _pv.rename_sub == row.sub {
        rmin := im.GetCursorScreenPos()
        name_x := rmin.x + look.pad_x + f32(depth) * look.indent * 2 + look.arrow_w + look.icon_w + 2
        im.SetCursorScreenPos(im.Vec2{name_x, rmin.y + (look.row_h - im.GetFrameHeight()) * 0.5})
        _project_rename_input(max(rmin.x + look.width - name_x, 40))
        im.SetCursorScreenPos(im.Vec2{rmin.x, rmin.y + look.row_h})
        im.Dummy(im.Vec2{0, 0})
        return
    }

    clicked := im.InvisibleButton("##row", im.Vec2{look.width, look.row_h})
    rmin := im.GetItemRectMin()
    rmax := im.Vec2{rmin.x + look.width, rmin.y + look.row_h}
    hovered := im.IsItemHovered({})
    double := hovered && im.IsMouseDoubleClicked(.Left)

    selected := sel_proj_is_sub(row.path, row.sub) if is_sub else sel_proj_is(row.path)
    if selected {
        im.DrawList_AddRectFilled(dl, rmin, rmax, look.selected)
    } else if hovered && !dragging {
        im.DrawList_AddRectFilled(dl, rmin, rmax, look.hovered)
    }
    _project_item_ping_flash(row.path, row.sub)

    x := rmin.x + look.pad_x + f32(depth) * look.indent * 2
    icon_x := x + look.arrow_w
    name_x := icon_x + look.icon_w + 2
    box := look.row_h - 4

    if is_sub {
        // The provider's own entry, with its preview: under an unfolded file,
        // or as a search hit with its file beside the name.
        raw_guid, known := assets.asset_db_get_guid(row.path)
        provider, has := subassets.find(strings.to_lower(filepath.ext(row.path), context.temp_allocator))
        label := row.name
        if row.hit {
            prefix := strings.concatenate({projectWindowData.rootPath, "/"}, context.temp_allocator)
            where_ := row.path[len(prefix):] if strings.has_prefix(row.path, prefix) else row.path
            label = fmt.tprintf("%s  (%s)", row.name, where_)
        }
        shown, cut := _project_fit_name(label, rmax.x - name_x - look.pad_x)
        if !known || !has {
            im.DrawList_AddText(dl, im.Vec2{icon_x, rmin.y + look.text_pad}, look.dim, icons.ICON_MD_IMAGE)
            im.DrawList_AddText(dl, im.Vec2{name_x, rmin.y + look.text_pad}, look.dim, shown)
            return
        }
        guid := core.Asset_GUID(raw_guid)
        entry := subassets.Sub_Asset{id = row.sub, name = row.name}
        for s in provider.list(row.path, context.temp_allocator) do if s.id == row.sub {
            entry = s
            break
        }
        if tid, uv0, uv1, tok := thumbnails.get_sub(row.path, entry); tok {
            _rows_thumb(dl, im.Vec2{icon_x, rmin.y + 2}, box, tid, uv0, uv1, entry.size.x, entry.size.y)
        } else {
            im.DrawList_AddText(dl, im.Vec2{icon_x, rmin.y + look.text_pad}, look.text, icons.ICON_MD_IMAGE)
        }
        im.DrawList_AddText(dl, im.Vec2{name_x, rmin.y + look.text_pad}, look.text, shown)
        if cut && hovered && !dragging do _project_name_tooltip(label)
        if clicked || double do _project_sub_asset_clicked(row.path, guid, entry, provider)
        _project_sub_asset_right_click(row.path, entry)
        _project_sub_asset_drag(row.path, guid, entry, fmt.ctprintf("%s%s", icons.ICON_MD_IMAGE, entry.name))
        return
    }

    // The fold arrow of a file with sub-assets, in a column every row keeps
    // so the names line up.
    sub, _ := _project_sub_assets(row.path, row.is_dir)
    open := len(sub) > 0 && _pv.expanded[row.path]
    in_arrow := len(sub) > 0 && look.mouse.x < icon_x
    if len(sub) > 0 do _rows_arrow(dl, im.Vec2{x + look.arrow_w * 0.5, rmin.y + look.row_h * 0.5}, open, look.text)

    dim := (!row.is_dir && !is_known_extension(row.path)) || project_file_is_cut(row.path)
    col := look.dim if dim else look.text
    icon := _project_dir_icon(row.is_link) if row.is_dir else _project_file_icon(row.path)
    drew_thumb := false
    if !row.is_dir {
        if tid, tok := thumbnails.get(row.path); tok {
            _rows_thumb(dl, im.Vec2{icon_x, rmin.y + 2}, box, tid, {0, 0}, {1, 1}, 1, 1)
            drew_thumb = true
        }
    }
    if !drew_thumb do im.DrawList_AddText(dl, im.Vec2{icon_x, rmin.y + look.text_pad}, col, strings.clone_to_cstring(icon, context.temp_allocator))

    star := _project_dirty_star(row.path)
    star_w := im.CalcTextSize(" *").x if star != "" else 0
    shown, cut := _project_fit_name(row.name, rmax.x - name_x - look.pad_x - star_w)
    im.DrawList_AddText(dl, im.Vec2{name_x, rmin.y + look.text_pad}, col, shown)
    if star != "" do im.DrawList_AddText(dl, im.Vec2{name_x + im.CalcTextSize(shown).x, rmin.y + look.text_pad}, col, " *")
    if cut && hovered && !dragging do _project_name_tooltip(row.name)

    _project_item_extras(row.path, row.is_dir, fmt.ctprintf("%s%s", icon, row.name))

    if hovered && im.IsMouseClicked(.Left) && in_arrow {
        // Keys are owned clones: folding keeps the entry for the next unfold.
        if row.path in _pv.expanded {
            _pv.expanded[row.path] = !open
        } else {
            _pv.expanded[strings.clone(row.path)] = true
        }
        return
    }
    if (clicked || double) && !in_arrow do _project_item_clicked(row.path, row.is_dir)
}

// A small picture where a row's glyph goes, fitted to a square box.
@(private = "file")
_rows_thumb :: proc(dl: ^im.DrawList, at: im.Vec2, box: f32, id: rawptr, uv0, uv1: [2]f32, w, h: f32) {
    dw, dh := box, box
    if w > 1 || h > 1 {
        scale := min(box / max(w, 1), box / max(h, 1))
        dw, dh = w * scale, h * scale
    }
    p0 := im.Vec2{at.x + (box - dw) * 0.5, at.y + (box - dh) * 0.5}
    im.DrawList_AddImage(dl, im.TextureRef{_TexID = im.TextureID(uintptr(id))}, p0, im.Vec2{p0.x + dw, p0.y + dh}, im.Vec2{uv0.x, uv0.y}, im.Vec2{uv1.x, uv1.y})
}

// --- The grid ------------------------------------------------------------------

// A drag from empty space in the grid: the cells it covers are the
// selection. Kept in the pane's content space, so it follows a scroll.
@(private = "file")
_band_active: bool
@(private = "file")
_band_from: im.Vec2
@(private = "file")
_band_keep: bool

// Draws the list pane as a grid of cells, `cell` points wide: the same rows
// in the same order, a row of cells at a time, the ones on screen only. A
// cell asks for its thumbnail, and a sub-asset's asks its file's provider for
// the sub-asset, which may load the file.
_project_list_draw_grid :: proc(cell: f32) {
    prof.zone()
    cells := _pv.list_rows[:]
    pad := im.GetStyle().ItemSpacing.x
    // Selectables grow their rect by half the item spacing on both sides:
    // each row leads by that much, so the first column stays inside the pane.
    lead := pad * 0.5
    cols := max(int((im.GetContentRegionAvail().x - lead + pad) / (cell + pad)), 1)
    _pv.grid_cols = cols
    label_h := im.GetTextLineHeightWithSpacing()
    origin := im.GetCursorScreenPos()
    row_pitch := cell + label_h + im.GetStyle().ItemSpacing.y
    rows := (len(cells) + cols - 1) / cols

    clipper: im.ListClipper
    im.ListClipper_Begin(&clipper, i32(rows), row_pitch)
    if (_pv.scroll_to_list_sel && _pv.active_pane == .List) || _pv.scroll_to_ping {
        for cl, i in cells {
            selected := sel_proj_is_sub(cl.path, cl.sub) if cl.sub != 0 else sel_proj_is(cl.path)
            pinged := _pv.scroll_to_ping && cl.path == _pv.ping_path && cl.sub == _pv.ping_sub
            if selected || pinged do im.ListClipper_IncludeItemByIndex(&clipper, i32(i / cols))
        }
    }
    for im.ListClipper_Step(&clipper) {
        for row in clipper.DisplayStart ..< clipper.DisplayEnd {
            for col in 0 ..< cols {
                i := int(row) * cols + col
                if i >= len(cells) do break
                cl := cells[i]
                if col > 0 do im.SameLine()
                else do im.SetCursorPosX(im.GetCursorPosX() + lead)
                if cl.sub == 0 {
                    // A search hit's row names its path: its cell, the file.
                    _project_draw_grid_cell(filepath.base(cl.path) if strings.contains(cl.name, "/") else cl.name, cl.path, cl.is_dir, cell, cl.is_link)
                    continue
                }
                raw_guid, known := assets.asset_db_get_guid(cl.path)
                provider, has := subassets.find(strings.to_lower(filepath.ext(cl.path), context.temp_allocator))
                if !known || !has {
                    im.Dummy(im.Vec2{cell, cell + label_h})
                    continue
                }
                entry := subassets.Sub_Asset{id = cl.sub, name = cl.name}
                for s in provider.list(cl.path, context.temp_allocator) do if s.id == cl.sub {
                    entry = s
                    break
                }
                _project_draw_grid_sub_cell(cl.path, core.Asset_GUID(raw_guid), entry, i, provider, cell)
            }
        }
    }
    im.ListClipper_End(&clipper)
    _rows_drag_scroll()

    // The selection band. It starts on empty space, and with Shift or Ctrl
    // it adds to the selection.
    io := im.GetIO()
    if !_band_active && im.IsWindowHovered({}) && !im.IsAnyItemHovered() && im.IsMouseClicked(.Left) && drag.items() == nil {
        _band_active = true
        _band_from = io.MousePos - origin
        _band_keep = io.KeyShift || io.KeyCtrl || io.KeySuper
        if !_band_keep {
            sel_proj_clear()
            _project_set_active("")
            _project_inspectors_refresh()
        }
    }
    if _band_active {
        if !im.IsMouseDown(.Left) {
            _band_active = false
            return
        }
        from := _band_from + origin
        lo := im.Vec2{min(from.x, io.MousePos.x), min(from.y, io.MousePos.y)}
        hi := im.Vec2{max(from.x, io.MousePos.x), max(from.y, io.MousePos.y)}
        if hi.x - lo.x < 3 && hi.y - lo.y < 3 do return
        accent := im.GetStyleColorVec4(.Header)^
        im.DrawList_AddRectFilled(im.GetWindowDrawList(), lo, hi, im.GetColorU32ImVec4({accent.x, accent.y, accent.z, 0.25}))
        im.DrawList_AddRect(im.GetWindowDrawList(), lo, hi, im.GetColorU32ImVec4({accent.x, accent.y, accent.z, 0.9}))
        if !_band_keep do sel_proj_clear()
        last := ""
        for cl, i in cells {
            c_min := im.Vec2{origin.x + lead + f32(i % cols) * (cell + pad), origin.y + f32(i / cols) * row_pitch}
            c_max := im.Vec2{c_min.x + cell, c_min.y + cell + label_h}
            if c_max.x < lo.x || c_min.x > hi.x || c_max.y < lo.y || c_min.y > hi.y do continue
            if cl.sub != 0 {
                if !sel_proj_is_sub(cl.path, cl.sub) do sel_proj_add(cl.path, cl.sub)
            } else if !sel_proj_is(cl.path) {
                sel_proj_add(cl.path)
            }
            last = cl.path
        }
        if last != "" && last != projectWindowData.selectedFile {
            _project_set_active(last)
            _project_inspectors_refresh()
        }
    }
}
