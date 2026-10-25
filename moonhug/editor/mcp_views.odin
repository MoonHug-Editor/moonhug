package editor

// The bridge's view tools (docs/core/McpBridge.md "Views"): list the
// editor's windows, float one at a rectangle, dock one beside another, resize
// one, size the editor itself, and (with screenshot's `window` view) capture
// one window. An agent sets a layout up before it reads a window, the way a
// person drags tabs.
//
// imgui applies layout inside a frame: docking through DockBuilder before
// the dockspace draws, undocking at the next NewFrame. So each tool queues an
// operation, mcp_bridge_window_ops applies it right after NewFrame, and the
// tool answers once the change shows: the window's rectangle as drawn.
//
// The layout these change is the one imgui saves to imgui.ini, as a person's
// drags are: the measuring scripts save and restore that file around a run.
//
// The Odin binding of imgui's Window struct declares C bitfields as whole
// fields, so its fields after the first bitfield (DockNode, DockIsActive,
// LastFrameActive, RootWindow) sit at the wrong offsets. These tools read
// only the fields before it (name, flags, position, size, Active, Hidden)
// and find a window's dock node by walking the dock tree from the dockspace
// (DockNode's own bitfields come after every field used here, and are never
// written).

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import im "moonhug:external/odin-imgui"
import mcp "moonhug:editor/mcp"
import gfx "moonhug:libs/gfx"

@(private = "file")
_Window_Op_Kind :: enum u8 {
	Place,  // float at rect
	Dock,   // beside `target`, or as its tab
	Resize, // rect.zw, the split moved when docked
}

@(private = "file")
_Window_Op :: struct {
	id:     i64,
	kind:   _Window_Op_Kind,
	name:   string, // the imgui window name, owned
	target: string, // Dock: the window to dock beside, owned
	side:   im.Dir, // Dock: None = a tab of the target's node
	ratio:  f32,    // Dock: the new node's share of the target's
	rect:   [4]f32, // Place: x, y, width, height. Resize: width, height in zw (0 = keep)
	stage:  int,    // the frames-long state machine (mcp_bridge_window_ops)
	frames: int,    // frames waited in the current stage
}

// Operations waiting for their frame, on the default allocator.
@(private = "file")
_window_ops: [dynamic]_Window_Op

// The title a window shows and its id: imgui names a window
// "<icon> Title###id", whose id hashes only what follows ###. The title drops
// the leading icon glyph and spaces. A name without ### is its own id.
mcp_window_title_id :: proc(name: string) -> (title, id: string) {
	title, id = name, name
	if i := strings.index(name, "###"); i >= 0 {
		title = name[:i]
		id = name[i + 3:]
	}
	for len(title) > 0 {
		r, n := utf8.decode_rune_in_string(title)
		if r < 0x80 && r != ' ' do break
		title = title[n:]
	}
	return strings.trim_space(title), id
}

// Every window docked in the main dockspace, by the leaf node holding it.
@(private = "file")
_dock_nodes :: proc() -> map[^im.Window]^im.DockNode {
	nodes := make(map[^im.Window]^im.DockNode, context.temp_allocator)
	walk :: proc(n: ^im.DockNode, nodes: ^map[^im.Window]^im.DockNode) {
		if n == nil do return
		if n.ChildNodes[0] != nil || n.ChildNodes[1] != nil {
			walk(n.ChildNodes[0], nodes)
			walk(n.ChildNodes[1], nodes)
			return
		}
		if n.Windows.Size > 0 {
			for w in ([^]^im.Window)(n.Windows.Data)[:n.Windows.Size] do nodes[w] = n
		}
	}
	if dock_space_id != 0 do walk(im.DockBuilderGetNode(dock_space_id), &nodes)
	return nodes
}

// The windows a person sees as views: open this frame or the last, docked or
// floating, not a child of another window, popup, tooltip or dock host, not
// a "##" host (the dockspace, the menu bar).
@(private = "file")
_view_windows :: proc() -> []^im.Window {
	ctx := im.GetCurrentContext()
	out := make([dynamic]^im.Window, context.temp_allocator)
	if ctx == nil || ctx.Windows.Size == 0 do return out[:]
	docked := _dock_nodes()
	for w in ([^]^im.Window)(ctx.Windows.Data)[:ctx.Windows.Size] {
		if w == nil || w.IsFallbackWindow do continue
		if w.Flags & {.Tooltip, .Popup, .Modal, .DockNodeHost} != {} do continue
		// imgui marks a docked window as a child of its dock host, in the
		// dockspace or floating on its own. A child that is part of another
		// window carries its parent's name ("Parent/Child_ID"). A view's key
		// can hold a slash too ("Inspector/2"), so the check is the ID suffix.
		if .ChildWindow in w.Flags && w not_in docked && _is_child_name(string(w.Name)) do continue
		// Begun last frame (the tick runs before NewFrame clears Active).
		if !w.Active && !w.WasActive do continue
		if strings.has_prefix(string(w.Name), "##") do continue
		append(&out, w)
	}
	return out[:]
}

// imgui names a child window "<parent>/<name>_<8 hex digits>", or
// "<parent>/<8 hex digits>" without a name.
@(private = "file")
_is_child_name :: proc(name: string) -> bool {
	slash := strings.last_index_byte(name, '/')
	if slash < 0 do return false
	seg := name[slash + 1:]
	if len(seg) < 8 || (len(seg) > 8 && seg[len(seg) - 9] != '_') do return false
	for c in seg[len(seg) - 8:] do if !strings.contains_rune("0123456789ABCDEF", c) do return false
	return true
}

// The open window `query` names: its title or id, case ignored, else the
// one window whose title or id contains it.
@(private = "file")
_find_view :: proc(query: string) -> (^im.Window, Mcp_Error) {
	if query == "" do return nil, {"bad_request", "need window (a title or id from window_list)"}
	q := strings.to_lower(query, context.temp_allocator)
	exact := make([dynamic]^im.Window, context.temp_allocator)
	partial := make([dynamic]^im.Window, context.temp_allocator)
	for w in _view_windows() {
		title, id := mcp_window_title_id(string(w.Name))
		t := strings.to_lower(title, context.temp_allocator)
		i := strings.to_lower(id, context.temp_allocator)
		if t == q || i == q do append(&exact, w)
		else if strings.contains(t, q) || strings.contains(i, q) do append(&partial, w)
	}
	if len(exact) == 1 do return exact[0], {}
	found := len(exact) > 1 ? exact[:] : partial[:]
	if len(found) == 1 do return found[0], {}
	if len(found) == 0 do return nil, {"not_found", fmt.tprintf("no open window matches %q (window_list names them)", query)}
	names := make([dynamic]string, context.temp_allocator)
	for w in found {
		title, _ := mcp_window_title_id(string(w.Name))
		append(&names, title)
	}
	return nil, {"ambiguous", fmt.tprintf("%q matches %d windows: %s", query, len(found), strings.join(names[:], ", ", context.temp_allocator))}
}

@(private = "file")
_Window_Info :: struct {
	title:   string,
	id:      string,
	x:       f32, // from the editor window's top-left, in points
	y:       f32,
	width:   f32,
	height:  f32,
	docked:  bool,
	visible: bool, // drawn this frame: a docked window's tab is in front
	floating: bool, // in its own OS window outside the main window (imgui_viewports.odin)
}

@(private = "file")
_window_info :: proc(w: ^im.Window) -> _Window_Info {
	vp := im.GetMainViewport()
	title, id := mcp_window_title_id(string(w.Name))
	// A docked window behind another tab is begun but hidden.
	return {
		title = title, id = id,
		x = w.Pos.x - vp.Pos.x, y = w.Pos.y - vp.Pos.y, width = w.Size.x, height = w.Size.y,
		docked = w in _dock_nodes(), visible = (w.Active || w.WasActive) && !w.Hidden,
		floating = w.Viewport != nil && w.Viewport.ID_ != vp.ID_,
	}
}

@(mcp_tool={description="The editor's open windows (Scene, Game, Inspector, Render Pipeline, ...): each one's title and id, its rectangle in points from the editor's top-left, whether it is docked, whether it is drawn (a docked window behind another tab is not), and whether it floats in its own OS window outside the editor. Plus the editor's own size and its pixels per point. window_place, window_resize and screenshot view=window take a title or id from here."})
mcp_tool_window_list :: proc(id: i64, params: json.Object) -> (string, Mcp_Error) {
	views := _view_windows()
	infos := make([]_Window_Info, len(views), context.temp_allocator)
	for w, i in views do infos[i] = _window_info(w)
	size := gfx.window_size()
	return mcp.tool_ok(struct {
		editor:  struct {
			width, height: i32,
			scale:         f32,
		},
		windows: []_Window_Info,
	}{editor = {size.x, size.y, im.GetIO().DisplayFramebufferScale.x}, windows = infos})
}

@(mcp_tool={
	description="Float a window at a rectangle (points from the editor's top-left), undocking it first, and bring it to the front. Or, with dock, put it back into the layout beside another docked window (side left, right, top or bottom, sharing that window's space by ratio) or as a tab next to it (side tab). Answers with the window's rectangle once the change shows. Changes the saved layout, as a drag does.",
	param_window="string!:Title or id of the window to move (window_list)",
	param_x="number:Left edge, points (floating)",
	param_y="number:Top edge, points (floating)",
	param_width="number:Width, points (floating; default: keep)",
	param_height="number:Height, points (floating; default: keep)",
	param_dock="string:Title or id of a docked window to dock beside instead of floating",
	param_side="string:With dock: left, right, top, bottom or tab (default tab)",
	param_ratio="number:With dock and a side: the moved window's share of the space, 0.1 to 0.9 (default 0.35)",
})
mcp_tool_window_place :: proc(id: i64, params: json.Object) -> (string, Mcp_Error) {
	query, _ := params["window"].(json.String)
	w, err := _find_view(query)
	if err.code != "" do return "", err
	op := _Window_Op{id = id, name = strings.clone(string(w.Name), runtime.default_allocator())}
	if target_query, has := params["dock"].(json.String); has && target_query != "" {
		target, terr := _find_view(target_query)
		if terr.code != "" {
			delete(op.name, runtime.default_allocator())
			return "", terr
		}
		if target == w || target not_in _dock_nodes() {
			delete(op.name, runtime.default_allocator())
			return mcp.tool_fail("bad_request", "dock needs another window that is docked (window_list: docked)")
		}
		side, _ := params["side"].(json.String)
		switch side {
		case "", "tab": op.side = .None
		case "left":    op.side = .Left
		case "right":   op.side = .Right
		case "top":     op.side = .Up
		case "bottom":  op.side = .Down
		case:
			delete(op.name, runtime.default_allocator())
			return mcp.tool_fail("bad_request", "side must be left, right, top, bottom or tab")
		}
		ratio, has_ratio := mcp.json_f32(params, "ratio")
		op.ratio = has_ratio ? clamp(ratio, 0.1, 0.9) : 0.35
		op.kind = .Dock
		op.target = strings.clone(string(target.Name), runtime.default_allocator())
	} else {
		info := _window_info(w)
		op.kind = .Place
		op.rect = {info.x, info.y, info.width, info.height}
		if v, ok := mcp.json_f32(params, "x"); ok do op.rect.x = v
		if v, ok := mcp.json_f32(params, "y"); ok do op.rect.y = v
		if v, ok := mcp.json_f32(params, "width"); ok do op.rect.z = max(v, 32)
		if v, ok := mcp.json_f32(params, "height"); ok do op.rect.w = max(v, 32)
	}
	_queue(op)
	return MCP_DEFERRED, {}
}

@(mcp_tool={
	description="Resize a window. A floating one takes the size as given. A docked one moves the split between it and its neighbour: width moves the nearest left-right split, height the nearest top-bottom one. Answers with the window's rectangle once the change shows. Changes the saved layout, as a drag does.",
	param_window="string!:Title or id of the window (window_list)",
	param_width="number:Width, points (default: keep)",
	param_height="number:Height, points (default: keep)",
})
mcp_tool_window_resize :: proc(id: i64, params: json.Object) -> (string, Mcp_Error) {
	query, _ := params["window"].(json.String)
	w, err := _find_view(query)
	if err.code != "" do return "", err
	op := _Window_Op{id = id, kind = .Resize, name = strings.clone(string(w.Name), runtime.default_allocator())}
	if v, ok := mcp.json_f32(params, "width"); ok do op.rect.z = max(v, 32)
	if v, ok := mcp.json_f32(params, "height"); ok do op.rect.w = max(v, 32)
	if op.rect.z == 0 && op.rect.w == 0 {
		delete(op.name, runtime.default_allocator())
		return mcp.tool_fail("bad_request", "need width or height")
	}
	_queue(op)
	return MCP_DEFERRED, {}
}

@(mcp_tool={
	description="Set the editor window's own size in points, keeping its position: the same size every run makes screenshots comparable. Saved on exit like a resize by hand.",
	param_width="integer!:Width, points",
	param_height="integer!:Height, points",
})
mcp_tool_editor_size :: proc(id: i64, params: json.Object) -> (string, Mcp_Error) {
	w := i32(mcp.json_int(params, "width", 0))
	h := i32(mcp.json_int(params, "height", 0))
	if w < 320 || h < 240 do return mcp.tool_fail("bad_request", "need width >= 320 and height >= 240")
	pos := gfx.window_position()
	gfx.set_window_geometry(pos.x, pos.y, w, h)
	return mcp.tool_ok(struct {width, height: i32}{w, h})
}

// The rectangle of window `query` in the editor capture's pixels (screenshot
// view=window), or an error.
mcp_window_capture_rect :: proc(query: string) -> (rect: [4]i32, title: string, err: Mcp_Error) {
	w: ^im.Window
	w, err = _find_view(query)
	if err.code != "" do return
	info := _window_info(w)
	if !info.visible {
		err = {"not_visible", fmt.tprintf("%q is not drawn (a tab behind another, or hidden): window_place brings it forward", info.title)}
		return
	}
	scale := im.GetIO().DisplayFramebufferScale
	rect = {i32(info.x * scale.x), i32(info.y * scale.y), i32(info.width * scale.x), i32(info.height * scale.y)}
	return rect, info.title, {}
}

@(private = "file")
_queue :: proc(op: _Window_Op) {
	if _window_ops == nil do _window_ops = make([dynamic]_Window_Op, runtime.default_allocator())
	append(&_window_ops, op)
}

@(private = "file")
_op_free :: proc(op: ^_Window_Op) {
	delete(op.name, runtime.default_allocator())
	delete(op.target, runtime.default_allocator())
}

// Applies the queued view operations: right after im.NewFrame, before the
// dockspace and the views draw (main.odin). Each runs over a few frames:
// - Place: undock (applied by imgui at the next NewFrame), then set the
//   rectangle and focus, then answer
// - Dock: DockBuilder split (or the target's node) before the dockspace
//   draws, then answer
// - Resize: the floating size, or the split's two sides, then answer
mcp_bridge_window_ops :: proc() {
	if len(_window_ops) == 0 do return
	ctx := im.GetCurrentContext()
	vp := im.GetMainViewport()
	for i := 0; i < len(_window_ops); {
		op := &_window_ops[i]
		done := false
		w := im.FindWindowByName(strings.clone_to_cstring(op.name, context.temp_allocator))
		nodes := _dock_nodes()
		if w == nil {
			_mcp_respond_error(op.id, "not_found", "the window closed")
			done = true
		} else if op.stage == 1 {
			// The change has had a frame to show.
			result, _ := mcp.tool_ok(_window_info(w))
			_mcp_respond(op.id, result)
			done = true
		} else {
			switch op.kind {
			case .Place:
				if w in nodes {
					// Undocking lands at the next NewFrame. A window that will
					// not leave its node is answered as it is.
					if op.frames == 0 do im.DockContextQueueUndockWindow(ctx, w)
					op.frames += 1
					if op.frames < 5 do break
				}
				im.SetWindowPosImGuiWindowPtr(w, {vp.Pos.x + op.rect.x, vp.Pos.y + op.rect.y})
				im.SetWindowSizeImGuiWindowPtr(w, {op.rect.z, op.rect.w})
				im.FocusWindow(w)
				op.stage = 1
			case .Dock:
				target := im.FindWindowByName(strings.clone_to_cstring(op.target, context.temp_allocator))
				node, target_docked := nodes[target]
				if target == nil || !target_docked {
					_mcp_respond_error(op.id, "not_found", "the window to dock beside is gone or no longer docked")
					done = true
					break
				}
				root := node
				for root.ParentNode != nil do root = root.ParentNode
				dest := node.ID_
				if op.side != .None {
					at_dir, opposite: im.ID
					im.DockBuilderSplitNode(node.ID_, op.side, op.ratio, &at_dir, &opposite)
					dest = at_dir
				}
				im.DockBuilderDockWindow(strings.clone_to_cstring(op.name, context.temp_allocator), dest)
				im.DockBuilderFinish(root.ID_)
				op.stage = 1
			case .Resize:
				if node, docked := nodes[w]; docked {
					if op.rect.z > 0 do _move_split(node, .X, op.rect.z)
					if op.rect.w > 0 do _move_split(node, .Y, op.rect.w)
				} else {
					size := w.SizeFull
					if op.rect.z > 0 do size.x = op.rect.z
					if op.rect.w > 0 do size.y = op.rect.w
					im.SetWindowSizeImGuiWindowPtr(w, size)
				}
				op.stage = 1
			}
		}
		if done {
			_op_free(op)
			ordered_remove(&_window_ops, i)
			continue
		}
		i += 1
	}
}

// Gives `node` (or its nearest ancestor that sits in a split along `axis`)
// `size` points along the axis: both sides of that split get their sizes
// written, which is what dragging the splitter does. The split divides by
// the two sides' SizeRef, or gives the side without the central node its
// own, so both are written.
@(private = "file")
_move_split :: proc(node: ^im.DockNode, axis: im.Axis, size: f32) {
	n := node
	for n.ParentNode != nil && n.ParentNode.SplitAxis != axis do n = n.ParentNode
	parent := n.ParentNode
	if parent == nil do return // the whole dockspace: the editor's size sets it
	other := parent.ChildNodes[0] == n ? parent.ChildNodes[1] : parent.ChildNodes[0]
	a := int(axis)
	avail := max(parent.Size[a] - 2, 1) // the splitter between them
	mine := clamp(size, 32, avail - 32)
	n.SizeRef[a] = mine
	n.Size[a] = mine
	other.SizeRef[a] = avail - mine
	other.Size[a] = avail - mine
}
