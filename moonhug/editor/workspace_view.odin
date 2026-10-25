package editor

// The Workspace view (docs/core/Views.md): a canvas you pan, holding frames.
// A frame is a tab group of views at a rectangle, each tab a window instance
// the view hosts (editor/window hosting): drawn into the frame instead of a
// window of its own, with the same chrome a dock node gives it, its tab-bar
// widgets and its ⋮ menu. The workspaces come from providers
// (editor/workspace): the dropdown lists every one every provider holds now,
// and the view remembers the one it shows by id, so a workspace whose
// provider no longer holds it (its scene closed) shows as not open.
//
// - Drag the canvas background to pan. Drag a frame's grip to move it, its
//   right or bottom border to resize it. A frame clicked comes to the front.
// - Each frame draws in a child window, so imgui's focus tells its views
//   apart: a view takes keys while its own frame is focused.
// - A view added from Add View opens hosted in a new frame. Move to Dock
//   gives it back its own window, and a docked view's tab menu moves it into
//   a workspace a Workspace view shows.

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import im "moonhug:external/odin-imgui"
import "moonhug:editor/icons"
import "moonhug:editor/session"
import "moonhug:editor/widgets"
import wnd "moonhug:editor/window"
import "moonhug:editor/workspace"

WORKSPACE_VIEW :: "workspace"

// One Workspace view copy's own state.
@(private = "file")
_WS_View :: struct {
	drag:       enum {None, Pan, Move},
	drag_frame: int,
	drag_from:  im.Vec2, // mouse at the press
	drag_start: [2]f32,  // the pan or the frame position at the press
	// Tabs closed from their frames: they leave the frame once their view is
	// gone, and stay when the close was held (unapplied edits, Cancel).
	closing:    [dynamic]string, // owned keys
	rename:     bool,     // open the rename popup this frame
	name_buf:   [128]u8,
}

@(editor_window={id="workspace", title="Workspace", icon="SPACE_DASHBOARD", canvas=true, width=1000, height=640, closed=workspace_view_closed})
workspace_view_draw :: proc(w: ^wnd.Window) {
	v := wnd.state(w, _WS_View{})
	_ws_toolbar(w, v)
	e, ok := workspace.find(workspace.view_selection(w.key))
	if !ok {
		msg: cstring = "Pick a workspace, or make one with New." if workspace.view_selection(w.key) == "" else "This workspace is not open: the source that holds it does not have it now."
		im.SetCursorPos(im.GetCursorPos() + {12, 12})
		im.TextDisabled(msg)
		return
	}
	_ws_rename_popup(v, e.ws)
	_ws_canvas(w, v, e.ws)
}

// Closing the view closes the views it hosts. One with unapplied edits asks
// first (view_close_prompt.odin).
workspace_view_closed :: proc(w: ^wnd.Window) {
	v := (^_WS_View)(w.data)
	if v == nil do return
	for key in _ws_hosted_keys(w.key) do wnd.close(key)
	for k in v.closing do delete(k, runtime.default_allocator())
	delete(v.closing)
	free(v, runtime.default_allocator())
	w.data = nil
}

// The keys of the instances the view `host` hosts, for the workspaces it
// showed (temp).
@(private = "file")
_ws_hosted_keys :: proc(host: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for inst in wnd.hosted_by(host) do append(&out, inst.key)
	return out[:]
}

// --- Toolbar ---------------------------------------------------------------

@(private = "file")
_WS_PAD :: f32(6)

@(private = "file")
_ws_toolbar :: proc(w: ^wnd.Window, v: ^_WS_View) {
	im.SetCursorPos(im.GetCursorPos() + {_WS_PAD, _WS_PAD})
	selected := workspace.view_selection(w.key)
	entries := workspace.all()
	provs := workspace.providers()
	preview: cstring = "No workspace"
	for en in entries do if en.ws.id == selected {
		preview = fmt.ctprintf("%s  (%s)", en.ws.name, provs[en.provider].name)
	}
	im.SetNextItemWidth(260)
	if im.BeginCombo("##ws_pick", preview) {
		for en, i in entries {
			im.PushIDInt(i32(i))
			label := fmt.ctprintf("%s  (%s)", en.ws.name, provs[en.provider].name)
			if im.Selectable(label, en.ws.id == selected) do workspace.view_select(w.key, en.ws.id)
			im.PopID()
		}
		if len(entries) == 0 do im.TextDisabled("No workspaces yet")
		im.EndCombo()
	}
	widgets.tooltip("The workspace this view shows, from every source")

	im.SameLine()
	if im.Button(icons.ICON_MD_ADD + " New") do im.OpenPopup("##ws_new")
	widgets.tooltip("Make a workspace, kept by the source picked")
	if im.BeginPopup("##ws_new") {
		for p in provs {
			if p.create == nil do continue
			if im.MenuItem(fmt.ctprintf("In %s", p.name)) {
				if ws := p.create(fmt.tprintf("Workspace %d", len(entries) + 1)); ws != nil {
					workspace.view_select(w.key, ws.id)
				}
			}
		}
		im.EndPopup()
	}

	im.SameLine()
	e, has := workspace.find(selected)
	im.BeginDisabled(!has)
	if im.Button("Add View") do im.OpenPopup("##ws_add")
	im.EndDisabled()
	widgets.tooltip("Open a view in a new frame of this workspace")
	if has && im.BeginPopup("##ws_add") {
		if id, picked := _ws_window_menu(); picked {
			n := len(e.ws.frames)
			rect := [4]f32{-e.ws.pan.x + 24 + f32(n % 8) * 28, -e.ws.pan.y + 24 + f32(n % 8) * 28, 460, 320}
			if inst := _ws_open_view(id, w.key); inst != nil {
				workspace.frame_add(e.ws, inst.key, rect)
				workspace.changed(e.ws)
			}
		}
		im.EndPopup()
	}
	im.SetCursorPosY(im.GetCursorPosY() + _WS_PAD)
}

// A menu of every registered window, by title. The id of the one picked.
@(private = "file")
_ws_window_menu :: proc() -> (id: string, picked: bool) {
	list := wnd.registered()
	slice.sort_by(list, proc(a, b: wnd.Title_Id) -> bool { return a.title < b.title })
	for r in list {
		if r.id == WORKSPACE_VIEW do continue
		if im.MenuItem(strings.clone_to_cstring(r.title, context.temp_allocator)) {
			id, picked = r.id, true
		}
	}
	return
}

// A new instance of the window `id` hosted by the view `host`: its plain
// instance when that is not open anywhere, another one when it is.
@(private = "file")
_ws_open_view :: proc(id: string, host: string) -> ^wnd.Window {
	if wnd.find(id) == nil do return wnd.host_open(id, host)
	inst := wnd.open_another(id)
	if inst == nil do return nil
	return wnd.host_open(inst.key, host)
}

// --- Canvas ----------------------------------------------------------------

@(private = "file")
_WS_GRID :: f32(32)

@(private = "file")
_ws_canvas :: proc(w: ^wnd.Window, v: ^_WS_View, ws: ^workspace.Workspace) {
	avail := im.GetContentRegionAvail()
	if !im.BeginChild("##ws_canvas", avail, {}, {.NoScrollbar, .NoScrollWithMouse}) {
		im.EndChild()
		return
	}
	defer im.EndChild()
	origin := im.GetCursorScreenPos()
	size := im.GetContentRegionAvail()
	dl := im.GetWindowDrawList()

	// A dot every grid step, moving with the pan, so panning reads.
	im.DrawList_AddRectFilled(dl, origin, origin + size, im.GetColorU32(.FrameBg))
	dot := im.GetColorU32(.TextDisabled)
	ox := math.mod(ws.pan.x, _WS_GRID)
	oy := math.mod(ws.pan.y, _WS_GRID)
	if ox < 0 do ox += _WS_GRID
	if oy < 0 do oy += _WS_GRID
	for x := ox; x < size.x; x += _WS_GRID {
		for y := oy; y < size.y; y += _WS_GRID {
			im.DrawList_AddRectFilled(dl, origin + {x, y}, origin + {x + 1.5, y + 1.5}, dot)
		}
	}

	// The background under the frames: a drag on it pans.
	im.SetCursorScreenPos(origin)
	im.InvisibleButton("##ws_bg", {max(size.x, 1), max(size.y, 1)}, {.MouseButtonLeft, .MouseButtonMiddle})
	if im.IsItemActivated() {
		v.drag = .Pan
		v.drag_from = im.GetMousePos()
		v.drag_start = ws.pan
	}
	if v.drag == .Pan {
		if im.IsItemActive() {
			ws.pan = v.drag_start + (im.GetMousePos() - v.drag_from)
		} else {
			v.drag = .None
			workspace.changed(ws)
		}
	}

	_ws_prune_closing(v, ws)
	front := -1
	for i := 0; i < len(ws.frames); i += 1 {
		if _ws_frame(w, v, ws, i, origin) do front = i
	}
	// The frame clicked comes to the front: frames draw in list order.
	if front >= 0 && front < len(ws.frames) - 1 {
		f := ws.frames[front]
		ordered_remove(&ws.frames, front)
		append(&ws.frames, f)
		workspace.changed(ws)
	}
}

// Tabs closed earlier whose views are gone now leave their frames.
@(private = "file")
_ws_prune_closing :: proc(v: ^_WS_View, ws: ^workspace.Workspace) {
	context.allocator = runtime.default_allocator()
	for i := len(v.closing) - 1; i >= 0; i -= 1 {
		key := v.closing[i]
		if wnd.find(key) != nil do continue
		for fi := len(ws.frames) - 1; fi >= 0; fi -= 1 {
			for t := len(ws.frames[fi].tabs) - 1; t >= 0; t -= 1 {
				if ws.frames[fi].tabs[t] == key do workspace.tab_remove(ws, fi, t)
			}
		}
		delete(key)
		ordered_remove(&v.closing, i)
		workspace.changed(ws)
	}
}

// One frame: a grip, the tab group, its active view's tab-bar widgets and ⋮
// menu, then the view's content. True when it was clicked.
@(private = "file")
_ws_frame :: proc(w: ^wnd.Window, v: ^_WS_View, ws: ^workspace.Workspace, i: int, origin: im.Vec2) -> (clicked: bool) {
	f := &ws.frames[i]
	if len(f.tabs) == 0 do return
	f.active = clamp(f.active, 0, len(f.tabs) - 1)
	pos := origin + ws.pan + {f.rect.x, f.rect.y}
	im.SetCursorScreenPos(pos)
	// Named by its first view, so its imgui state survives a reorder.
	im.PushIDStr(fmt.ctprintf("frame_%s", f.tabs[0]), nil)
	defer im.PopID()
	im.SetNextWindowSize({f.rect.z, f.rect.w}, .Appearing)
	child_flags: im.ChildFlags = {.Borders, .ResizeX, .ResizeY}
	if !im.BeginChild("##frame", {f.rect.z, f.rect.w}, child_flags, {.NoScrollbar, .NoScrollWithMouse, .NoSavedSettings}) {
		im.EndChild()
		return
	}
	defer im.EndChild()
	clicked = im.IsWindowHovered(im.HoveredFlags_ChildWindows) && (im.IsMouseClicked(.Left) || im.IsMouseClicked(.Right) || im.IsMouseClicked(.Middle))
	// The border drag resizes the child: the frame follows it.
	if sz := im.GetWindowSize(); sz != {f.rect.z, f.rect.w} {
		f.rect.z, f.rect.w = sz.x, sz.y
		if !im.IsMouseDown(.Left) do workspace.changed(ws)
	}

	style := im.GetStyle()
	bar_h := im.GetFrameHeight()

	// Grip: drag to move the frame.
	im.InvisibleButton("##grip", {bar_h * 0.6, bar_h})
	grip_hot := im.IsItemHovered() || im.IsItemActive()
	if im.IsItemActivated() {
		v.drag = .Move
		v.drag_frame = i
		v.drag_from = im.GetMousePos()
		v.drag_start = {f.rect.x, f.rect.y}
	}
	if v.drag == .Move && v.drag_frame == i {
		if im.IsItemActive() {
			d := im.GetMousePos() - v.drag_from
			f.rect.x, f.rect.y = v.drag_start.x + d.x, v.drag_start.y + d.y
		} else {
			v.drag = .None
			workspace.changed(ws)
		}
	}
	gmin := im.GetItemRectMin()
	gsz := im.CalcTextSize(icons.ICON_MD_DRAG_INDICATOR)
	im.DrawList_AddText(im.GetWindowDrawList(), gmin + (im.Vec2{bar_h * 0.6, bar_h} - gsz) * 0.5, im.GetColorU32(.Text if grip_hot else .TextDisabled), icons.ICON_MD_DRAG_INDICATOR)
	widgets.tooltip("Drag to move the frame")

	// The tab group, in a child as wide as the bar leaves, then the active
	// view's widgets and its menu at the bar's right end.
	active := wnd.host_open(f.tabs[f.active], w.key) if !_ws_closing(v, f.tabs[f.active]) else wnd.find(f.tabs[f.active])
	active_view := session.view_of(f.tabs[f.active])
	widgets_w := view_tab_bar_width(active_view) if active != nil else 0
	menu_w := bar_h
	im.SameLine(0, 0)
	tabs_w := max(im.GetContentRegionAvail().x - widgets_w - menu_w - style.ItemSpacing.x * 2, 40)
	if im.BeginChild("##tabs", {tabs_w, bar_h}, {}, {.NoScrollbar, .NoScrollWithMouse}) {
		if im.BeginTabBar("##bar", {.Reorderable, .FittingPolicyShrink}) {
			for t := 0; t < len(f.tabs); t += 1 {
				key := f.tabs[t]
				inst := wnd.find(key) if _ws_closing(v, key) else wnd.host_open(key, w.key)
				label: cstring = wnd.title(inst) if inst != nil else fmt.ctprintf("%s %s###%s", icons.ICON_MD_WARNING, key, key)
				open := true
				if im.BeginTabItem(label, &open, {}) {
					f.active = t
					im.EndTabItem()
				}
				if !open do _ws_close_tab(v, key)
			}
			im.EndTabBar()
		}
	}
	im.EndChild()
	if active != nil && widgets_w > 0 {
		im.SameLine()
		view_tab_bar_draw(active_view)
	}
	im.SameLine()
	if im.Button(icons.ICON_MD_MENU + "##menu", {menu_w, bar_h}) do im.OpenPopup("##frame_menu")
	if im.BeginPopup("##frame_menu") {
		_ws_frame_menu(w, v, ws, i)
		im.EndPopup()
	}

	// The active view's content, inside the frame's padding. A canvas view
	// gets no scrollbars, as its own window would.
	if active == nil {
		im.TextDisabled("This view's window or asset is missing: its plugin is not installed, or the asset is gone.")
		return
	}
	canvas := wnd.is_canvas(active)
	if canvas do im.PushStyleVarImVec2(.WindowPadding, {0, 0})
	content_flags: im.WindowFlags = {.NoScrollbar, .NoScrollWithMouse} if canvas else {}
	visible := im.BeginChild("##content", {0, 0}, {}, content_flags)
	if canvas do im.PopStyleVar()
	if visible do wnd.draw_content(active)
	im.EndChild()
	return
}

@(private = "file")
_ws_closing :: proc(v: ^_WS_View, key: string) -> bool {
	for k in v.closing do if k == key do return true
	return false
}

// Closes a tab's view. The tab leaves its frame once the view is gone
// (_ws_prune_closing): a view with unapplied edits may be kept open.
@(private = "file")
_ws_close_tab :: proc(v: ^_WS_View, key: string) {
	if _ws_closing(v, key) do return
	append(&v.closing, strings.clone(key, runtime.default_allocator()))
	wnd.close(key)
}

// The frame's ⋮ menu: the active view's own items (tab_menu_view_items),
// Move to Dock, Add Tab.
@(private = "file")
_ws_frame_menu :: proc(w: ^wnd.Window, v: ^_WS_View, ws: ^workspace.Workspace, i: int) {
	f := &ws.frames[i]
	key := f.tabs[f.active]
	if tab_menu_view_items(key) do _ws_close_tab(v, key)
	if im.MenuItem("Move to Dock") {
		if inst := wnd.find(key); inst != nil do wnd.host_release(inst)
		workspace.tab_remove(ws, i, f.active)
		workspace.changed(ws)
		return
	}
	im.Separator()
	if im.BeginMenu("Add Tab") {
		if id, picked := _ws_window_menu(); picked {
			if inst := _ws_open_view(id, w.key); inst != nil {
				append(&f.tabs, strings.clone(inst.key, runtime.default_allocator()))
				f.active = len(f.tabs) - 1
				workspace.changed(ws)
			}
		}
		im.EndMenu()
	}
}

// --- Rename and delete (the view's ⋮ menu) ----------------------------------

@(view_menu={view="workspace", label="Rename Workspace", enabled=_ws_has_selection})
workspace_rename_menu :: proc(view: session.View) {
	if w := wnd.find(view.key); w != nil && w.data != nil do (^_WS_View)(w.data).rename = true
}

@(view_menu={view="workspace", label="Delete Workspace", enabled=_ws_has_selection})
workspace_delete_menu :: proc(view: session.View) {
	context.allocator = runtime.default_allocator()
	delete(_ws_delete_view)
	_ws_delete_view = strings.clone(view.key)
	e, ok := workspace.find(workspace.view_selection(view.key))
	if !ok do return
	widgets.dialog_open({
		title       = "Delete Workspace",
		description = fmt.tprintf("Delete \"%s\"?\nIts views close, and the workspace is gone.", e.ws.name),
		buttons     = {{label = "Delete", action = _ws_delete_confirmed, is_default = true}, {label = "Cancel", is_cancel = true}},
	})
}

_ws_has_selection :: proc(view: session.View) -> bool {
	_, ok := workspace.find(workspace.view_selection(view.key))
	return ok
}

// The view the open delete question is about.
@(private = "file")
_ws_delete_view: string // owned

@(private = "file")
_ws_delete_confirmed :: proc() {
	e, ok := workspace.find(workspace.view_selection(_ws_delete_view))
	if !ok do return
	for f in e.ws.frames do for key in f.tabs do wnd.close(key)
	if p := workspace.providers()[e.provider]; p.remove != nil do p.remove(e.ws)
}

@(private = "file")
_ws_rename_popup :: proc(v: ^_WS_View, ws: ^workspace.Workspace) {
	if v.rename {
		v.rename = false
		v.name_buf = {}
		copy(v.name_buf[:len(v.name_buf) - 1], ws.name)
		im.OpenPopup("##ws_rename")
	}
	if im.BeginPopup("##ws_rename") {
		im.SetKeyboardFocusHere()
		if im.InputText("Name", cstring(raw_data(v.name_buf[:])), len(v.name_buf), {.EnterReturnsTrue}) {
			name := string(cstring(raw_data(v.name_buf[:])))
			if name != "" {
				context.allocator = runtime.default_allocator()
				delete(ws.name)
				ws.name = strings.clone(name)
				workspace.changed(ws)
			}
			im.CloseCurrentPopup()
		}
		im.EndPopup()
	}
}
