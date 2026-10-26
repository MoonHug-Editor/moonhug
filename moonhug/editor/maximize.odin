package editor

// Maximize View (Window menu, Shift+Space): the view under the mouse fills
// the dockspace's area, and the same shortcut puts it back where it was. The
// dock layout stays as it is:
// - The main dockspace keeps its nodes but shows nothing (KeepAliveOnly), so
//   every docked view hides and stays docked.
// - The view docks into a second dockspace over the same area, which gives it
//   its tab, its tab-bar widgets and its ⋮ menu (tab_menu_draw_all).
// - A hidden placeholder holds the node the view left: imgui deletes a node
//   when its last window leaves, and the split would close. Back in its node,
//   the view takes its tab's place again and the placeholder leaves.
// - imgui.ini is written first and not saved while a view is maximized, so a
//   quit then keeps the layout as it was.
// - A floating dock tree takes the rect of a window that comes back to it as
//   its only one, here the maximize area: its rect is put back after.
// - A view in a Workspace view's frame has no window of its own: it gets one
//   while maximized, its frame shows that it is away, and it goes back to its
//   frame after, shown there.

import "base:runtime"
import "core:fmt"
import "core:strings"
import im "moonhug:external/odin-imgui"
import "moonhug:editor/icons"
import "moonhug:editor/menu"
import wnd "moonhug:editor/window"

@(private = "file")
_MAX_PLACEHOLDER :: "###maximize_placeholder"

@(private = "file")
_max: struct {
	// Enter and Leave take effect at the next draw_dockspace, Unplace after
	// that frame's views, Focus at the frame after.
	state:      enum {None, Enter, On, Leave, Unplace, Focus},
	name:       cstring, // owned, "###<key>": the view's imgui window by its id, whatever its label shows
	key:        string,  // owned, its window instance key, "" for the Game view
	node:       im.ID,   // the dock node it left, 0 for a frame's view
	host:       string,  // owned, the Workspace view whose frame it left, "" for a docked view
	tab:        int,     // its tab's place in that node, -1 for unknown
	float_root: im.ID,   // the floating dock tree it left, 0 for the main dockspace
	float_rect: [2]im.Vec2, // that tree's position and size
	focus_next: bool,    // focus it next frame, once docked in the maximize dockspace
	ini:        cstring, // io.IniFilename while saving is paused
}

@(menu_item={path="Window/Maximize View", order=19, shortcut="Shift+Space", checked=maximize_is_on})
maximize_toggle :: proc() {
	#partial switch _max.state {
	case .On:
		_max.state = .Leave
	case .None:
		name, key, dock, ok := _max_hovered_view()
		if !ok do return
		if w := wnd.find(key); w != nil && w.host != "" {
			// A frame's view: a window of its own until it goes back.
			_max.host = strings.clone(w.host, runtime.default_allocator())
			wnd.host_release(w)
			w.placed = true
		} else {
			node := im.DockBuilderGetNode(dock)
			if node == nil do return
			_max.node = dock
			_max.tab = _max_tab_index(node, strings.clone_to_cstring(name, context.temp_allocator))
			if root := im.DockNodeGetRootNode(node); root != nil && root.ID_ != dock_space_id {
				_max.float_root = root.ID_
				_max.float_rect = {root.Pos, root.Size}
			}
		}
		_max.name = strings.clone_to_cstring(name, runtime.default_allocator())
		_max.key = strings.clone(key, runtime.default_allocator())
		_max.state = .Enter
	}
}

// The key of the frame's view that is maximized, "" for none: its frame
// leaves it be until it comes back (workspace_view.odin).
@(private)
maximize_key :: proc() -> string {
	if _max.host == "" || !maximize_is_on() do return ""
	return _max.key
}

// Whether a view is maximized: the main dockspace shows nothing.
maximize_is_on :: proc() -> bool {
	return _max.state == .Enter || _max.state == .On
}

// From draw_dockspace, right after the main dockspace and before any view.
maximize_frame :: proc(pos, size: im.Vec2) {
	#partial switch _max.state {
	case .Enter:
		io := im.GetIO()
		if io.IniFilename != nil {
			im.SaveIniSettingsToDisk(io.IniFilename)
			_max.ini = io.IniFilename
			io.IniFilename = nil
		}
		if _max.node != 0 {
			im.SetNextWindowDockID(_max.node, .Always)
			im.Begin(_MAX_PLACEHOLDER, nil, {.NoSavedSettings, .NoFocusOnAppearing, .NoNavInputs, .NoNavFocus})
			im.End()
		}
		im.DockBuilderDockWindow(_max.name, _max_space(pos, size))
		_max.focus_next = true
		_max.state = .On
	case .On:
		// A closed view puts the layout back.
		if (_max.key != "" && wnd.find(_max.key) == nil) || (_max.key == "" && !menu.show_game) {
			_max.state = .Leave
			_max_restore()
			return
		}
		_max_space(pos, size)
		if _max.focus_next {
			_max.focus_next = false
			im.SetWindowFocusStr(_max.name)
		}
	case .Leave:
		_max_restore()
	case .Focus:
		// imgui adds a window coming back to a node as its last tab.
		if node := im.DockBuilderGetNode(_max.node); _max.node != 0 && node != nil && node.TabBar != nil && _max.tab >= 0 {
			if cur := _max_tab_index(node, _max.name); cur >= 0 && cur != _max.tab {
				tabs := ([^]im.TabItem)(node.TabBar.Tabs.Data)
				im.TabBarQueueReorder(node.TabBar, &tabs[cur], i32(_max.tab - cur))
			}
		}
		if _max.float_root != 0 {
			im.DockBuilderSetNodePos(_max.float_root, _max.float_rect[0])
			im.DockBuilderSetNodeSize(_max.float_root, _max.float_rect[1])
		}
		if _max.host == "" do im.SetWindowFocusStr(_max.name)
		delete(_max.name, runtime.default_allocator())
		delete(_max.key, runtime.default_allocator())
		delete(_max.host, runtime.default_allocator())
		_max = {}
	}
}

// From the main loop after the views: the view is back in its node, so the
// placeholder leaves it.
maximize_after_views :: proc() {
	if _max.state != .Unplace do return
	im.DockBuilderDockWindow(_MAX_PLACEHOLDER, 0)
	_max.state = .Focus
}

// The view back in the node or the frame it left, and imgui.ini saving again.
@(private = "file")
_max_restore :: proc() {
	if _max.host != "" {
		// Out of the maximize dockspace, then hosted again: its window goes.
		im.DockBuilderDockWindow(_max.name, 0)
		if wnd.find(_max.key) != nil {
			wnd.host_open(_max.key, _max.host)
			workspace_view_reveal(_max.host, _max.key)
		} else {
			workspace_view_forget(_max.host, _max.key) // closed while maximized
		}
	} else {
		im.DockBuilderDockWindow(_max.name, _max.node)
	}
	if _max.ini != nil {
		im.GetIO().IniFilename = _max.ini
		_max.ini = nil
	}
	_max.state = .Unplace
}

// The maximize dockspace over the main dockspace's area. Its node takes no
// split and lets go of nothing: it holds the one view.
@(private = "file")
_max_space :: proc(pos, size: im.Vec2) -> im.ID {
	im.SetNextWindowPos(pos)
	im.SetNextWindowSize(size)
	id: im.ID
	flags := im.WindowFlags{.NoTitleBar, .NoResize, .NoMove, .NoScrollbar, .NoCollapse, .NoNavFocus, .NoDocking, .NoSavedSettings}
	if im.Begin("##MaximizeHost", nil, flags) {
		id = im.GetID("MaximizeSpace")
		im.DockSpace(id, {0, 0}, {.NoDockingSplit, .NoUndocking}, nil)
		tab_menu_draw_all(im.DockBuilderGetNode(id))
	}
	im.End()
	return id
}

// The place of the window `name`'s tab in the tab bar of `node`, -1 for none.
@(private = "file")
_max_tab_index :: proc(node: ^im.DockNode, name: cstring) -> int {
	if node.TabBar == nil do return -1
	win := im.FindWindowByName(name)
	tabs := ([^]im.TabItem)(node.TabBar.Tabs.Data)
	for i in 0 ..< int(node.TabBar.Tabs.Size) do if win != nil && tabs[i].Window_ == win do return i
	return -1
}

// The view under the mouse: its imgui window name, its instance key ("" for
// the Game view) and its dock node.
@(private = "file")
_max_hovered_view :: proc() -> (name, key: string, dock: im.ID, ok: bool) {
	if w := wnd.hovered(); w != nil && (w.dock != 0 || w.host != "") {
		return fmt.tprintf("###%s", w.key), w.key, w.dock, true
	}
	if game_view_hover.frame >= im.GetFrameCount() - 1 && game_view_hover.dock != 0 {
		return string(icons.TITLE_GAME), "", game_view_hover.dock, true
	}
	return
}
