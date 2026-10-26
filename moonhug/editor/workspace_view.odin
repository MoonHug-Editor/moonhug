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
// - Drag the canvas background to pan. Drag a frame's grip to move its
//   chain, its right or bottom border to resize it.
// - Frames form chains (workspace.layout): a frame chained to another sits
//   right of it, linked by a curve. A window a frame's view opens joins that
//   frame's chain (window.host_hook), and a view already in a frame is shown
//   there when opened again. Chains keep apart: the chain being dragged or
//   worked in pushes the others away.
// - Each frame draws in a child window, so imgui's focus tells its views
//   apart: a view takes keys while its own frame is focused.
// - A view added from Add View opens hosted in a new frame. Move to Dock
//   gives it back its own window, and a docked view's tab menu moves it into
//   a workspace a Workspace view shows.
// - The mini-map shows every frame and the visible area. Click or drag in it
//   to go there. The toolbar button shows and hides it, a drag with Ctrl or
//   Cmd held moves it, each corner resizes it, and the view's menu attaches
//   it to a corner or a side of the canvas. Each Workspace view copy keeps
//   its own.
// - Frames are opaque in the window background, on a canvas a shade darker.

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

// A view to add as a chained frame: its key (owned) and the frame it is
// chained to.
@(private = "file")
_WS_Pending :: struct {
	key:    string,
	parent: u32,
}

// One Workspace view copy's own state.
@(private = "file")
_WS_View :: struct {
	drag:       enum {None, Pan, Move, Map_Pan, Map_Move, Map_Resize},
	drag_grip:  u32,      // a move: the frame whose grip is held
	drag_frame: u32,      // a move: the frame heading its chain, which moves
	drag_from:  im.Vec2, // mouse at the press
	drag_start: [2]f32,  // the pan, the frame position, or the mini-map's offset or size at the press
	focused:    int,      // the frame focused this frame, -1 for none
	touched:    u32,      // the frame last moved, resized, clicked or opened in: its chain stays when chains part
	reveal:     string,   // owned, a view key to show next frame: its tab picked, its frame brought into view
	pending:    [dynamic]_WS_Pending, // chained frames to add next frame
	map_frozen: _WS_Map,  // the mini-map's scale while a drag in it pans, so it holds still
	map_corner: [2]f32,   // the corner a resize drags: -1 the left or top, 1 the right or bottom
	map_start:  [4]f32,   // the mini-map's rect at the press of a resize
	map_grab:   [2]f32,   // that drag: the canvas point under the mouse, from the visible area's centre
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
	owner := ""
	if ok do owner = workspace_view_owner(e.ws.id)
	if !ok || owner != w.key {
		msg: cstring = "Pick a workspace, or make one with New."
		if ok do msg = "This workspace is open in another Workspace view: pick another one here."
		else if workspace.view_selection(w.key) != "" do msg = "This workspace is not open: the source that holds it does not have it now."
		im.SetCursorPos(im.GetCursorPos() + {12, 12})
		im.TextDisabled(msg)
		return
	}
	_ws_rename_popup(v, e.ws)
	_ws_canvas(w, v, e.ws)
}

// The key of the Workspace view that shows the workspace `id`: the first one
// open that picked it, "" for none. Only that one draws it and hosts its
// views, so two Workspace views never fight over them.
@(private)
workspace_view_owner :: proc(id: string) -> string {
	for inst in wnd.instances(WORKSPACE_VIEW) do if workspace.view_selection(inst.key) == id do return inst.key
	return ""
}

// Closing the view closes the views it hosts. One with unapplied edits asks
// first (view_close_prompt.odin).
workspace_view_closed :: proc(w: ^wnd.Window) {
	v := (^_WS_View)(w.data)
	if v == nil do return
	for key in _ws_hosted_keys(w.key) do wnd.close(key)
	for k in v.closing do delete(k, runtime.default_allocator())
	delete(v.closing)
	for p in v.pending do delete(p.key, runtime.default_allocator())
	delete(v.pending)
	delete(v.reveal, runtime.default_allocator())
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
			owner := workspace_view_owner(en.ws.id)
			elsewhere := owner != "" && owner != w.key
			if im.Selectable(label, en.ws.id == selected, {.Disabled} if elsewhere else {}) do workspace.view_select(w.key, en.ws.id)
			if elsewhere do widgets.tooltip("Open in another Workspace view", im.HoveredFlags_AllowWhenDisabled)
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

	m := &workspace.view_settings(w.key).minimap
	im.SameLine(max(im.GetWindowWidth() - _WS_PAD - im.GetFrameHeight(), im.GetCursorPosX()))
	if widgets.icon_button(icons.ICON_MD_MAP, "##ws_map", "Show or hide the mini-map", active = !m.hidden) {
		m.hidden = !m.hidden
		workspace.view_settings_save()
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

	_ws_apply_pending(v, ws)
	if workspace.fix(ws) do workspace.changed(ws)
	if workspace.layout(ws, v.touched) && !im.IsMouseDown(.Left) do workspace.changed(ws)
	_ws_apply_reveal(v, ws, size)

	// A dot every grid step, moving with the pan, so panning reads. The
	// canvas is a darker shade of the window background, so the frames, in
	// the window background, stand out from it.
	cbg := im.GetStyleColorVec4(.WindowBg)^
	im.DrawList_AddRectFilled(dl, origin, origin + size, im.GetColorU32ImVec4({cbg.x * 0.72, cbg.y * 0.72, cbg.z * 0.72, 1}))
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
	_ws_links(dl, ws, origin + ws.pan, 1, 2)

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
	// The mini-map draws over the frames, but imgui lets a splitter or a
	// frame's resize border take the mouse through any window inside the same
	// root window (FlattenChildren). With the mouse over the map, the frames
	// draw with no mouse, as when it is outside the window, so nothing in them
	// is hovered or clicked. A drag already under way, or a field being typed
	// in, keeps the mouse.
	io := im.GetIO()
	real_mouse := io.MousePos
	if mpos, msize, shown := _ws_map_rect(w.key, size); shown && im.IsMouseHoveringRect(origin + mpos, origin + mpos + msize) {
		clicked := im.IsMouseClicked(.Left) || im.IsMouseClicked(.Right) || im.IsMouseClicked(.Middle)
		held := im.IsMouseDown(.Left) || im.IsMouseDown(.Right) || im.IsMouseDown(.Middle)
		if clicked || (!held && !im.IsAnyItemActive()) do io.MousePos = {-math.F32_MAX, -math.F32_MAX}
	}
	v.focused = -1
	// Frames are named by workspace and frame id, so no frame takes the imgui
	// state (its size) of a frame of another workspace.
	im.PushIDStr(strings.clone_to_cstring(ws.id, context.temp_allocator), nil)
	for i := 0; i < len(ws.frames); i += 1 {
		id := ws.frames[i].id
		if _ws_frame(w, v, ws, i, origin) do v.touched = id
	}
	im.PopID()
	io.MousePos = real_mouse
	// After the frames: a sibling child submitted later draws over them and
	// takes the mouse before them.
	_ws_minimap(w, v, ws, origin, size)
}

// The link from a frame's parent to it: a curve from the parent's right edge
// to the frame's left edge, level with their tab bars. `at` is the canvas
// origin on screen, `scale` the canvas-to-screen scale (the mini-map draws
// them smaller).
@(private = "file")
_ws_links :: proc(dl: ^im.DrawList, ws: ^workspace.Workspace, at: im.Vec2, scale, thickness: f32) {
	y := im.GetStyle().WindowPadding.y + im.GetFrameHeight() * 0.5
	col := im.GetColorU32(.CheckMark)
	for f in ws.frames {
		p := workspace.frame_index(ws, f.parent)
		if p < 0 do continue
		pr := ws.frames[p].rect
		a := at + im.Vec2{pr.x + pr.z, pr.y + y} * scale
		b := at + im.Vec2{f.rect.x, f.rect.y + y} * scale
		k := (b.x - a.x) * 0.6
		im.DrawList_AddBezierCubic(dl, a, a + {k, 0}, b - {k, 0}, b, col, thickness)
	}
}

// The frame holding the view `key`, -1 for none.
@(private = "file")
_ws_frame_of :: proc(ws: ^workspace.Workspace, key: string) -> int {
	for f, i in ws.frames do for t in f.tabs do if t == key do return i
	return -1
}

// Adds the child frames queued since the last frame (_ws_host_hook, Add
// Child), each shown once laid out.
@(private = "file")
_ws_apply_pending :: proc(v: ^_WS_View, ws: ^workspace.Workspace) {
	context.allocator = runtime.default_allocator()
	if len(v.pending) == 0 do return
	for p in v.pending {
		if _ws_frame_of(ws, p.key) < 0 do workspace.frame_add(ws, p.key, {0, 0, 460, 320}, p.parent)
		v.touched = workspace.chain_root(ws, p.parent)
		delete(v.reveal)
		v.reveal = p.key
	}
	clear(&v.pending)
	workspace.changed(ws)
}

// Shows the view queued in `reveal`: its tab picked, and its frame centred
// when any of it is out of view.
@(private = "file")
_ws_apply_reveal :: proc(v: ^_WS_View, ws: ^workspace.Workspace, canvas: [2]f32) {
	if v.reveal == "" do return
	defer {
		delete(v.reveal, runtime.default_allocator())
		v.reveal = ""
	}
	fi := _ws_frame_of(ws, v.reveal)
	if fi < 0 do return
	f := &ws.frames[fi]
	for t, ti in f.tabs do if t == v.reveal do f.active = ti
	v.touched = f.id
	lo := ws.pan + {f.rect.x, f.rect.y}
	hi := lo + {f.rect.z, f.rect.w}
	if lo.x < 0 || lo.y < 0 || hi.x > canvas.x || hi.y > canvas.y {
		ws.pan = canvas * 0.5 - ({f.rect.x, f.rect.y} + {f.rect.z, f.rect.w} * 0.5)
	}
	workspace.changed(ws)
}

// Shows the view `key` in its frame of the Workspace view `host` next frame,
// and brings that Workspace view forward.
@(private)
workspace_view_reveal :: proc(host, key: string) {
	hv := wnd.find(host)
	if hv == nil || hv.id != WORKSPACE_VIEW do return
	v := wnd.state(hv, _WS_View{})
	delete(v.reveal, runtime.default_allocator())
	v.reveal = strings.clone(key, runtime.default_allocator())
	wnd.focus(hv)
}

// Takes the view `key` out of its frame in the workspace the Workspace view
// `host` shows: it closed while away from it.
@(private)
workspace_view_forget :: proc(host, key: string) {
	e, ok := workspace.find(workspace.view_selection(host))
	if !ok do return
	fi := _ws_frame_of(e.ws, key)
	if fi < 0 do return
	for t, ti in e.ws.frames[fi].tabs do if t == key {
		workspace.tab_remove(e.ws, fi, ti)
		workspace.changed(e.ws)
		return
	}
}

// The window registry's host hook (window.host_hook). A window opened while a
// frame's view draws opens chained to that frame. A view already in a frame
// is shown there, and its Workspace view comes forward.
@(private = "file")
_ws_host_hook :: proc(opener, w: ^wnd.Window, created: bool) {
	context.allocator = runtime.default_allocator()
	if !created {
		workspace_view_reveal(w.host, w.key)
		return
	}
	if opener == nil do return
	hv := wnd.find(opener.host)
	if hv == nil || hv.id != WORKSPACE_VIEW do return
	e, ok := workspace.find(workspace.view_selection(hv.key))
	if !ok do return
	fi := _ws_frame_of(e.ws, opener.key)
	if fi < 0 do return
	wnd.host_open(w.key, hv.key)
	v := wnd.state(hv, _WS_View{})
	append(&v.pending, _WS_Pending{strings.clone(w.key), e.ws.frames[fi].id})
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
	// Named by its id, so its imgui state survives a reorder.
	im.PushIDInt(i32(f.id))
	defer im.PopID()
	im.SetNextWindowSize({f.rect.z, f.rect.w}, .Appearing)
	child_flags: im.ChildFlags = {.Borders, .ResizeX, .ResizeY}
	if !im.BeginChild("##frame", {f.rect.z, f.rect.w}, child_flags, {.NoScrollbar, .NoScrollWithMouse, .NoSavedSettings}) {
		im.EndChild()
		return
	}
	defer im.EndChild()
	// Opaque in the window background, as a docked view's window is.
	wbg := im.GetStyleColorVec4(.WindowBg)^
	wbg.w = 1
	im.DrawList_AddRectFilled(im.GetWindowDrawList(), im.GetWindowPos(), im.GetWindowPos() + im.GetWindowSize(), im.GetColorU32ImVec4(wbg), im.GetStyle().ChildRounding)
	if im.IsWindowFocused({.ChildWindows}) do v.focused = i
	clicked = im.IsWindowHovered(im.HoveredFlags_ChildWindows) && (im.IsMouseClicked(.Left) || im.IsMouseClicked(.Right) || im.IsMouseClicked(.Middle))
	// The border drag resizes the child: the frame follows it.
	if sz := im.GetWindowSize(); sz != {f.rect.z, f.rect.w} {
		f.rect.z, f.rect.w = sz.x, sz.y
		v.touched = f.id
		if !im.IsMouseDown(.Left) do workspace.changed(ws)
	}

	style := im.GetStyle()
	bar_h := im.GetFrameHeight()

	// The active view and the width of its tab-bar widgets, measured before
	// the grip: the measure draws them off to the side, and the tab group
	// below goes on the grip's line. A view maximized out of its frame
	// (maximize.odin) is left be until it comes back.
	away := f.tabs[f.active] == maximize_key()
	active := wnd.host_open(f.tabs[f.active], w.key) if !_ws_closing(v, f.tabs[f.active]) && !away else wnd.find(f.tabs[f.active])
	active_view := session.view_of(f.tabs[f.active])
	widgets_w := view_tab_bar_width(active_view) if active != nil && !away else 0

	// Grip: drag to move the frame's chain, by the frame heading it.
	im.InvisibleButton("##grip", {bar_h * 0.6, bar_h})
	grip_hot := im.IsItemHovered() || im.IsItemActive()
	if im.IsItemActivated() {
		root := &ws.frames[workspace.frame_index(ws, workspace.chain_root(ws, f.id))]
		v.drag = .Move
		v.drag_grip = f.id
		v.drag_frame = root.id
		v.drag_from = im.GetMousePos()
		v.drag_start = {root.rect.x, root.rect.y}
		v.touched = f.id
	}
	if v.drag == .Move && v.drag_grip == f.id {
		if r := workspace.frame_index(ws, v.drag_frame); r >= 0 && im.IsItemActive() {
			d := im.GetMousePos() - v.drag_from
			ws.frames[r].rect.x, ws.frames[r].rect.y = v.drag_start.x + d.x, v.drag_start.y + d.y
		} else {
			v.drag = .None
			workspace.changed(ws)
		}
	}
	gmin := im.GetItemRectMin()
	gsz := im.CalcTextSize(icons.ICON_MD_DRAG_INDICATOR)
	im.DrawList_AddText(im.GetWindowDrawList(), gmin + (im.Vec2{bar_h * 0.6, bar_h} - gsz) * 0.5, im.GetColorU32(.Text if grip_hot else .TextDisabled), icons.ICON_MD_DRAG_INDICATOR)
	widgets.tooltip("Drag to move the frame with its parent and children")

	// The tab group, in a child as wide as the bar leaves, then the active
	// view's widgets and its menu at the bar's right end.
	menu_w := bar_h
	im.SameLine(0, 0)
	tabs_w := max(im.GetContentRegionAvail().x - widgets_w - menu_w - style.ItemSpacing.x * 2, 40)
	if im.BeginChild("##tabs", {tabs_w, bar_h}, {}, {.NoScrollbar, .NoScrollWithMouse}) {
		if im.BeginTabBar("##bar", {.Reorderable, .FittingPolicyShrink}) {
			for t := 0; t < len(f.tabs); t += 1 {
				key := f.tabs[t]
				inst := wnd.find(key) if _ws_closing(v, key) || key == maximize_key() else wnd.host_open(key, w.key)
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
	if active != nil && widgets_w > 0 && !away {
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
	if away {
		im.TextDisabled("Maximized. Shift+Space puts it back here.")
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
// Move to Dock, Add Tab, and the chain: Add Child (a view in a new child
// frame), Set Parent, Unparent.
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
	if im.BeginMenu("Add Child") {
		if id, picked := _ws_window_menu(); picked {
			if inst := _ws_open_view(id, w.key); inst != nil {
				append(&v.pending, _WS_Pending{strings.clone(inst.key, runtime.default_allocator()), f.id})
			}
		}
		im.EndMenu()
	}
	own := workspace.chain_root(ws, f.id)
	others := false
	for g in ws.frames do if g.parent == 0 && g.id != own do others = true
	if im.BeginMenu("Set Parent", others) {
		for g in ws.frames {
			if g.parent != 0 || g.id == own do continue
			if im.MenuItem(_ws_frame_label(g)) {
				workspace.chain(ws, f.id, g.id)
				v.touched = g.id
				workspace.changed(ws)
			}
		}
		im.EndMenu()
	}
	if im.MenuItem("Unparent", nil, false, f.parent != 0) {
		// The parent's chain stays, so the frame moves out of its way.
		v.touched = f.parent
		workspace.chain(ws, f.id, 0)
		workspace.changed(ws)
	}
}

// A frame as its showing view's tab title, for menus.
@(private = "file")
_ws_frame_label :: proc(f: workspace.Frame) -> cstring {
	key := f.tabs[clamp(f.active, 0, len(f.tabs) - 1)]
	if inst := wnd.find(key); inst != nil do return wnd.title(inst)
	return strings.clone_to_cstring(key, context.temp_allocator)
}

// --- Mini-map ----------------------------------------------------------------

@(private = "file")
_WS_MAP_SIZE :: [2]f32{220, 150}
@(private = "file")
_WS_MAP_MIN :: [2]f32{100, 70}
@(private = "file")
_WS_MAP_MARGIN :: f32(10)
@(private = "file")
_WS_MAP_PAD :: f32(24) // canvas space around the frames
// The key held to move the mini-map instead of panning the view.
@(private = "file")
_WS_MAP_MOVE_KEY :: "Cmd" when ODIN_OS == .Darwin else "Ctrl"
@(private = "file")
_WS_MAP_CORNER :: f32(10) // the resize zone in each corner

// Canvas to mini-map: screen = base + (p - min) * scale. `base` is from the
// map's top-left corner.
@(private = "file")
_WS_Map :: struct {
	min:   [2]f32,
	scale: f32,
	base:  [2]f32,
}

@(private = "file")
_ws_map_to_screen :: proc(mp: _WS_Map, body_min: im.Vec2, p: [2]f32) -> im.Vec2 {
	return body_min + mp.base + (p - mp.min) * mp.scale
}

@(private = "file")
_ws_map_to_canvas :: proc(mp: _WS_Map, body_min: im.Vec2, s: im.Vec2) -> [2]f32 {
	return (s - body_min - mp.base) / mp.scale + mp.min
}

// Where an anchor sits on each axis: 0 the start, 0.5 the middle, 1 the end.
@(private = "file")
_ws_anchor_t :: proc(a: workspace.Anchor) -> [2]f32 {
	switch a {
	case .Top_Left:     return {0, 0}
	case .Top:          return {0.5, 0}
	case .Top_Right:    return {1, 0}
	case .Left:         return {0, 0.5}
	case .Right:        return {1, 0.5}
	case .Bottom_Left:  return {0, 1}
	case .Bottom:       return {0.5, 1}
	case .Bottom_Right: return {1, 1}
	}
	return {1, 0}
}

// The mini-map's size and its position from the anchor before its offset,
// in the canvas `canvas` big.
@(private = "file")
_ws_map_place :: proc(m: ^workspace.Minimap, canvas: [2]f32) -> (base, size: [2]f32) {
	avail := canvas - 2 * _WS_MAP_MARGIN
	size = m.size if m.size.x > 0 && m.size.y > 0 else _WS_MAP_SIZE
	size.x = clamp(size.x, _WS_MAP_MIN.x, max(avail.x, _WS_MAP_MIN.x))
	size.y = clamp(size.y, _WS_MAP_MIN.y, max(avail.y, _WS_MAP_MIN.y))
	base = _WS_MAP_MARGIN + (avail - size) * _ws_anchor_t(m.anchor)
	return
}

// Kept inside the canvas.
@(private = "file")
_ws_map_clamp :: proc(pos, size, canvas: [2]f32) -> [2]f32 {
	return {clamp(pos.x, 0, max(canvas.x - size.x, 0)), clamp(pos.y, 0, max(canvas.y - size.y, 0))}
}

// A corner drag: the dragged corner follows the mouse and the opposite one
// stays, which sets a new size and the offset that keeps the map there.
@(private = "file")
_ws_map_resize :: proc(m: ^workspace.Minimap, v: ^_WS_View, mouse: im.Vec2, canvas: [2]f32) {
	lo := [2]f32{v.map_start.x, v.map_start.y}
	hi := lo + [2]f32{v.map_start.z, v.map_start.w}
	d := mouse - v.drag_from
	least := _WS_MAP_MIN
	most := [2]f32{max(canvas.x - 2 * _WS_MAP_MARGIN, least.x), max(canvas.y - 2 * _WS_MAP_MARGIN, least.y)}
	for k in 0 ..< 2 {
		if v.map_corner[k] < 0 {
			lo[k] = max(clamp(lo[k] + d[k], hi[k] - most[k], hi[k] - least[k]), 0)
		} else {
			hi[k] = min(clamp(hi[k] + d[k], lo[k] + least[k], lo[k] + most[k]), canvas[k])
		}
	}
	m.size = hi - lo
	base, _ := _ws_map_place(m, canvas)
	m.offset = lo - base
}

// The mini-map's rect in the canvas, false while it is hidden.
@(private = "file")
_ws_map_rect :: proc(view: string, canvas: [2]f32) -> (pos, size: [2]f32, shown: bool) {
	m := &workspace.view_settings(view).minimap
	if m.hidden do return
	base: [2]f32
	base, size = _ws_map_place(m, canvas)
	return _ws_map_clamp(base + m.offset, size, canvas), size, true
}

@(private = "file")
_ws_minimap :: proc(w: ^wnd.Window, v: ^_WS_View, ws: ^workspace.Workspace, origin, canvas: im.Vec2) {
	m := &workspace.view_settings(w.key).minimap
	if m.hidden do return
	base, size := _ws_map_place(m, canvas)
	pos := _ws_map_clamp(base + m.offset, size, canvas)

	im.SetCursorScreenPos(origin + pos)
	im.PushStyleVarImVec2(.WindowPadding, {0, 0})
	visible := im.BeginChild("##ws_minimap", size, {}, {.NoScrollbar, .NoScrollWithMouse, .NoSavedSettings})
	im.PopStyleVar()
	defer im.EndChild()
	if !visible do return
	dl := im.GetWindowDrawList()
	cmin := im.GetWindowPos()
	mouse := im.GetMousePos()
	// The panel of a scene view overlay: see-through, rounded, outlined.
	bg := im.GetStyleColorVec4(.WindowBg)^
	bg.w = 0.85
	im.DrawList_AddRectFilled(dl, cmin, cmin + size, im.GetColorU32ImVec4(bg), 4)
	im.DrawList_AddRect(dl, cmin, cmin + size, im.GetColorU32(.Border), 4)

	// Ctrl or Cmd held over the map: a drag anywhere on it moves it. On macOS
	// imgui turns a click with the physical Ctrl key into a right click, so
	// with the key held the map takes either button.
	moving := im.GetIO().KeyCtrl || im.GetIO().KeySuper
	if v.drag == .Map_Move || (moving && v.drag == .None && im.IsWindowHovered({})) do im.SetMouseCursor(.ResizeAll)

	// Every corner resizes it, and the opposite corner stays put. First, so a
	// corner wins over the body where they meet.
	c := _WS_MAP_CORNER
	for corner, ci in ([4][2]f32{{-1, -1}, {1, -1}, {-1, 1}, {1, 1}}) {
		im.SetCursorScreenPos(cmin + {0 if corner.x < 0 else size.x - c, 0 if corner.y < 0 else size.y - c})
		im.PushIDInt(i32(ci))
		im.InvisibleButton("##resize", {c, c}, {.MouseButtonLeft, .MouseButtonRight})
		im.PopID()
		if !moving && (im.IsItemHovered() || im.IsItemActive()) do im.SetMouseCursor(.ResizeNWSE if corner.x == corner.y else .ResizeNESW)
		if im.IsItemActivated() && (moving || im.IsMouseClicked(.Left)) {
			v.drag = .Map_Move if moving else .Map_Resize
			v.drag_from = mouse
			v.drag_start = m.offset
			v.map_corner = corner
			v.map_start = {pos.x, pos.y, size.x, size.y}
		}
		if v.drag == .Map_Resize && v.map_corner == corner {
			if im.IsItemActive() {
				_ws_map_resize(m, v, mouse, canvas)
			} else {
				v.drag = .None
				workspace.view_settings_save()
			}
		}
	}


	// The body: every frame and the visible area, scaled to fit. A click or a
	// drag goes there. Grabbing the visible area keeps the grab point.
	body_min := cmin
	body := size
	view_min := -ws.pan
	view_max := -ws.pan + canvas
	mp := v.map_frozen
	if v.drag != .Map_Pan {
		lo, hi := view_min, view_max
		for f in ws.frames {
			lo = {min(lo.x, f.rect.x), min(lo.y, f.rect.y)}
			hi = {max(hi.x, f.rect.x + f.rect.z), max(hi.y, f.rect.y + f.rect.w)}
		}
		lo -= _WS_MAP_PAD
		hi += _WS_MAP_PAD
		inner := body - 8
		mp.min = lo
		mp.scale = max(min(inner.x / (hi.x - lo.x), inner.y / (hi.y - lo.y)), 0.0001)
		mp.base = (body - (hi - lo) * mp.scale) * 0.5
	}
	im.SetCursorScreenPos(body_min)
	im.InvisibleButton("##body", {max(body.x, 1), max(body.y, 1)}, {.MouseButtonLeft, .MouseButtonRight})
	if im.IsItemActivated() && moving {
		v.drag = .Map_Move
		v.drag_from = mouse
		v.drag_start = m.offset
	} else if im.IsItemActivated() && im.IsMouseClicked(.Left) {
		v.drag = .Map_Pan
		v.map_frozen = mp
		p := _ws_map_to_canvas(mp, body_min, mouse)
		inside := p.x >= view_min.x && p.y >= view_min.y && p.x <= view_max.x && p.y <= view_max.y
		v.map_grab = p - (view_min + view_max) * 0.5 if inside else {}
	}
	if v.drag == .Map_Pan {
		if im.IsItemActive() {
			centre := _ws_map_to_canvas(mp, body_min, mouse) - v.map_grab
			ws.pan = -(centre - canvas * 0.5)
			view_min, view_max = -ws.pan, -ws.pan + canvas
		} else {
			v.drag = .None
			workspace.changed(ws)
		}
	}
	widgets.tooltip("Click or drag to go there. Hold " + _WS_MAP_MOVE_KEY + " to move the mini-map.")

	// A move, from the body or a corner pressed with Ctrl or Cmd held, goes
	// on until the button is released.
	if v.drag == .Map_Move {
		if im.IsMouseDown(.Left) || im.IsMouseDown(.Right) {
			m.offset = _ws_map_clamp(base + v.drag_start + (mouse - v.drag_from), size, canvas) - base
		} else {
			v.drag = .None
			workspace.view_settings_save()
		}
	}

	im.PushClipRect(body_min, body_min + body, true)
	defer im.PopClipRect()
	for f, i in ws.frames {
		a := _ws_map_to_screen(mp, body_min, {f.rect.x, f.rect.y})
		b := _ws_map_to_screen(mp, body_min, {f.rect.x + f.rect.z, f.rect.y + f.rect.w})
		b = {max(b.x, a.x + 2), max(b.y, a.y + 2)}
		im.DrawList_AddRectFilled(dl, a, b, im.GetColorU32(.ButtonActive if i == v.focused else .Button))
		im.DrawList_AddRect(dl, a, b, im.GetColorU32(.Border))
	}
	_ws_links(dl, ws, _ws_map_to_screen(mp, body_min, {0, 0}), mp.scale, 1)
	va := _ws_map_to_screen(mp, body_min, view_min)
	vb := _ws_map_to_screen(mp, body_min, view_max)
	im.DrawList_AddRectFilled(dl, va, vb, im.GetColorU32(.Text, 0.06))
	im.DrawList_AddRect(dl, va, vb, im.GetColorU32(.Text, 0.8), 0, 1.5)
}

// The view menu's Mini-map submenu: show it, attach it to a corner or a side,
// or reset its place and size.
@(private = "file")
_WS_ANCHORS := [?]struct {
	anchor: workspace.Anchor,
	label:  cstring,
}{
	{.Top_Left, "Top Left"}, {.Top, "Top"}, {.Top_Right, "Top Right"},
	{.Left, "Left"}, {.Right, "Right"},
	{.Bottom_Left, "Bottom Left"}, {.Bottom, "Bottom"}, {.Bottom_Right, "Bottom Right"},
}

@(phase={key=core.Phase.EditorInit, order=1, mode=Editor})
workspace_view_install :: proc() {
	view_menu_add_dynamic(WORKSPACE_VIEW, "Mini-map", _ws_minimap_menu, order = 10)
	wnd.host_hook = _ws_host_hook
}

@(private = "file")
_ws_minimap_menu :: proc(view: session.View) {
	m := &workspace.view_settings(view.key).minimap
	if im.MenuItem("Show", nil, !m.hidden) {
		m.hidden = !m.hidden
		workspace.view_settings_save()
	}
	if im.BeginMenu("Attach To") {
		for a in _WS_ANCHORS {
			if a.anchor == .Left || a.anchor == .Bottom_Left do im.Separator()
			if im.MenuItem(a.label, nil, m.anchor == a.anchor) {
				m.anchor = a.anchor
				m.offset = {}
				m.hidden = false
				workspace.view_settings_save()
			}
		}
		im.EndMenu()
	}
	im.Separator()
	if im.MenuItem("Reset") {
		m^ = {}
		workspace.view_settings_save()
	}
	widgets.tooltip("Shown, at the top right, at its default size")
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
