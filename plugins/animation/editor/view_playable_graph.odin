package animation_editor

// Playable Graph window — the node canvas's first client (docs/
// PlayableGraph.md step 7): a READ-ONLY visualizer of the selected Animation
// component's PlayableGraph, Unity's PlayableGraph Visualizer being the
// model. Clip leaves sit on the left, the root output on the right, edge
// opacity follows input weight. Nodes auto-layout by depth from the root and
// stay draggable on top of that (the layout recomputes when the graph's
// structure changes).
//
// The editor never simulates, so a component's runtime graph rarely exists
// here. The window shows the most live source available:
//   1. the component's RUNTIME graph (graph_ready), live weights and times,
//   2. the Animation window's scrub-preview graph while preview is on,
//   3. otherwise the AUTHORED SHAPE — the graph the component builds when it
//      plays (layer mixer root, one mixer per authored layer, clip leaves) —
//      rebuilt into temp memory each frame; weights are structural, not live.

import "core:fmt"
import im "moonhug:external/odin-imgui"
import "moonhug:editor/menu"
import nc "moonhug:editor/node_canvas"
import engine "moonhug:engine"
import anim "moonhug:packages/animation"
import "moonhug:editor/icons"

@(private = "file") _PG_COL_W :: f32(230) // one depth rank
@(private = "file") _PG_ROW_H :: f32(95)

@(private = "file")
_pg: struct {
	cv:  nc.Node_Canvas,
	pos: map[int]im.Vec2, // node id -> canvas position (drag offsets live here)
	sig: u64, // structure signature the current layout was computed for
}

shutdown_playable_graph_view :: proc() {
	delete(_pg.pos)
	_pg.pos = nil
}

draw_playable_graph_view :: proc() {
	if !im.Begin(icons.TITLE_PLAYABLE_GRAPH, &menu.show_playable_graph, {.NoCollapse}) {
		im.End()
		return
	}
	defer im.End()

	// Who owns a graph is not this window's business: it asks the registry
	// (playable_graph.odin) and draws whatever claims the selection. An
	// Animation, a TimelineAnimator, a director's track arena and the scrub
	// preview all answer through the same call.
	owner, src, found := _pg_selected_source()
	if !found {
		im.TextDisabled("Select an object that owns a playable graph.")
		return
	}
	g, live := src.graph, src.live

	im.TextDisabled("Source: %s", fmt.ctprint(src.label))
	if g == nil || anim.graph_output(g) == nil || anim.playable_node(g, anim.graph_output(g).root) == nil {
		im.TextDisabled("The graph is empty (nothing to play).")
		return
	}

	_pg_layout(g, u64(uintptr(engine.Handle(owner).index)))

	if nc.canvas_begin(&_pg.cv, "##pg_canvas") {
		_pg_draw(g, live)
	}
	nc.canvas_end(&_pg.cv)
}

// The graph the component builds when it plays, from authored data alone —
// every state present, blend children under their blend's mixer — through the
// same builder the driver uses (animation_graph_build_authored), so this window
// cannot show a shape the component would not play. Temp-allocated wholesale:
// no destroy, the frame's free_all reclaims it. Handles are deterministic (same
// build order every frame), so layout and selection stay stable.
@(private = "file")
_pg_authored_shape :: proc(a: ^anim.Animation) -> ^anim.Playable_Graph {
	context.allocator = context.temp_allocator
	g := new(anim.Playable_Graph)
	anim.animation_graph_build_authored(a, g, {}, 1)
	return g
}

// Rank layout: depth = hops from the root, root in the rightmost column,
// rows in visit order. Recomputed only when the structure signature changes,
// so user drags survive frames (and the per-frame authored-shape rebuild,
// whose handles are deterministic).
@(private = "file")
_pg_layout :: proc(g: ^anim.Playable_Graph, salt: u64) {
	sig := salt
	for &n, i in g.nodes {
		if !n.alive do continue
		tag := u64(0)
		switch _ in n.kind {
		case anim.Playable_Clip:        tag = 1
		case anim.Playable_Mixer:       tag = 2
		case anim.Playable_Layer_Mixer: tag = 3
		case anim.Playable_Script:      tag = 4
		}
		sig = sig * 31 + u64(i) * 7 + tag
		for inp in n.inputs {
			sig = sig * 131 + u64(inp.node)
		}
	}
	if sig == _pg.sig && _pg.pos != nil do return
	_pg.sig = sig

	n := len(g.nodes)
	depth := make([]int, n, context.temp_allocator)
	for i in 0 ..< n do depth[i] = -1
	queue := make([dynamic]anim.Playable_Handle, context.temp_allocator)
	max_depth := 0
	for &o in g.outputs {
		if anim.playable_node(g, o.root) == nil do continue
		depth[int(o.root) - 1] = 0
		append(&queue, o.root)
	}
	for qi := 0; qi < len(queue); qi += 1 {
		h := queue[qi]
		node := anim.playable_node(g, h)
		if node == nil do continue
		d := depth[int(h) - 1]
		for inp in node.inputs {
			ci := int(inp.node) - 1
			if ci < 0 || ci >= n || depth[ci] >= 0 do continue
			depth[ci] = d + 1
			max_depth = max(max_depth, d + 1)
			append(&queue, inp.node)
		}
	}
	// Alive nodes unreachable from the root park one rank left of the leaves.
	for i in 0 ..< n {
		if g.nodes[i].alive && depth[i] < 0 do depth[i] = max_depth + 1
	}

	if _pg.pos == nil do _pg.pos = make(map[int]im.Vec2)
	clear(&_pg.pos)
	rows := make([]int, max_depth + 2, context.temp_allocator)
	for i in 0 ..< n {
		if !g.nodes[i].alive do continue
		d := depth[i]
		_pg.pos[i + 1] = im.Vec2{f32(max_depth + 1 - d) * _PG_COL_W + 20, f32(rows[d]) * _PG_ROW_H + 20}
		rows[d] += 1
	}
}

@(private = "file")
_pg_draw :: proc(g: ^anim.Playable_Graph, live: bool) {
	cv := &_pg.cv

	// Per-node presentation, computed before edges need port positions.
	_Desc :: struct {
		title: cstring,
		color: im.Vec4,
		lines: []cstring,
	}
	descs := make([]_Desc, len(g.nodes), context.temp_allocator)
	for &n, i in g.nodes {
		if !n.alive do continue
		lines := make([dynamic]cstring, context.temp_allocator)
		d: _Desc
		switch v in n.kind {
		case anim.Playable_Clip:
			d.title = "Clip"
			d.color = {0.26, 0.42, 0.69, 1}
			append(&lines, fmt.ctprintf("%s", _pv_clip_name(v.clip)))
			if clip, ok := anim.animation_clip_load(v.clip); ok {
				if live {
					append(&lines, fmt.ctprintf("t %.2f / %.2f s", n.time, clip.length))
				} else {
					append(&lines, fmt.ctprintf("len %.2f s, %v", clip.length, clip.wrap))
				}
			}
		case anim.Playable_Mixer:
			d.title = "Mixer"
			d.color = {0.29, 0.55, 0.35, 1}
			append(&lines, fmt.ctprintf("%d input%s", len(n.inputs), len(n.inputs) == 1 ? "" : "s"))
		case anim.Playable_Layer_Mixer:
			d.title = "Layer Mixer"
			d.color = {0.52, 0.36, 0.64, 1}
			append(&lines, fmt.ctprintf("%d layer%s", len(n.inputs), len(n.inputs) == 1 ? "" : "s"))
		case anim.Playable_Script:
			d.title = "Script"
			d.color = {0.75, 0.52, 0.25, 1}
			if live do append(&lines, fmt.ctprintf("t %.2f s", n.time))
		}
		d.lines = lines[:]
		descs[i] = d
	}

	// Edges first (under the nodes): child output -> parent input, opacity
	// following the input weight when the graph is live.
	for &n, i in g.nodes {
		if !n.alive do continue
		id := i + 1
		for inp, ii in n.inputs {
			ci := int(inp.node) - 1
			if ci < 0 || ci >= len(g.nodes) || !g.nodes[ci].alive do continue
			from := nc.canvas_port_out(cv, _pg.pos[ci + 1], len(descs[ci].lines))
			to := nc.canvas_port_in(cv, _pg.pos[id], len(descs[i].lines), ii, len(n.inputs))
			alpha := live ? 0.25 + 0.75 * clamp(inp.weight, 0, 1) : 1
			col := im.GetColorU32(.Text, alpha)
			label := live ? fmt.ctprintf("%.2f", inp.weight) : nil
			nc.canvas_link(cv, from, to, col, 1 + (live ? clamp(inp.weight, 0, 1) : 0), label)
		}
	}

	for &n, i in g.nodes {
		if !n.alive do continue
		id := i + 1
		pos := _pg.pos[id]
		nc.canvas_node(cv, id, &pos, descs[i].title, descs[i].color, descs[i].lines, len(n.inputs), !_pg_is_output_root(g, i + 1))
		_pg.pos[id] = pos
	}
}

// Whether a node is one of the graph's output roots — those draw without an
// output pin, since nothing downstream consumes them.
@(private = "file")
_pg_is_output_root :: proc(g: ^anim.Playable_Graph, h: int) -> bool {
	for &o in g.outputs do if int(o.root) == h do return true
	return false
}

// The graph to show for the current selection, searched up the ancestors so
// selecting a child bone keeps the window on the animated root.
//
// The BEST source across the chain wins, not the nearest one. An object can
// carry an Animation with no clips — which the authored-shape fallback happily
// claims — while the driver actually posing it is a TimelineAnimator further
// up. Stopping at the first ancestor that answers shows the empty one.
@(private = "file")
_pg_selected_source :: proc() -> (owner: engine.Transform_Handle, src: anim.Graph_Source, found: bool) {
	w := engine.ctx_world()
	tH := engine.inspector_active_selection()
	best_order := max(int)
	for engine.pool_valid(&w.transforms, engine.Handle(tH)) {
		if s, ok := anim.playable_graph_for_object(tH); ok && s.order < best_order {
			owner, src, found, best_order = tH, s, true, s.order
		}
		t := engine.pool_get(&w.transforms, engine.Handle(tH))
		if t == nil do break
		tH = engine.Transform_Handle(t.parent.handle)
	}
	return
}

// Editor-only sources, registered behind the runtime ones: a live preview
// outranks a shape rebuilt from authored data.
@(phase={key=engine.Phase.EditorInit, order=1, mode=Editor})
playable_graph_editor_providers_init :: proc() {
	@(static) done := false
	if done do return
	done = true

	anim.playable_graph_register_provider(40, proc(owner: engine.Transform_Handle) -> (anim.Graph_Source, bool) {
		g := _pv_preview_graph(owner)
		if g == nil do return {}, false
		return {graph = g, label = "scrub preview graph (live)", live = true}, true
	})
	anim.playable_graph_register_provider(50, proc(owner: engine.Transform_Handle) -> (anim.Graph_Source, bool) {
		_, a := engine.transform_get_comp(owner, anim.Animation)
		if a == nil do return {}, false
		return {graph = _pg_authored_shape(a), label = "authored shape (weights not live)", live = false}, true
	})
}
