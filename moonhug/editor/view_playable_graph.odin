package editor

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
import engine "../engine"

@(private = "file") _PG_COL_W :: f32(230) // one depth rank
@(private = "file") _PG_ROW_H :: f32(95)

@(private = "file")
_pg: struct {
	cv:  Node_Canvas,
	pos: map[int]im.Vec2, // node id -> canvas position (drag offsets live here)
	sig: u64, // structure signature the current layout was computed for
}

shutdown_playable_graph_view :: proc() {
	delete(_pg.pos)
	_pg.pos = nil
}

draw_playable_graph_view :: proc() {
	if !im.Begin("Playable Graph", nil, {.NoCollapse}) {
		im.End()
		return
	}
	defer im.End()

	owner, a := _pv_target()
	if a == nil {
		im.TextDisabled("Select an object with an Animation component.")
		return
	}

	g: ^engine.Playable_Graph
	source: cstring
	live := false
	if a.graph_ready {
		g = &a.graph
		source = "runtime graph (live)"
		live = true
	} else if pg := _pv_preview_graph(owner); pg != nil {
		g = pg
		source = "scrub preview graph (live)"
		live = true
	} else {
		g = _pg_authored_shape(a)
		source = "authored shape (weights not live)"
	}

	im.TextDisabled("Source: %s", source)
	if g == nil || engine.playable_node(g, g.root) == nil {
		im.TextDisabled("The component produces an empty graph (no clips).")
		return
	}

	_pg_layout(g, u64(uintptr(engine.Handle(owner).index)))

	if canvas_begin(&_pg.cv, "##pg_canvas") {
		_pg_draw(g, live)
	}
	canvas_end(&_pg.cv)
}

// The graph the component builds when it plays, from authored data alone:
// layer mixer root, one mixer per authored layer (at least the default
// layer 0), clip leaves. Temp-allocated wholesale — no destroy, the frame's
// free_all reclaims it. Handles are deterministic (same build order every
// frame), so layout and selection stay stable.
@(private = "file")
_pg_authored_shape :: proc(a: ^engine.Animation) -> ^engine.Playable_Graph {
	context.allocator = context.temp_allocator
	g := new(engine.Playable_Graph)
	engine.playable_graph_init(g)
	g.root = engine.playable_add(g, engine.Layer_Mixer_Playable{})

	n_layers := max(len(a.layers), 1)
	for li in 0 ..< n_layers {
		mixer := engine.playable_add(g, engine.Mixer_Playable{})
		engine.playable_connect(g, g.root, mixer, 1)

		clips := make([dynamic]engine.Asset_GUID)
		if li == 0 && a.clip != {} do append(&clips, a.clip)
		if li < len(a.layers) {
			for c in a.layers[li].clips {
				if c == {} do continue
				dup := false
				for e in clips {
					if e == c do dup = true
				}
				if !dup do append(&clips, c)
			}
		}
		for c in clips {
			engine.playable_connect(g, mixer, engine.playable_add(g, engine.Clip_Playable{clip = c}), 1)
		}
	}
	return g
}

// Rank layout: depth = hops from the root, root in the rightmost column,
// rows in visit order. Recomputed only when the structure signature changes,
// so user drags survive frames (and the per-frame authored-shape rebuild,
// whose handles are deterministic).
@(private = "file")
_pg_layout :: proc(g: ^engine.Playable_Graph, salt: u64) {
	sig := salt
	for &n, i in g.nodes {
		if !n.alive do continue
		tag := u64(0)
		switch _ in n.variant {
		case engine.Clip_Playable:        tag = 1
		case engine.Mixer_Playable:       tag = 2
		case engine.Layer_Mixer_Playable: tag = 3
		case engine.Script_Playable:      tag = 4
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
	queue := make([dynamic]engine.Playable_Handle, context.temp_allocator)
	max_depth := 0
	if engine.playable_node(g, g.root) != nil {
		depth[int(g.root) - 1] = 0
		append(&queue, g.root)
	}
	for qi := 0; qi < len(queue); qi += 1 {
		h := queue[qi]
		node := engine.playable_node(g, h)
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
_pg_draw :: proc(g: ^engine.Playable_Graph, live: bool) {
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
		switch v in n.variant {
		case engine.Clip_Playable:
			d.title = "Clip"
			d.color = {0.26, 0.42, 0.69, 1}
			append(&lines, fmt.ctprintf("%s", _pv_clip_name(v.clip)))
			if clip, ok := engine.animation_clip_load(v.clip); ok {
				if live {
					append(&lines, fmt.ctprintf("t %.2f / %.2f s", n.time, clip.length))
				} else {
					append(&lines, fmt.ctprintf("len %.2f s, %v", clip.length, clip.wrap))
				}
			}
		case engine.Mixer_Playable:
			d.title = "Mixer"
			d.color = {0.29, 0.55, 0.35, 1}
			append(&lines, fmt.ctprintf("%d input%s", len(n.inputs), len(n.inputs) == 1 ? "" : "s"))
		case engine.Layer_Mixer_Playable:
			d.title = "Layer Mixer"
			d.color = {0.52, 0.36, 0.64, 1}
			append(&lines, fmt.ctprintf("%d layer%s", len(n.inputs), len(n.inputs) == 1 ? "" : "s"))
		case engine.Script_Playable:
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
			from := canvas_port_out(cv, _pg.pos[ci + 1], len(descs[ci].lines))
			to := canvas_port_in(cv, _pg.pos[id], len(descs[i].lines), ii, len(n.inputs))
			alpha := live ? 0.25 + 0.75 * clamp(inp.weight, 0, 1) : 1
			col := im.GetColorU32(.Text, alpha)
			label := live ? fmt.ctprintf("%.2f", inp.weight) : nil
			canvas_link(cv, from, to, col, 1 + (live ? clamp(inp.weight, 0, 1) : 0), label)
		}
	}

	for &n, i in g.nodes {
		if !n.alive do continue
		id := i + 1
		pos := _pg.pos[id]
		canvas_node(cv, id, &pos, descs[i].title, descs[i].color, descs[i].lines, len(n.inputs), id != int(g.root))
		_pg.pos[id] = pos
	}
}
