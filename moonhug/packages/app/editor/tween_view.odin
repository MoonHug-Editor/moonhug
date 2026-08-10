package app_editor

// Tween graph view: the Player's tween trees as a node canvas, with the
// selected node's fields in a panel beside it.
//
// A tween tree is a BEHAVIOUR TREE, not a timeline -- Parallel and Sequence run
// their children until each reports Done, and only leaf tweens carry a
// duration. There is no fixed span to lay clips against, which is why this is a
// graph rather than a track view.
//
// The canvas (packages/node_graph) knows nothing about tweens. This file owns
// the whole mapping: walk the union tree into flat nodes + links, hand them
// over, and turn the clicked User_Handle back into a tween pointer.

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
import app "moonhug:packages/app"

@(private = "file")
_state: struct {
	view: ng.View,

	// The selected node, as its PATH from the tree root (child ordinals). A
	// pointer is not a stable identity here: undo restores the whole Player
	// payload, which reallocates the animations array and every node in it, so
	// a pointer-keyed selection died on every undo -- deselecting the node the
	// user had just edited and hiding its panel. The path survives any edit
	// that keeps the tree's shape, and resolves to nothing (clearing the
	// selection) only when the shape actually changes.
	sel_path:   [64]i32,
	sel_depth:  int,
	sel_active: bool,
	// Which tree the path belongs to. A path resolved against a different
	// player or anim would select an unrelated node that happens to share it.
	sel_player: int,
	sel_anim:   int,

	// Which Player's animations are shown, by index into the pool iteration,
	// and which entry of that Player's `animations` array.
	player_idx: int,
	anim_idx:   int,

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

	// Collect the Players that actually carry animations, with their component
	// handles -- the handle is the undo identity for edits made in the panel.
	// Done every frame because a tween tree is live data the user may be editing.
	// The pool iterator's handle carries no type_key (a pool does not know its
	// own key), so it is filled in here.
	players := make([dynamic]^app.Player, context.temp_allocator)
	handles := make([dynamic]engine.Handle, context.temp_allocator)
	it := engine.pool_iterator(app.players(w))
	for p, h in engine.pool_next(&it) {
		if len(p.animations) == 0 do continue
		ph := h
		ph.type_key = .Player
		append(&players, p)
		append(&handles, ph)
	}
	if len(players) == 0 {
		im.TextDisabled("No Player component with tweens in the scene.")
		im.TextDisabled("Tweens live on Player.animations - see packages/app.")
		return
	}

	_state.player_idx = clamp(_state.player_idx, 0, len(players) - 1)
	player := players[_state.player_idx]
	_state.anim_idx = clamp(_state.anim_idx, 0, len(player.animations) - 1)

	_draw_toolbar(players[:], player)
	im.Separator()

	walked := make([dynamic]_Walked, context.temp_allocator)
	nodes := make([dynamic]ng.Node, context.temp_allocator)
	links := make([dynamic]ng.Link, context.temp_allocator)
	_walk(&player.animations[_state.anim_idx], -1, &walked, &nodes, &links, 0)

	// Resolve the selection path against THIS frame's walk. The pointers below
	// (walked[sel_idx].ptr) are only ever this frame's, never stored.
	parents := make([]int, len(walked), context.temp_allocator)
	for wk, i in walked do parents[i] = wk.parent

	sel_idx := -1
	if _state.sel_active && _state.sel_player == _state.player_idx && _state.sel_anim == _state.anim_idx {
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
				_state.sel_player = _state.player_idx
				_state.sel_anim = _state.anim_idx
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
			_draw_selected_panel(handles[_state.player_idx], walked[sel_idx].ptr, walked[sel_idx].tid)
		} else {
			im.TextDisabled("Select a node.")
		}
	}
	im.EndChild()
}

@(private = "file")
_draw_toolbar :: proc(players: []^app.Player, player: ^app.Player) {
	im.SetNextItemWidth(160)
	label := strings.clone_to_cstring(fmt.tprintf("Player %d", _state.player_idx), context.temp_allocator)
	if im.BeginCombo("##player", label) {
		for _, i in players {
			id := strings.clone_to_cstring(fmt.tprintf("Player %d", i), context.temp_allocator)
			if im.Selectable(id, i == _state.player_idx) {
				_state.player_idx = i
				_state.framed = false
			}
		}
		im.EndCombo()
	}

	im.SameLine()
	im.SetNextItemWidth(160)
	anim_label := strings.clone_to_cstring(fmt.tprintf("Anim%d", _state.anim_idx), context.temp_allocator)
	if im.BeginCombo("##anim", anim_label) {
		for i in 0 ..< len(player.animations) {
			id := strings.clone_to_cstring(fmt.tprintf("Anim%d", i), context.temp_allocator)
			if im.Selectable(id, i == _state.anim_idx) {
				_state.anim_idx = i
				_state.framed = false
			}
		}
		im.EndCombo()
	}

	im.SameLine()
	if im.Button("Frame All") do _state.framed = false
	im.SameLine()
	im.TextDisabled("middle-drag pans, wheel zooms")
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
// `player_handle` is the undo owner for everything edited here. The tween lives
// in the Player's `animations` array -- heap storage, outside the component
// itself -- so the session records the WHOLE Player component per edit (the
// out-of-storage granularity rule, docs/Undo.md). Undo rebuilds the
// array, which moves every node -- which is why the caller resolves `sel_ptr`
// fresh from this frame's walk (selection is a tree path, never a stored
// pointer), and the node stays selected across the undo.
//
// Without an owner the inspector's rows open no session at all -- the edit
// writes memory and records NOTHING, which is how this panel first shipped.
@(private = "file")
_draw_selected_panel :: proc(player_handle: engine.Handle, sel_ptr: rawptr, sel_tid: typeid) {
	// The union's payload begins at the union base, so the variant is inspected
	// by pointing the inspector at that address with the variant's typeid.
	ptr_tid, ok := engine.get_pointer_typeid_by_typeid(sel_tid)
	if !ok {
		im.TextDisabled("This tween type is not registered for inspection.")
		return
	}

	im.TextUnformatted(strings.clone_to_cstring(_type_label(sel_tid), context.temp_allocator))
	im.Separator()

	undo.push_component_owner(player_handle)
	defer undo.pop_owner()

	target := sel_ptr
	inspector.draw_inspector(any{data = &target, id = ptr_tid})
}

@(menu_item={path="Window/Tween Graph", shortcut=""})
tween_graph_window_open :: proc() {
	wnd.open("tween_graph")
}
