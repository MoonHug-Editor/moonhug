package editor

// Unity's tab context menu: a menu button pinned to the right of every dock
// node's tab bar, opening actions for the tab that node is showing.
//
// imgui's own dock-node buttons are both off (apply_theme, menu_content.odin):
// its close-all button closes every docked view at once, and its window-menu
// button's contents come from a handler that imgui reinstalls after startup,
// so neither is usable here. The button below is a real tab item
// (TabItemButton with Trailing) appended to the node's tab bar through
// DockNodeBeginAmendTabBar, which puts its look and its menu under our
// control.

import im "moonhug:external/odin-imgui"
import "menu"
import wnd "moonhug:editor/window"
import "moonhug:editor/icons"
import "core:fmt"
import "core:strings"

// Walk the dockspace tree and give every leaf node a menu button. Call from
// the dockspace host window, after im.DockSpace.
tab_menu_draw_all :: proc(root: ^im.DockNode) {
	if root == nil do return
	if root.ChildNodes[0] == nil && root.ChildNodes[1] == nil {
		_tab_menu_node(root)
		return
	}
	tab_menu_draw_all(root.ChildNodes[0])
	tab_menu_draw_all(root.ChildNodes[1])
}

// The popup id must be unique per node, or every node's button opens the same
// popup. Built from the node id, which is stable across frames.
@(private = "file")
_popup_id :: proc(node: ^im.DockNode) -> cstring {
	return fmt.ctprintf("##tabmenu_%d", node.ID_)
}

@(private = "file")
_tab_menu_node :: proc(node: ^im.DockNode) {
	if node.TabBar == nil || node.HostWindow == nil do return
	// An empty node has no tab to act on. A node whose tab bar is hidden
	// (single window, tab bar collapsed) has no bar to put the button on.
	if node.Windows.Size == 0 do return

	popup := _popup_id(node)
	tab_bar := node.TabBar

	// Drawn in the host window at the FAR RIGHT of the tab bar rect, past
	// where tabs flow, so it reads as chrome on the bar rather than as
	// another tab. A plain InvisibleButton carries the click; the look is
	// drawn by hand (no tab shape, no frame) — hover only tints the square.
	im.Begin(node.HostWindow.Name)
	{
		bar := tab_bar.BarRect
		size := im.GetFrameHeight()
		// BarRect stops short of the node's right edge (imgui reserves room
		// there for the buttons it would draw, both of which are off). Sit
		// against the node edge instead, inside the window border.
		style := im.GetStyle()
		right := node.Pos.x + node.Size.x - style.WindowBorderSize
		bmin := im.Vec2{right - size, bar.Min.y}
		// Nothing to click if the bar is too narrow for the button.
		if bar.Max.x - bar.Min.x > size {
			dl := im.GetWindowDrawList()
			// The button's own id must be unique per node too, or every node's
			// button shares one id and only the first responds. The popup name
			// already carries the node id, so it doubles as the button label.
			im.SetCursorScreenPos(bmin)
			clicked := im.InvisibleButton(popup, {size, size})
			hovered := im.IsItemHovered({})
			if clicked do im.OpenPopup(popup)

			if hovered {
				im.DrawList_AddRectFilled(dl, bmin, bmin + {size, size}, im.GetColorU32(.ButtonHovered), 3)
			}
			glyph_sz := im.CalcTextSize(icons.ICON_MD_MENU, nil, false, -1)
			glyph_pos := bmin + (im.Vec2{size, size} - glyph_sz) * 0.5
			col: im.Col = hovered ? .Text : .TextDisabled
			im.DrawList_AddText(dl, glyph_pos, im.GetColorU32(col), icons.ICON_MD_MENU)
		}

		if im.BeginPopup(popup, {}) {
			_tab_menu_contents(node)
			im.EndPopup()
		}
	}
	im.End()
}

// Close the view whose imgui window title is `title`: a built-in view clears
// its open flag, a plugin window closes by id. Titles are "<icon> Name###id",
// and a plugin window's id is the text after "###".
@(private = "file")
_close_view :: proc(title: cstring) {
	if flag := menu.view_show_flag(title); flag != nil {
		flag^ = false
		return
	}
	s := string(title)
	if idx := strings.last_index(s, "###"); idx >= 0 {
		wnd.close(s[idx + 3:])
	}
}

@(private = "file")
_tab_menu_contents :: proc(node: ^im.DockNode) {
	// Acts on the tab the node is showing.
	active_title: cstring
	if node.VisibleWindow != nil do active_title = node.VisibleWindow.Name

	if active_title != nil {
		if im.MenuItem("Close Tab") {
			_close_view(active_title)
		}
		im.Separator()
	}

	// The editor keeps one tab per view at a saved place, so this opens a
	// view rather than adding a tab — it mirrors the main Window menu, minus
	// the entries that are editor-wide rather than per-tab.
	if im.BeginMenu("Window") {
		menu.draw_menu_subtree_except("Window", {"Theme", "Reset Layout"})
		im.EndMenu()
	}

	// The node's own tabs, to switch between them.
	tab_bar := node.TabBar
	if tab_bar != nil && tab_bar.Tabs.Size > 1 {
		im.Separator()
		tabs := ([^]im.TabItem)(tab_bar.Tabs.Data)[:tab_bar.Tabs.Size]
		for &tab in tabs {
			// ImGuiTabItemFlags_Button, private to imgui: a tab acting as a
			// button, not a window to switch to.
			if transmute(i32)tab.Flags & _TAB_ITEM_FLAG_BUTTON != 0 do continue
			name := im.TabBarGetTabName(tab_bar, &tab)
			if im.Selectable(name, tab.ID_ == tab_bar.SelectedTabId) {
				im.TabBarQueueFocus(tab_bar, &tab)
			}
		}
	}
}

// ImGuiTabItemFlags_Button (1<<21) — private to imgui, not in the bindings.
@(private = "file")
_TAB_ITEM_FLAG_BUTTON :: i32(1 << 21)
