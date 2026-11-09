package menu

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"
import im "moonhug:external/odin-imgui"
import "moonhug:editor/keymap"
import "moonhug:editor/session"
import "moonhug:editor/widgets"

MenuEntryKind :: enum {
	Submenu,
	Action,
	Toggle,
	Separator,
	// A submenu whose items are drawn by a proc at draw time instead of being
	// registered at init: Recent Scenes. The escape hatch
	// for an item set that only exists at runtime, not the general form —
	// nothing inside it can be listed, invoked by path, or bound to a key,
	// because the tree does not know what is in it.
	Dynamic,
}

ORDER_DEFAULT :: 1 << 30

// Menu section bands (Unity's priority bands): items register once into a
// real menu, and popups mirror an order slice of it via draw_menu_sections.
//
// GameObject: the creation section is everything up to and including
// ORDER_DEFAULT — a plain @(menu_item) with no order lands there, so it
// mirrors into the hierarchy context menu for free.
GO_SECTION_PARENTING :: ORDER_DEFAULT + 1_000_000
GO_SECTION_VIEW      :: ORDER_DEFAULT + 2_000_000

// Edit: the selection-ops band (Cut..Delete) — mirrored to the top of the
// hierarchy context menu.
EDIT_SECTION_SELECTION_MIN :: -50
EDIT_SECTION_SELECTION_MAX :: -41

MenuNode :: struct {
	name:          string,
	name_cstr:     cstring,
	shortcut:      string,
	shortcut_cstr: cstring,
	// The main menu item's command id (editor/keymap): the shortcut it shows
	// is the "Menu" keymap's live binding, overrides included. "" for a window
	// menu's item.
	command:       string,
	kind:          MenuEntryKind,
	action:        proc(),
	value:         ^bool,
	enabled:       proc() -> bool, // nil = always enabled
	// Draws the item checked when it returns true. An Action whose state is
	// computed rather than stored in a bool: a radio group is N actions that
	// each set the state and each report whether they are the current one.
	checked:       proc() -> bool,
	draw:          proc(), // Dynamic: emits the submenu's items, called while it is open
	// A window menu's action and predicates take the window they act for
	// (window_chrome.odin), set instead of `action`, `enabled` and `checked`.
	// The tree's draw and invoke pass that window down.
	window_action:   proc(window: session.Window_Ref),
	window_enabled:  proc(window: session.Window_Ref) -> bool,
	window_checked:  proc(window: session.Window_Ref) -> bool,
	window_draw:     proc(window: session.Window_Ref), // a window menu's Dynamic, set instead of `draw`
	children:      [dynamic]^MenuNode,
	order:         int, // sort key (lower = earlier); ORDER_DEFAULT when unspecified
	// The @(menu_item) that created this node, with its file and line, as
	// rendered by the generator. Shown in the item's tooltip with debug tooltips on.
	// Empty for a node created by hand or as a path segment.
	origin:        string,
}

// THE main menu bar's tree. Every add_menu_* / invoke_path / collect_* below
// is a one-line wrapper that passes it to the tree_* proc of the same name.
//
// The tree is a PARAMETER rather than a hidden global because there is more
// than one menu: each window has its own (window_chrome.odin), shown in its tab
// bar's popup. A window menu is the same tree, the same node kinds and the same
// drawing — only the root differs — so submenus, ordering, separators,
// `checked`, `enabled` and invoke-by-path work there without a second
// implementation that would drift from this one.
_menu_root: ^MenuNode

tree_make :: proc() -> ^MenuNode {
	root := new(MenuNode)
	root.kind = .Submenu
	root.order = ORDER_DEFAULT
	root.children = make([dynamic]^MenuNode)
	return root
}

tree_destroy :: proc(root: ^MenuNode) {
	if root == nil do return
	_destroy_node(root)
}

// init_menu initializes the menu system. Call once before adding items.
init_menu :: proc() {
	_menu_root = tree_make()
}

_NodeOrder :: struct {
	node:  ^MenuNode,
	order: int,
}

// _sort_children_by_order sorts node's children by top_order[path] (lower = earlier), then recurs into submenus.
// parent_path is the path to node (e.g. "" for root, "Window" for Window's children). Keys are "ParentPath/ChildName".
_sort_children_by_order :: proc(node: ^MenuNode, parent_path: string, top_order: map[string]int) {
	children := &node.children
	if len(children) <= 1 do return
	pairs := make([]_NodeOrder, len(children))
	defer delete(pairs)
	for c, i in children {
		path := c.name
		if parent_path != "" do path = fmt.tprintf("%s/%s", parent_path, c.name)
		ord := path in top_order ? top_order[path] : c.order
		pairs[i] = {c, ord}
	}
	// STABLE sort: equal orders keep registration order (an unstable sort
	// scrambled ties — e.g. the Component menu, which prebuild already emits
	// alphabetically and registers in one run).
	slice.stable_sort_by(pairs[:], proc(a, b: _NodeOrder) -> bool {
		return a.order < b.order
	})
	clear(children)
	for p in pairs do append(children, p.node)
	for c in children {
		if c.kind == .Submenu do _sort_children_by_order(c, parent_path == "" ? c.name : fmt.tprintf("%s/%s", parent_path, c.name), top_order)
	}
}

// sort_top_menu sorts menu nodes at every level by top_order (lower = left). Keys are paths, e.g. "File", "Window", "Window/Theme".
// Call after all add_menu_*. Caller allocates and defers delete of the map.
sort_top_menu :: proc(top_order: map[string]int) {
	_sort_children_by_order(_menu_root, "", top_order)
}

shutdown_menu :: proc() {
	tree_destroy(_menu_root)
	_menu_root = nil
}

_destroy_node :: proc(node: ^MenuNode) {
	for child in node.children {
		_destroy_node(child)
	}
	delete(node.children)
	if node.name != "" do delete(node.name)
	if node.name_cstr != nil do delete(node.name_cstr)
	if node.shortcut != "" do delete(node.shortcut)
	if node.shortcut_cstr != nil do delete(node.shortcut_cstr)
	free(node)
}

draw_menu_subtree :: proc(path: string) {
	_draw_menu_children(_get_or_create_path(_menu_root, path))
}

// Draws every item under `root`. A window's menu is a whole tree rather than a
// subtree of the main one, so it draws from its root.
// Draws a tree's items into an open menu. A window menu passes the window its
// items act for.
tree_draw :: proc(root: ^MenuNode, window := session.Window_Ref{}) -> (drew: bool) {
	if root == nil || len(root.children) == 0 do return false
	_draw_menu_children(root, window)
	return true
}

// Menu_Section selects a slice of one subtree's direct children by order band.
// Build with section() — the struct's zero value filters everything out.
Menu_Section :: struct {
	path:      string,
	min_order: int,
	max_order: int,
}

section :: proc(path: string, min_order := min(int), max_order := max(int)) -> Menu_Section {
	return {path, min_order, max_order}
}

// draw_menu_sections draws several subtree slices inline into the currently
// open menu/popup, with one separator between non-empty sections. Context
// menus compose registered items this way (e.g. the hierarchy popup = the
// "Hierarchy" ops + the GameObject creation band) instead of hardcoding
// entries, so plugins can extend every section.
draw_menu_sections :: proc(sections: []Menu_Section) {
	prev_drawn := false
	for s in sections {
		node := _get_or_create_path(_menu_root, s.path)
		has_items := false
		for child in node.children {
			if child.kind != .Separator && child.order >= s.min_order && child.order <= s.max_order {
				has_items = true
				break
			}
		}
		if !has_items do continue
		if prev_drawn do im.Separator()
		for child in node.children {
			if child.order < s.min_order || child.order > s.max_order do continue
			_draw_menu_child(child)
		}
		prev_drawn = true
	}
}

// Adds an item to the editor's main menu bar.
//
// On a proc the item is an action that calls it, on a bool variable a toggle
// that flips it. `path` is "Menu/Submenu/Item", `order` sorts siblings (lower
// first), `shortcut` is a chord like "Ctrl+S", or several separated by a
// comma and a space, "Ctrl+Shift+Z, Ctrl+Y". `enabled` and `checked` name
// procs in the same package, polled each frame: one greys the item out, the
// other draws a tick, for computed toggles and radio groups.
//
// path format: "RootItem/NodeItem1/NodeItem2/LeafItem"
// add_menu_item adds an action at the given path. When selected, action is called.
// enabled (optional) is polled at draw time; nil means always enabled.
// checked (optional) is polled the same way and draws the item with a tick —
// for a toggle whose state is computed, and for radio groups, where each option
// is an action that sets the state and reports whether it is the current one.
// `id` is the item's command id (editor/keymap), the declaring proc's
// qualified name from the generator, which keeps the user's bindings when the
// item moves in the menu. The path when empty. `help` is one sentence on what
// the item does, shown in its tooltip and by the command palette.
@(extension_point={attribute="menu_item", target="proc var", fields="path order shortcut enabled checked id help"})
add_menu_item :: proc(path: string, shortcut: string, action: proc(), order: int = ORDER_DEFAULT, enabled: proc() -> bool = nil, checked: proc() -> bool = nil, origin := "", id := "", help := "") {
	tree_add_item(_menu_root, path, shortcut, action, order, enabled, checked, origin)
	_menu_command(_get_or_create_path(_menu_root, path), path, id, help)
}

tree_add_item :: proc(root: ^MenuNode, path: string, shortcut: string, action: proc(), order: int = ORDER_DEFAULT, enabled: proc() -> bool = nil, checked: proc() -> bool = nil, origin := "") {
	node := _get_or_create_path(root, path)
	node.kind = .Action
	node.order = order
	if node.shortcut_cstr != nil {
		mem.delete_cstring(node.shortcut_cstr)
	}
	// strings.clone("") still allocates, and the free guard below skips empty
	// strings — so cloning a missing shortcut leaked it. Most items have none.
	node.shortcut = shortcut == "" ? "" : strings.clone(shortcut)
	node.shortcut_cstr = strings.clone_to_cstring(node.shortcut)
	node.action = action
	node.enabled = enabled
	node.checked = checked
	node.origin = origin
}

// A window menu's action: the action and its predicates take the window they act
// for (window_chrome.odin).
tree_add_window_item :: proc(root: ^MenuNode, path: string, action: proc(window: session.Window_Ref), order: int = ORDER_DEFAULT, enabled: proc(window: session.Window_Ref) -> bool = nil, checked: proc(window: session.Window_Ref) -> bool = nil, origin := "") {
	node := _get_or_create_path(root, path)
	node.kind = .Action
	node.order = order
	node.window_action = action
	node.window_enabled = enabled
	node.window_checked = checked
	node.origin = origin
}

// add_menu_toggle adds a checkbox at the given path that toggles the value.
// Declared as @(menu_item) on a bool variable — the same attribute an action
// uses on a proc, since what it is attached to already says which it is.
// A shortcut ("Ctrl+1" — Ctrl renders as Cmd on macOS) toggles it globally.
add_menu_toggle :: proc(path: string, value: ^bool, order: int = ORDER_DEFAULT, shortcut := "", enabled: proc() -> bool = nil, origin := "", id := "", help := "") {
	tree_add_toggle(_menu_root, path, value, order, shortcut, enabled, origin)
	_menu_command(_get_or_create_path(_menu_root, path), path, id, help)
}

tree_add_toggle :: proc(root: ^MenuNode, path: string, value: ^bool, order: int = ORDER_DEFAULT, shortcut := "", enabled: proc() -> bool = nil, origin := "") {
	node := _get_or_create_path(root, path)
	node.kind = .Toggle
	node.order = order
	if node.shortcut_cstr != nil {
		mem.delete_cstring(node.shortcut_cstr)
	}
	// strings.clone("") still allocates, and the free guard below skips empty
	// strings — so cloning a missing shortcut leaked it. Most items have none.
	node.shortcut = shortcut == "" ? "" : strings.clone(shortcut)
	node.shortcut_cstr = strings.clone_to_cstring(node.shortcut)
	node.value = value
	node.enabled = enabled
	node.origin = origin
}

// Adds a submenu whose items a proc draws each frame it is open.
//
// For item sets that exist only at runtime, like Recent Scenes. The proc emits
// plain im.MenuItem calls, `path` and `order` place the submenu. Its items
// cannot be listed or invoked by path over MCP, nor bound to a shortcut, so
// @(menu_item) stays the form for anything known at build time.
//
// A submenu at `path` whose contents `draw` emits each frame it is open, with
// plain im.MenuItem calls. See MenuEntryKind.Dynamic for what it gives up.
@(extension_point={attribute="menu_dynamic", target="proc", fields="path order"})
add_menu_dynamic :: proc(path: string, draw: proc(), order: int = ORDER_DEFAULT, origin := "") {
	tree_add_dynamic(_menu_root, path, draw, order, origin)
}

tree_add_dynamic :: proc(root: ^MenuNode, path: string, draw: proc(), order: int = ORDER_DEFAULT, origin := "") {
	node := _get_or_create_path(root, path)
	node.kind = .Dynamic
	node.draw = draw
	node.order = order
	node.origin = origin
}

// A window menu's Dynamic: `draw` gets the window the menu is drawn for.
tree_add_window_dynamic :: proc(root: ^MenuNode, path: string, draw: proc(window: session.Window_Ref), order: int = ORDER_DEFAULT, origin := "") {
	node := _get_or_create_path(root, path)
	node.kind = .Dynamic
	node.window_draw = draw
	node.order = order
	node.origin = origin
}

// Adds a separator line to the menu at `path`, the parent menu ("File").
//
// It goes on an empty proc. `order` places it among the menu's items, after
// the items that share its order. Several separators at one path are how a
// menu is split into sections.
//
// add_menu_separator adds a separator in the menu at the given path (path = parent menu, e.g. "File").
@(extension_point={attribute="menu_separator", target="proc", fields="path order"})
add_menu_separator :: proc(path: string, order: int = ORDER_DEFAULT) {
	tree_add_separator(_menu_root, path, order)
}

tree_add_separator :: proc(root: ^MenuNode, path: string, order: int = ORDER_DEFAULT) {
	parent := _get_or_create_path(root, path)
	sep := new(MenuNode)
	sep.kind = .Separator
	sep.name = ""
	sep.order = order
	sep.children = make([dynamic]^MenuNode)
	append(&parent.children, sep)
}

// Finds an existing node without creating path segments (nil = no such path).
find_path :: proc(path: string) -> ^MenuNode {
	return tree_find(_menu_root, path)
}

tree_find :: proc(root: ^MenuNode, path: string) -> ^MenuNode {
	parts := strings.split(path, "/", context.temp_allocator)
	node := root
	for part in parts {
		name := strings.trim_space(part)
		if name == "" do continue
		node = _find_child(node, name)
		if node == nil do return nil
	}
	return node
}

// Whether `node` is something invoke_path can fire. Actions and toggles both
// are: clicking either does something. Submenus and separators are not.
@(private = "file")
_node_invokable :: proc(node: ^MenuNode) -> bool {
	if node == nil do return false
	#partial switch node.kind {
	case .Action: return node.action != nil || node.window_action != nil
	case .Toggle: return node.value != nil
	}
	return false
}

// Invokes the item at `path` as clicking it would, honoring its enabled
// predicate: an Action runs, a Toggle flips. `state` is the toggle's value
// afterwards, so a caller that cannot see the menu knows where it landed —
// flipping is not idempotent, and there is no other way to read it back.
// False when the path doesn't exist, isn't invokable, or is disabled.
invoke_path :: proc(path: string) -> (ok: bool, state: bool) {
	return tree_invoke(_menu_root, path)
}

tree_invoke :: proc(root: ^MenuNode, path: string, window := session.Window_Ref{}) -> (ok: bool, state: bool) {
	node := tree_find(root, path)
	if !_node_invokable(node) do return false, false
	if !_node_enabled(node, window) do return false, false
	#partial switch node.kind {
	case .Action:
		_node_run(node, window)
		// An action with a tick predicate IS a toggle or a radio option, so
		// the reply says where it landed — without it a caller that cannot see
		// the menu learns nothing from invoking one.
		if node.checked != nil || node.window_checked != nil do return true, _node_ticked(node, window)
	case .Toggle:
		node.value^ = !node.value^
		return true, node.value^
	}
	return true, false
}

// Every path invoke_path accepts ("Edit/Undo", "Help/Input Debug", ...),
// temp-allocated. Toggles are included: they are as clickable as actions, and
// leaving them out made them invisible to anything driving the menu from
// outside, with no hint that they existed.
collect_invokable_paths :: proc(allocator := context.temp_allocator) -> []string {
	return tree_collect(_menu_root, "", allocator)
}

// Every invokable path under `root`, each prefixed with `prefix` — a window menu
// passes "Window Menu/<window>" so its items address the same way main-menu ones do.
tree_collect :: proc(root: ^MenuNode, prefix := "", allocator := context.temp_allocator) -> []string {
	if root == nil do return nil
	out := make([dynamic]string, allocator)
	walk :: proc(node: ^MenuNode, prefix: string, out: ^[dynamic]string, allocator: mem.Allocator) {
		for child in node.children {
			path := prefix == "" ? child.name : strings.concatenate({prefix, "/", child.name}, allocator)
			if _node_invokable(child) {
				append(out, path)
			}
			walk(child, path, out, allocator)
		}
	}
	walk(root, prefix, &out, allocator)
	return out[:]
}

// The node at `path`, nil when no item registered under it. For widgets that
// present a subtree their own way (the Add Component popup).
node_at :: proc(path: string) -> ^MenuNode {
	return tree_find(_menu_root, path)
}

node_enabled :: proc(node: ^MenuNode) -> bool {
	return _node_enabled(node)
}

_get_or_create_path :: proc(root: ^MenuNode, path: string) -> ^MenuNode {
	parts := strings.split(path, "/")
	defer delete(parts)
	if len(parts) == 0 do return root
	node := root
	for i in 0 ..< len(parts) {
		name := strings.trim_space(parts[i])
		if name == "" do continue
		child := _find_child(node, name)
		if child == nil {
			child = new(MenuNode)
			child.name, _ = strings.clone(name)
			child.name_cstr = strings.clone_to_cstring(child.name)
			child.kind = .Submenu
			child.order = ORDER_DEFAULT
			child.children = make([dynamic]^MenuNode)
			append(&node.children, child)
		}
		node = child
	}
	return node
}

_find_child :: proc(node: ^MenuNode, name: string) -> ^MenuNode {
	for c in node.children {
		if c.kind == .Separator do continue
		if c.name == name do return c
	}
	return nil
}

// --- Commands -------------------------------------------------------------
//
// Every item and toggle of the main menu is a command named by its path
// ("Edit/Undo"), and its shortcut is a binding in the "Menu" keymap, so the
// keymap resolver (editor/keymap) runs it whether the menu is open or not.
// The node is the command's data: the predicates it carries answer for it.

@(private = "file")
_menu_keymap: ^keymap.Keymap

@(private = "file")
_menu_command :: proc(node: ^MenuNode, path: string, id: string, help: string) {
	node.command = keymap.command_add_data(path, _menu_command_run, node, _menu_command_enabled, node.origin, id, help = help).id
	if node.shortcut == "" do return
	if _menu_keymap == nil {
		_menu_keymap = keymap.add("Menu", "", nil, origin = "menu/menu.odin")
	}
	// A re-registered item binds once: drop its earlier binding.
	keymap.unbind(_menu_keymap, node.command)
	for chord in keymap.split_chords(node.shortcut) do keymap.bind(_menu_keymap, chord, node.command)
}

// The chords of the item's command in the "Menu" keymap, as shown. Temp.
@(private = "file")
_menu_chords :: proc(node: ^MenuNode) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	if node.command == "" do return out[:]
	if km := keymap.find("Menu"); km != nil {
		c := keymap.command(node.command)
		for &b in km.bindings do if keymap.bound(&b, c, node.command) do append(&out, keymap.format_chord(b.chord))
	}
	return out[:]
}

// How many of an item's chords the menu shows. The rest go to its tooltip.
@(private = "file")
_MENU_CHORDS_SHOWN :: 2

// The shortcut an item shows: the "Menu" keymap's bindings for its command,
// so an override shows in the menu, the first _MENU_CHORDS_SHOWN of them.
// An item without a command (a window menu's) shows the declared one.
@(private = "file")
_menu_shortcut_label :: proc(node: ^MenuNode) -> cstring {
	if node.command != "" {
		chords := _menu_chords(node)
		if len(chords) == 0 do return ""
		return strings.clone_to_cstring(strings.join(chords[:min(len(chords), _MENU_CHORDS_SHOWN)], ", ", context.temp_allocator), context.temp_allocator)
	}
	return node.shortcut_cstr if node.shortcut_cstr != nil else ""
}

// The item's tooltip: its command's help, why it cannot run when it is
// disabled, and every chord when the item shows only some. "" for none.
@(private = "file")
_menu_tip :: proc(node: ^MenuNode) -> cstring {
	lines := make([dynamic]string, context.temp_allocator)
	if c := keymap.command(node.command); c != nil {
		if c.help != "" do append(&lines, c.help)
		if enabled, reason := keymap.command_state(c); !enabled && reason != "" do append(&lines, reason)
	}
	chords := _menu_chords(node)
	if len(chords) > _MENU_CHORDS_SHOWN do append(&lines, strings.join(chords, ", ", context.temp_allocator))
	return strings.clone_to_cstring(strings.join(lines[:], "\n", context.temp_allocator), context.temp_allocator)
}

// The item's tooltip, built only while the item is hovered: the reason runs
// the item's enabled proc again.
@(private = "file")
_menu_item_tooltip :: proc(node: ^MenuNode) {
	flags := im.HoveredFlags_AllowWhenDisabled
	if !im.IsItemHovered(flags) do return
	widgets.tooltip(_menu_tip(node), flags)
}

@(private = "file")
_menu_command_run :: proc(data: rawptr) {
	node := (^MenuNode)(data)
	switch node.kind {
	case .Action:
		if node.action != nil do node.action()
	case .Toggle:
		if node.value != nil do node.value^ = !node.value^
	case .Separator, .Dynamic, .Submenu:
	}
}

@(private = "file")
_menu_command_enabled :: proc(data: rawptr) -> bool {
	return _node_enabled((^MenuNode)(data))
}

_node_enabled :: proc(node: ^MenuNode, window := session.Window_Ref{}) -> bool {
	if node.window_enabled != nil do return node.window_enabled(window)
	return node.enabled == nil || node.enabled()
}

_node_ticked :: proc(node: ^MenuNode, window: session.Window_Ref) -> bool {
	if node.window_checked != nil do return node.window_checked(window)
	return node.checked != nil && node.checked()
}

_node_run :: proc(node: ^MenuNode, window: session.Window_Ref) {
	if node.window_action != nil {
		node.window_action(window)
	} else if node.action != nil {
		node.action()
	}
}

_draw_menu_children :: proc(node: ^MenuNode, window := session.Window_Ref{}) {
	for child in node.children {
		_draw_menu_child(child, window)
	}
}
_draw_menu_child :: proc(child: ^MenuNode, window := session.Window_Ref{}) {
	switch child.kind {
	case .Separator:
		im.Separator()
	case .Dynamic:
		// The header is the registered element, so it carries the origin. Its
		// tooltip only shows while the submenu is closed: once open, imgui's
		// "last item" is inside the child window.
		prev := widgets.ui_origin_push(child.origin)
		defer widgets.ui_origin_pop(prev)
		if im.BeginMenu(child.name_cstr, _node_enabled(child, window)) {
			if child.draw != nil do child.draw()
			if child.window_draw != nil do child.window_draw(window)
			im.EndMenu()
		} else {
			widgets.tooltip("", im.HoveredFlags_AllowWhenDisabled)
		}
	case .Submenu, .Action, .Toggle:
		if child.kind == .Submenu || len(child.children) > 0 {
			if im.BeginMenu(child.name_cstr, true) {
				_draw_menu_children(child, window)
				im.EndMenu()
			}
		} else {
			// An item with no help, no reason and no hidden chords has an
			// empty tooltip, which draws nothing outside debug tooltips.
			prev := widgets.ui_origin_push(child.origin)
			defer widgets.ui_origin_pop(prev)
			#partial switch child.kind {
			case .Action:
				shortcut_label := _menu_shortcut_label(child)
				ticked := _node_ticked(child, window)
				if im.MenuItem(child.name_cstr, shortcut_label, ticked, _node_enabled(child, window)) {
					_node_run(child, window)
				}
				_menu_item_tooltip(child)
			case .Toggle:
				if child.value != nil {
					im.MenuItemBoolPtr(child.name_cstr, _menu_shortcut_label(child), child.value, _node_enabled(child, window))
					_menu_item_tooltip(child)
				}
			}
		}
	}
}

// draw_menu_bar builds and draws the ImGui main menu bar from the path tree.
// Top-level menu shortcuts are processed every frame so they work when the menu is not open.
draw_menu_bar :: proc() -> bool {
	if !im.BeginMainMenuBar() do return false
	defer im.EndMainMenuBar()
	_draw_menu_children(_menu_root)
	return true
}
