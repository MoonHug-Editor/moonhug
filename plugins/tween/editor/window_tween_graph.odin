package tween_editor

// Tween Graph window: a component's authored tween trees as a node canvas,
// with the selected node's fields in a panel beside it.
//
// An authored tween is a guid-tagged json.Value (tween.Authored) — children
// nest inside the parent's "children" array. The window walks that JSON, so it
// needs no union and no registration knowledge: any node type shows up by
// its guid. The selected node is edited through a MATERIALIZED typed
// instance (guid → typeid → unmarshal), and an edit marshals back into the
// blob under a whole-component undo session.
//
// The window's target is (component handle, root ordinal): the handle
// survives undo, and the Nth Authored field in the component's reflection
// walk names the same tree across any edit that keeps the component's shape.
// Selection is the node's PATH from the root (child ordinals) — undo
// replaces the whole blob, so nothing stores pointers into it.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:reflect"
import "core:strings"
import im "moonhug:external/odin-imgui"
import "moonhug:libs/gfx"
import engine "moonhug:packages/engine"
import tween "moonhug:packages/tween"
import nc "moonhug:editor/node_canvas"
import "moonhug:editor/icons"
import "moonhug:editor/inspector"
import "moonhug:editor/undo"
import wnd "moonhug:editor/window"
import "moonhug:editor/widgets"
import "moonhug:editor/preview"

@(private = "file")
_state: struct {
	cv: nc.Node_Canvas,

	target:     engine.Handle,
	root_idx:   int,
	has_target: bool,

	sel_path:   [64]i32,
	sel_depth:  int,
	sel_active: bool,

	framed: bool, // framed once its content has been drawn
	drawn:  bool, // the canvas has drawn once, so it knows its size

	// The tree playing in edit mode. A paused run, kept when done: the game's ticks
	// leave it alone, and the preview hooks below drive it.
	preview:         tween.Handle,
	preview_pending: f32, // seconds to advance at the next apply
	preview_done:    f32, // seconds the finished preview has shown its end pose
}

// How long a finished preview shows its end pose before it ends.
// The window's layout, saved per developer: the node panel shown or not and
// its width, and the canvas's mini-map. The toolbar's Node and map toggles
// flip them, the splitter sets the width.
Tween_Graph_Prefs :: struct {
	hide_panel: bool,
	panel_w:    f32, // 0 = the default
	minimap:    widgets.Minimap,
}

@(user_settings={name="Tween Graph"})
tween_graph_prefs: Tween_Graph_Prefs

@(private = "file") _PANEL_W :: f32(300)
@(private = "file") _MIN_PANEL :: f32(160)
@(private = "file") _MIN_CANVAS :: f32(200)

@(private = "file")
_PREVIEW_HOLD_SECONDS :: f32(0.75)

// The preview poses the world only for the Scene and Game render, the way the
// Animation and Sequencer windows do (moonhug:editor/preview): apply right
// before the render, restore right after. Saves, undo and the inspector see
// authored values, and an edit made during a preview is kept.
@(phase={key=EditorInit, order=2, mode=Editor})
tween_preview_install :: proc() {
	preview.register({apply = _preview_apply, restore = _preview_restore})
	preview.register_frame({frame = _preview_frame})
}

@(private = "file")
_preview_start :: proc(owner: engine.Transform_Handle, root: ^tween.Authored) {
	_preview_stop()
	_state.preview = tween.run(root, tween.TweenContext{subject = owner})
	tween.set_keep_when_done(_state.preview, true)
	tween.set_paused(_state.preview, true)
	// The tree begins at the next apply, inside the render bracket, so its
	// starts are authored values and restore puts them back.
	_state.preview_pending = 0
	_state.preview_done = 0
}

// Ends the preview. Outside the render the world holds authored values, so
// nothing is left to put back.
@(private = "file")
_preview_stop :: proc() {
	tween.stop(_state.preview)
	_state.preview = {}
}

// Once per frame, before the windows draw, whether or not the Tween Graph is
// on screen: time passes, and a finished preview ends after its hold.
@(private = "file")
_preview_frame :: proc() {
	if !tween.is_alive(_state.preview) do return
	// The editor draws at its idle rate when nothing happens. A preview moves
	// with no input, so it asks for the full rate while it plays.
	gfx.keep_awake()
	dt := min(im.GetIO().DeltaTime, 0.1)
	if tween.is_done(_state.preview) {
		_state.preview_done += dt
		if _state.preview_done >= _PREVIEW_HOLD_SECONDS do _preview_stop()
		return
	}
	_state.preview_pending += dt
}

@(private = "file")
_preview_apply :: proc() {
	if !tween.is_alive(_state.preview) do return
	tween.replay(_state.preview)
	if !tween.is_done(_state.preview) && _state.preview_pending > 0 {
		tween.tick(_state.preview, _state.preview_pending)
	}
	_state.preview_pending = 0
}

@(private = "file")
_preview_restore :: proc() {
	tween.unapply(_state.preview)
}

// Play starts from the scene as it was authored, not from a preview's pose.
@(phase={key=ExitingEditMode, mode=Editor})
tween_graph_exiting_edit_mode :: proc() {
	_preview_stop()
}

// One node of the walk: the authored value (shares the blob's storage, so
// mutations through it edit the component) and its resolved type.
@(private = "file")
_Walked :: struct {
	value:     json.Value,
	tid:       typeid,
	title:     string, // the node type's label
	summary:   string, // delay, await, skipped: the node's one row
	skip:      bool,
	parent:    int, // index into the walk, -1 for a root
	child_ord: int, // ordinal in the parent's children array, -1 for a root
}

// The window closed: a preview left playing would keep its pose in the scene.
tween_graph_window_closed :: proc(w: ^wnd.Window) {
	_preview_stop()
}

@(editor_window={id="tween_graph", title="Tween Graph", icon="SHOW_CHART", width=900, height=520, closed=tween_graph_window_closed})
tween_graph_window_draw :: proc(w: ^wnd.Window) {
	w := engine.ctx_world()
	if w == nil {
		im.TextDisabled("No world.")
		return
	}

	// Resolved fresh every frame: the handle survives undo, the blob values
	// behind it do not.
	roots: []^tween.Authored
	base: rawptr
	if _state.has_target {
		base = engine.world_pool_get(w, _state.target)
		if base != nil {
			if tid := engine.get_typeid_by_type_key(_state.target.type_key); tid != nil {
				roots = tween_roots_of(base, tid)
			}
		}
	}
	if base == nil || _state.root_idx >= len(roots) {
		_preview_stop()
		_state.has_target = false
		im.TextDisabled("No tween tree open.")
		im.TextDisabled("Click a tween row's graph button in the inspector.")
		return
	}

	_draw_toolbar(base, roots)
	im.Separator()

	walked := make([dynamic]_Walked, context.temp_allocator)
	_walk(roots[_state.root_idx].value, -1, -1, &walked, 0)

	parents := make([]int, len(walked), context.temp_allocator)
	for wk, i in walked do parents[i] = wk.parent

	sel_idx := -1
	if _state.sel_active {
		sel_idx = nc.tree_find_path(parents, 0, _state.sel_path[:_state.sel_depth])
	}
	if sel_idx < 0 do _state.sel_active = false

	// Every node has one row, its summary, so all are the same size and the
	// links meet the row's ports.
	sizes := make([]im.Vec2, len(walked), context.temp_allocator)
	for &sz in sizes do sz = nc.canvas_node_size(1)
	positions := make([]im.Vec2, len(walked), context.temp_allocator)
	nc.canvas_layout_tree(parents, sizes, positions)

	// Canvas | node panel, split by the shared splitter. The panel keeps its
	// width when the window resizes and gives way to the canvas when the
	// window gets too narrow for both.
	prefs := &tween_graph_prefs
	show_panel := !prefs.hide_panel
	avail := im.GetContentRegionAvail()
	panel_w := show_panel ? (prefs.panel_w > 0 ? prefs.panel_w : _PANEL_W) : 0
	splitter := show_panel ? widgets.SPLITTER_SIZE : 0
	canvas_w := avail.x - splitter - panel_w
	if canvas_w < _MIN_CANVAS && show_panel {
		panel_w = max(panel_w - (_MIN_CANVAS - canvas_w), _MIN_PANEL)
		canvas_w = avail.x - splitter - panel_w
	}

	cv := &_state.cv
	cv.minimap = &prefs.minimap
	// The canvas knows its size after it drew once, so framing waits a frame.
	if !_state.framed && _state.drawn && len(walked) > 0 {
		lo, hi := positions[0], positions[0] + sizes[0]
		for p, i in positions {
			lo = {min(lo.x, p.x), min(lo.y, p.y)}
			hi = {max(hi.x, p.x + sizes[i].x), max(hi.y, p.y + sizes[i].y)}
		}
		nc.canvas_frame(cv, lo, hi)
		_state.framed = true
	}

	cv.sel = sel_idx
	if im.BeginChild("##tween_canvas_host", im.Vec2{canvas_w, avail.y}) {
		if nc.canvas_begin(cv, "##tween_canvas") {
			for wk, i in walked {
				if wk.parent < 0 do continue
				from := nc.canvas_port_out(cv, positions[wk.parent], 0)
				to := nc.canvas_port_in(cv, positions[i], 0)
				nc.canvas_link(cv, from, to, im.GetColorU32(.Text, 0.45))
			}
			for &wk, i in walked {
				color := _color_for(wk.tid)
				if wk.skip do color.w = 0.45
				has_children := false
				for p in parents do if p == i do has_children = true
				rows := [1]nc.Canvas_Row{{label = strings.clone_to_cstring(wk.summary, context.temp_allocator), port = wk.parent >= 0}}
				nc.canvas_node(cv, i, &positions[i], strings.clone_to_cstring(wk.title, context.temp_allocator), color, rows[:], has_children, movable = false)
			}
		}
		nc.canvas_end(cv)
		_state.drawn = true
	}
	im.EndChild()

	// The canvas selects on a press and clears on a click on empty canvas.
	// Node identity on the canvas is the walk index, stable within the frame,
	// and the kept selection is the path.
	if cv.sel != sel_idx {
		sel_idx = cv.sel
		if sel_idx >= 0 && sel_idx < len(walked) {
			_state.sel_depth = nc.tree_path_of(parents, sel_idx, _state.sel_path[:])
			_state.sel_active = true
		} else {
			sel_idx = -1
			_state.sel_active = false
		}
	}

	if !show_panel do return
	im.SameLine(0, 0)
	if widgets.splitter("##tween_split", true, &canvas_w, &panel_w, _MIN_CANVAS, _MIN_PANEL) do prefs.panel_w = panel_w
	im.SameLine(0, 0)
	if im.BeginChild("##tween_props", im.Vec2{0, avail.y}, {.Borders}) {
		if sel_idx >= 0 {
			// Type button + structural ops head the panel, fields below —
			// the type names the node, so it reads as the panel's title.
			// Pointers into the OWNING storage — the mutators write map
			// headers back through them.
			root := roots[_state.root_idx]
			v_ptr := _walked_ptr(walked[:], sel_idx, root)
			parent_ptr: ^json.Value
			if p := walked[sel_idx].parent; p >= 0 do parent_ptr = _walked_ptr(walked[:], p, root)
			_draw_structural_ops(
				_state.target,
				v_ptr,
				walked[sel_idx].tid,
				parent_ptr,
				walked[sel_idx].child_ord,
			)
			im.Separator()
			_draw_selected_panel(_state.target, walked[sel_idx].value, walked[sel_idx].tid)
		} else {
			im.TextDisabled("Select a node.")
		}
	}
	im.EndChild()
}

// Resolves a walked node to a pointer INTO the owning storage (the root
// Authored field or a children-array element) — the mutators need it, a
// walked copy of the value is read-only.
@(private = "file")
_walked_ptr :: proc(walked: []_Walked, idx: int, root: ^tween.Authored) -> ^json.Value {
	if walked[idx].parent < 0 do return &root.value
	parent_ptr := _walked_ptr(walked, walked[idx].parent, root)
	obj, is_obj := parent_ptr^.(json.Object)
	if !is_obj do return nil
	arr, has := obj["children"].(json.Array)
	if !has || walked[idx].child_ord < 0 || walked[idx].child_ord >= len(arr) do return nil
	return &arr[walked[idx].child_ord]
}

// Add-child (composites) and Delete (non-root) for a node, each one undo
// step on the owning component.
@(private = "file")
_draw_structural_ops :: proc(
	owner: engine.Handle,
	v: ^json.Value,
	tid: typeid,
	parent_v: ^json.Value,
	child_ord: int,
) {
	comp_tid := engine.get_typeid_by_type_key(owner.type_key)
	if comp_tid == nil || v == nil do return

	// The button IS the node's type name — it labels the node and opens the
	// picker, so no separate "Change Type" affordance is needed.
	type_name := tid != nil ? _type_label(tid) : "unknown type"
	if im.Button(strings.clone_to_cstring(type_name, context.temp_allocator)) do im.OpenPopup("##tw_retype")
	widgets.tooltip("Change node type", im.HoveredFlags_ForTooltip)
	if new_tid, picked := _node_type_popup("##tw_retype"); picked && new_tid != tid {
		// The session is claimed by the field editors too — flush it so a
		// pending field edit lands before the structural step.
		_edit_finalize()
		e := undo.edit_begin(owner, comp_tid, "Change Node Type")
		tween.authored_retype(v, new_tid)
		undo.edit_end(&e)
	}

	if tid != nil && tween.node_type_has_children(tid) {
		im.SameLine()
		if im.Button("Add Child") do im.OpenPopup("##tw_add_child")
		if new_tid, picked := _node_type_popup("##tw_add_child"); picked {
			if child, cok := tween.authored_make(new_tid); cok {
				_edit_finalize()
				e := undo.edit_begin(owner, comp_tid, "Add Child Node")
				if !tween.authored_add_child(v, child) do tween.authored_destroy(&child)
				undo.edit_end(&e)
			}
		}
	}

	if child_ord >= 0 && parent_v != nil {
		im.SameLine()
		if im.Button("Delete Node") {
			_edit_finalize()
			e := undo.edit_begin(owner, comp_tid, "Delete Node")
			tween.authored_remove_child(parent_v, child_ord)
			undo.edit_end(&e)
			_state.sel_active = false
		}
	}
}

// The node-type picker: every REGISTERED type, so a package's nodes appear
// here the moment it is installed — nothing lists types by hand.
@(private = "file")
_node_type_popup :: proc(id: cstring) -> (tid: typeid, picked: bool) {
	if !im.BeginPopup(id) do return nil, false
	defer im.EndPopup()
	im.TextDisabled("Node type")
	im.Separator()
	for t in tween.registered_node_types() {
		label := _type_label(t)
		if tween.node_type_has_children(t) {
			label = fmt.tprintf("%s  (composite)", label)
		}
		if im.Selectable(strings.clone_to_cstring(label, context.temp_allocator)) {
			im.CloseCurrentPopup()
			return t, true
		}
	}
	return nil, false
}

@(private = "file")
_draw_toolbar :: proc(base: rawptr, roots: []^tween.Authored) {
	owner_name := "?"
	w := engine.ctx_world()
	comp := cast(^engine.CompData)base
	if t := engine.pool_get(&w.transforms, engine.Handle(comp.owner)); t != nil {
		owner_name = t.name
	}
	im.TextUnformatted(strings.clone_to_cstring(owner_name, context.temp_allocator))

	im.SameLine()
	if len(roots) > 1 {
		im.SetNextItemWidth(180)
		if im.BeginCombo("##root", _root_label(roots, _state.root_idx)) {
			for _, i in roots {
				if im.Selectable(_root_label(roots, i), i == _state.root_idx) {
					_preview_stop()
					_state.root_idx = i
					_state.sel_active = false
					_state.framed = false
				}
			}
			im.EndCombo()
		}
	} else {
		im.TextUnformatted(_root_label(roots, 0))
	}

	// Preview: the tree plays on its object in edit mode, shows its end pose
	// for a moment and puts everything back.
	im.SameLine()
	if engine.game_running() {
		im.BeginDisabled()
		im.Button("Preview")
		im.EndDisabled()
	} else if tween.is_alive(_state.preview) {
		if im.Button("Stop") do _preview_stop()
	} else if im.Button("Preview") {
		_preview_start(comp.owner, roots[_state.root_idx])
	}
	widgets.tooltip("Plays the tree on its object in edit mode, then puts every value back. In Play, the game starts the tree.", im.HoveredFlags_ForTooltip | im.HoveredFlags_AllowWhenDisabled)

	im.SameLine()
	if im.Button("Frame All") do _state.framed = false

	// The pane toggles, right-aligned: the node panel and the mini-map.
	style := im.GetStyle()
	w_node := im.CalcTextSize("Node").x + style.FramePadding.x * 2
	w_map := im.GetFrameHeight()
	im.SameLine()
	x := im.GetCursorPosX()
	im.SetCursorPosX(max(x + im.GetContentRegionAvail().x - w_node - w_map - style.ItemSpacing.x, x))
	prefs := &tween_graph_prefs
	lit := !prefs.hide_panel
	if lit do im.PushStyleColorImVec4(.Button, im.GetStyleColorVec4(.ButtonActive)^)
	if im.Button("Node") do prefs.hide_panel = !prefs.hide_panel
	if lit do im.PopStyleColor()
	widgets.tooltip("Show the selected node's fields")
	im.SameLine()
	if widgets.icon_button(icons.ICON_MD_MAP, "##tween_map", "Show or hide the mini-map", active = !prefs.minimap.hidden) {
		prefs.minimap.hidden = !prefs.minimap.hidden
	}
}

@(private = "file")
_root_label :: proc(roots: []^tween.Authored, i: int) -> cstring {
	name := "?"
	if tid, ok := tween.authored_typeid(roots[i].value); ok {
		name = _type_label(tid)
	}
	return strings.clone_to_cstring(fmt.tprintf("%d: %s", i, name), context.temp_allocator)
}

// Flattens the authored JSON tree into nodes + links.
@(private = "file")
_walk :: proc(
	v: json.Value,
	parent: int,
	child_ord: int,
	walked: ^[dynamic]_Walked,
	depth: int,
) {
	if depth > 64 do return
	tid, tok := tween.authored_typeid(v)
	idx := len(walked)

	title := "?"
	if tok do title = _type_label(tid)
	skip, summary := _base_summary(v)

	append(walked, _Walked{value = v, tid = tid, title = title, summary = summary, skip = skip, parent = parent, child_ord = child_ord})

	if children, kok := tween.authored_children(v); kok {
		for child, i in children {
			_walk(child, idx, i, walked, depth + 1)
		}
	}
}

// "TweenMoveToLocal" -> "Move To Local".
@(private = "file")
_type_label :: proc(tid: typeid) -> string {
	name := fmt.tprintf("%v", tid)
	if strings.has_prefix(name, "Tween") && len(name) > 5 do name = name[5:]

	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< len(name) {
		c := name[i]
		if i > 0 && c >= 'A' && c <= 'Z' && !(name[i - 1] >= 'A' && name[i - 1] <= 'Z') {
			strings.write_byte(&b, ' ')
		}
		strings.write_byte(&b, c)
	}
	return strings.to_string(b)
}

// The base fields worth seeing without selecting the node, read from the
// node's "base" object.
@(private = "file")
_base_summary :: proc(v: json.Value) -> (skip: bool, subtitle: string) {
	obj, is_obj := v.(json.Object)
	if !is_obj do return false, ""
	base, has_base := obj["base"].(json.Object)
	if !has_base do return false, ""

	parts := make([dynamic]string, context.temp_allocator)
	if d, ok := base["delay"].(json.Float); ok && d > 0 {
		append(&parts, fmt.tprintf("delay %.2fs", d))
	}
	if a, ok := base["is_await"].(json.Boolean); ok && bool(a) {
		append(&parts, "await")
	}
	if s, ok := base["skip"].(json.Boolean); ok && bool(s) {
		skip = true
		append(&parts, "skipped")
	}
	if len(parts) == 0 do return skip, ""
	return skip, strings.join(parts[:], "  ", context.temp_allocator)
}

@(private = "file")
_color_for :: proc(tid: typeid) -> [4]f32 {
	name := fmt.tprintf("%v", tid)
	switch name {
	case "Sequence": return {0.22, 0.42, 0.65, 1}
	case "Parallel": return {0.25, 0.52, 0.45, 1}
	case "Tween":    return {0.38, 0.38, 0.44, 1}
	}
	return {0.45, 0.36, 0.58, 1} // leaf tween
}

// The selected node's fields: the blob node MATERIALIZES into a typed temp
// instance, the ordinary inspector draws it (drawers and decorators behave
// as in the main inspector), and a change marshals back into the blob under
// a whole-component undo step. Undo replaces the component's blob — the
// caller re-walks every frame and selection is a path, so the node stays
// selected across the undo.
@(private = "file")
_draw_selected_panel :: proc(owner_handle: engine.Handle, v: json.Value, sel_tid: typeid) {
	if sel_tid == nil {
		im.TextDisabled("Unknown tween type (package not installed?).")
		return
	}
	_, ok := engine.get_pointer_typeid_by_typeid(sel_tid)
	if !ok {
		im.TextDisabled("This tween type is not registered for inspection.")
		return
	}

	_node_editor(owner_handle, _state.root_idx, _state.sel_path[:_state.sel_depth], v, sel_tid)
}

// --- The node field editor ----------------------------------------------------

// One edit session exists at a time: fields edit a MATERIALIZED typed
// instance that persists across frames while its widget is active (drags
// accumulate), and release splices the result into the blob as ONE
// whole-component undo step. Idle editors materialize per frame — an f32
// instance re-marshaled against itself is byte-stable, so no phantom edits.
//
// The persisted instance is a byte copy: node fields must be PLAIN data (no
// strings, no arrays beyond the runtime-managed children) or the copy would
// share frame-temporary heap.
@(private = "file")
_edit: struct {
	key:      u64,
	owner:    engine.Handle,
	root_idx: int,
	path:     [64]i32,
	depth:    int,
	tid:      typeid,
	buf:      rawptr,
	baseline: []byte, // the instance's marshal at claim time
}

@(private = "file")
_edit_key :: proc(owner: engine.Handle, root_idx: int, path: []i32) -> u64 {
	mix :: proc(h, x: u64) -> u64 { return (h ~ x) * 0x100000001b3 }
	h: u64 = 0xcbf29ce484222325
	h = mix(h, u64(owner.index))
	h = mix(h, u64(owner.generation))
	h = mix(h, u64(owner.type_key))
	h = mix(h, u64(root_idx) + 1)
	for p in path do h = mix(h, u64(p) + 0x9e37)
	return h
}

@(private = "file")
_edit_reset :: proc() {
	if _edit.buf != nil do free(_edit.buf, runtime.default_allocator())
	if _edit.baseline != nil do delete(_edit.baseline, runtime.default_allocator())
	_edit = {}
}

// Splices the session's instance into its node (re-resolved fresh — blobs
// move under undo) as one undo step, then clears the session.
@(private = "file")
_edit_finalize :: proc() {
	defer _edit_reset()
	if _edit.buf == nil do return
	after, merr := json.marshal(any{_edit.buf, _edit.tid}, {spec = .JSON}, context.temp_allocator)
	if merr != nil || string(after) == string(_edit.baseline) do return

	w := engine.ctx_world()
	if w == nil do return
	base := engine.world_pool_get(w, _edit.owner)
	if base == nil do return
	comp_tid := engine.get_typeid_by_type_key(_edit.owner.type_key)
	if comp_tid == nil do return
	roots := tween_roots_of(base, comp_tid)
	if _edit.root_idx >= len(roots) do return
	// A POINTER into the owning storage — the splice writes the map header
	// back through it.
	v := &roots[_edit.root_idx].value
	for i in 0 ..< _edit.depth {
		obj, is_obj := v^.(json.Object)
		if !is_obj do return
		children, kok := obj["children"].(json.Array)
		if !kok || int(_edit.path[i]) >= len(children) do return
		v = &children[_edit.path[i]]
	}
	if tid, tok := tween.authored_typeid(v^); !tok || tid != _edit.tid do return

	e := undo.edit_begin(_edit.owner, comp_tid, "Edit Node")
	_splice_into_node(v, after)
	undo.edit_end(&e)
}

@(private = "file")
_node_editor :: proc(owner: engine.Handle, root_idx: int, path: []i32, v: json.Value, tid: typeid) {
	ptr_tid, ok := engine.get_pointer_typeid_by_typeid(tid)
	if !ok {
		im.TextDisabled("This tween type is not registered for inspection.")
		return
	}
	key := _edit_key(owner, root_idx, path)
	mine := _edit.buf != nil && _edit.key == key && _edit.tid == tid

	instance: rawptr
	pre: []byte
	if mine {
		instance = _edit.buf
	} else {
		ti := type_info_of(tid)
		inst, aerr := mem.alloc(ti.size, ti.align, context.temp_allocator)
		if aerr != nil do return
		bytes, merr := json.marshal(v, {spec = .JSON}, context.temp_allocator)
		if merr != nil do return
		pp := inst
		if json.unmarshal_any(bytes, any{&pp, ptr_tid}) != nil do return
		engine.type_on_validate_by_typeid(tid, inst)
		// The value holds references by saved id only. Bind their handles in
		// the owner's scene, or the inspector shows every one as missing.
		if w := engine.ctx_world(); w != nil {
			if comp := cast(^engine.CompData)engine.world_pool_get(w, owner); comp != nil {
				if t := engine.pool_get(&w.transforms, engine.Handle(comp.owner)); t != nil && t.scene != nil {
					engine.refs_resolve_in_value(inst, type_info_of(tid), t.scene)
				}
			}
		}
		instance = inst
		pb, perr := json.marshal(any{instance, tid}, {spec = .JSON}, context.temp_allocator)
		if perr != nil do return
		pre = pb
	}

	// Two editors can show the same node (inline row + graph panel) — the id
	// scope keeps their widgets distinct.
	im.PushID(fmt.ctprintf("tw_node_%v", key))
	target := instance
	// No inspector owner is pushed here, since this editor records its own
	// undo. Reference fields still need the owner's scene to pick from.
	inspector.ref_scope_begin(owner)
	inspector.draw_inspector(any{data = &target, id = ptr_tid})
	inspector.ref_scope_end()
	im.PopID()

	if mine {
		if !im.IsAnyItemActive() do _edit_finalize()
		return
	}

	post, merr := json.marshal(any{instance, tid}, {spec = .JSON}, context.temp_allocator)
	if merr != nil do return
	if string(post) == string(pre) do return

	// A change claims the session (finalizing another editor's first).
	_edit_finalize()
	ti := type_info_of(tid)
	buf, aerr := mem.alloc(ti.size, ti.align, runtime.default_allocator())
	if aerr != nil do return
	mem.copy(buf, instance, ti.size)
	baseline := make([]byte, len(pre), runtime.default_allocator())
	copy(baseline, pre)
	_edit.key = key
	_edit.owner = owner
	_edit.root_idx = root_idx
	for p, i in path do _edit.path[i] = p
	_edit.depth = len(path)
	_edit.tid = tid
	_edit.buf = buf
	_edit.baseline = baseline
	// Click-shaped widgets (checkbox, combo) are done within the frame.
	if !im.IsAnyItemActive() do _edit_finalize()
}

// Writes the typed instance's fields into the node object in place —
// "__type_guid" and "children" are never in the instance's marshal, so they
// survive untouched.
@(private = "file")
_splice_into_node :: proc(v: ^json.Value, fields_json: []byte) {
	obj, is_obj := v^.(json.Object)
	if !is_obj do return
	prev := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev
	// Inserts can rehash — the header must land back in the caller's storage.
	defer v^ = obj
	fresh, perr := json.parse(fields_json, .JSON, true)
	if perr != nil do return
	fobj, fok := fresh.(json.Object)
	if !fok {
		json.destroy_value(fresh)
		return
	}
	// Collect first (mutating a map while iterating it skips entries), and
	// free the replaced/donor key strings — delete_key alone leaks them.
	// Values move out and keys are freed per iteration — at the end only the
	// map's own storage remains.
	defer delete(fobj)
	fresh_keys := make([dynamic]string, context.temp_allocator)
	for key in fobj do append(&fresh_keys, key)
	for key in fresh_keys {
		defer delete(key)
		if old, has := obj[key]; has {
			json.destroy_value(old)
			old_key, _ := delete_key(&obj, key)
			delete(old_key)
		}
		obj[strings.clone(key)] = fobj[key]
	}
}

@(menu_item={path="Window/Animation/Tween Graph", shortcut="", help="Opens the Tween Graph"})
tween_graph_window_open :: proc() {
	wnd.open("tween_graph")
}

// --- Opening the graph from the inspector -----------------------------------

// account_tree / swap_horiz \u2014 duplicated literals, the editor root owns the
// canonical list and this package cannot import it.
@(private = "file")
_ICON_GRAPH :: "\ue97a"

// Every authored-tween row in the inspector shows a summary and a Graph
// button (the graph panel is the field editor).
@(property_drawer={type=tween.Authored})
property_drawer_Authored :: proc(ctx: ^inspector.Ctx) {
	ptr, label := ctx.ptr, ctx.label
	a := cast(^tween.Authored)ptr
	if im.SmallButton(fmt.ctprintf("%s##tg_%v", _ICON_GRAPH, ptr)) {
		_open_graph_for(a)
	}
	widgets.tooltip("Open in Tween Graph", im.HoveredFlags_ForTooltip)
	im.SameLine()

	ntid, nok := tween.authored_typeid(a.value)
	if !nok {
		// An empty slot (a fresh array element): pick its type here, since
		// the graph has no tree to open yet.
		popup_id := fmt.ctprintf("##tw_new_%v", ptr)
		if im.Button(fmt.ctprintf("Set Type##tw_set_%v", ptr)) do im.OpenPopup(popup_id)
		if new_tid, picked := _node_type_popup(popup_id); picked {
			o, o_ok := undo.current_owner()
			if made, mok := tween.authored_make(new_tid); mok {
				if o_ok && o.kind == .Pooled {
					comp_tid := engine.get_typeid_by_type_key(o.handle.type_key)
					e := undo.edit_begin(o.handle, comp_tid, "Set Node Type")
					tween.authored_destroy(a)
					a^ = made
					undo.edit_end(&e)
				} else {
					tween.authored_destroy(a)
					a^ = made
				}
			}
		}
		im.SameLine()
		im.TextUnformatted(strings.clone_to_cstring(fmt.tprintf("%s: empty", label), context.temp_allocator))
		return
	}

	// Retype the root from the row itself — the button IS the type name, so
	// it reads as the node's type and opens the picker. Nested nodes retype
	// in the graph panel, where each is selectable.
	root_popup := fmt.ctprintf("##tw_rt_%v", ptr)
	if im.SmallButton(fmt.ctprintf("%s##tw_rtb_%v", _type_label(ntid), ptr)) do im.OpenPopup(root_popup)
	widgets.tooltip("Change node type", im.HoveredFlags_ForTooltip)
	if new_tid, picked := _node_type_popup(root_popup); picked && new_tid != ntid {
		o, o_ok := undo.current_owner()
		if o_ok && o.kind == .Pooled {
			comp_tid := engine.get_typeid_by_type_key(o.handle.type_key)
			e := undo.edit_begin(o.handle, comp_tid, "Set Root Type")
			tween.authored_retype(&a.value, new_tid)
			undo.edit_end(&e)
		} else {
			tween.authored_retype(&a.value, new_tid)
		}
	}
	im.SameLine()

	// The editors need the owning component (undo target + node addressing).
	// The inspector pushes it as the ambient owner during a component's draw.
	o, o_ok := undo.current_owner()
	root_idx := -1
	if o_ok && o.kind == .Pooled && o.base_ptr != nil {
		if comp_tid := engine.get_typeid_by_type_key(o.handle.type_key); comp_tid != nil {
			for root, i in tween_roots_of(o.base_ptr, comp_tid) {
				if root == a {
					root_idx = i
					break
				}
			}
		}
	}
	if root_idx < 0 {
		im.TextUnformatted(label)
		return
	}

	if im.TreeNode(fmt.ctprintf("%s##tw_%v", label, ptr)) {
		// The node editors record their own undo (one splice per released
		// edit) — the ambient owner steps aside so the inspector's field
		// sessions don't double-record the component.
		undo.pop_owner()
		path: [64]i32
		_draw_node_inline(o.handle, root_idx, path[:], 0, a.value)
		undo.push_component_owner(o.handle)
		im.TreePop()
	}
}

// One node's fields plus its children as sub-trees — the same editor the
// graph panel uses, addressed by (root ordinal, child path).
@(private = "file")
_draw_node_inline :: proc(owner: engine.Handle, root_idx: int, path: []i32, depth: int, v: json.Value) {
	tid, tok := tween.authored_typeid(v)
	if !tok {
		im.TextDisabled("Unknown tween type (package not installed?).")
		return
	}
	if depth >= 60 do return
	_node_editor(owner, root_idx, path[:depth], v, tid)

	if children, kok := tween.authored_children(v); kok {
		for child, i in children {
			clabel := "?"
			if ctid, cok := tween.authored_typeid(child); cok do clabel = _type_label(ctid)
			if im.TreeNode(fmt.ctprintf("%d: %s##twc_%d_%d", i, clabel, depth, i)) {
				path[depth] = i32(i)
				_draw_node_inline(owner, root_idx, path, depth + 1, child)
				im.TreePop()
			}
		}
	}
}

// Opens the window on the clicked tree. The owning component comes from the
// inspector's ambient owner — the button lives inside a component's draw.
@(private = "file")
_open_graph_for :: proc(a: ^tween.Authored) {
	_preview_stop()
	o, o_ok := undo.current_owner()
	if !o_ok || o.kind != .Pooled || o.base_ptr == nil do return
	tid := engine.get_typeid_by_type_key(o.handle.type_key)
	if tid == nil do return

	roots := tween_roots_of(o.base_ptr, tid)
	for root, i in roots {
		if root != a do continue
		_state.target = o.handle
		_state.root_idx = i
		_state.has_target = true
		_state.sel_depth = 0
		_state.sel_active = true
		_state.framed = false
		wnd.open("tween_graph")
		return
	}
}

// Every Authored field in the value graph rooted at `base`, in walk order —
// nested structs, fixed and dynamic arrays and slices included.
// Temp-allocated. A root's ordinal is stable for any edit that keeps the
// component's shape (walk order is field order and array order).
tween_roots_of :: proc(base: rawptr, tid: typeid) -> []^tween.Authored {
	roots := make([dynamic]^tween.Authored, context.temp_allocator)
	_collect_tween_roots(base, type_info_of(tid), &roots, 0)
	return roots[:]
}

@(private = "file")
_collect_tween_roots :: proc(ptr: rawptr, ti: ^runtime.Type_Info, roots: ^[dynamic]^tween.Authored, depth: int) {
	if ptr == nil || ti == nil || depth > 16 do return

	if ti.id == typeid_of(tween.Authored) {
		a := cast(^tween.Authored)ptr
		if a.value != nil do append(roots, a)
		return
	}

	bti := runtime.type_info_base(ti)
	#partial switch v in bti.variant {
	case runtime.Type_Info_Struct:
		for i in 0 ..< int(v.field_count) {
			_collect_tween_roots(rawptr(uintptr(ptr) + v.offsets[i]), v.types[i], roots, depth + 1)
		}
	case runtime.Type_Info_Array:
		for i in 0 ..< v.count {
			_collect_tween_roots(rawptr(uintptr(ptr) + uintptr(i * v.elem_size)), v.elem, roots, depth + 1)
		}
	case runtime.Type_Info_Dynamic_Array:
		da := (^runtime.Raw_Dynamic_Array)(ptr)
		if da.data == nil do return
		for i in 0 ..< da.len {
			_collect_tween_roots(rawptr(uintptr(da.data) + uintptr(i * v.elem_size)), v.elem, roots, depth + 1)
		}
	case runtime.Type_Info_Slice:
		s := (^runtime.Raw_Slice)(ptr)
		if s.data == nil do return
		for i in 0 ..< s.len {
			_collect_tween_roots(rawptr(uintptr(s.data) + uintptr(i * v.elem_size)), v.elem, roots, depth + 1)
		}
	case runtime.Type_Info_Union:
		if vtid := reflect.union_variant_typeid(any{ptr, ti.id}); vtid != nil {
			_collect_tween_roots(ptr, type_info_of(vtid), roots, depth + 1)
		}
	}
	// Pointers and maps are not walked: nothing stores tweens that way.
}
