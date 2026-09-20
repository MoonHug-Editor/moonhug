package editor

// Per-view MENU and TOOLBAR, extensible by any package.
//
// The MENU has a button already: dock_tab_menu.odin pins one to the right of
// every dock node's tab bar, and view items are appended to it. A second
// button inside the view would put two of them one above the other.
//
// The TOOLBAR is the view's own header row, so a view draws
// view_chrome_draw(id) where it wants the strip.
//
//   @(view_toolbar={view="Console", order=0})  on proc()      -> a widget
//   @(view_menu={view="Console", label="..."}) on proc()      -> an action
//   @(view_menu={view="Console", label="..."}) on a bool var  -> a toggle
//
// What goes where: frequent controls on the TOOLBAR, rare or modal ones in the
// MENU. Splitting them by any other rule makes users hunt in two places.
//
// The registries are their OWN, not a reserved root inside the main menu tree.
// Hanging view items off that tree would mean the menu bar, the shortcut walk
// and collect_invokable_paths each had to know to skip them — three places
// kept in sync by a naming convention.
//
// The view id is the text after `###` in the window title ("Scene",
// "Console"), which is already what imgui hashes for the ini and dock layout.
// icons.TITLE_* are written so that suffix is stable while the visible label
// is free to change.

import "base:runtime"
import "core:slice"
import "core:strings"
import im "moonhug:external/odin-imgui"
import gfx "moonhug:engine/gfx"

View_Menu_Item :: struct {
	view:  string,
	label: string,
	cstr:  cstring,
	order: int,

	// An action runs. A toggle flips `value`. Same split the main menu makes,
	// and for the same reason: what the item is attached to already says which.
	action: proc(),
	value:  ^bool,

	// Both polled at draw time. `checked` ticks an ACTION whose state is
	// computed — which is what a radio group is, N actions that each set the
	// state and report whether they are the current one.
	enabled: proc() -> bool,
	checked: proc() -> bool,
}

View_Toolbar_Item :: struct {
	view:  string,
	draw:  proc(),
	order: int,
}

@(private = "file") _view_menus: [dynamic]View_Menu_Item
@(private = "file") _view_toolbars: [dynamic]View_Toolbar_Item

// Registered once at startup from view_chrome_generated.odin. Process-global,
// so never borrows the caller's allocator.
view_menu_add_action :: proc(
	view, label: string,
	action: proc(),
	order := 0,
	enabled: proc() -> bool = nil,
	checked: proc() -> bool = nil,
) {
	context.allocator = runtime.default_allocator()
	append(&_view_menus, View_Menu_Item{
		view = view, label = label, cstr = strings.clone_to_cstring(label),
		order = order, action = action, enabled = enabled, checked = checked,
	})
}

view_menu_add_toggle :: proc(view, label: string, value: ^bool, order := 0, enabled: proc() -> bool = nil) {
	context.allocator = runtime.default_allocator()
	append(&_view_menus, View_Menu_Item{
		view = view, label = label, cstr = strings.clone_to_cstring(label),
		order = order, value = value, enabled = enabled,
	})
}

view_toolbar_add_item :: proc(view: string, draw: proc(), order := 0) {
	context.allocator = runtime.default_allocator()
	append(&_view_toolbars, View_Toolbar_Item{view = view, draw = draw, order = order})
}

view_chrome_shutdown :: proc() {
	// Freed under the allocator the labels were cloned with, not whatever is
	// ambient at shutdown — the registries pin default_allocator on the way in.
	context.allocator = runtime.default_allocator()
	for it in _view_menus do delete(it.cstr)
	delete(_view_menus)
	delete(_view_toolbars)
	_view_menus = nil
	_view_toolbars = nil
}

// Sorted by order, then label, so the layout does not depend on which package
// happened to register first.
@(private = "file")
_menu_items_for :: proc(view: string) -> []View_Menu_Item {
	out := make([dynamic]View_Menu_Item, context.temp_allocator)
	for it in _view_menus do if it.view == view do append(&out, it)
	slice.sort_by(out[:], proc(a, b: View_Menu_Item) -> bool {
		return a.order != b.order ? a.order < b.order : a.label < b.label
	})
	return out[:]
}

@(private = "file")
_toolbar_items_for :: proc(view: string) -> []View_Toolbar_Item {
	out := make([dynamic]View_Toolbar_Item, context.temp_allocator)
	for it in _view_toolbars do if it.view == view do append(&out, it)
	slice.sort_by(out[:], proc(a, b: View_Toolbar_Item) -> bool { return a.order < b.order })
	return out[:]
}

@(private = "file")
_item_enabled :: proc(it: View_Menu_Item) -> bool {
    return it.enabled == nil || it.enabled()
}

// The id a title carries: everything after "###". Falls back to the whole
// string, so a title written without the marker still keys something stable.
view_chrome_id :: proc(title: cstring) -> string {
	s := string(title)
	if i := strings.last_index(s, "###"); i >= 0 do return s[i + 3:]
	return s
}

// Horizontal space `view`'s toolbar needs INCLUDING the gap before it, or 0
// when it has none. A view that right-aligns content of its own (the console's
// log-level buttons) reserves this too, or its layout eats the right edge and
// the strip draws off it.
//
// Measuring means drawing the items once off-screen, so the answer is cached
// for the frame: a view asks for the width and then draws, and neither should
// cost a second hidden pass.
view_chrome_width :: proc(view: string) -> f32 {
	if _width_cache.view == view && _width_cache.frame == gfx.frame_index {
		return _width_cache.width
	}
	tools := _toolbar_items_for(view)
	w: f32
	if len(tools) > 0 {
		style := im.GetStyle()
		for _ in tools do w += style.ItemSpacing.x
		w += _view_toolbar_measure(tools)
	}
	_width_cache = {view = view, frame = gfx.frame_index, width = w}
	return w
}

@(private = "file")
_width_cache: struct {
	view:  string,
	frame: u64,
	width: f32,
}

// Draws `view`'s toolbar items, nothing at all when it has none.
//
// The caller does NOT put im.SameLine() before this: it continues the row
// itself, per item, and leaves no pending SameLine behind. A dangling SameLine
// around an empty strip puts whatever the view draws next on the toolbar row —
// which is how the console's log rows ended up in a zero-width child pinned to
// the right edge.
//
// `right_align` puts the strip against the view's right edge, which is what a
// view with a plain header row wants. A view that has already right-aligned
// something of its own passes false and positions the cursor itself, having
// reserved view_chrome_width.
view_chrome_draw :: proc(view: string, right_align := true) {
	tools := _toolbar_items_for(view)
	if len(tools) == 0 do return

	if right_align {
		im.SameLine()
		im.SetCursorPosX(im.GetCursorPosX() + im.GetContentRegionAvail().x - view_chrome_width(view))
	}
	for it, i in tools {
		// Right-aligned, the cursor is already placed for the first item.
		if i > 0 || !right_align do im.SameLine()
		if it.draw != nil do it.draw()
	}
}

// `view`'s menu items, drawn into an already-open menu. The dock tab bar's
// button owns the popup (dock_tab_menu.odin) — this only fills it.
view_menu_draw_items :: proc(view: string) -> (drew: bool) {
	for it in _menu_items_for(view) {
		drew = true
		if it.value != nil {
			im.MenuItemBoolPtr(it.cstr, nil, it.value, _item_enabled(it))
			continue
		}
		ticked := it.checked != nil && it.checked()
		if im.MenuItem(it.cstr, nil, ticked, _item_enabled(it)) {
			if it.action != nil do it.action()
		}
	}
	return drew
}

// Width of the toolbar items, measured by drawing them off-screen once. imgui
// has no way to ask a widget its size before it draws, and the strip has to
// know its total width to right-align.
@(private = "file")
_view_toolbar_measure :: proc(tools: []View_Toolbar_Item) -> f32 {
	start := im.GetCursorPos()
	im.SetCursorPos(im.Vec2{-10000, start.y})
	im.BeginGroup()
	for it, i in tools {
		if i > 0 do im.SameLine()
		if it.draw != nil do it.draw()
	}
	im.EndGroup()
	w := im.GetItemRectSize().x
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
	for it in _view_menus {
		append(&out, strings.concatenate({VIEW_MENU_PREFIX, it.view, "/", it.label}, allocator))
	}
	slice.sort(out[:])
	return out[:]
}

// Invokes "View/<view>/<label>" the way clicking it would: an action runs, a
// toggle flips. `state` is the toggle's value afterwards. False when the path
// names no view item, or its enabled predicate refuses.
view_menu_invoke :: proc(path: string) -> (ok: bool, state: bool) {
	if !strings.has_prefix(path, VIEW_MENU_PREFIX) do return false, false
	rest := path[len(VIEW_MENU_PREFIX):]
	slash := strings.index_byte(rest, '/')
	if slash < 0 do return false, false
	view, label := rest[:slash], rest[slash + 1:]

	for it in _view_menus {
		if it.view != view || it.label != label do continue
		if !_item_enabled(it) do return false, false
		if it.value != nil {
			it.value^ = !it.value^
			return true, it.value^
		}
		if it.action == nil do return false, false
		it.action()
		// An action with a tick predicate is a toggle whose state lives
		// somewhere else — report it, or invoking one says nothing.
		if it.checked != nil do return true, it.checked()
		return true, false
	}
	return false, false
}
