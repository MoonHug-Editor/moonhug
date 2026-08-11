package tween_editor

// Tween graph view: a component's tween trees as a node canvas, with the
// selected node's fields in a panel beside it.
//
// A tween tree is a BEHAVIOUR TREE, not a timeline -- Parallel and Sequence run
// their children until each reports Done, and only leaf tweens carry a
// duration. There is no fixed span to lay clips against, which is why this is a
// graph rather than a track view.
//
// The view is generic over components: it names no component type. Roots are
// found by REFLECTION -- every TweenUnion in the owning component's value
// graph, at any depth (nested structs, arrays, union payloads). The window's
// target is (component handle, root ordinal): the handle survives undo, and
// the Nth root in walk order names the same tree across any edit that keeps
// the component's shape, because walk order is field order and array order.
// Nothing stores a pointer into the tree -- undo reallocates every node, so
// pointers are resolved fresh from each frame's walk.
//
// The canvas (packages/node_graph) knows nothing about tweens. This file owns
// the whole mapping: walk the union tree into flat nodes + links, hand them
// over, and turn the clicked User_Handle back into a tween pointer.
//
import "base:runtime"
import "core:fmt"
import "core:reflect"
import "core:strings"
import im "moonhug:external/odin-imgui"
import engine "moonhug:engine"
import ng "moonhug:packages/node_graph"
import "moonhug:editor/inspector"
import "moonhug:editor/undo"
import wnd "moonhug:editor/window"

@(private = "file")
_state: struct {
	view: ng.View,

	// The tree being inspected, set by the Graph button on a tween row: the
	// owning component (by handle) and which of its tween roots, by ordinal
	// in the reflection walk. The window shows this ONE tree.
	target:     engine.Handle,
	root_idx:   int,
	has_target: bool,

	// The selected node, as its PATH from the tree root (child ordinals). A
	// pointer is not a stable identity here: undo restores the whole component
	// payload, which reallocates every node, so a pointer-keyed selection died
	// on every undo -- deselecting the node the user had just edited and hiding
	// its panel. The path survives any edit that keeps the tree's shape, and
	// resolves to nothing (clearing the selection) only when the shape changes.
	sel_path:   [64]i32,
	sel_depth:  int,
	sel_active: bool,

	framed: bool, // frame_all once, on first draw with content
}

// One node of the walk: where the tween lives and how deep it sits.
@(private = "file")
_Walked :: struct {
	ptr:    rawptr, // ^TweenUnion, as a raw pointer for User_Handle round-tripping
	tid:    typeid, // the ACTIVE variant's typeid, for the inspector
	parent: int,    // index into the walk, -1 for a root
}

@(editor_window={id="tween_graph", title="Tween Graph", width=900, height=520})
tween_graph_window_draw :: proc() {
	w := engine.ctx_world()
	if w == nil {
		im.TextDisabled("No world.")
		return
	}

	// The target is set by the Graph button on a tween row. Resolved fresh
	// every frame: the handle survives undo, the pointers behind it do not.
	roots: []^engine.TweenUnion
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
	_walk(roots[_state.root_idx], -1, &walked, &nodes, &links, 0)

	// Resolve the selection path against THIS frame's walk. The pointers below
	// (walked[sel_idx].ptr) are only ever this frame's, never stored.
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

	// Canvas on the left, inspector on the right. The panel is fixed-width so
	// the canvas takes whatever is left when the window resizes.
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
			for wk, i in walked {
				if ng.User_Handle(uintptr(wk.ptr)) != result.clicked do continue
				_state.sel_depth = ng.tree_path_of(parents, i, _state.sel_path[:])
				_state.sel_active = true
				sel_idx = i
				break
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
			_draw_selected_panel(_state.target, walked[sel_idx].ptr, walked[sel_idx].tid)
		} else {
			im.TextDisabled("Select a node.")
		}
	}
	im.EndChild()
}

@(private = "file")
_draw_toolbar :: proc(base: rawptr, roots: []^engine.TweenUnion) {
	// The owning object's name says WHOSE tree this is. Every component embeds
	// CompData at offset 0, so the owner is readable without knowing the type.
	owner_name := "?"
	w := engine.ctx_world()
	comp := cast(^engine.CompData)base
	if t := engine.pool_get(&w.transforms, engine.Handle(comp.owner)); t != nil {
		owner_name = t.name
	}
	im.TextUnformatted(strings.clone_to_cstring(owner_name, context.temp_allocator))

	// Which root, when the component carries more than one tree.
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
_root_label :: proc(roots: []^engine.TweenUnion, i: int) -> cstring {
	name := "?"
	if tid := reflect.union_variant_typeid(roots[i]^); tid != nil {
		name = _type_label(tid)
	}
	return strings.clone_to_cstring(fmt.tprintf("%d: %s", i, name), context.temp_allocator)
}

// Flattens the tween tree into nodes + links.
//
// `children` is reached by REFLECTION rather than by naming Parallel and
// Sequence: any composite tween declaring a `children: [dynamic]TweenUnion`
// field shows its subtree here without this file being edited. A new composite
// type is otherwise invisible in the graph, which is a silent wrong answer
// rather than a compile error.
@(private = "file")
_walk :: proc(
	tw: ^engine.TweenUnion,
	parent: int,
	walked: ^[dynamic]_Walked,
	nodes: ^[dynamic]ng.Node,
	links: ^[dynamic]ng.Link,
	depth: int,
) {
	if tw == nil || depth > 64 do return
	tid := reflect.union_variant_typeid(tw^)
	if tid == nil do return

	base := engine.tween_base(tw)
	idx := len(walked)

	append(walked, _Walked{ptr = rawptr(tw), tid = tid, parent = parent})
	append(nodes, ng.Node{
		user_handle  = ng.User_Handle(uintptr(rawptr(tw))),
		title        = _type_label(tid),
		subtitle     = _subtitle(base),
		header_color = _color_for(tid),
		dimmed       = base.skip,
	})
	if parent >= 0 do append(links, ng.Link{from = parent, to = idx})

	// Composite children, found structurally.
	if kids := _children_of(tw, tid); kids != nil {
		for i in 0 ..< len(kids) {
			_walk(&kids[i], idx, walked, nodes, links, depth + 1)
		}
	}
}

// The `children` field of a composite tween, or nil for a leaf.
@(private = "file")
_children_of :: proc(tw: ^engine.TweenUnion, tid: typeid) -> []engine.TweenUnion {
	ti := runtime.type_info_base(type_info_of(tid))
	st, is_struct := ti.variant.(runtime.Type_Info_Struct)
	if !is_struct do return nil

	for i in 0 ..< int(st.field_count) {
		if st.names[i] != "children" do continue
		if st.types[i].id != typeid_of([dynamic]engine.TweenUnion) do return nil
		// The variant's payload starts at the union's base pointer.
		arr := (^[dynamic]engine.TweenUnion)(rawptr(uintptr(rawptr(tw)) + st.offsets[i]))
		return arr[:]
	}
	return nil
}

// "TweenMoveToLocal" -> "Move To Local": the type name is the node's label, so
// it reads as a title rather than as an identifier.
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

// The base fields worth seeing without selecting the node.
@(private = "file")
_subtitle :: proc(base: ^engine.Tween) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	if base.delay > 0 do append(&parts, fmt.tprintf("delay %.2fs", base.delay))
	if base.is_await do append(&parts, "await")
	if base.skip do append(&parts, "skipped")
	if len(parts) == 0 do return ""
	return strings.join(parts[:], "  ", context.temp_allocator)
}

// Composites and leaves get different header colors, so the tree's structure
// reads at a glance without following every link.
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

// The selected node's fields, through the ordinary inspector -- so property
// drawers and decorators (the euler widget on TweenRotateToLocal) behave
// exactly as they do in the main inspector.
//
// `owner_handle` is the undo owner for everything edited here. The tween lives
// in heap storage outside the component itself, so the session records the
// WHOLE component per edit (the out-of-storage granularity rule, docs/Undo.md).
// Undo rebuilds that storage, which moves every node -- which is why the caller
// resolves `sel_ptr` fresh from this frame's walk (selection is a tree path,
// never a stored pointer), and the node stays selected across the undo.
//
// Without an owner the inspector's rows open no session at all -- the edit
// writes memory and records NOTHING, which is how this panel first shipped.
@(private = "file")
_draw_selected_panel :: proc(owner_handle: engine.Handle, sel_ptr: rawptr, sel_tid: typeid) {
	// The union's payload begins at the union base, so the variant is inspected
	// by pointing the inspector at that address with the variant's typeid.
	ptr_tid, ok := engine.get_pointer_typeid_by_typeid(sel_tid)
	if !ok {
		im.TextDisabled("This tween type is not registered for inspection.")
		return
	}

	im.TextUnformatted(strings.clone_to_cstring(_type_label(sel_tid), context.temp_allocator))
	im.Separator()

	undo.push_component_owner(owner_handle)
	defer undo.pop_owner()

	target := sel_ptr
	inspector.draw_inspector(any{data = &target, id = ptr_tid})
}

@(menu_item={path="Window/Animation/Tween Graph", shortcut=""})
tween_graph_window_open :: proc() {
	wnd.open("tween_graph")
}

// --- Opening the graph from the inspector -----------------------------------

// Registers the TweenUnion drawer at editor startup: every tween row in the
// inspector gains a Graph button. Runtime registration because the drawer map
// belongs to the inspector package, which this package imports -- a generated
// entry there would be an import cycle. order=1 runs after editor_init
// (order=0), which creates the map this writes into.
@(phase={key=engine.Phase.EditorInit, order=1, mode=Editor})
tween_view_install :: proc() {
	inspector.mapPropertyDrawer[typeid_of(engine.TweenUnion)] = _draw_tween_union_row
}

// account_tree - the editor root owns the canonical list (material_icons.odin)
// and this package cannot import it, so the literal is duplicated, the way the
// inspector package duplicates the search icon.
@(private = "file")
_ICON_GRAPH :: "\ue97a"

// The normal union row plus a Graph button. `record_undo=false` because this
// drawer runs under field_edit_row, whose transaction already records the whole
// owner on any change -- the variant switch recording its own step too would
// make one click cost two Ctrl+Z.
@(private = "file")
_draw_tween_union_row :: proc(ptr: rawptr, tid: typeid, label: cstring) {
	if im.SmallButton(fmt.ctprintf("%s##tg_%v", _ICON_GRAPH, ptr)) {
		_open_graph_for(cast(^engine.TweenUnion)ptr)
	}
	im.SetItemTooltip("Open in Tween Graph")
	im.SameLine()
	inspector.draw_inspector_union(ptr, tid, label, record_undo = false)
}

// Opens the window on the tree containing the clicked tween, with that node
// selected. The owning component comes from the inspector's ambient owner --
// the button lives inside a component's draw, so the owner is pushed. That is
// what makes this generic: no scan, no component type named anywhere.
@(private = "file")
_open_graph_for :: proc(tw: ^engine.TweenUnion) {
	o, o_ok := undo.current_owner()
	if !o_ok || o.kind != .Pooled || o.base_ptr == nil do return
	tid := engine.get_typeid_by_type_key(o.handle.type_key)
	if tid == nil do return

	root_idx, path, depth, ok := tween_graph_locate_in(o.base_ptr, tid, tw)
	if !ok do return

	_state.target = o.handle
	_state.root_idx = root_idx
	_state.has_target = true
	_state.sel_path = path
	_state.sel_depth = depth
	_state.sel_active = true
	_state.framed = false
	wnd.open("tween_graph")
}

// Which of the component's tween trees contains `tw`, and where in it. The
// pointer may be a root or any nested child -- the graph always shows the
// whole containing tree, selection marks the node that was asked for. A
// pointer matching nothing reports ok=false rather than guessing.
tween_graph_locate_in :: proc(base: rawptr, base_tid: typeid, tw: ^engine.TweenUnion) -> (root_idx: int, path: [64]i32, depth: int, ok: bool) {
	if base == nil || tw == nil do return

	roots := tween_roots_of(base, base_tid)
	for root, i in roots {
		walked := make([dynamic]_Walked, context.temp_allocator)
		nodes := make([dynamic]ng.Node, context.temp_allocator)
		links := make([dynamic]ng.Link, context.temp_allocator)
		_walk(root, -1, &walked, &nodes, &links, 0)

		for wk, j in walked {
			if wk.ptr != rawptr(tw) do continue
			parents := make([]int, len(walked), context.temp_allocator)
			for wk2, k in walked do parents[k] = wk2.parent
			depth = ng.tree_path_of(parents, j, path[:])
			root_idx = i
			ok = true
			return
		}
	}
	return
}

// Every TweenUnion in the value graph rooted at `base`, in walk order --
// nested structs, fixed and dynamic arrays, slices and union payloads
// included. Temp-allocated.
//
// The walk does NOT descend into a TweenUnion: nested children live inside its
// variants and are reachable only through their root, so each tree is one
// root, and a root's ordinal is stable for any edit that keeps the component's
// shape (walk order is field order and array order).
tween_roots_of :: proc(base: rawptr, tid: typeid) -> []^engine.TweenUnion {
	roots := make([dynamic]^engine.TweenUnion, context.temp_allocator)
	_collect_tween_roots(base, type_info_of(tid), &roots, 0)
	return roots[:]
}

@(private = "file")
_collect_tween_roots :: proc(ptr: rawptr, ti: ^runtime.Type_Info, roots: ^[dynamic]^engine.TweenUnion, depth: int) {
	if ptr == nil || ti == nil || depth > 16 do return

	if ti.id == typeid_of(engine.TweenUnion) {
		append(roots, cast(^engine.TweenUnion)ptr)
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
		// The data pointer is read HERE, at the moment of use -- an undo
		// restore reallocates it, so it is never cached anywhere.
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
		// Some OTHER union carrying a tween in a variant: descend into the
		// active payload only -- the inactive variants' bytes mean nothing.
		if vtid := reflect.union_variant_typeid(any{ptr, ti.id}); vtid != nil {
			_collect_tween_roots(ptr, type_info_of(vtid), roots, depth + 1)
		}
	}
	// Pointers and maps are not walked: a tween behind a pointer has no stable
	// ordinal, and nothing in the codebase stores tweens that way.
}
