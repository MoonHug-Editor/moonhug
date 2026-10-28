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
//   tree, its right or bottom border to resize it. A child frame's up and
//   down arrows, beside its grip, move it one place among its parent's
//   children, or with Shift to the top or the bottom.
// - A tab dragged up or down out of its frame's tab bar drops onto another
//   frame, joining its tabs, or onto empty canvas, where it gets a frame of
//   its own (its frame moves there when it was the only tab). Along the bar a
//   drag reorders the tabs.
// - Frames form trees of any depth (workspace.layout): a frame chained to
//   another sits right of it, linked by a curve. A window a frame's view
//   opens becomes that frame's child (window.host_hook), and a view already
//   in a frame is shown there when opened again. Trees keep apart: the tree
//   being dragged or worked in pushes the others away.
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

// A tab dropped somewhere: its view key (owned), the frame it leaves, and the
// frame it joins, or 0 for a new frame at `at` on the canvas.
@(private = "file")
_WS_Move :: struct {
	key:  string,
	from: u32,
	to:   u32,
	at:   [2]f32,
}

// A frame's ⋮ menu action, applied at the next frame's start so the frame
// list does not change while the frames draw. `frame` is the frame's id,
// `key` (owned) the view it acts on or adds, `parent` the new parent.
@(private = "file")
_WS_Edit :: struct {
	kind:   enum {Move_To_Dock, Add_Tab, Set_Parent, Unparent},
	frame:  u32,
	key:    string,
	parent: u32,
}

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
	drag_frame: u32,      // a move: the frame heading its tree, which moves with its subtree
	drag_from:  im.Vec2, // mouse at the press
	drag_start: [2]f32,  // the pan, the frame position, or the mini-map's offset or size at the press
	focused:    int,      // the frame focused this frame, -1 for none
	touched:    u32,      // the frame last moved, resized, clicked or opened in: its tree stays when trees part
	reveal:     string,   // owned, a view key to show next frame: its tab picked, its frame brought into view
	pending:    [dynamic]_WS_Pending, // chained frames to add next frame
	moves:      [dynamic]_WS_Move, // tabs dropped, moved next frame
	edits:      [dynamic]_WS_Edit, // frame menu actions, applied next frame
	reorder:    struct {
		id: u32, // a child moving to another place among its siblings, 0 for none
		to: int, // that place, applied next frame
	},
	map_frozen: _WS_Map,  // the mini-map's scale while a drag in it pans, so it holds still
	map_corner: [2]f32,   // the corner a resize drags: -1 the left or top, 1 the right or bottom
	map_start:  [4]f32,   // the mini-map's rect at the press of a resize
	map_grab:   [2]f32,   // that drag: the canvas point under the mouse, from the visible area's centre
	// Tabs closed from their frames: they leave the frame once their view is
	// gone, and stay when the close was held (unapplied edits, Cancel).
	closing:    [dynamic]string, // owned keys
	// Each frame's active tab as its tab bar last showed it, by frame id, for
	// the workspace `synced_ws`. A frame whose active tab differs (code picked
	// it, or the workspace just loaded) has it selected in its tab bar.
	synced:     map[u32]int,
	synced_ws:  string,   // owned
	// A frame resized, or the layout moved frames, while the mouse was held:
	// the workspace saves once it is released.
	save_pending: bool,
	rename:     bool,     // open the rename popup this frame
	name_buf:   [128]u8,
	// The workspaces this view has loaded (owned ids): their views live, with
	// their documents, until the workspace is unloaded, shown or not. Only
	// the selected one draws.
	loaded:     [dynamic]string,
	// The view's own close waits for the unload of everything it loaded.
	closing_view: bool,
}

// The view's state, made on first use. Its arrays and map live on the
// default allocator, whoever appends to them.
@(private = "file")
_ws_state :: proc(w: ^wnd.Window) -> ^_WS_View {
	if w.data != nil do return (^_WS_View)(w.data)
	v := wnd.state(w, _WS_View{})
	a := runtime.default_allocator()
	v.pending.allocator = a
	v.moves.allocator = a
	v.edits.allocator = a
	v.closing.allocator = a
	v.loaded.allocator = a
	v.synced = make(map[u32]int, a)
	return v
}

@(editor_window={id="workspace", title="Workspace", icon="SPACE_DASHBOARD", canvas=true, width=1000, height=640, closed=workspace_view_closed})
workspace_view_draw :: proc(w: ^wnd.Window) {
	v := _ws_state(w)
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
	_ws_apply_queued(w, v, e.ws)
	_ws_load(v, e.ws.id)
	// Every tab's view of every loaded workspace is claimed each frame, shown
	// or not, frame on screen or not: the registry closes a hosted view no
	// host claims (window.host_open). A loaded workspace that is gone (its
	// source dropped it) unloads.
	for i := len(v.loaded) - 1; i >= 0; i -= 1 {
		le, lok := workspace.find(v.loaded[i])
		if !lok {
			_ws_unload_request(w, v, {v.loaded[i]})
			continue
		}
		for f in le.ws.frames do for key in f.tabs do _ws_claim(w, v, key)
	}
	_ws_canvas(w, v, e.ws)
}

// A workspace is closed, loaded, or shown. Loaded, its views exist with
// their documents and unapplied edits, claimed by the Workspace view that
// loaded it and drawn only while it is the one shown. Showing another
// workspace keeps it loaded. Unloading closes its views without saving, after
// one question naming the documents with unapplied edits. Closing the
// Workspace view unloads everything it loaded the same way.

@(private = "file")
_ws_load :: proc(v: ^_WS_View, id: string) {
	if _ws_loaded(v, id) do return
	append(&v.loaded, strings.clone(id, runtime.default_allocator()))
}

@(private = "file")
_ws_loaded :: proc(v: ^_WS_View, id: string) -> bool {
	for l in v.loaded do if l == id do return true
	return false
}

// The one unload question up, answered by the dialog's buttons.
@(private = "file")
_unload: struct {
	view: string,          // owned, the Workspace view's key
	ids:  [dynamic]string, // owned
}

// Unloads `ids` at once when no view of theirs holds unapplied edits, else
// asks first, naming the documents that would lose them.
@(private = "file")
_ws_unload_request :: proc(w: ^wnd.Window, v: ^_WS_View, ids: []string) {
	context.allocator = runtime.default_allocator()
	names := make([dynamic]string, context.temp_allocator)
	for id in ids {
		e, ok := workspace.find(id)
		if !ok do continue
		for f in e.ws.frames do for key in f.tabs {
			if d, dok := session.view_document(key); dok && d.view == key && d.dirty do append(&names, session.document_name(d))
		}
	}
	if len(names) == 0 {
		_ws_unload_now(w, v, ids)
		return
	}
	delete(_unload.view)
	_unload.view = strings.clone(w.key)
	for id in _unload.ids do delete(id)
	clear(&_unload.ids)
	for id in ids do append(&_unload.ids, strings.clone(id))
	widgets.dialog_open({
		title       = "Unload Workspace",
		description = fmt.tprintf("Unapplied changes in %s will be lost.\nUnload without applying them?", strings.join(names[:], ", ", context.temp_allocator)),
		buttons     = {{label = "Unload", action = _ws_unload_confirmed}, {label = "Cancel", action = _ws_unload_cancelled, is_cancel = true, is_default = true}},
	})
}

@(private = "file")
_ws_unload_confirmed :: proc() {
	w := wnd.find(_unload.view)
	if w == nil || w.data == nil do return
	_ws_unload_now(w, (^_WS_View)(w.data), _unload.ids[:])
}

@(private = "file")
_ws_unload_cancelled :: proc() {
	if w := wnd.find(_unload.view); w != nil && w.data != nil do (^_WS_View)(w.data).closing_view = false
}

// Closes the views of `ids` without saving: each document with unapplied
// edits is discarded first, so no close asks again. The ids leave `loaded`,
// and a Workspace view waiting to close closes once nothing is loaded.
@(private = "file")
_ws_unload_now :: proc(w: ^wnd.Window, v: ^_WS_View, ids: []string) {
	context.allocator = runtime.default_allocator()
	for id in ids {
		if e, ok := workspace.find(id); ok {
			for f in e.ws.frames do for key in f.tabs {
				if d, dok := session.view_document(key); dok && d.view == key do session.document_discard(d)
				wnd.close(key)
			}
		}
		for i := len(v.loaded) - 1; i >= 0; i -= 1 do if v.loaded[i] == id {
			delete(v.loaded[i])
			ordered_remove(&v.loaded, i)
		}
		// Unloaded, the workspace shown is shown no more.
		if workspace.view_selection(w.key) == id do workspace.view_select(w.key, "")
	}
	if v.closing_view && len(v.loaded) == 0 do wnd.close(w.key)
}

// Closing the Workspace view unloads everything it loaded first (installed
// in view_close_guard): true keeps it open until that is done.
workspace_view_close_guard :: proc(w: ^wnd.Window) -> bool {
	is_ws := false
	for inst in wnd.instances(WORKSPACE_VIEW) do if inst == w do is_ws = true
	if !is_ws || w.data == nil do return false
	v := (^_WS_View)(w.data)
	if len(v.loaded) == 0 do return false
	if !v.closing_view {
		v.closing_view = true
		ids := make([]string, len(v.loaded), context.temp_allocator)
		copy(ids, v.loaded[:])
		_ws_unload_request(w, v, ids)
	}
	return len(v.loaded) > 0
}


// The view `key` of a frame, claimed for this view: nil when it is missing,
// or held by another Workspace view (window.host_held_elsewhere). A view
// maximized out of its frame is found and not claimed. One whose close is
// under way is claimed while it stays open, and nil once it is gone: hosting
// would reopen it from its key.
@(private = "file")
_ws_claim :: proc(w: ^wnd.Window, v: ^_WS_View, key: string) -> ^wnd.Window {
	if key == maximize_key() do return wnd.find(key)
	if _ws_closing(v, key) && wnd.find(key) == nil do return nil
	return wnd.host_open(key, w.key)
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
	for id in v.loaded do delete(id, runtime.default_allocator())
	delete(v.loaded)
	delete(v.synced)
	delete(v.synced_ws, runtime.default_allocator())
	for p in v.pending do delete(p.key, runtime.default_allocator())
	delete(v.pending)
	for m in v.moves do delete(m.key, runtime.default_allocator())
	delete(v.moves)
	for e in v.edits do delete(e.key, runtime.default_allocator())
	delete(v.edits)
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
			// Showing another workspace keeps this one loaded: its views live on,
			// hidden, until it is unloaded.
			if im.Selectable(label, en.ws.id == selected, {.Disabled} if elsewhere else {}) && en.ws.id != selected do workspace.view_select(w.key, en.ws.id)
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
	_, has := workspace.find(selected)
	im.BeginDisabled(!has)
	if im.Button("Add View") do im.OpenPopup("##ws_add")
	im.EndDisabled()
	widgets.tooltip("Open a view in a new frame of this workspace")
	if has && im.BeginPopup("##ws_add") {
		if id, picked := _ws_window_menu(); picked {
			if k := _ws_new_key(id); k != "" do workspace_view_add(w.key, k)
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

// The key of a new instance of the window `id`: its plain instance's when
// that is not open anywhere (hosting opens it from the key), another one's
// when it is (open_another makes it). "" for an unknown id.
@(private = "file")
_ws_new_key :: proc(id: string) -> string {
	if wnd.find(id) == nil do return id
	inst := wnd.open_another(id)
	return inst.key if inst != nil else ""
}

// Adds the view `key` to the workspace the Workspace view `view` shows, in a
// new frame, and hosts it there. With a `parent` (a frame id) the frame is
// chained to it and added next frame, shown once laid out. Without one it is
// added now, a step down and right of the last one from the visible area's
// corner. Returns the view, nil when `view` shows no workspace, the key opens
// no window, or another Workspace view holds it.
@(private)
workspace_view_add :: proc(view, key: string, parent: u32 = 0) -> ^wnd.Window {
	hv := wnd.find(view)
	if hv == nil || hv.id != WORKSPACE_VIEW do return nil
	e, ok := workspace.find(workspace.view_selection(view))
	if !ok do return nil
	inst := wnd.host_open(key, view)
	if inst == nil do return nil
	if parent != 0 {
		append(&_ws_state(hv).pending, _WS_Pending{strings.clone(key, runtime.default_allocator()), parent})
		return inst
	}
	n := len(e.ws.frames)
	workspace.frame_add(e.ws, key, {-e.ws.pan.x + 24 + f32(n % 8) * 28, -e.ws.pan.y + 24 + f32(n % 8) * 28, 460, 320})
	workspace.changed(e.ws)
	return inst
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

	// The layout moves frames while one is dragged or resized: saved once
	// the mouse is released.
	if workspace.layout(ws, v.touched) do v.save_pending = true
	if v.save_pending && !im.IsMouseDown(.Left) {
		v.save_pending = false
		workspace.changed(ws)
	}
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
	// A tab dropped on empty canvas gets a frame there. Over a frame, that
	// frame's smaller target wins.
	if key := _ws_dragged(w); key != "" && im.BeginDragDropTarget() {
		if p := im.AcceptDragDropPayload(wnd.TAB_PAYLOAD, {.AcceptNoDrawDefaultRect}); p != nil && wnd.tab_payload_key(p) == key {
			at := im.GetMousePos() - origin - ws.pan - {24, im.GetFrameHeight() * 0.5}
			_ws_move_queue(v, ws, key, 0, at)
		}
		im.EndDragDropTarget()
	}
	if v.drag == .Pan {
		if im.IsItemActive() {
			ws.pan = v.drag_start + (im.GetMousePos() - v.drag_from)
		} else {
			v.drag = .None
			workspace.changed(ws)
		}
	}

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

// A child frame's up and down arrows, stacked in one bar's height: a click
// moves it one place among its parent's children, Shift+click to the top or
// the bottom. An arrow with nowhere to go is off.
@(private = "file")
_ws_order_arrows :: proc(v: ^_WS_View, ws: ^workspace.Workspace, f: workspace.Frame, bar_h: f32) {
	at := workspace.sibling_index(ws, f.id)
	count := 0
	for g in ws.frames do if g.parent == f.parent do count += 1
	shift := im.GetIO().KeyShift
	// Both arrows on the same whole-pixel column: after the grip the cursor x
	// is fractional, and a new line in the group would truncate it, which
	// would shift one arrow against the other.
	p0 := im.GetCursorScreenPos()
	p0 = {math.floor(p0.x), math.floor(p0.y)}
	size := im.Vec2{math.floor(bar_h * 0.6), math.floor(bar_h * 0.5)}
	cx := p0.x + math.floor(size.x * 0.5)
	r := math.floor(min(size.x, size.y) * 0.3) + 0.5
	dl := im.GetWindowDrawList()
	// Stacked with no gap, so the pair is exactly one bar high.
	im.PushStyleVarImVec2(.ItemSpacing, {im.GetStyle().ItemSpacing.x, 0})
	defer im.PopStyleVar()
	im.BeginGroup()
	defer im.EndGroup()
	for up, k in ([2]bool{true, false}) {
		off := up ? at <= 0 : at >= count - 1
		top := p0.y + f32(k) * size.y
		im.SetCursorScreenPos({p0.x, top})
		im.BeginDisabled(off)
		pressed := im.InvisibleButton("##up" if up else "##down", size)
		hot := im.IsItemHovered()
		im.EndDisabled()
		if hot && !off do im.DrawList_AddRectFilled(dl, {p0.x, top}, {p0.x + size.x, top + size.y}, im.GetColorU32(.ButtonHovered), 2)
		// A small triangle pointing up or down, centred on the column.
		c := im.Vec2{cx, top + math.floor(size.y * 0.5)}
		col := im.GetColorU32(.TextDisabled if off else .Text)
		if up do im.DrawList_AddTriangleFilled(dl, c + {-r, r * 0.6}, c + {r, r * 0.6}, c + {0, -r * 0.6}, col)
		else do im.DrawList_AddTriangleFilled(dl, c + {-r, -r * 0.6}, c + {0, r * 0.6}, c + {r, -r * 0.6}, col)
		if up do widgets.tooltip("Move up among its parent's children. Shift+click: to the top", im.HoveredFlags_AllowWhenDisabled)
		else do widgets.tooltip("Move down among its parent's children. Shift+click: to the bottom", im.HoveredFlags_AllowWhenDisabled)
		if pressed && !off {
			to := (0 if shift else at - 1) if up else (count - 1 if shift else at + 1)
			v.reorder = {f.id, to}
			v.touched = f.parent
		}
	}
}

// A tab dragged along its frame's bar: imgui shows the new order, and the
// frame takes it, so it is saved, with the same tab active. `ids` are the
// frame's tabs' imgui ids, in the frame's order.
@(private = "file")
_ws_sync_tab_order :: proc(ws: ^workspace.Workspace, f: ^workspace.Frame, ids: []im.ID) {
	bar := im.GetCurrentTabBar()
	if bar == nil || len(f.tabs) < 2 || len(ids) != len(f.tabs) do return
	shown := ([^]im.TabItem)(bar.Tabs.Data)[:bar.Tabs.Size]
	// The frame's tab indices in the order the bar shows them.
	order := make([dynamic]int, 0, len(ids), context.temp_allocator)
	for tab in shown {
		for id, i in ids do if id == tab.ID_ {
			append(&order, i)
			break
		}
	}
	if len(order) != len(ids) do return // a tab the bar has not taken yet
	moved := false
	for i, k in order do if i != k do moved = true
	if !moved do return
	active := f.tabs[clamp(f.active, 0, len(f.tabs) - 1)]
	keys := make([]string, len(order), context.temp_allocator)
	for i, k in order do keys[k] = f.tabs[i]
	for key, k in keys {
		f.tabs[k] = key
		if key == active do f.active = k
	}
	workspace.changed(ws)
}

// The tab just submitted as a drag source, once the mouse leaves its bar up
// or down: along the bar imgui reorders the tabs, and stops while a drag and
// drop is under way. The payload is the view's key (window.TAB_PAYLOAD).
@(private = "file")
_ws_tab_drag :: proc(w: ^wnd.Window, key: string, label: cstring, bar_min, bar_max: im.Vec2) {
	if !im.IsItemActive() do return
	ours := _ws_dragged(w) == key
	mouse := im.GetMousePos()
	if !ours && mouse.y >= bar_min.y - 6 && mouse.y <= bar_max.y + 6 do return
	if !im.BeginDragDropSource({}) do return
	defer im.EndDragDropSource()
	wnd.tab_payload_set(key)
	text := string(label)
	if i := strings.index(text, "###"); i >= 0 do text = text[:i]
	im.TextUnformatted(strings.clone_to_cstring(text, context.temp_allocator))
}

// The key of the tab of this Workspace view's frames being dragged, "" for
// none: a tab payload whose view this view hosts.
@(private = "file")
_ws_dragged :: proc(w: ^wnd.Window) -> string {
	key := wnd.tab_payload_key(im.GetDragDropPayload())
	if key == "" do return ""
	inst := wnd.find(key)
	return key if inst != nil && inst.host == w.key else ""
}

// Queues the dragged tab `key` to move to the frame `to` (an id), or to a new
// frame at `at` with 0. Dropped back onto its own frame, nothing moves.
@(private = "file")
_ws_move_queue :: proc(v: ^_WS_View, ws: ^workspace.Workspace, key: string, to: u32, at: [2]f32) {
	fi := _ws_frame_of(ws, key)
	if fi < 0 || ws.frames[fi].id == to do return
	append(&v.moves, _WS_Move{strings.clone(key, runtime.default_allocator()), ws.frames[fi].id, to, at})
}

// The edits queued since the last frame, before anything draws: frame menu
// actions, dropped tabs, new child frames, a child's new place, tabs whose
// views closed. Then the frames are made valid.
@(private = "file")
_ws_apply_queued :: proc(w: ^wnd.Window, v: ^_WS_View, ws: ^workspace.Workspace) {
	_ws_apply_edits(w, v, ws)
	_ws_apply_moves(v, ws)
	_ws_apply_pending(v, ws)
	if v.reorder.id != 0 {
		workspace.sibling_move(ws, v.reorder.id, v.reorder.to)
		v.reorder = {}
	}
	_ws_prune_closing(v, ws)
	if workspace.fix(ws) do workspace.changed(ws)
	// The tab bars' state is for one workspace: another one shown has its
	// saved tabs selected.
	if v.synced_ws != ws.id {
		clear(&v.synced)
		delete(v.synced_ws, runtime.default_allocator())
		v.synced_ws = strings.clone(ws.id, runtime.default_allocator())
	}
}

// Moves the tabs dropped since the last frame (_WS_Move). A tab that was its
// frame's only one onto empty canvas moves the frame itself, with its
// subtree, out of its parent's tree.
@(private = "file")
_ws_apply_moves :: proc(v: ^_WS_View, ws: ^workspace.Workspace) {
	context.allocator = runtime.default_allocator()
	if len(v.moves) == 0 do return
	defer clear(&v.moves)
	for m in v.moves {
		defer delete(m.key)
		fi := workspace.frame_index(ws, m.from)
		if fi < 0 do continue
		ti := -1
		for t, i in ws.frames[fi].tabs do if t == m.key do ti = i
		if ti < 0 || (m.to != 0 && workspace.frame_index(ws, m.to) < 0) do continue
		size := [2]f32{ws.frames[fi].rect.z, ws.frames[fi].rect.w}
		switch {
		case m.to == 0 && len(ws.frames[fi].tabs) == 1:
			workspace.chain(ws, m.from, 0)
			ws.frames[fi].rect.x, ws.frames[fi].rect.y = m.at.x, m.at.y
			v.touched = m.from
		case m.to == 0:
			workspace.tab_remove(ws, fi, ti)
			v.touched = workspace.frame_add(ws, m.key, {m.at.x, m.at.y, size.x, size.y})
		case:
			workspace.tab_remove(ws, fi, ti)
			to := &ws.frames[workspace.frame_index(ws, m.to)]
			append(&to.tabs, strings.clone(m.key))
			to.active = len(to.tabs) - 1
			v.touched = m.to
		}
		workspace.changed(ws)
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
	v := _ws_state(hv)
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
	workspace_view_add(hv.key, w.key, e.ws.frames[fi].id)
}

// Tabs closed earlier whose views are gone now leave their frames. A view
// still open with no question up had its close held and cancelled
// (view_close_prompt.odin): it is no longer closing, so its tab closes again.
@(private = "file")
_ws_prune_closing :: proc(v: ^_WS_View, ws: ^workspace.Workspace) {
	context.allocator = runtime.default_allocator()
	for i := len(v.closing) - 1; i >= 0; i -= 1 {
		key := v.closing[i]
		if wnd.find(key) != nil {
			if !widgets.dialog_is_open() {
				delete(key)
				ordered_remove(&v.closing, i)
			}
			continue
		}
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
	_ws_frame_drop_target(w, v, ws, f)
	if im.IsWindowFocused({.ChildWindows}) do v.focused = i
	clicked = im.IsWindowHovered(im.HoveredFlags_ChildWindows) && (im.IsMouseClicked(.Left) || im.IsMouseClicked(.Right) || im.IsMouseClicked(.Middle))
	// The border drag resizes the child: the frame follows it, and the
	// workspace saves once the mouse is released.
	if sz := im.GetWindowSize(); sz != {f.rect.z, f.rect.w} {
		f.rect.z, f.rect.w = sz.x, sz.y
		v.touched = f.id
		v.save_pending = true
	}

	style := im.GetStyle()
	bar_h := im.GetFrameHeight()

	// The active view and the width of its tab-bar widgets, measured before
	// the grip: the measure draws them off to the side, and the tab group
	// below goes on the grip's line. A view maximized out of its frame
	// (maximize.odin) is left be until it comes back, and one another
	// Workspace view holds is not drawn here.
	key := f.tabs[f.active]
	away := key == maximize_key()
	held := wnd.host_held_elsewhere(key, w.key)
	active := _ws_claim(w, v, key)
	active_view := session.view_of(key)
	widgets_w := view_tab_bar_width(active_view) if active != nil && !away else 0

	_ws_frame_grip(v, ws, f, bar_h)
	// The tab group, in a child as wide as the bar leaves, then the active
	// view's widgets and its menu at the bar's right end.
	menu_w := bar_h
	im.SameLine(0, 0)
	_ws_frame_tabs(w, v, ws, f, max(im.GetContentRegionAvail().x - widgets_w - menu_w - style.ItemSpacing.x * 2, 40), bar_h)
	if active != nil && widgets_w > 0 && !away {
		im.SameLine()
		view_tab_bar_draw(active_view)
	}
	im.SameLine()
	if im.Button(icons.ICON_MD_MENU + "##menu", {menu_w, bar_h}) do im.OpenPopup("##frame_menu")
	if im.BeginPopup("##frame_menu") {
		_ws_frame_menu(w, v, ws, f^)
		im.EndPopup()
	}
	_ws_frame_content(active, held, away)
	return
}

// A dragged tab of this view drops onto the frame. Back onto its own frame,
// nothing moves.
@(private = "file")
_ws_frame_drop_target :: proc(w: ^wnd.Window, v: ^_WS_View, ws: ^workspace.Workspace, f: ^workspace.Frame) {
	key := _ws_dragged(w)
	if key == "" do return
	fmin := im.GetWindowPos()
	if !im.BeginDragDropTargetCustom({fmin, fmin + im.GetWindowSize()}, im.GetID("##tab_drop")) do return
	if p := im.AcceptDragDropPayload(wnd.TAB_PAYLOAD); p != nil && wnd.tab_payload_key(p) == key do _ws_move_queue(v, ws, key, f.id, {})
	im.EndDragDropTarget()
}

// The grip, a drag on which moves the frame's tree: the frame heading it and
// its whole subtree, by the same amount, so the frames drawn after the grip
// follow in the same frame. A chained frame's place follows its parent
// (workspace.layout), so a child's grip moves the tree it is in. A child
// frame's order arrows come after the grip.
@(private = "file")
_ws_frame_grip :: proc(v: ^_WS_View, ws: ^workspace.Workspace, f: ^workspace.Frame, bar_h: f32) {
	im.InvisibleButton("##grip", {bar_h * 0.6, bar_h})
	grip_hot := im.IsItemHovered() || im.IsItemActive()
	if im.IsItemActivated() {
		root := &ws.frames[workspace.frame_index(ws, workspace.chain_root(ws, f.id))]
		v.drag = .Move
		v.drag_grip = f.id
		v.drag_frame = root.id
		v.drag_from = im.GetMousePos()
		v.drag_start = {root.rect.x, root.rect.y}
		v.touched = root.id
	}
	if v.drag == .Move && v.drag_grip == f.id {
		if r := workspace.frame_index(ws, v.drag_frame); r >= 0 && im.IsItemActive() {
			to := v.drag_start + (im.GetMousePos() - v.drag_from)
			d := to - {ws.frames[r].rect.x, ws.frames[r].rect.y}
			for id in workspace.subtree(ws, v.drag_frame) {
				g := &ws.frames[workspace.frame_index(ws, id)]
				g.rect.x += d.x
				g.rect.y += d.y
			}
		} else {
			v.drag = .None
			workspace.changed(ws)
		}
	}
	gmin := im.GetItemRectMin()
	gsz := im.CalcTextSize(icons.ICON_MD_DRAG_INDICATOR)
	im.DrawList_AddText(im.GetWindowDrawList(), gmin + (im.Vec2{bar_h * 0.6, bar_h} - gsz) * 0.5, im.GetColorU32(.Text if grip_hot else .TextDisabled), icons.ICON_MD_DRAG_INDICATOR)
	widgets.tooltip("Drag to move the frame's whole tree" if f.parent != 0 else "Drag to move the frame with its children")
	if f.parent != 0 {
		im.SameLine(0, 0)
		_ws_order_arrows(v, ws, f^, bar_h)
	}
}

// The frame's tab bar, `width` wide. A tab picked by code, or saved, since
// the bar last showed it is selected (imgui shows it from the next frame),
// and a click on another tab makes it the frame's active one.
@(private = "file")
_ws_frame_tabs :: proc(w: ^wnd.Window, v: ^_WS_View, ws: ^workspace.Workspace, f: ^workspace.Frame, width, bar_h: f32) {
	defer im.EndChild()
	if !im.BeginChild("##tabs", {width, bar_h}, {}, {.NoScrollbar, .NoScrollWithMouse}) do return
	bar_min := im.GetWindowPos()
	bar_max := bar_min + im.GetWindowSize()
	if !im.BeginTabBar("##bar", {.Reorderable, .FittingPolicyShrink}) do return
	defer im.EndTabBar()
	ids := make([]im.ID, len(f.tabs), context.temp_allocator)
	// Until imgui shows the tab code picked, the bar's pick is not a click.
	synced, has := v.synced[f.id]
	force := f.active if !has || synced != f.active else -1
	picked := -1
	for t := 0; t < len(f.tabs); t += 1 {
		key := f.tabs[t]
		inst := _ws_claim(w, v, key)
		if inst == nil do inst = wnd.find(key) // held by another Workspace view
		label: cstring = wnd.title(inst) if inst != nil else fmt.ctprintf("%s %s###%s", icons.ICON_MD_WARNING, key, key)
		open := true
		selected := im.BeginTabItem(label, &open, {.SetSelected} if t == force else {})
		ids[t] = im.GetItemID()
		if inst != nil && inst.host == w.key do _ws_tab_drag(w, key, label, bar_min, bar_max)
		if selected {
			picked = t
			im.EndTabItem()
		}
		if !open do _ws_close_tab(v, key)
	}
	if force < 0 && picked >= 0 && picked != f.active {
		f.active = picked
		workspace.changed(ws)
	}
	_ws_sync_tab_order(ws, f, ids)
	v.synced[f.id] = f.active
}

// The active view's content, inside the frame's padding. A canvas view gets
// no scrollbars, as its own window would.
@(private = "file")
_ws_frame_content :: proc(active: ^wnd.Window, held, away: bool) {
	switch {
	case held:
		im.TextDisabled("This view is open in another Workspace view.")
		return
	case active == nil:
		im.TextDisabled("This view's window or asset is missing: its plugin is not installed, or the asset is gone.")
		return
	case away:
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
	if !_ws_closing(v, key) do append(&v.closing, strings.clone(key, runtime.default_allocator()))
	wnd.close(key)
}

// The frame's ⋮ menu: the active view's own items (tab_menu_view_items),
// Move to Dock, Add Tab, and the tree: Add Child (a view in a new child
// frame), Set Parent (a menu of the trees, _ws_parent_menu), Unparent. Its
// actions apply at the next frame's start (_ws_apply_edits).
@(private = "file")
_ws_frame_menu :: proc(w: ^wnd.Window, v: ^_WS_View, ws: ^workspace.Workspace, f: workspace.Frame) {
	key := f.tabs[f.active]
	if tab_menu_view_items(key) do _ws_close_tab(v, key)
	if im.MenuItem("Move to Dock") do _ws_edit_queue(v, {kind = .Move_To_Dock, frame = f.id, key = key})
	im.Separator()
	if im.BeginMenu("Add Tab") {
		if id, picked := _ws_window_menu(); picked {
			if k := _ws_new_key(id); k != "" && wnd.host_open(k, w.key) != nil {
				_ws_edit_queue(v, {kind = .Add_Tab, frame = f.id, key = k})
			}
		}
		im.EndMenu()
	}
	if im.BeginMenu("Add Child") {
		if id, picked := _ws_window_menu(); picked {
			if k := _ws_new_key(id); k != "" do workspace_view_add(w.key, k, f.id)
		}
		im.EndMenu()
	}
	// Any frame but this one and the frames below it can be its parent.
	others := false
	for g in ws.frames do if g.id != f.id && !workspace.is_ancestor(ws, f.id, g.id) do others = true
	if im.BeginMenu("Set Parent", others) {
		_ws_parent_menu(v, ws, f, 0)
		im.EndMenu()
	}
	if im.MenuItem("Unparent", nil, false, f.parent != 0) do _ws_edit_queue(v, {kind = .Unparent, frame = f.id})
}

// The Set Parent items for the children of the frame `parent` (0: the
// roots), in sibling order. A frame with no children to show is an item that
// parents `f` to it. One with children is a submenu: first "+ <label>",
// which parents `f` to it, then its children the same way. The frame `f` is
// left out with its subtree: none of it can be its parent. Its parent now is
// checked.
@(private = "file")
_ws_parent_menu :: proc(v: ^_WS_View, ws: ^workspace.Workspace, f: workspace.Frame, parent: u32) {
	for g in ws.frames {
		if g.parent != parent || g.id == f.id do continue
		im.PushIDInt(i32(g.id))
		defer im.PopID()
		kids := false
		for c in ws.frames do if c.parent == g.id && c.id != f.id do kids = true
		label := _ws_frame_label(g)
		current := g.id == f.parent
		if !kids {
			if im.MenuItem(label, nil, current) do _ws_edit_queue(v, {kind = .Set_Parent, frame = f.id, parent = g.id})
			continue
		}
		if im.BeginMenu(label) {
			if im.MenuItem(fmt.ctprintf("+ %s", label), nil, current) do _ws_edit_queue(v, {kind = .Set_Parent, frame = f.id, parent = g.id})
			im.Separator()
			_ws_parent_menu(v, ws, f, g.id)
			im.EndMenu()
		}
	}
}

// Queues a frame menu action. Its key is cloned.
@(private = "file")
_ws_edit_queue :: proc(v: ^_WS_View, e: _WS_Edit) {
	e := e
	e.key = strings.clone(e.key, runtime.default_allocator())
	append(&v.edits, e)
}

// Applies the frame menu actions queued since the last frame.
@(private = "file")
_ws_apply_edits :: proc(w: ^wnd.Window, v: ^_WS_View, ws: ^workspace.Workspace) {
	context.allocator = runtime.default_allocator()
	if len(v.edits) == 0 do return
	defer clear(&v.edits)
	for e in v.edits {
		defer delete(e.key)
		fi := workspace.frame_index(ws, e.frame)
		if fi < 0 do continue
		switch e.kind {
		case .Move_To_Dock:
			ti := -1
			for t, i in ws.frames[fi].tabs do if t == e.key do ti = i
			if ti < 0 do continue
			if inst := wnd.find(e.key); inst != nil && inst.host == w.key do wnd.host_release(inst)
			workspace.tab_remove(ws, fi, ti)
		case .Add_Tab:
			f := &ws.frames[fi]
			append(&f.tabs, strings.clone(e.key))
			f.active = len(f.tabs) - 1
		case .Set_Parent:
			workspace.chain(ws, e.frame, e.parent)
			v.touched = e.parent
		case .Unparent:
			// The parent's tree stays, so the frame moves out of its way.
			v.touched = ws.frames[fi].parent
			workspace.chain(ws, e.frame, 0)
		}
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

	// A tab dropped on the map stays where it was: without this target the
	// canvas would give it a frame under the map.
	if _ws_dragged(w) != "" && im.BeginDragDropTargetCustom({cmin, cmin + size}, im.GetID("##map_drop")) {
		im.AcceptDragDropPayload(wnd.TAB_PAYLOAD, {.AcceptNoDrawDefaultRect})
		im.EndDragDropTarget()
	}

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
	view_menu_add_dynamic(WORKSPACE_VIEW, "Save In", _ws_save_in_menu, order = 5)
	wnd.host_hook = _ws_host_hook
}

// The view menu's Save In submenu: the providers the shown workspace can
// move to, the one holding it checked. It keeps its id, so this view and any
// other goes on showing it.
@(private = "file")
_ws_save_in_menu :: proc(view: session.View) {
	e, ok := workspace.find(workspace.view_selection(view.key))
	if !ok {
		im.TextDisabled("No workspace shown")
		return
	}
	for p, i in workspace.providers() {
		here := i == e.provider
		label := strings.clone_to_cstring(p.name, context.temp_allocator)
		if im.MenuItem(label, nil, here, here || workspace.can_move_to(e.ws, i)) && !here do workspace.move_to(e.ws, i)
	}
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

// Unload closes the shown workspace's views without saving, after one
// question when any holds unapplied edits. The view then shows no workspace.
@(view_menu={view="workspace", label="Unload Workspace", enabled=_ws_has_selection})
workspace_unload_menu :: proc(view: session.View) {
	w := wnd.find(view.key)
	if w == nil || w.data == nil do return
	id := workspace.view_selection(view.key)
	_ws_unload_request(w, (^_WS_View)(w.data), {strings.clone(id, context.temp_allocator)})
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
		description = fmt.tprintf("Delete \"%s\"?\nIts views close without applying their changes, and the workspace is gone.", e.ws.name),
		buttons     = {{label = "Delete", action = _ws_delete_confirmed, is_default = true}, {label = "Cancel", is_cancel = true}},
	})
}

// Frees what the Workspace views keep outside their instances, at editor
// shutdown.
workspace_view_shutdown :: proc() {
	delete(_ws_delete_view, runtime.default_allocator())
	_ws_delete_view = ""
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
	w := wnd.find(_ws_delete_view)
	delete(_ws_delete_view, runtime.default_allocator())
	_ws_delete_view = ""
	if !ok do return
	// Deleting unloads: the question above said the views close.
	if w != nil && w.data != nil do _ws_unload_now(w, (^_WS_View)(w.data), {e.ws.id})
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
