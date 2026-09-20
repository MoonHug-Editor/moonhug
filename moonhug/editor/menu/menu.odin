package menu

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"
import im "moonhug:external/odin-imgui"

MenuEntryKind :: enum {
	Submenu,
	Action,
	Toggle,
	Separator,
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
	kind:          MenuEntryKind,
	action:        proc(),
	value:         ^bool,
	enabled:       proc() -> bool, // nil = always enabled
	// Draws the item checked when it returns true. An Action whose state is
	// computed rather than stored in a bool: a radio group is N actions that
	// each set the state and each report whether they are the current one.
	checked:       proc() -> bool,
	children:      [dynamic]^MenuNode,
	order:         int, // sort key (lower = earlier); ORDER_DEFAULT when unspecified
}

// THE main menu bar's tree. Every add_menu_* / invoke_path / collect_* below
// is a one-line wrapper that passes it to the tree_* proc of the same name.
//
// The tree is a PARAMETER rather than a hidden global because there is more
// than one menu: each view has its own (view_chrome.odin), shown in its tab
// bar's popup. A view menu is the same tree, the same node kinds and the same
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
// parent_path is the path to node (e.g. "" for root, "View" for View's children). Keys are "ParentPath/ChildName".
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

// sort_top_menu sorts menu nodes at every level by top_order (lower = left). Keys are paths, e.g. "File", "View", "View/Theme".
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

// Draws every item under `root`. A view's menu is a whole tree rather than a
// subtree of the main one, so it draws from its root.
tree_draw :: proc(root: ^MenuNode) -> (drew: bool) {
	if root == nil || len(root.children) == 0 do return false
	_draw_menu_children(root)
	return true
}

// Draw a subtree's children, leaving out the ones named in `skip`. The tab
// menu shows the Window subtree without its Theme and Reset Layout entries,
// which are editor-wide rather than per-tab.
draw_menu_subtree_except :: proc(path: string, skip: []string) {
	node := _get_or_create_path(_menu_root, path)
	if node == nil do return
	for child in node.children {
		skipped := false
		for name in skip {
			if child.name == name {
				skipped = true
				break
			}
		}
		if skipped do continue
		_draw_menu_child(child)
	}
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

// path format: "RootItem/NodeItem1/NodeItem2/LeafItem"
// add_menu_item adds an action at the given path. When selected, action is called.
// enabled (optional) is polled at draw time; nil means always enabled.
// checked (optional) is polled the same way and draws the item with a tick —
// for a toggle whose state is computed, and for radio groups, where each option
// is an action that sets the state and reports whether it is the current one.
add_menu_item :: proc(path: string, shortcut: string, action: proc(), order: int = ORDER_DEFAULT, enabled: proc() -> bool = nil, checked: proc() -> bool = nil) {
	tree_add_item(_menu_root, path, shortcut, action, order, enabled, checked)
}

tree_add_item :: proc(root: ^MenuNode, path: string, shortcut: string, action: proc(), order: int = ORDER_DEFAULT, enabled: proc() -> bool = nil, checked: proc() -> bool = nil) {
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
}

// add_menu_toggle adds a checkbox at the given path that toggles the value.
// Declared as @(menu_item) on a bool variable — the same attribute an action
// uses on a proc, since what it is attached to already says which it is.
// A shortcut ("Ctrl+1" — Ctrl renders as Cmd on macOS) toggles it globally.
add_menu_toggle :: proc(path: string, value: ^bool, order: int = ORDER_DEFAULT, shortcut := "", enabled: proc() -> bool = nil) {
	tree_add_toggle(_menu_root, path, value, order, shortcut, enabled)
}

tree_add_toggle :: proc(root: ^MenuNode, path: string, value: ^bool, order: int = ORDER_DEFAULT, shortcut := "", enabled: proc() -> bool = nil) {
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
}

// add_menu_separator adds a separator in the menu at the given path (path = parent menu, e.g. "File").
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
	case .Action: return node.action != nil
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

tree_invoke :: proc(root: ^MenuNode, path: string) -> (ok: bool, state: bool) {
	node := tree_find(root, path)
	if !_node_invokable(node) do return false, false
	if node.enabled != nil && !node.enabled() do return false, false
	#partial switch node.kind {
	case .Action:
		node.action()
		// An action with a tick predicate IS a toggle or a radio option, so
		// the reply says where it landed — without it a caller that cannot see
		// the menu learns nothing from invoking one.
		if node.checked != nil do return true, node.checked()
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

// Every invokable path under `root`, each prefixed with `prefix` — a view menu
// passes "View/<view>" so its items address the same way main-menu ones do.
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

// _parse_shortcut converts strings like "Ctrl+S", "Alt+F4" into ImGui KeyChord for SetNextItemShortcut.
_parse_shortcut :: proc(shortcut: string) -> (chord: im.KeyChord, ok: bool) {
    s := strings.trim_space(shortcut)
    if s == "" do return 0, false
    
    parts := strings.split(s, "+")
    defer delete(parts)
    
    mods: im.KeyChord = 0
    key: im.Key = .None

    for p in parts {
        tok := strings.trim_space(p)
        if len(tok) == 0 do continue
        lower := strings.to_lower(tok, context.temp_allocator)

        switch lower {
        case "ctrl", "control": mods |= im.KeyChord(im.Key.ImGuiMod_Ctrl)
        case "alt":            mods |= im.KeyChord(im.Key.ImGuiMod_Alt)
        case "shift":          mods |= im.KeyChord(im.Key.ImGuiMod_Shift)
        case "super", "cmd":    mods |= im.KeyChord(im.Key.ImGuiMod_Super)
        case:
            // Handle Single Characters (A-Z, 0-9)
            if len(tok) == 1 {
                r := tok[0]
                if r >= 'a' && r <= 'z' {
                    key = im.Key(cast(int)im.Key.A + int(r - 'a'))
                } else if r >= 'A' && r <= 'Z' {
                    key = im.Key(cast(int)im.Key.A + int(r - 'A'))
                } else if r >= '0' && r <= '9' {
                    key = im.Key(cast(int)im.Key._0 + int(r - '0'))
                } else {
                    // Punctuation keys, spelled as the character itself.
                    switch r {
                    case ',': key = .Comma
                    case '.': key = .Period
                    case '-': key = .Minus
                    case '=': key = .Equal
                    case '/': key = .Slash
                    }
                }
            } // Handle F-Keys
            else if (tok[0] == 'F' || tok[0] == 'f') && len(tok) > 1 {
                n := 0
                for i in 1..<len(tok) {
                    if tok[i] >= '0' && tok[i] <= '9' {
                        n = n * 10 + int(tok[i] - '0')
                    }
                }
                if n >= 1 && n <= 12 {
                    key = im.Key(cast(int)im.Key.F1 + (n - 1))
                }
            }
            // Add specific cases here like "Enter", "Escape", "Delete" if needed
        }
    }

    if key == .None do return 0, false
    return mods | im.KeyChord(key), true
}

// _process_menu_shortcuts walks the menu tree and triggers actions for any shortcut pressed (global, so works when menu is closed).
_process_menu_shortcuts :: proc(node: ^MenuNode) {
	for child in node.children {
		switch child.kind {
		case .Separator:
			// skip
		case .Submenu:
			_process_menu_shortcuts(child)
		case .Action:
			if child.shortcut != "" && child.action != nil {
				if chord, ok := _parse_shortcut(child.shortcut); ok {
					if im.Shortcut(chord, {.RouteGlobal}) && _node_enabled(child) {
						child.action()
					}
				}
			}
			// recurse in case this node has children (shouldn't for Action, but safe)
			_process_menu_shortcuts(child)
		case .Toggle:
			if child.shortcut != "" && child.value != nil {
				if chord, ok := _parse_shortcut(child.shortcut); ok {
					if im.Shortcut(chord, {.RouteGlobal}) && _node_enabled(child) {
						child.value^ = !child.value^
					}
				}
			}
			_process_menu_shortcuts(child)
		}
	}
}

_node_enabled :: proc(node: ^MenuNode) -> bool {
	return node.enabled == nil || node.enabled()
}

_draw_menu_children :: proc(node: ^MenuNode) {
	for child in node.children {
		_draw_menu_child(child)
	}
}

_draw_menu_child :: proc(child: ^MenuNode) {
	switch child.kind {
	case .Separator:
		im.Separator()
	case .Submenu, .Action, .Toggle:
		if child.kind == .Submenu || len(child.children) > 0 {
			if im.BeginMenu(child.name_cstr, true) {
				_draw_menu_children(child)
				im.EndMenu()
			}
		} else {
			#partial switch child.kind {
			case .Action:
				shortcut_label := child.shortcut_cstr if child.shortcut_cstr != nil else ""
				ticked := child.checked != nil && child.checked()
				if im.MenuItem(child.name_cstr, shortcut_label, ticked, _node_enabled(child)) {
					if child.action != nil do child.action()
				}
			case .Toggle:
				if child.value != nil {
					im.MenuItemBoolPtr(child.name_cstr, child.shortcut_cstr, child.value, _node_enabled(child))
				}
			}
		}
	}
}

// draw_menu_bar builds and draws the ImGui main menu bar from the path tree.
// Top-level menu shortcuts are processed every frame so they work when the menu is not open.
draw_menu_bar :: proc() -> bool {
	_process_menu_shortcuts(_menu_root)
	if !im.BeginMainMenuBar() do return false
	defer im.EndMainMenuBar()
	_draw_menu_children(_menu_root)
	return true
}
