package editor

// The tab menu: a menu button pinned to the right of every dock
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
import "moonhug:editor/session"
import "moonhug:editor/widgets"
import "core:fmt"
import "core:slice"
import "core:strings"

// Walk a dock tree and give every leaf node a menu button. For the
// dockspace, call from its host window after im.DockSpace.
tab_menu_draw_all :: proc(root: ^im.DockNode) {
	if root == nil do return
	if root.ChildNodes[0] == nil && root.ChildNodes[1] == nil {
		_tab_menu_node(root)
		return
	}
	tab_menu_draw_all(root.ChildNodes[0])
	tab_menu_draw_all(root.ChildNodes[1])
}

// Views floating outside the dockspace: each sits in a dock tree of its own
// (io.ConfigDockingAlwaysTabBar gives even a lone view one), which the
// dockspace walk above never reaches. Gives every leaf of those trees the same
// button. Call after the views have drawn this frame, so the floating hosts
// have begun.
tab_menu_draw_floating :: proc() {
	ctx := im.GetCurrentContext()
	if ctx == nil || ctx.Windows.Size == 0 do return
	// A window's dock node is read through imgui's own call on the current
	// window, never from im.Window's fields: the binding's Window struct is
	// misaligned past imgui's bitfields, so its later fields are garbage.
	// Begin on a window already begun this frame appends to it.
	names := make([dynamic]cstring, context.temp_allocator)
	for w in ([^]^im.Window)(ctx.Windows.Data)[:ctx.Windows.Size] {
		if w == nil || !w.Active || w.IsFallbackWindow do continue
		if w.Flags & {.Tooltip, .Popup, .Modal, .DockNodeHost} != {} do continue
		// A docked view is a child window of its dock host. A child that is
		// part of another window carries its parent's name ("Parent/Child_ID").
		if .ChildWindow in w.Flags && strings.contains(string(w.Name), "/") do continue
		append(&names, w.Name)
	}
	roots := make([dynamic]^im.DockNode, context.temp_allocator)
	for name in names {
		im.Begin(name)
		node := im.GetWindowDockNode()
		im.End()
		if node == nil do continue
		root := im.DockNodeGetRootNode(node)
		if root == nil || root.ID_ == dock_space_id || slice.contains(roots[:], root) do continue
		append(&roots, root)
	}
	for root in roots do tab_menu_draw_all(root)
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
	active_title: cstring
	if node.VisibleWindow != nil do active_title = node.VisibleWindow.Name

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
			// The tab's menu button stands in for the tab itself with debug tooltips on:
			// a plugin window is declared by @(editor_window), and this is the
			// one piece of its chrome the dock system owns. The button has no
			// tooltip of its own, so the empty text draws nothing outside help
			// mode.
			origin_prev := widgets.ui_origin_push(_window_origin(active_title))
			im.SetCursorScreenPos(bmin)
			clicked := im.InvisibleButton(popup, {size, size})
			hovered := im.IsItemHovered({})
			widgets.tooltip("")
			widgets.ui_origin_pop(origin_prev)
			if clicked do im.OpenPopup(popup)

			if hovered {
				im.DrawList_AddRectFilled(dl, bmin, bmin + {size, size}, im.GetColorU32(.ButtonHovered), 3)
			}
			glyph_sz := im.CalcTextSize(icons.ICON_MD_MENU, nil, false, -1)
			glyph_pos := bmin + (im.Vec2{size, size} - glyph_sz) * 0.5
			col: im.Col = hovered ? .Text : .TextDisabled
			im.DrawList_AddText(dl, glyph_pos, im.GetColorU32(col), icons.ICON_MD_MENU)

			// The visible tab's toolbar items, left of the menu button. Here
			// rather than inside the view because a view then owes the feature
			// nothing: no call to make, no width to reserve, no placement to
			// choose, and no silent failure when it forgets. Switching tabs
			// switches the toolbar for free, since the bar belongs to the node
			// and the items are looked up per frame from its visible window.
			if active_title != nil {
				// Items are arbitrary widgets, so the BAR decides how they
				// look: no frame, hover tint only, and frame padding sized so
				// a button is exactly the bar's height. Otherwise a default
				// button is taller than the bar and hangs out of it.
				//
				// Pushed BEFORE measuring, or the width is measured in one
				// style and drawn in another.
				bar_h := bar.Max.y - bar.Min.y
				// Sized from the FONT, not the text line height: an icon glyph
				// is taller than the base line, so padding derived from the
				// line height makes a button that overflows the bar. INSET
				// keeps its background just inside the bar rather than filling
				// it edge to edge, which is what reads as chrome.
				INSET :: f32(4)
				pad_y := max((bar_h - im.GetFontSize() - INSET) * 0.5, 0)
				im.PushStyleColorImVec4(.Button, {0, 0, 0, 0})
				im.PushStyleVarImVec2(.FramePadding, {style.FramePadding.x, pad_y})
				im.PushStyleVar(.FrameRounding, 3) // matches the menu button's hover
				// Every node's items draw into the same HOST window, so two
				// views whose items share a label would collide. The node id
				// is unique and is what distinguishes them.
				im.PushIDInt(i32(node.ID_))

				view := session.view_of(view_key_of(active_title))
				items_w := view_tab_bar_width(view)
				// Only when the bar has room beside the tabs. A narrow node
				// keeps its tabs readable and its items reachable through the
				// menu instead.
				if items_w > 0 && bmin.x - items_w - style.ItemSpacing.x > bar.Min.x + tab_bar.WidthAllTabs {
					// Centred on whatever height the padding produced, rather
					// than pinned to the bar's top edge.
					item_h := im.GetFrameHeight()
					y := bar.Min.y + max((bar_h - item_h) * 0.5, 0)
					im.SetCursorScreenPos({bmin.x - items_w, y})
					view_tab_bar_draw(view)
				}

				im.PopID()
				im.PopStyleVar(2)
				im.PopStyleColor()
			}
		}

		if im.BeginPopup(popup, {}) {
			_tab_menu_contents(node)
			im.EndPopup()
		}
	}
	im.End()
}

// The @(editor_window) origin behind the tab whose imgui window title is
// `title`. Titles are "<icon> Name###id", and a plugin window's id is the text
// after "###" — a built-in view has no registered window and answers "".
@(private = "file")
_window_origin :: proc(title: cstring) -> string {
	if title == nil do return ""
	s := string(title)
	idx := strings.last_index(s, "###")
	if idx < 0 do return ""
	return wnd.origin_of(s[idx + 3:])
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
		view := session.view_of(view_key_of(active_title))
		// The file the view shows first (session/documents.odin): Save, and
		// Discard after a confirmation. Both are off while it has no unsaved
		// changes.
		if d, ok := session.view_document(view.key); ok {
			im.BeginDisabled(!d.dirty)
			if im.MenuItem("Save") do session.document_save(d)
			im.EndDisabled()
			im.BeginDisabled(!d.dirty || !d.can_discard)
			if im.MenuItem("Discard") do session.document_discard_ask(d)
			im.EndDisabled()
			im.Separator()
		}
		// The visible view's OWN options next: they are what this menu is for,
		// and the tab actions below are the same on every view.
		if view_menu_draw_items(view) {
			im.Separator()
		}
		if im.MenuItem("Close Tab") {
			_close_view(active_title)
		}
		im.Separator()
	}

	if im.BeginMenu("Add Tab") {
		_add_tab_items(node.ID_)
		im.EndMenu()
	}
}

// --- Add Tab ----------------------------------------------------------------

// Add Tab lists every view, sorted by name, and opens a new one in the node:
// the window's plain instance, or another instance when the plain one already
// shows somewhere. The Game view is the one view that exists once: it opens
// here when closed and is focused where it is when open.
@(private = "file")
_add_tab_items :: proc(node: im.ID) {
	Entry :: struct {
		label: string,
		title: cstring,      // a built-in view's title
		flag:  ^bool,        // a built-in view's open flag
		id:    string,       // a window's id
	}
	entries := make([dynamic]Entry, context.temp_allocator)
	for v in menu.builtin_views() do append(&entries, Entry{label = _plain_label(v.title), title = v.title, flag = v.flag})
	for w in wnd.registered() do append(&entries, Entry{label = w.title, id = w.id})
	slice.sort_by(entries[:], proc(a, b: Entry) -> bool { return a.label < b.label })
	for e in entries {
		if !im.MenuItem(strings.clone_to_cstring(e.label, context.temp_allocator)) do continue
		if e.flag != nil {
			if e.flag^ {
				im.SetWindowFocusStr(e.title)
			} else {
				e.flag^ = true
				_tab_dock(view_key_of(e.title), node)
			}
			continue
		}
		w := wnd.open_another(e.id) if wnd.find(e.id) != nil else wnd.open(e.id)
		if w != nil do _tab_dock(w.key, node)
	}
}

// A title's label: the text between the icon and ###.
@(private = "file")
_plain_label :: proc(title: cstring) -> string {
	s := string(title)
	if i := strings.last_index(s, "###"); i >= 0 do s = s[:i]
	if i := strings.index_byte(s, ' '); i >= 0 do s = s[i + 1:]
	return strings.trim_space(s)
}

// Docks a view into the node. It only sets the view's dock id (or its
// imgui.ini entry, for a view not drawn yet), and the view joins the node
// when it draws later this frame.
@(private = "file")
_tab_dock :: proc(key: string, node: im.ID) {
	im.DockBuilderDockWindow(fmt.ctprintf("###%s", key), node)
}
