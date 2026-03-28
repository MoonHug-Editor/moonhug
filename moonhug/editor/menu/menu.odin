package menu

import "core:fmt"
import "core:mem"
import "core:sort"
import "core:strings"
import "core:unicode/utf8"
import im "../../../external/odin-imgui"

MenuEntryKind :: enum {
	Submenu,
	Action,
	Toggle,
	Separator,
}

ORDER_DEFAULT :: 1 << 30

MenuNode :: struct {
	name:          string,
	name_cstr:     cstring,
	shortcut:      string,
	shortcut_cstr: cstring,
	kind:          MenuEntryKind,
	action:        proc(),
	value:         ^bool,
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
	sort.quick_sort_proc(pairs[:], proc(a, b: _NodeOrder) -> int {
		if a.order < b.order do return -1
		if a.order > b.order do return 1
		return 0
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

// draw_menu_subtree draws the children of the menu node at path (e.g. "Assets") into the current context (e.g. a popup).
draw_menu_subtree :: proc(path: string) {
	node := _get_or_create_path(path)
	_draw_menu_children(node)
}

// path format: "RootItem/NodeItem1/NodeItem2/LeafItem"
// add_menu_item adds an action at the given path. When selected, action is called.
add_menu_item :: proc(path: string, shortcut: string, action: proc(), order: int = ORDER_DEFAULT) {
	node := _get_or_create_path(path)
	node.kind = .Action
	node.order = order
	if node.shortcut_cstr != nil {
		mem.delete_cstring(node.shortcut_cstr)
	}
	node.shortcut, _ = strings.clone(shortcut)
	node.shortcut_cstr = strings.clone_to_cstring(node.shortcut)
	node.action = action
}

// add_menu_toggle adds a checkbox at the given path that toggles the value.
add_menu_toggle :: proc(path: string, value: ^bool, order: int = ORDER_DEFAULT) {
	node := _get_or_create_path(path)
	node.kind = .Toggle
	node.order = order
	node.value = value
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

_get_or_create_path :: proc(path: string) -> ^MenuNode {
	parts := strings.split(path, "/")
	defer delete(parts)
	if len(parts) == 0 do return _menu_root
	node := _menu_root
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
        lower := strings.to_lower(tok)

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
					if im.Shortcut(chord, {.RouteGlobal}) {
						child.action()
					}
				}
			}
			// recurse in case this node has children (shouldn't for Action, but safe)
			_process_menu_shortcuts(child)
		case .Toggle:
			_process_menu_shortcuts(child)
		}
	}
}

_draw_menu_children :: proc(node: ^MenuNode) {
	for child in node.children {
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
					if im.MenuItem(child.name_cstr, shortcut_label, false, true) {
						if child.action != nil do child.action()
					}
				case .Toggle:
					if child.value != nil {
						im.MenuItemBoolPtr(child.name_cstr, nil, child.value, true)
					}
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
