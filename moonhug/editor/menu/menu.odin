package menu

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"
import "moonhug:engine/log"
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
	// Full registration path ("GameObject/Create Empty"). Diagnostics only:
	// `name` alone is ambiguous across submenus, so dispatch logs quote this.
	path:          string,
	shortcut:      string,
	shortcut_cstr: cstring,
	kind:          MenuEntryKind,
	action:        proc(),
	value:         ^bool,
	enabled:       proc() -> bool, // nil = always enabled
	children:      [dynamic]^MenuNode,
	order:         int, // sort key (lower = earlier); ORDER_DEFAULT when unspecified
}

_menu_root: ^MenuNode

// init_menu initializes the menu system. Call once before adding items.
init_menu :: proc() {
	_menu_root = new(MenuNode)
	_menu_root.kind = .Submenu
	_menu_root.order = ORDER_DEFAULT
	_menu_root.children = make([dynamic]^MenuNode)
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
	if _menu_root == nil do return
	_destroy_node(_menu_root)
	_menu_root = nil
}

_destroy_node :: proc(node: ^MenuNode) {
	for child in node.children {
		_destroy_node(child)
	}
	delete(node.children)
	if node.name != "" do delete(node.name)
	if node.path != "" do delete(node.path)
	if node.name_cstr != nil do delete(node.name_cstr)
	if node.shortcut != "" do delete(node.shortcut)
	if node.shortcut_cstr != nil do delete(node.shortcut_cstr)
	free(node)
}

draw_menu_subtree :: proc(path: string) {
	node := _get_or_create_path(path)
	_draw_menu_children(node)
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
		node := _get_or_create_path(s.path)
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
add_menu_item :: proc(path: string, shortcut: string, action: proc(), order: int = ORDER_DEFAULT, enabled: proc() -> bool = nil) {
	node := _get_or_create_path(path)
	node.kind = .Action
	node.order = order
	if node.shortcut_cstr != nil {
		mem.delete_cstring(node.shortcut_cstr)
	}
	node.shortcut, _ = strings.clone(shortcut)
	node.shortcut_cstr = strings.clone_to_cstring(node.shortcut)
	node.action = action
	node.enabled = enabled
}

// add_menu_toggle adds a checkbox at the given path that toggles the value.
// A shortcut ("Ctrl+1" — Ctrl renders as Cmd on macOS) toggles it globally.
add_menu_toggle :: proc(path: string, value: ^bool, order: int = ORDER_DEFAULT, shortcut := "", enabled: proc() -> bool = nil) {
	node := _get_or_create_path(path)
	node.kind = .Toggle
	node.order = order
	if node.shortcut_cstr != nil {
		mem.delete_cstring(node.shortcut_cstr)
	}
	node.shortcut, _ = strings.clone(shortcut)
	node.shortcut_cstr = strings.clone_to_cstring(node.shortcut)
	node.value = value
	node.enabled = enabled
}

// add_menu_separator adds a separator in the menu at the given path (path = parent menu, e.g. "File").
add_menu_separator :: proc(path: string, order: int = ORDER_DEFAULT) {
	parent := _get_or_create_path(path)
	sep := new(MenuNode)
	sep.kind = .Separator
	sep.name = ""
	sep.order = order
	sep.children = make([dynamic]^MenuNode)
	append(&parent.children, sep)
}

// Finds an existing node without creating path segments (nil = no such path).
find_path :: proc(path: string) -> ^MenuNode {
	parts := strings.split(path, "/", context.temp_allocator)
	node := _menu_root
	for part in parts {
		name := strings.trim_space(part)
		if name == "" do continue
		node = _find_child(node, name)
		if node == nil do return nil
	}
	return node
}

// Invokes the Action registered at `path`, honoring its enabled predicate.
// False when the path doesn't exist, isn't an action, or is disabled.
invoke_path :: proc(path: string) -> bool {
	node := find_path(path)
	if node == nil || node.kind != .Action || node.action == nil do return false
	if node.enabled != nil && !node.enabled() do return false
	node.action()
	return true
}

// Every invokable action path ("Edit/Undo", ...), temp-allocated.
collect_action_paths :: proc(allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	walk :: proc(node: ^MenuNode, prefix: string, out: ^[dynamic]string, allocator: mem.Allocator) {
		for child in node.children {
			path := prefix == "" ? child.name : strings.concatenate({prefix, "/", child.name}, allocator)
			if child.kind == .Action && child.action != nil {
				append(out, path)
			}
			walk(child, path, out, allocator)
		}
	}
	walk(_menu_root, "", &out, allocator)
	return out[:]
}

_get_or_create_path :: proc(path: string) -> ^MenuNode {
	parts := strings.split(path, "/")
	defer delete(parts)
	if len(parts) == 0 do return _menu_root
	node := _menu_root
	prefix := "" // path of `node`; borrowed from node.path, root's is ""
	for i in 0 ..< len(parts) {
		name := strings.trim_space(parts[i])
		if name == "" do continue
		child := _find_child(node, name)
		if child == nil {
			child = new(MenuNode)
			child.name, _ = strings.clone(name)
			child.name_cstr = strings.clone_to_cstring(child.name)
			if prefix == "" {
				child.path, _ = strings.clone(child.name)
			} else {
				child.path, _ = strings.concatenate({prefix, "/", child.name})
			}
			child.kind = .Submenu
			child.order = ORDER_DEFAULT
			child.children = make([dynamic]^MenuNode)
			append(&node.children, child)
		}
		node = child
		prefix = node.path
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
						log.infof("[menu] invoked %q via shortcut %q", child.path, child.shortcut)
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
				enabled := _node_enabled(child)
				if im.MenuItem(child.name_cstr, shortcut_label, false, enabled) {
					// Dispatch trace: an item that logs "invoked" but produces no
					// visible change failed INSIDE its action, not in the menu layer.
					log.infof("[menu] invoked %q (enabled=%v, action=%v)", child.path, enabled, child.action != nil)
					if child.action != nil {
						child.action()
					} else {
						log.warningf("[menu] %q has no action registered — click does nothing", child.path)
					}
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
