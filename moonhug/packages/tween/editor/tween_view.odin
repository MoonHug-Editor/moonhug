package tween_editor

// Tween graph view: a component's authored tween trees as a node canvas,
// with the selected node's fields in a panel beside it.
//
// An authored tween is a guid-tagged json.Value (tween.Authored) — children
// nest inside the parent's "children" array. The view walks that JSON, so it
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
import engine "moonhug:engine"
import tween "moonhug:packages/tween"
import ng "moonhug:packages/node_graph"
import "moonhug:editor/inspector"
import "moonhug:editor/undo"
import wnd "moonhug:editor/window"

@(private = "file")
_state: struct {
	view: ng.View,

	target:     engine.Handle,
	root_idx:   int,
	has_target: bool,

	sel_path:   [64]i32,
	sel_depth:  int,
	sel_active: bool,

	framed: bool, // frame_all once, on first draw with content
}

// One node of the walk: the authored value (shares the blob's storage, so
// mutations through it edit the component) and its resolved type.
@(private = "file")
_Walked :: struct {
	value:     json.Value,
	tid:       typeid,
	parent:    int, // index into the walk, -1 for a root
	child_ord: int, // ordinal in the parent's children array, -1 for a root
}

@(editor_window={id="tween_graph", title="Tween Graph", width=900, height=520})
tween_graph_window_draw :: proc() {
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
		_state.has_target = false
		im.TextDisabled("No tween tree open.")
		im.TextDisabled("Click a tween row's graph button in the inspector.")
		return
	}

	_draw_toolbar(base, roots)
	im.Separator()

	walked := make([dynamic]_Walked, context.temp_allocator)
	nodes := make([dynamic]ng.Node, context.temp_allocator)
	links := make([dynamic]ng.Link, context.temp_allocator)
	_walk(roots[_state.root_idx].value, -1, -1, &walked, &nodes, &links, 0)

	parents := make([]int, len(walked), context.temp_allocator)
	for wk, i in walked do parents[i] = wk.parent

	sel_idx := -1
	if _state.sel_active {
		sel_idx = ng.tree_find_path(parents, 0, _state.sel_path[:_state.sel_depth])
	}
	if sel_idx >= 0 {
		nodes[sel_idx].selected = true
	} else {
		_state.sel_active = false
	}

	ng.layout_tree(nodes[:], links[:])

	PANEL_W :: 280
	avail := im.GetContentRegionAvail()
	canvas_w := max(120, avail.x - PANEL_W - 8)

	if !_state.framed && len(nodes) > 0 {
		ng.frame_all(&_state.view, nodes[:], {canvas_w, avail.y})
		_state.framed = true
	}

	if im.BeginChild("##tween_canvas", im.Vec2{canvas_w, avail.y}, {.Borders}) {
		result := ng.draw(&_state.view, nodes[:], links[:])
		if result.clicked_valid {
			// Node identity on the canvas is the walk index — stable within
			// the frame, and the persisted selection is the path.
			i := int(uintptr(result.clicked))
			if i >= 0 && i < len(walked) {
				_state.sel_depth = ng.tree_path_of(parents, i, _state.sel_path[:])
				_state.sel_active = true
				sel_idx = i
			}
		} else if result.clicked_empty {
			_state.sel_active = false
			sel_idx = -1
		}
	}
	im.EndChild()

	im.SameLine()

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
	im.SetItemTooltip("Change node type")
	if new_tid, picked := _node_type_popup("##tw_retype"); picked && new_tid != tid {
		// The session is claimed by the field editors too — flush it so a
		// pending field edit lands before the structural step.
		_edit_finalize()
		e := undo.edit_begin(owner, comp_tid)
		tween.authored_retype(v, new_tid)
		undo.edit_end(&e)
	}

	if tid != nil && tween.node_type_has_children(tid) {
		im.SameLine()
		if im.Button("Add Child") do im.OpenPopup("##tw_add_child")
		if new_tid, picked := _node_type_popup("##tw_add_child"); picked {
			if child, cok := tween.authored_make(new_tid); cok {
				_edit_finalize()
				e := undo.edit_begin(owner, comp_tid)
				if !tween.authored_add_child(v, child) do tween.authored_destroy(&child)
				undo.edit_end(&e)
			}
		}
	}

	if child_ord >= 0 && parent_v != nil {
		im.SameLine()
		if im.Button("Delete Node") {
			_edit_finalize()
			e := undo.edit_begin(owner, comp_tid)
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

	im.SameLine()
	if im.Button("Frame All") do _state.framed = false
	im.SameLine()
	im.TextDisabled("middle-drag pans, wheel zooms")
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
	nodes: ^[dynamic]ng.Node,
	links: ^[dynamic]ng.Link,
	depth: int,
) {
	if depth > 64 do return
	tid, tok := tween.authored_typeid(v)
	idx := len(walked)

	title := "?"
	if tok do title = _type_label(tid)
	skip, subtitle := _base_summary(v)

	append(walked, _Walked{value = v, tid = tid, parent = parent, child_ord = child_ord})
	append(nodes, ng.Node{
		user_handle  = ng.User_Handle(uintptr(idx)),
		title        = title,
		subtitle     = subtitle,
		header_color = _color_for(tid),
		dimmed       = skip,
	})
	if parent >= 0 do append(links, ng.Link{from = parent, to = idx})

	if kids, kok := tween.authored_children(v); kok {
		for child, i in kids {
			_walk(child, idx, i, walked, nodes, links, depth + 1)
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
	ptr_tid, ok := engine.get_pointer_typeid_by_typeid(sel_tid)
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
		kids, kok := obj["children"].(json.Array)
		if !kok || int(_edit.path[i]) >= len(kids) do return
		v = &kids[_edit.path[i]]
	}
	if tid, tok := tween.authored_typeid(v^); !tok || tid != _edit.tid do return

	e := undo.edit_begin(_edit.owner, comp_tid)
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
		instance = inst
		pb, perr := json.marshal(any{instance, tid}, {spec = .JSON}, context.temp_allocator)
		if perr != nil do return
		pre = pb
	}

	// Two editors can show the same node (inline row + graph panel) — the id
	// scope keeps their widgets distinct.
	im.PushID(fmt.ctprintf("tw_node_%v", key))
	target := instance
	inspector.draw_inspector(any{data = &target, id = ptr_tid})
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

@(menu_item={path="Window/Animation/Tween Graph", shortcut=""})
tween_graph_window_open :: proc() {
	wnd.open("tween_graph")
}

// --- Opening the graph from the inspector -----------------------------------

// Registers the Authored drawer at editor startup: every authored-tween row
// in the inspector shows a summary and a Graph button (the graph panel is
// the field editor). order=1 runs after editor_init (order=0), which creates
// the drawer map this writes into.
@(phase={key=engine.Phase.EditorInit, order=1, mode=Editor})
tween_view_install :: proc() {
	inspector.mapPropertyDrawer[typeid_of(tween.Authored)] = _draw_authored_row
}

// account_tree / swap_horiz \u2014 duplicated literals, the editor root owns the
// canonical list and this package cannot import it.
@(private = "file")
_ICON_GRAPH :: "\ue97a"

@(private = "file")
_draw_authored_row :: proc(ptr: rawptr, tid: typeid, label: cstring) {
	a := cast(^tween.Authored)ptr
	if im.SmallButton(fmt.ctprintf("%s##tg_%v", _ICON_GRAPH, ptr)) {
		_open_graph_for(a)
	}
	im.SetItemTooltip("Open in Tween Graph")
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
					e := undo.edit_begin(o.handle, comp_tid)
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
	im.SetItemTooltip("Change node type")
	if new_tid, picked := _node_type_popup(root_popup); picked && new_tid != ntid {
		o, o_ok := undo.current_owner()
		if o_ok && o.kind == .Pooled {
			comp_tid := engine.get_typeid_by_type_key(o.handle.type_key)
			e := undo.edit_begin(o.handle, comp_tid)
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

	if kids, kok := tween.authored_children(v); kok {
		for child, i in kids {
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
