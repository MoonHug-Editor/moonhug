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
// The window shows a tree of the object it follows: the selected object, or
// the one its padlock holds (lock="instance", each copy its own lock, as in
// the Inspector). Every tree of every component on the object is listed in
// the toolbar by its field path. A copy keeps the tree it was last set to as
// (component type, which component of that type, field path), saved with the
// copy, and shows it whenever its object has one, else the object's first.
// Within a frame a tree is (component handle, root ordinal): the handle
// survives undo, and the Nth Authored field in the component's reflection
// walk names the same tree across any edit that keeps the component's shape.
// Selection is the node's PATH from the root (child ordinals) — undo
// replaces the whole blob, so nothing stores pointers into it.
//
// Each copy has its own tree, node selection and canvas (_TG_Window). The
// preview is one for the editor, as the Animation window's transport is.

import "base:runtime"
import "core:encoding/json"
import "core:encoding/uuid"
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
import "moonhug:editor/session"
import "moonhug:editor/undo"
import wnd "moonhug:editor/window"
import "moonhug:editor/widgets"
import "moonhug:editor/preview"

// A tree on an object, named so that a restart finds it again: the
// component's type, which of the object's components of that type, and the
// field path in it.
@(private = "file")
_Tree_Ref :: struct {
	component: string, // the component type's guid
	nth:       int,    // among the object's components of that type, 0 first
	path:      string, // the field path in the component: `idle`, `animations[1]`
}

// One Tween Graph copy's state. `tree` is the tree last picked in the
// toolbar or with a Graph button, saved with the copy (wnd.state). It shows
// whenever the copy's object has it, and the object's first tree shows when
// not. The strings are on the default allocator.
@(private = "file")
_TG_State :: struct {
	tree: _Tree_Ref,
	run:  ^_TG_Window `json:"-"`,
}

// A copy's state for the session.
@(private = "file")
_TG_Window :: struct {
	cv: nc.Node_Canvas,

	// The tree shown this frame, resolved from the object every frame.
	target:     engine.Handle, // the component holding it
	root_idx:   int,           // its ordinal among the component's trees (tween_roots_of)
	has_target: bool,
	shown:      u64,           // the tree shown last frame, component and path: a change resets the view

	sel_path:   [64]i32,
	sel_depth:  int,
	sel_active: bool,

	framed: bool, // framed once its content has been drawn
	drawn:  bool, // the canvas has drawn once, so it knows its size

	pick_seen: int, // the last inspector pick (_state.pick_gen) this copy has seen
}

// The copy being drawn.
@(private = "file")
_tg: ^_TG_Window

@(private = "file")
_state: struct {
	// The tree playing in edit mode. A paused run, kept when done: the game's ticks
	// leave it alone, and the preview hooks below drive it.
	preview:         tween.Handle,
	preview_target:  engine.Handle, // the tree it plays: component and root ordinal
	preview_root:    int,
	preview_pending: f32, // seconds to advance at the next apply
	preview_done:    f32, // seconds the finished preview has shown its end pose

	// The tree an inspector row's graph button picked. Every copy that shows
	// the tree's object switches to it, once per pick.
	pick_target: engine.Handle,
	pick_root:   int,
	pick_gen:    int,
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
_preview_start :: proc(owner: engine.Transform_Handle, root: ^tween.Authored, target: engine.Handle, root_idx: int) {
	_preview_stop()
	_state.preview = tween.run(root, tween.TweenContext{subject = owner})
	_state.preview_target = target
	_state.preview_root = root_idx
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

// Whether the preview plays the tree copy `tg` shows.
@(private = "file")
_preview_is_of :: proc(tg: ^_TG_Window) -> bool {
	return tween.is_alive(_state.preview) && tg.has_target && _state.preview_target == tg.target && _state.preview_root == tg.root_idx
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
	info:      []string, // own subject, delay, await, skipped: one row each
	skip:      bool,
	parent:    int, // index into the walk, -1 for a root
	child_ord: int, // ordinal in the parent's children array, -1 for a root
}

// A copy closed. The preview of its tree would keep playing with no Stop
// button on screen, so it ends. Its saved tree comes back with it.
tween_graph_window_closed :: proc(win: ^wnd.Window) {
	st := (^_TG_State)(win.data)
	if st == nil do return
	if st.run != nil {
		if _preview_is_of(st.run) do _preview_stop()
		free(st.run, runtime.default_allocator())
	}
	_tree_ref_free(&st.tree)
	free(st, runtime.default_allocator())
	win.data = nil
}

@(private = "file")
_tree_ref_free :: proc(r: ^_Tree_Ref) {
	delete(r.component, runtime.default_allocator())
	delete(r.path, runtime.default_allocator())
	r^ = {}
}

// A tree on the followed object: the component holding it, its ordinal
// among the component's trees, how a saved reference names it, and the
// toolbar's label for it.
@(private = "file")
_Object_Tree :: struct {
	target:    engine.Handle,
	root_idx:  int,
	component: string, // the component type's guid
	nth:       int,    // among the object's components of that type
	path:      string, // the field path in the component
	label:     cstring,
}

// Every tree on object `obj`, component by component in the object's order,
// each in its component's field order. A label is the component, numbered
// when the object has two of its type, the field path and the root's type:
// `TweenPlayer.animations[1]: Sequence`. Temp-allocated.
@(private = "file")
_object_trees :: proc(w: ^engine.World, obj: engine.Transform_Handle) -> []_Object_Tree {
	out := make([dynamic]_Object_Tree, context.temp_allocator)
	t := engine.pool_get(&w.transforms, engine.Handle(obj))
	if t == nil do return out[:]
	of_type := make(map[engine.TypeKey]int, context.temp_allocator)
	for c in t.components do of_type[c.handle.type_key] += 1
	seen := make(map[engine.TypeKey]int, context.temp_allocator)
	for c in t.components {
		nth := seen[c.handle.type_key]
		seen[c.handle.type_key] = nth + 1
		tid := engine.get_typeid_by_type_key(c.handle.type_key)
		if tid == nil || !type_holds_tweens(type_info_of(tid)) do continue
		base := engine.world_pool_get(w, c.handle)
		if base == nil do continue
		comp_name := fmt.tprintf("%v", tid)
		if dot := strings.last_index_byte(comp_name, '.'); dot >= 0 do comp_name = comp_name[dot + 1:]
		if of_type[c.handle.type_key] > 1 do comp_name = fmt.tprintf("%s #%d", comp_name, nth + 1)
		guid := uuid.to_string(engine.get_guid_by_type_key(c.handle.type_key), context.temp_allocator)
		roots, paths := tween_roots_with_paths(base, tid)
		for root, i in roots {
			root_type := "?"
			if rtid, ok := tween.authored_typeid(root.value); ok do root_type = _type_label(rtid)
			append(&out, _Object_Tree{
				target = c.handle, root_idx = i, component = guid, nth = nth, path = paths[i],
				label = fmt.ctprintf("%s.%s: %s", comp_name, paths[i], root_type),
			})
		}
	}
	return out[:]
}

// The tree of `trees` that saved reference `r` names, -1 for none.
@(private = "file")
_tree_find :: proc(trees: []_Object_Tree, r: _Tree_Ref) -> int {
	for t, i in trees do if t.component == r.component && t.nth == r.nth && t.path == r.path do return i
	return -1
}

// Tree `t` becomes the copy's saved pick.
@(private = "file")
_tree_pick :: proc(st: ^_TG_State, t: _Object_Tree) {
	_tree_ref_free(&st.tree)
	st.tree = {
		component = strings.clone(t.component, runtime.default_allocator()),
		nth       = t.nth,
		path      = strings.clone(t.path, runtime.default_allocator()),
	}
}

// Which tree a copy shows, as a number: its component and its path.
@(private = "file")
_tree_id :: proc(t: _Object_Tree) -> u64 {
	mix :: proc(h, x: u64) -> u64 { return (h ~ x) * 0x100000001b3 }
	h: u64 = 0xcbf29ce484222325
	h = mix(h, u64(t.target.index))
	h = mix(h, u64(t.target.generation))
	h = mix(h, u64(t.target.type_key))
	for i in 0 ..< len(t.path) do h = mix(h, u64(t.path[i]))
	return h
}

// The copy being drawn shows `t`. Another tree than last frame starts with
// its root selected and frames it.
@(private = "file")
_tree_show :: proc(t: _Object_Tree) {
	id := _tree_id(t)
	if !_tg.has_target || _tg.shown != id {
		_tg.sel_depth = 0
		_tg.sel_active = true
		_tg.framed = false
	}
	_tg.target = t.target
	_tg.root_idx = t.root_idx
	_tg.has_target = true
	_tg.shown = id
}

// The copy's toolbar picked tree `i`, or a Graph button did.
@(private = "file")
_choose_tree :: proc(st: ^_TG_State, trees: []_Object_Tree, i: int) {
	_tree_pick(st, trees[i])
	_tree_show(trees[i])
}

@(editor_window={id="tween_graph", title="Tween Graph", icon="SHOW_CHART", width=900, height=520, closed=tween_graph_window_closed, lock="instance"})
tween_graph_window_draw :: proc(win: ^wnd.Window) {
	st := wnd.state(win, _TG_State{}, saved = true)
	if st.run == nil do st.run = new(_TG_Window, runtime.default_allocator())
	_tg = st.run

	w := engine.ctx_world()
	if w == nil {
		im.TextDisabled("No world.")
		return
	}
	if session.window_lock_missing_note(win.key) do return

	// The object this copy follows: the one its padlock holds, else the
	// selection. Its trees are listed fresh every frame: the handles survive
	// undo, the blob values behind them do not.
	obj := engine.Transform_Handle(session.window_object(win.key))
	trees := _object_trees(w, obj)
	// An inspector row's graph button picked a tree: shown here when it is on
	// this copy's object.
	if _tg.pick_seen != _state.pick_gen {
		_tg.pick_seen = _state.pick_gen
		for t in trees do if t.target == _state.pick_target && t.root_idx == _state.pick_root do _tree_pick(st, t)
	}
	if len(trees) == 0 {
		_tg.has_target = false
		if t := engine.pool_get(&w.transforms, engine.Handle(obj)); t != nil {
			im.TextDisabledUnformatted(fmt.ctprintf("%s has no tween trees.", t.name))
		} else {
			im.TextDisabled("Select an object with a tween tree.")
		}
		return
	}
	// The saved pick when the object has it, else the object's first tree,
	// which leaves the pick as it is for the next object that has it.
	cur := max(_tree_find(trees, st.tree), 0)
	_tree_show(trees[cur])

	base := engine.world_pool_get(w, _tg.target)
	roots := tween_roots_of(base, engine.get_typeid_by_type_key(_tg.target.type_key))

	_draw_toolbar(st, base, roots, trees, cur)
	im.Separator()

	walked := make([dynamic]_Walked, context.temp_allocator)
	// The scene the nodes' own subjects are looked up in: the owner's.
	scene: ^engine.Scene
	if t := engine.pool_get(&w.transforms, engine.Handle((cast(^engine.CompData)base).owner)); t != nil do scene = t.scene
	_walk(roots[_tg.root_idx].value, -1, -1, &walked, scene, 0)

	parents := make([]int, len(walked), context.temp_allocator)
	for wk, i in walked do parents[i] = wk.parent

	sel_idx := -1
	if _tg.sel_active {
		sel_idx = nc.tree_find_path(parents, 0, _tg.sel_path[:_tg.sel_depth])
	}
	if sel_idx < 0 do _tg.sel_active = false

	// A row per piece of information, at least one: the links meet the first
	// row's ports.
	sizes := make([]im.Vec2, len(walked), context.temp_allocator)
	for &sz, i in sizes do sz = nc.canvas_node_size(max(len(walked[i].info), 1))
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

	cv := &_tg.cv
	cv.minimap = &prefs.minimap
	// The canvas knows its size after it drew once, so framing waits a frame.
	if !_tg.framed && _tg.drawn && len(walked) > 0 {
		lo, hi := positions[0], positions[0] + sizes[0]
		for p, i in positions {
			lo = {min(lo.x, p.x), min(lo.y, p.y)}
			hi = {max(hi.x, p.x + sizes[i].x), max(hi.y, p.y + sizes[i].y)}
		}
		nc.canvas_frame(cv, lo, hi)
		_tg.framed = true
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
				has_children := false
				for p in parents do if p == i do has_children = true
				rows := make([]nc.Canvas_Row, max(len(wk.info), 1), context.temp_allocator)
				for line, r in wk.info do rows[r].label = strings.clone_to_cstring(line, context.temp_allocator)
				rows[0].port = wk.parent >= 0
				nc.canvas_node(cv, i, &positions[i], strings.clone_to_cstring(wk.title, context.temp_allocator), _color_for(wk.tid), rows, has_children, movable = false, dimmed = wk.skip)
			}
		}
		nc.canvas_end(cv)
		_tg.drawn = true
	}
	im.EndChild()

	// The canvas selects on a press and clears on a click on empty canvas.
	// Node identity on the canvas is the walk index, stable within the frame,
	// and the kept selection is the path.
	if cv.sel != sel_idx {
		sel_idx = cv.sel
		if sel_idx >= 0 && sel_idx < len(walked) {
			_tg.sel_depth = nc.tree_path_of(parents, sel_idx, _tg.sel_path[:])
			_tg.sel_active = true
		} else {
			sel_idx = -1
			_tg.sel_active = false
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
			root := roots[_tg.root_idx]
			v_ptr := _walked_ptr(walked[:], sel_idx, root)
			parent_ptr: ^json.Value
			if p := walked[sel_idx].parent; p >= 0 do parent_ptr = _walked_ptr(walked[:], p, root)
			_draw_structural_ops(
				_tg.target,
				v_ptr,
				walked[sel_idx].tid,
				parent_ptr,
				walked[sel_idx].child_ord,
			)
			im.Separator()
			_draw_selected_panel(_tg.target, walked[sel_idx].value, walked[sel_idx].tid)
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
			_tg.sel_active = false
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
_draw_toolbar :: proc(st: ^_TG_State, base: rawptr, roots: []^tween.Authored, trees: []_Object_Tree, cur: int) {
	owner_name := "?"
	w := engine.ctx_world()
	comp := cast(^engine.CompData)base
	if t := engine.pool_get(&w.transforms, engine.Handle(comp.owner)); t != nil {
		owner_name = t.name
	}
	im.TextUnformatted(strings.clone_to_cstring(owner_name, context.temp_allocator))

	// Every tree on the object, across its components.
	im.SameLine()
	if len(trees) > 1 {
		widest: f32
		for t in trees do widest = max(widest, im.CalcTextSize(t.label).x)
		im.SetNextItemWidth(min(widest + im.GetFrameHeight() + im.GetStyle().FramePadding.x * 2, 420))
		if im.BeginCombo("##root", trees[cur].label) {
			for t, i in trees {
				if im.Selectable(fmt.ctprintf("%s##tree%d", t.label, i), i == cur) && i != cur {
					if _preview_is_of(_tg) do _preview_stop()
					_choose_tree(st, trees, i)
				}
			}
			im.EndCombo()
		}
	} else {
		im.TextUnformatted(trees[cur].label)
	}

	// Preview: the tree plays on its object in edit mode, shows its end pose
	// for a moment and puts everything back. One preview plays at a time, so
	// starting one here ends another copy's.
	im.SameLine()
	if engine.game_running() {
		im.BeginDisabled()
		im.Button("Preview")
		im.EndDisabled()
	} else if _preview_is_of(_tg) {
		if im.Button("Stop") do _preview_stop()
	} else if im.Button("Preview") {
		_preview_start(comp.owner, roots[_tg.root_idx], _tg.target, _tg.root_idx)
	}
	widgets.tooltip("Plays the tree on its object in edit mode, then puts every value back. In Play, the game starts the tree.", im.HoveredFlags_ForTooltip | im.HoveredFlags_AllowWhenDisabled)

	im.SameLine()
	if im.Button("Frame All") do _tg.framed = false

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

// Flattens the authored JSON tree into nodes + links.
@(private = "file")
_walk :: proc(
	v: json.Value,
	parent: int,
	child_ord: int,
	walked: ^[dynamic]_Walked,
	scene: ^engine.Scene,
	depth: int,
) {
	if depth > 64 do return
	tid, tok := tween.authored_typeid(v)
	idx := len(walked)

	title := "?"
	if tok do title = _type_label(tid)
	skip, info := _base_summary(v, scene)

	append(walked, _Walked{value = v, tid = tid, title = title, info = info, skip = skip, parent = parent, child_ord = child_ord})

	if children, kok := tween.authored_children(v); kok {
		for child, i in children {
			_walk(child, idx, i, walked, scene, depth + 1)
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
_base_summary :: proc(v: json.Value, scene: ^engine.Scene) -> (skip: bool, info: []string) {
	obj, is_obj := v.(json.Object)
	if !is_obj do return false, nil
	base, has_base := obj["base"].(json.Object)
	if !has_base do return false, nil

	parts := make([dynamic]string, context.temp_allocator)
	// A node with its own subject names it: it animates that object, not the
	// one the tree runs on.
	if subj, ok := base["subject"].(json.Object); ok {
		if pp, pok := subj["pptr"].(json.Object); pok {
			if lid, lok := pp["local_id"].(json.Integer); lok && lid != 0 {
				name := "Missing"
				if tH, found := engine.scene_ref_resolve_transform(scene, engine.Ref{pptr = {local_id = engine.Local_ID(lid)}}); found {
					if t := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(tH)); t != nil do name = t.name
				}
				append(&parts, fmt.tprintf("on %s", name))
			}
		}
	}
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
	return skip, parts[:]
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

	_node_editor(owner_handle, _tg.root_idx, _tg.sel_path[:_tg.sel_depth], v, sel_tid)
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

// Shows the clicked tree. The owning component comes from the inspector's
// ambient owner — the button lives inside a component's draw. Every copy
// showing the component's object switches to the tree (_state.pick_*), and
// the first of them comes to the front. With none, the window opens, and
// shows the tree when it follows the object.
@(private = "file")
_open_graph_for :: proc(a: ^tween.Authored) {
	o, o_ok := undo.current_owner()
	if !o_ok || o.kind != .Pooled || o.base_ptr == nil do return
	tid := engine.get_typeid_by_type_key(o.handle.type_key)
	if tid == nil do return

	roots := tween_roots_of(o.base_ptr, tid)
	for root, i in roots {
		if root != a do continue
		_state.pick_target = o.handle
		_state.pick_root = i
		_state.pick_gen += 1
		owner := engine.Handle((cast(^engine.CompData)o.base_ptr).owner)
		for win in wnd.instances("tween_graph") {
			if engine.Handle(session.window_object(win.key)) == owner {
				wnd.focus(win)
				return
			}
		}
		wnd.open("tween_graph")
		return
	}
}

// Every Authored field in the value graph rooted at `base`, in walk order —
// nested structs, fixed and dynamic arrays, slices and unions included.
// Temp-allocated. A root's ordinal is stable for any edit that keeps the
// component's shape (walk order is field order and array order).
tween_roots_of :: proc(base: rawptr, tid: typeid) -> []^tween.Authored {
	roots := make([dynamic]^tween.Authored, context.temp_allocator)
	_collect_tween_roots(base, type_info_of(tid), &roots, nil, "", 0)
	return roots[:]
}

// tween_roots_of with each root's field path in the value: `idle`,
// `animations[1]`, `settings.on_open`. An array element's path is its index
// in the array, so an empty slot before it does not change it.
// Temp-allocated.
tween_roots_with_paths :: proc(base: rawptr, tid: typeid) -> (roots: []^tween.Authored, paths: []string) {
	r := make([dynamic]^tween.Authored, context.temp_allocator)
	p := make([dynamic]string, context.temp_allocator)
	_collect_tween_roots(base, type_info_of(tid), &r, &p, "", 0)
	return r[:], p[:]
}

@(private = "file")
_collect_tween_roots :: proc(ptr: rawptr, ti: ^runtime.Type_Info, roots: ^[dynamic]^tween.Authored, paths: ^[dynamic]string, path: string, depth: int) {
	if ptr == nil || ti == nil || depth > 16 do return

	if ti.id == typeid_of(tween.Authored) {
		a := cast(^tween.Authored)ptr
		if a.value != nil {
			append(roots, a)
			if paths != nil do append(paths, path)
		}
		return
	}
	if !type_holds_tweens(ti) do return

	bti := runtime.type_info_base(ti)
	#partial switch v in bti.variant {
	case runtime.Type_Info_Struct:
		for i in 0 ..< int(v.field_count) {
			sub := ""
			if paths != nil do sub = path == "" ? v.names[i] : fmt.tprintf("%s.%s", path, v.names[i])
			_collect_tween_roots(rawptr(uintptr(ptr) + v.offsets[i]), v.types[i], roots, paths, sub, depth + 1)
		}
	case runtime.Type_Info_Array:
		for i in 0 ..< v.count {
			sub := paths != nil ? fmt.tprintf("%s[%d]", path, i) : ""
			_collect_tween_roots(rawptr(uintptr(ptr) + uintptr(i * v.elem_size)), v.elem, roots, paths, sub, depth + 1)
		}
	case runtime.Type_Info_Dynamic_Array:
		da := (^runtime.Raw_Dynamic_Array)(ptr)
		if da.data == nil do return
		for i in 0 ..< da.len {
			sub := paths != nil ? fmt.tprintf("%s[%d]", path, i) : ""
			_collect_tween_roots(rawptr(uintptr(da.data) + uintptr(i * v.elem_size)), v.elem, roots, paths, sub, depth + 1)
		}
	case runtime.Type_Info_Slice:
		s := (^runtime.Raw_Slice)(ptr)
		if s.data == nil do return
		for i in 0 ..< s.len {
			sub := paths != nil ? fmt.tprintf("%s[%d]", path, i) : ""
			_collect_tween_roots(rawptr(uintptr(s.data) + uintptr(i * v.elem_size)), v.elem, roots, paths, sub, depth + 1)
		}
	case runtime.Type_Info_Union:
		if vtid := reflect.union_variant_typeid(any{ptr, ti.id}); vtid != nil {
			_collect_tween_roots(ptr, type_info_of(vtid), roots, paths, path, depth + 1)
		}
	}
	// Pointers and maps are not walked: nothing stores tweens that way.
}

// Whether a value of type `ti` can hold an Authored where the walk above
// looks: itself, a field, an element of a fixed or dynamic array or a slice,
// a union variant. Worked out once per type and kept, so the walk skips a
// component without tweens and an array of plain data, such as a particle
// system's particles, with one lookup.
type_holds_tweens :: proc(ti: ^runtime.Type_Info) -> bool {
	if ti == nil do return false
	if h, ok := _holds[ti.id]; ok do return h
	holds, _ := _holds_tweens(ti)
	// Every type it reached that was still being worked out was on the way
	// from this one, so this answer is whole.
	_holds[ti.id] = holds
	return holds
}

// By type. Types live as long as the process, and so does this.
@(private = "file")
_holds: map[typeid]bool

// The types being worked out, for a type that holds itself through an array
// or a slice.
@(private = "file")
_holds_pending: map[typeid]bool

// `pending`: the answer is false only so far, because the type reached a
// type still being worked out, and it is not kept.
@(private = "file")
_holds_tweens :: proc(ti: ^runtime.Type_Info) -> (holds, pending: bool) {
	if ti == nil do return false, false
	if ti.id == typeid_of(tween.Authored) do return true, false
	if h, ok := _holds[ti.id]; ok do return h, false
	if ti.id in _holds_pending do return false, true
	if _holds.allocator.procedure == nil {
		_holds.allocator = runtime.default_allocator()
		_holds_pending.allocator = runtime.default_allocator()
	}
	_holds_pending[ti.id] = true
	defer delete_key(&_holds_pending, ti.id)

	elem := proc(ti: ^runtime.Type_Info, holds, pending: ^bool) {
		h, p := _holds_tweens(ti)
		holds^ ||= h
		pending^ ||= p
	}
	#partial switch v in runtime.type_info_base(ti).variant {
	case runtime.Type_Info_Struct:
		for i in 0 ..< int(v.field_count) do elem(v.types[i], &holds, &pending)
	case runtime.Type_Info_Array:
		elem(v.elem, &holds, &pending)
	case runtime.Type_Info_Dynamic_Array:
		elem(v.elem, &holds, &pending)
	case runtime.Type_Info_Slice:
		elem(v.elem, &holds, &pending)
	case runtime.Type_Info_Union:
		for variant in v.variants do elem(variant, &holds, &pending)
	}
	if holds do pending = false
	if !pending do _holds[ti.id] = holds
	return
}
