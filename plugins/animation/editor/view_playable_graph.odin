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

@(private = "file") _PG_BAR_PAD :: f32(4) // inset of the strip above the canvas
@(private = "file") _PG_COL_W :: f32(250) // one depth rank
@(private = "file") _PG_GAP :: f32(26) // vertical space between nodes in a rank

// Node hues. A pose source, a blend, the layer stack and a script each get
// their own, and the graph's OUTPUT ROOT gets a terminal colour of its own —
// there is exactly one, and "this is where the pose leaves the graph" is the
// first thing to find when reading an unfamiliar graph.
@(private = "file") _PG_CLIP :: im.Vec4{0.55, 0.49, 0.29, 1}
@(private = "file") _PG_MIXER :: im.Vec4{0.28, 0.52, 0.45, 1}
@(private = "file") _PG_LAYERS :: im.Vec4{0.45, 0.36, 0.62, 1}
@(private = "file") _PG_SCRIPT :: im.Vec4{0.62, 0.43, 0.23, 1}
@(private = "file") _PG_OUTPUT :: im.Vec4{0.55, 0.28, 0.28, 1}

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
	// No window padding, so the canvas reaches every edge of the view — a
	// canvas framed by the panel colour reads as a widget sitting in a window
	// rather than as the surface the window is for. Everything drawn above it
	// pads itself instead (the game view's toolbar does the same).
	im.PushStyleVarImVec2(.WindowPadding, im.Vec2{0, 0})
	defer im.PopStyleVar()

	if !im.Begin(icons.TITLE_PLAYABLE_GRAPH, &menu.show_playable_graph, {.NoCollapse, .NoScrollbar, .NoScrollWithMouse}) {
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
		_pg_pad()
		im.TextDisabled("Select an object that owns a playable graph.")
		return
	}
	g, live := src.graph, src.live

	_pg_pad()
	im.TextDisabled("Source: %s", fmt.ctprint(src.label))
	if g == nil || anim.graph_output(g) == nil || anim.playable_node(g, anim.graph_output(g).root) == nil {
		_pg_pad()
		im.TextDisabled("The graph is empty (nothing to play).")
		return
	}
	im.SetCursorPosY(im.GetCursorPosY() + _PG_BAR_PAD)

	_pg_layout(g, u64(uintptr(engine.Handle(owner).index)))

	if nc.canvas_begin(&_pg.cv, "##pg_canvas") {
		_pg_draw(g, live)
	}
	nc.canvas_end(&_pg.cv)
}

// Inset for one line drawn above the canvas. The window has no padding of its
// own, so anything outside the canvas supplies it.
@(private = "file")
_pg_pad :: proc() {
	im.SetCursorPosX(im.GetCursorPosX() + _PG_BAR_PAD)
	im.SetCursorPosY(im.GetCursorPosY() + _PG_BAR_PAD)
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
	// A y cursor per rank rather than a fixed row pitch: node height follows
	// its input count now, so a six-input mixer would sit under its neighbour.
	next_y := make([]f32, max_depth + 2, context.temp_allocator)
	for &y in next_y do y = 20
	for i in 0 ..< n {
		if !g.nodes[i].alive do continue
		d := depth[i]
		_pg.pos[i + 1] = im.Vec2{f32(max_depth + 1 - d) * _PG_COL_W + 20, next_y[d]}
		next_y[d] += nc.canvas_node_size(_pg_row_count(&g.nodes[i])).y + _PG_GAP
	}
}

// How many body rows a node draws. Shared with _pg_draw so the layout cannot
// size a node differently from the way it is drawn.
@(private = "file")
_pg_row_count :: proc(n: ^anim.Playable_Node) -> int {
	switch _ in n.kind {
	case anim.Playable_Clip:
		return 3
	case anim.Playable_Mixer, anim.Playable_Layer_Mixer, anim.Playable_Script:
		return 1 + len(n.inputs)
	}
	return 1
}

@(private = "file")
_pg_draw :: proc(g: ^anim.Playable_Graph, live: bool) {
	cv := &_pg.cv

	// Per-node presentation, computed before edges need port positions.
	// Row 0 is always the node's own summary and carries the output port, so
	// input i sits on row i+1 — the rule the edge routing below relies on.
	_Desc :: struct {
		title: cstring,
		color: im.Vec4,
		rows:  []nc.Canvas_Row,
	}
	descs := make([]_Desc, len(g.nodes), context.temp_allocator)
	for &n, i in g.nodes {
		if !n.alive do continue
		rows := make([dynamic]nc.Canvas_Row, context.temp_allocator)
		d: _Desc
		switch v in n.kind {
		case anim.Playable_Clip:
			d.title, d.color = "Clip", _PG_CLIP
			append(&rows, nc.Canvas_Row{label = "Clip", value = fmt.ctprintf("%s", _pv_clip_name(v.clip))})
			if clip, ok := anim.animation_clip_load(v.clip); ok {
				append(&rows, live \
					? nc.Canvas_Row{label = "Time", value = fmt.ctprintf("%.2f / %.2f", n.time, clip.length)} \
					: nc.Canvas_Row{label = "Length", value = fmt.ctprintf("%.2f s", clip.length)})
				append(&rows, nc.Canvas_Row{label = "Wrap", value = fmt.ctprintf("%v", clip.wrap)})
			} else {
				append(&rows, nc.Canvas_Row{label = "Length", value = "—"})
				append(&rows, nc.Canvas_Row{label = "Wrap", value = "—"})
			}
		case anim.Playable_Mixer:
			d.title, d.color = "Mixer", _PG_MIXER
			append(&rows, nc.Canvas_Row{label = "Inputs", value = fmt.ctprintf("%d", len(n.inputs))})
			_pg_input_rows(&rows, n.inputs[:], "Pose", live)
		case anim.Playable_Layer_Mixer:
			d.title, d.color = "Layer Mixer", _PG_LAYERS
			append(&rows, nc.Canvas_Row{label = "Layers", value = fmt.ctprintf("%d", len(n.inputs))})
			_pg_input_rows(&rows, n.inputs[:], "Layer", live)
		case anim.Playable_Script:
			d.title, d.color = "Script", _PG_SCRIPT
			append(&rows, nc.Canvas_Row{label = "Time", value = live ? fmt.ctprintf("%.2f s", n.time) : "—"})
			_pg_input_rows(&rows, n.inputs[:], "Pose", live)
		}
		if _pg_is_output_root(g, i + 1) do d.color = _PG_OUTPUT
		d.rows = rows[:]
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
			from := nc.canvas_port_out(cv, _pg.pos[ci + 1])
			to := nc.canvas_port_in(cv, _pg.pos[id], ii + 1)
			// An edge carries a pose, so it takes the pose port's colour and
			// fades with the weight rather than going grey. Beads flow along it
			// only when a pose is actually moving through: on a live graph that
			// is the weight, and the authored shape is not running at all.
			w := clamp(inp.weight, 0, 1)
			col := nc.PORT_POSE
			col.w = live ? 0.28 + 0.72 * w : 0.9
			nc.canvas_link(cv, from, to, im.GetColorU32ImVec4(col), 1.4 + (live ? w : 0), live ? w : 0)
		}
	}

	for &n, i in g.nodes {
		if !n.alive do continue
		id := i + 1
		pos := _pg.pos[id]
		nc.canvas_node(cv, id, &pos, descs[i].title, descs[i].color, descs[i].rows, !_pg_is_output_root(g, id))
		_pg.pos[id] = pos
	}
}

// One row per input, each carrying the port its edge lands on. The weight is
// the value: it is the only thing that differs between a mixer's inputs, and
// on a live graph it is what the window exists to show.
@(private = "file")
_pg_input_rows :: proc(rows: ^[dynamic]nc.Canvas_Row, inputs: []anim.Playable_Input, label: string, live: bool) {
	for inp, i in inputs {
		append(rows, nc.Canvas_Row{
			label = fmt.ctprintf("%s %d", label, i),
			value = live ? fmt.ctprintf("%.2f", inp.weight) : "",
			port  = true,
			col   = nc.PORT_POSE,
		})
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
	tH := engine.inspector_inspected_selection()
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
