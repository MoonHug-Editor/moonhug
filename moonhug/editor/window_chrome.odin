package editor

// Per-window MENU and TAB BAR items, extensible by any package.
//
// Both render in the dock node's TAB BAR (dock_tab_menu.odin): items sit at
// its right end, then the ⋮ button whose popup carries the menu entries.
//
//   @(window_tab_bar={window="Animation", order=0}) on proc(window)  -> a widget
//   @(window_menu={window="Animation", label="..."}) on proc(window) -> an action
//   @(window_menu={window="Animation", label="..."}) on a bool var -> a toggle
//
// A widget's and an action's proc takes the window it acts for
// (session.Window_Ref), so each instance of a window gets its own. A toggle is a
// bool shared by every instance.
//
// THE WINDOW OWES THIS NOTHING. No call to make, no width to reserve, no layout
// to choose — and so no silent failure when it forgets. The bar belongs to the
// dock node rather than the window, which also means switching tabs switches the
// items for free, and a window written later gets the feature without knowing.
//
// An earlier version drew the strip inside each window. It cost every window three
// obligations and produced two invisible-layout bugs in a day, so it is gone.
//
// A window's MENU is a menu.MenuNode tree rooted per window, not a list of its
// own: actions, toggles, `checked`, `enabled`, ordering, separators, submenus
// and invoke-by-path are the menu package's, so there is no second
// implementation to drift from the main menu bar's.
//
// The window id is the text after `###` in the window title ("Scene",
// "Animation"), which is already what imgui hashes for the ini and dock
// layout. icons.TITLE_* are written so that suffix is stable while the visible
// label is free to change.

import "base:runtime"
import "core:slice"
import "core:strings"
import im "moonhug:external/odin-imgui"
import gfx "moonhug:libs/gfx"
import "moonhug:editor/session"
import wnd "moonhug:editor/window"
import "moonhug:editor/widgets"
import "menu"

Window_Tab_Bar_Item :: struct {
	window: string,
	draw:   proc(window: session.Window_Ref),
	order:  int,
	// The @(window_tab_bar) that created the item, with its file and line, as
	// rendered by the generator. Shown in the item's tooltip with debug tooltips on.
	origin: string,
}

// One menu TREE per window, the same kind the main menu bar is. Nothing here
// re-implements actions, toggles, `checked`, `enabled`, ordering, separators
// or invoke-by-path — a window menu gets all of it, submenus included, because
// it IS a menu.Menu tree that happens to be rooted per window.
@(private = "file") _window_menus: map[string]^menu.MenuNode
@(private = "file") _window_tab_bar_items: [dynamic]Window_Tab_Bar_Item

@(private = "file")
_window_menu_tree :: proc(window: string) -> ^menu.MenuNode {
	if t, ok := _window_menus[window]; ok do return t
	context.allocator = runtime.default_allocator()
	t := menu.tree_make()
	_window_menus[strings.clone(window)] = t
	return t
}

// Adds an item to a window's menu, the ⋮ button in its dock tab bar.
//
// `window` is the window's id, the text after ### in its window title ("Scene",
// "Animation"), and `label` is the item's path inside that menu. On a proc the
// item is an action, on a bool variable a toggle. `order`, `enabled` and
// `checked` work as on @(menu_item). The action and both predicates take the
// window they act for, so each instance of a window gets its own.
//
// Registered once at startup from window_chrome_generated.odin. Process-global,
// so never borrows the caller's allocator.
@(extension_point={attribute="window_menu", target="proc var", fields="window label order enabled checked"})
window_menu_add_action :: proc(
    window, label: string,
    action: proc(window: session.Window_Ref),
    order := 0,
    enabled: proc(window: session.Window_Ref) -> bool = nil,
    checked: proc(window: session.Window_Ref) -> bool = nil,
    origin := "",
) {
    context.allocator = runtime.default_allocator()
    menu.tree_add_window_item(_window_menu_tree(window), label, action, order, enabled, checked, origin)
}

window_menu_add_toggle :: proc(window, label: string, value: ^bool, order := 0, enabled: proc() -> bool = nil, origin := "") {
    context.allocator = runtime.default_allocator()
    menu.tree_add_toggle(_window_menu_tree(window), label, value, order, "", enabled, origin)
}

// A submenu of `window`'s menu whose contents `draw` emits each frame it is
// open: any widgets (a slider, checkboxes, which leave the menu open). `draw`
// gets the window the menu is open for.
window_menu_add_dynamic :: proc(window, label: string, draw: proc(window: session.Window_Ref), order := 0, origin := "") {
	context.allocator = runtime.default_allocator()
	menu.tree_add_window_dynamic(_window_menu_tree(window), label, draw, order, origin)
}

// Adds a widget to a window's dock tab bar, left of its ⋮ menu button.
//
// `window` is the window's id, the text after ### in its window title, and items
// sort by `order`. The proc draws the widget with imgui for the window it is
// given, and should keep a fixed width. The bar belongs to the dock node, so
// the window itself needs no code.
@(extension_point={attribute="window_tab_bar", target="proc", fields="window order"})
window_tab_bar_add_item :: proc(window: string, draw: proc(window: session.Window_Ref), order := 0, origin := "") {
	context.allocator = runtime.default_allocator()
	append(&_window_tab_bar_items, Window_Tab_Bar_Item{window = window, draw = draw, order = order, origin = origin})
}

window_chrome_shutdown :: proc() {
    // Everything here was allocated under default_allocator (the registries
    // pin it on the way in), so it is freed under the same one — not whatever
    // is ambient at shutdown. Under a tracking allocator the mismatch reports
    // every node as a bad free, and under a different one it would crash.
    context.allocator = runtime.default_allocator()
    for window, tree in _window_menus {
        menu.tree_destroy(tree)
        delete(window)
    }
    delete(_window_menus)
    _window_menus = nil
    delete(_window_tab_bar_items)
    _window_tab_bar_items = nil
    // Registered by the same generated proc, so released with it.
    toolbar_shutdown()
}

// Sorted by order, so the strip does not depend on registration order.
@(private = "file")
_window_tab_bar_items_for :: proc(window: string) -> []Window_Tab_Bar_Item {
	out := make([dynamic]Window_Tab_Bar_Item, context.temp_allocator)
	for it in _window_tab_bar_items do if it.window == window do append(&out, it)
	slice.sort_by(out[:], proc(a, b: Window_Tab_Bar_Item) -> bool { return a.order < b.order })
	// A window that declares a lock gets its padlock first, from the
	// shell, the same for every such window (window_lock.odin).
	if wnd.lock_mode(window) != .None {
		inject_at(&out, 0, Window_Tab_Bar_Item{window = window, draw = _window_lock_tab_item, origin = "@(editor_window lock)  moonhug/editor/window_chrome.odin"})
	}
	return out[:]
}

@(private = "file")
_window_lock_tab_item :: proc(window: session.Window_Ref) {
	session.window_lock_button(window.key)
}

// The window id a title carries: everything after "###", up to the `/` an
// instance of a window adds (`shader_graph/<asset guid>`), so every instance
// of a window shares its window's menu and tab bar items. Falls back to the
// whole string, so a title written without the marker still keys something
// stable.
window_id_of :: proc(title: cstring) -> string {
	key := window_key_of(title)
	if slash := strings.index_byte(key, '/'); slash >= 0 do return key[:slash]
	return key
}

// The key a title carries: everything after "###", an instance's own id.
window_key_of :: proc(title: cstring) -> string {
	s := string(title)
	if i := strings.last_index(s, "###"); i >= 0 do return s[i + 3:]
	return s
}

// Horizontal space `window`'s tab bar items need including the gap before each,
// or 0 when it has none. The bar reserves this beside the tabs.
//
// Measuring means drawing the items once off-screen, so the answer is cached
// for the frame: a window asks for the window_tab_bar_width and then draws, and neither should
// cost a second hidden pass.
window_tab_bar_width :: proc(window: session.Window_Ref) -> f32 {
	if _window_tab_bar_width_cache.window == window.key && _window_tab_bar_width_cache.frame == gfx.frame_index {
		return _window_tab_bar_width_cache.width
	}
	tools := _window_tab_bar_items_for(window.id)
	w: f32
	if len(tools) > 0 {
		// Spacing BETWEEN items only. A leading one would push the whole strip
		// away from the menu button beside it, and both already carry their own
		// frame padding.
		w += im.GetStyle().ItemSpacing.x * f32(len(tools) - 1)
		w += _window_tab_bar_measure(tools, window)
	}
	_window_tab_bar_width_cache = {window = window.key, frame = gfx.frame_index, width = w}
	return w
}

@(private = "file")
_window_tab_bar_width_cache: struct {
	window: string,
	frame: u64,
	width: f32,
}

// Draws `window`'s items from exactly where the caller left the cursor, nothing
// at all when it has none.
//
// No SameLine before the first item: the caller positions the strip by screen
// coordinates (the tab bar sits outside any window's layout), and SameLine would
// discard that and continue from whatever was drawn last.
window_tab_bar_draw :: proc(window: session.Window_Ref) {
	items := _window_tab_bar_items_for(window.id)
	for it, i in items {
		if i > 0 do im.SameLine()
		if it.draw == nil do continue
		// Ambient for the duration of the item's draw, so any tooltip it
		// raises can name the attribute that registered it (debug tooltips).
		prev := widgets.ui_origin_push(it.origin)
		it.draw(window)
		widgets.ui_origin_pop(prev)
	}
}

// `window`'s menu items, drawn into an already-open menu. The dock tab bar's
// button owns the popup (dock_tab_menu.odin) — this only fills it.
window_menu_draw_items :: proc(window: session.Window_Ref) -> (drew: bool) {
    if t, ok := _window_menus[window.id]; ok do return menu.tree_draw(t, window)
    return false
}

// Width of the items, measured by drawing them off-screen once. imgui has no
// way to ask a widget its size before it draws, and the bar has to know the
// total before placing the strip.
@(private = "file")
_window_tab_bar_measure :: proc(tools: []Window_Tab_Bar_Item, window: session.Window_Ref) -> f32 {
	start := im.GetCursorPos()
	im.SetCursorPos(im.Vec2{-10000, start.y})
	// Its own id scope: these are throwaway copies of widgets that are about
	// to be drawn for real, and without this every item exists twice under one
	// id — which imgui reports as "2 visible items with conflicting ID".
	im.PushID("##measure")
	im.BeginGroup()
	for it, i in tools {
		if i > 0 do im.SameLine()
		if it.draw != nil do it.draw(window)
	}
	im.EndGroup()
	w := im.GetItemRectSize().x
	im.PopID()
	im.SetCursorPos(start)
	return w
}

// --- The bridge's window of it ------------------------------------------------
//
// Window items are as clickable as menu items, so list_menus and invoke_menu
// reach them too, addressed "Window Menu/<window>/<label>". Separating the registry
// from the main menu tree must not make them invisible to anything driving the
// editor from outside.

WINDOW_MENU_PREFIX :: "Window Menu/"

window_menu_paths :: proc(allocator := context.temp_allocator) -> []string {
    out := make([dynamic]string, allocator)
    for window, tree in _window_menus {
        prefix := strings.concatenate({WINDOW_MENU_PREFIX, window}, allocator)
        append(&out, ..menu.tree_collect(tree, prefix, allocator))
    }
    slice.sort(out[:])
    return out[:]
}

// Invokes "Window Menu/<window>/<path>" the way clicking it would: an action runs, a
// toggle flips. `state` is what a toggle (or an action carrying a `checked`
// predicate) reads afterwards. False when the path names no window item.
window_menu_invoke :: proc(path: string) -> (ok: bool, state: bool) {
    if !strings.has_prefix(path, WINDOW_MENU_PREFIX) do return false, false
    rest := path[len(WINDOW_MENU_PREFIX):]
    slash := strings.index_byte(rest, '/')
    if slash < 0 do return false, false
    window, item := rest[:slash], rest[slash + 1:]
    tree, has := _window_menus[window]
    if !has do return false, false
    return menu.tree_invoke(tree, item, session.window_ref_of(window))
}
