package editor

// Per-view MENU and TAB BAR items, extensible by any package.
//
// Both render in the dock node's TAB BAR (dock_tab_menu.odin): items sit at
// its right end, then the ⋮ button whose popup carries the menu entries.
//
//   @(view_tab_bar={view="Animation", order=0}) on proc()      -> a widget
//   @(view_menu={view="Animation", label="..."}) on proc()     -> an action
//   @(view_menu={view="Animation", label="..."}) on a bool var -> a toggle
//
// THE VIEW OWES THIS NOTHING. No call to make, no width to reserve, no layout
// to choose — and so no silent failure when it forgets. The bar belongs to the
// dock node rather than the view, which also means switching tabs switches the
// items for free, and a view written later gets the feature without knowing.
//
// An earlier version drew the strip inside each view. It cost every view three
// obligations and produced two invisible-layout bugs in a day, so it is gone.
//
// A view's MENU is a menu.MenuNode tree rooted per view, not a list of its
// own: actions, toggles, `checked`, `enabled`, ordering, separators, submenus
// and invoke-by-path are the menu package's, so there is no second
// implementation to drift from the main menu bar's.
//
// The view id is the text after `###` in the window title ("Scene",
// "Animation"), which is already what imgui hashes for the ini and dock
// layout. icons.TITLE_* are written so that suffix is stable while the visible
// label is free to change.

import "base:runtime"
import "core:slice"
import "core:strings"
import im "moonhug:external/odin-imgui"
import gfx "moonhug:engine/gfx"
import "moonhug:editor/widgets"
import "menu"

View_Tab_Bar_Item :: struct {
	view:   string,
	draw:   proc(),
	order:  int,
	// The @(view_tab_bar) that created the item, with its file and line, as
	// rendered by the generator. Shown in the item's tooltip with debug tooltips on.
	origin: string,
}

// One menu TREE per view, the same kind the main menu bar is. Nothing here
// re-implements actions, toggles, `checked`, `enabled`, ordering, separators
// or invoke-by-path — a view menu gets all of it, submenus included, because
// it IS a menu.Menu tree that happens to be rooted per view.
@(private = "file") _view_menus: map[string]^menu.MenuNode
@(private = "file") _view_tab_bar_items: [dynamic]View_Tab_Bar_Item

@(private = "file")
_view_menu_tree :: proc(view: string) -> ^menu.MenuNode {
	if t, ok := _view_menus[view]; ok do return t
	context.allocator = runtime.default_allocator()
	t := menu.tree_make()
	_view_menus[strings.clone(view)] = t
	return t
}

// Registered once at startup from view_chrome_generated.odin. Process-global,
// so never borrows the caller's allocator.
view_menu_add_action :: proc(
    view, label: string,
    action: proc(),
    order := 0,
    enabled: proc() -> bool = nil,
    checked: proc() -> bool = nil,
    origin := "",
) {
    context.allocator = runtime.default_allocator()
    menu.tree_add_item(_view_menu_tree(view), label, "", action, order, enabled, checked, origin)
}

view_menu_add_toggle :: proc(view, label: string, value: ^bool, order := 0, enabled: proc() -> bool = nil, origin := "") {
    context.allocator = runtime.default_allocator()
    menu.tree_add_toggle(_view_menu_tree(view), label, value, order, "", enabled, origin)
}

view_tab_bar_add_item :: proc(view: string, draw: proc(), order := 0, origin := "") {
	context.allocator = runtime.default_allocator()
	append(&_view_tab_bar_items, View_Tab_Bar_Item{view = view, draw = draw, order = order, origin = origin})
}

view_chrome_shutdown :: proc() {
    // Everything here was allocated under default_allocator (the registries
    // pin it on the way in), so it is freed under the same one — not whatever
    // is ambient at shutdown. Under a tracking allocator the mismatch reports
    // every node as a bad free, and under a different one it would crash.
    context.allocator = runtime.default_allocator()
    for view, tree in _view_menus {
        menu.tree_destroy(tree)
        delete(view)
    }
    delete(_view_menus)
    _view_menus = nil
    delete(_view_tab_bar_items)
    _view_tab_bar_items = nil
}

// Sorted by order, so the strip does not depend on registration order.
@(private = "file")
_view_tab_bar_items_for :: proc(view: string) -> []View_Tab_Bar_Item {
	out := make([dynamic]View_Tab_Bar_Item, context.temp_allocator)
	for it in _view_tab_bar_items do if it.view == view do append(&out, it)
	slice.sort_by(out[:], proc(a, b: View_Tab_Bar_Item) -> bool { return a.order < b.order })
	return out[:]
}

// The id a title carries: everything after "###". Falls back to the whole
// string, so a title written without the marker still keys something stable.
view_id_of :: proc(title: cstring) -> string {
	s := string(title)
	if i := strings.last_index(s, "###"); i >= 0 do return s[i + 3:]
	return s
}

// Horizontal space `view`'s tab bar items need including the gap before each,
// or 0 when it has none. The bar reserves this beside the tabs.
//
// Measuring means drawing the items once off-screen, so the answer is cached
// for the frame: a view asks for the view_tab_bar_width and then draws, and neither should
// cost a second hidden pass.
view_tab_bar_width :: proc(view: string) -> f32 {
	if _view_tab_bar_width_cache.view == view && _view_tab_bar_width_cache.frame == gfx.frame_index {
		return _view_tab_bar_width_cache.width
	}
	tools := _view_tab_bar_items_for(view)
	w: f32
	if len(tools) > 0 {
		// Spacing BETWEEN items only. A leading one would push the whole strip
		// away from the menu button beside it, and both already carry their own
		// frame padding.
		w += im.GetStyle().ItemSpacing.x * f32(len(tools) - 1)
		w += _view_tab_bar_measure(tools)
	}
	_view_tab_bar_width_cache = {view = view, frame = gfx.frame_index, width = w}
	return w
}

@(private = "file")
_view_tab_bar_width_cache: struct {
	view:  string,
	frame: u64,
	width: f32,
}

// Draws `view`'s items from exactly where the caller left the cursor, nothing
// at all when it has none.
//
// No SameLine before the first item: the caller positions the strip by screen
// coordinates (the tab bar sits outside any view's layout), and SameLine would
// discard that and continue from whatever was drawn last.
view_tab_bar_draw :: proc(view: string) {
	items := _view_tab_bar_items_for(view)
	for it, i in items {
		if i > 0 do im.SameLine()
		if it.draw == nil do continue
		// Ambient for the duration of the item's draw, so any tooltip it
		// raises can name the attribute that registered it (debug tooltips).
		prev := widgets.ui_origin_push(it.origin)
		it.draw()
		widgets.ui_origin_pop(prev)
	}
}

// `view`'s menu items, drawn into an already-open menu. The dock tab bar's
// button owns the popup (dock_tab_menu.odin) — this only fills it.
view_menu_draw_items :: proc(view: string) -> (drew: bool) {
    if t, ok := _view_menus[view]; ok do return menu.tree_draw(t)
    return false
}

// Width of the items, measured by drawing them off-screen once. imgui has no
// way to ask a widget its size before it draws, and the bar has to know the
// total before placing the strip.
@(private = "file")
_view_tab_bar_measure :: proc(tools: []View_Tab_Bar_Item) -> f32 {
	start := im.GetCursorPos()
	im.SetCursorPos(im.Vec2{-10000, start.y})
	// Its own id scope: these are throwaway copies of widgets that are about
	// to be drawn for real, and without this every item exists twice under one
	// id — which imgui reports as "2 visible items with conflicting ID".
	im.PushID("##measure")
	im.BeginGroup()
	for it, i in tools {
		if i > 0 do im.SameLine()
		if it.draw != nil do it.draw()
	}
	im.EndGroup()
	w := im.GetItemRectSize().x
	im.PopID()
	im.SetCursorPos(start)
	return w
}

// --- The bridge's view of it ------------------------------------------------
//
// View items are as clickable as menu items, so list_menus and invoke_menu
// reach them too, addressed "View/<view>/<label>". Separating the registry
// from the main menu tree must not make them invisible to anything driving the
// editor from outside.

VIEW_MENU_PREFIX :: "View/"

view_menu_paths :: proc(allocator := context.temp_allocator) -> []string {
    out := make([dynamic]string, allocator)
    for view, tree in _view_menus {
        prefix := strings.concatenate({VIEW_MENU_PREFIX, view}, allocator)
        append(&out, ..menu.tree_collect(tree, prefix, allocator))
    }
    slice.sort(out[:])
    return out[:]
}

// Invokes "View/<view>/<path>" the way clicking it would: an action runs, a
// toggle flips. `state` is what a toggle (or an action carrying a `checked`
// predicate) reads afterwards. False when the path names no view item.
view_menu_invoke :: proc(path: string) -> (ok: bool, state: bool) {
    if !strings.has_prefix(path, VIEW_MENU_PREFIX) do return false, false
    rest := path[len(VIEW_MENU_PREFIX):]
    slash := strings.index_byte(rest, '/')
    if slash < 0 do return false, false
    view, item := rest[:slash], rest[slash + 1:]
    tree, has := _view_menus[view]
    if !has do return false, false
    return menu.tree_invoke(tree, item)
}
