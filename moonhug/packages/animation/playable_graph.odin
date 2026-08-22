package animation

// PlayableGraph (docs/PlayableGraph.md): the animation evaluation layer.
//
// A graph of nodes — clip leaves sample AnimationClips, mixers blend their
// inputs by weight, a layer mixer stacks layer results over the default pose —
// evaluated by a pull from the root at explicit node times. Evaluation is a
// PURE function with no memory: same graph, same times, same pose, in any call
// order. Nothing here advances time or remembers the previous frame — that
// state lives in drivers (component_Animation.odin), which freely restructure
// and reweight the graph BETWEEN evaluations.
//
// Evaluation produces a POSE — accumulated weighted (position, rotation,
// scale) values per bound transform — and only animation_pose_apply writes
// transforms. Blending resolves against the DEFAULT POSE captured at bind
// time, never the live transform (live values feed back frame to frame and
// drift): a clip at weight 0.3 lands at 0.3 clip + 0.7 default.
//
// Script nodes are collected during evaluation and fired only after the pose
// is applied, so callbacks never observe a half-evaluated frame.

import "base:runtime"
import "moonhug:engine"
import "core:math/linalg"
import "core:strings"

PLAYABLE_WEIGHT_EPS :: f32(0.0001)

// 0 is "no node", so zero-initialized structs are safely inert. Index = h-1.
Playable_Handle :: distinct i32

Playable_Input :: struct {
	node:   Playable_Handle,
	weight: f32,
}

// Leaf: samples an AnimationClip at the node's local time.
Clip_Playable :: struct {
	clip: engine.Asset_GUID,
}

// Blends its inputs by weight. Input weights sum to 1 in normal play — a sum
// below 1 blends the remainder from the default pose, above 1 normalizes.
Mixer_Playable :: struct {}

// Stacks layer poses bottom-up: the result starts as the default pose and
// each input blends over the running result by its weight, so a higher layer
// overrides lower ones wherever it animates a channel.
Layer_Mixer_Playable :: struct {}

// Leaf: a callback with a local time. Timeline markers are the zero-duration
// case. on_play/on_pause are for drivers; evaluation only collects `process`.
Script_Playable :: struct {
	user_data: rawptr,
	on_play:   proc(data: rawptr),
	on_pause:  proc(data: rawptr),
	process:   proc(data: rawptr, time: f32, weight: f32),
}

Playable_Variant :: union {
	Clip_Playable,
	Mixer_Playable,
	Layer_Mixer_Playable,
	Script_Playable,
}

Playable_Node :: struct {
	alive:   bool,
	time:    f32, // local time, written by the driver (already wrapped for clips)
	speed:   f32,
	inputs:  [dynamic]Playable_Input,
	variant: Playable_Variant,
}

Playable_Graph :: struct {
	nodes:      [dynamic]Playable_Node,
	free_slots: [dynamic]Playable_Handle,
	root:       Playable_Handle,
}

playable_graph_init :: proc(g: ^Playable_Graph) {
	g.nodes = make([dynamic]Playable_Node)
	g.free_slots = make([dynamic]Playable_Handle)
	g.root = {}
}

playable_graph_destroy :: proc(g: ^Playable_Graph) {
	for &n in g.nodes do delete(n.inputs)
	delete(g.nodes)
	delete(g.free_slots)
	g^ = {}
}

playable_node :: proc(g: ^Playable_Graph, h: Playable_Handle) -> ^Playable_Node {
	idx := int(h) - 1
	if idx < 0 || idx >= len(g.nodes) do return nil
	n := &g.nodes[idx]
	return n.alive ? n : nil
}

playable_add :: proc(g: ^Playable_Graph, variant: Playable_Variant, speed: f32 = 1) -> Playable_Handle {
	if len(g.free_slots) > 0 {
		h := pop(&g.free_slots)
		n := &g.nodes[int(h) - 1]
		inputs := n.inputs
		clear(&inputs)
		n^ = Playable_Node{alive = true, speed = speed, inputs = inputs, variant = variant}
		return h
	}
	append(&g.nodes, Playable_Node{alive = true, speed = speed, inputs = make([dynamic]Playable_Input), variant = variant})
	return Playable_Handle(len(g.nodes))
}

// Frees the node and disconnects it from every parent. Not recursive — a
// removed mixer orphans its children, which the driver owns anyway.
playable_remove :: proc(g: ^Playable_Graph, h: Playable_Handle) {
	n := playable_node(g, h)
	if n == nil do return
	n.alive = false
	for &p in g.nodes {
		if !p.alive do continue
		for i := len(p.inputs) - 1; i >= 0; i -= 1 {
			if p.inputs[i].node == h do ordered_remove(&p.inputs, i)
		}
	}
	append(&g.free_slots, h)
	if g.root == h do g.root = {}
}

playable_connect :: proc(g: ^Playable_Graph, parent, child: Playable_Handle, weight: f32 = 1) {
	p := playable_node(g, parent)
	if p == nil do return
	append(&p.inputs, Playable_Input{node = child, weight = weight})
}

playable_set_input_weight :: proc(g: ^Playable_Graph, parent, child: Playable_Handle, weight: f32) {
	p := playable_node(g, parent)
	if p == nil do return
	for &inp in p.inputs {
		if inp.node == child {
			inp.weight = weight
			return
		}
	}
}

// --- Pose and binding ---------------------------------------------------------------

Pose_Prop :: enum u8 {
	Position,
	Rotation,
	Scale,
}
Pose_Props :: bit_set[Pose_Prop; u8]

// Accumulated weighted sums per bound transform: value = sum(w_i * v_i),
// *_w = sum(w_i). Rotations accumulate nlerp-style with neighborhood
// correction (contributions flipped into the accumulator's hemisphere).
Pose_Value :: struct {
	pos:   [3]f32,
	pos_w: f32,
	rot:   [4]f32,
	rot_w: f32,
	scl:   [3]f32,
	scl_w: f32,
}

// One bound channel target. `animated` records which properties any clip ever
// bound — only those are ever written back, and only those default-fill.
// Defaults are CAPTURED AT BIND TIME (docs/PlayableGraph.md default pose rule).
Binding_Slot :: struct {
	path:        string, // owned copy of the channel target path
	target:      engine.Transform_Handle,
	resolved:    bool,
	animated:    Pose_Props,
	default_pos: [3]f32,
	default_rot: [4]f32,
	default_scl: [3]f32,
}

// Name-path -> transform binding cache for one graph output. Replaces the
// per-frame name walk the pre-graph runtime did on every apply: paths resolve
// once and re-resolve only when their handle dies (reparent/delete/reload).
Animation_Binding :: struct {
	owner:   engine.Transform_Handle,
	slots:   [dynamic]Binding_Slot,
	by_path: map[string]i32,
}

animation_binding_init :: proc(b: ^Animation_Binding, owner: engine.Transform_Handle) {
	b.owner = owner
	b.slots = make([dynamic]Binding_Slot)
	b.by_path = make(map[string]i32)
}

animation_binding_destroy :: proc(b: ^Animation_Binding) {
	for &s in b.slots do delete(s.path)
	delete(b.slots)
	delete(b.by_path)
	b^ = {}
}

@(private = "file")
_binding_slot :: proc(b: ^Animation_Binding, path: string, prop: Pose_Prop) {
	if idx, ok := b.by_path[path]; ok {
		s := &b.slots[idx]
		s.animated += {prop}
		if !s.resolved do _binding_resolve(b, s)
		return
	}
	append(&b.slots, Binding_Slot{path = strings.clone(path), animated = {prop}})
	s := &b.slots[len(b.slots) - 1]
	_binding_resolve(b, s)
	b.by_path[s.path] = i32(len(b.slots) - 1)
}

@(private = "file")
_binding_resolve :: proc(b: ^Animation_Binding, s: ^Binding_Slot) {
	s.resolved = false
	tH, ok := _animation_resolve_target(b.owner, s.path)
	if !ok do return
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return
	s.target = tH
	s.resolved = true
	s.default_pos = t.position
	s.default_rot = t.rotation
	s.default_scl = t.scale
}

// Re-capture the defaults from the live transforms (dead slots re-resolve).
// The editor's scrub preview calls this right before evaluating: at that point
// the transforms hold their authored values (the preview restores them after
// rendering), so partial-weight blends resolve against the CURRENT authored
// pose and edits made between scrubs are picked up.
animation_binding_refresh_defaults :: proc(b: ^Animation_Binding) {
	w := engine.ctx_world()
	for &s in b.slots {
		if !s.resolved || !engine.pool_valid(&w.transforms, engine.Handle(s.target)) {
			_binding_resolve(b, &s)
			continue
		}
		t := engine.pool_get(&w.transforms, engine.Handle(s.target))
		if t == nil do continue
		s.default_pos = t.position
		s.default_rot = t.rotation
		s.default_scl = t.scale
	}
}

// Write the defaults back to the bound transforms, animated properties only —
// the scrub preview's restore: the world returns to its authored pose.
animation_binding_write_defaults :: proc(b: ^Animation_Binding) {
	w := engine.ctx_world()
	for &s in b.slots {
		if !s.resolved || !engine.pool_valid(&w.transforms, engine.Handle(s.target)) do continue
		t := engine.pool_get(&w.transforms, engine.Handle(s.target))
		if t == nil do continue
		if .Position in s.animated do t.position = s.default_pos
		if .Rotation in s.animated do t.rotation = s.default_rot
		if .Scale in s.animated do t.scale = s.default_scl
	}
}

// --- Evaluation ---------------------------------------------------------------------

Script_Invocation :: struct {
	script: Script_Playable,
	time:   f32,
	weight: f32,
}

// Ensure every alive clip node's channels have binding slots, so the pose
// buffer size is fixed before evaluation. Cache-hit cheap after the first call.
@(private = "file")
_graph_bind :: proc(g: ^Playable_Graph, b: ^Animation_Binding) {
	for &n in g.nodes {
		if !n.alive do continue
		c, is_clip := n.variant.(Clip_Playable)
		if !is_clip do continue
		clip, ok := animation_clip_load(c.clip)
		if !ok do continue
		for &ch in clip.channels {
			prop: Pose_Prop
			switch ch.path {
			case .Position: prop = .Position
			case .Rotation: prop = .Rotation
			case .Scale:    prop = .Scale
			}
			_binding_slot(b, ch.target, prop)
		}
	}
}

// Pull the pose from the root at the nodes' current local times. Pure: mutates
// nothing but the returned buffer (and the optional script collection).
playable_graph_evaluate :: proc(
	g: ^Playable_Graph,
	b: ^Animation_Binding,
	scripts: ^[dynamic]Script_Invocation = nil,
	allocator := context.temp_allocator,
) -> []Pose_Value {
	_graph_bind(g, b)
	out := make([]Pose_Value, len(b.slots), allocator)
	if playable_node(g, g.root) != nil {
		_eval_node(g, g.root, b, out, 1, scripts, allocator)
	}
	return out
}

@(private = "file")
_eval_node :: proc(
	g: ^Playable_Graph,
	h: Playable_Handle,
	b: ^Animation_Binding,
	out: []Pose_Value,
	path_weight: f32,
	scripts: ^[dynamic]Script_Invocation,
	allocator: runtime.Allocator,
) {
	n := playable_node(g, h)
	if n == nil do return
	switch v in n.variant {
	case Clip_Playable:
		clip, ok := animation_clip_load(v.clip)
		if !ok do return
		for &ch in clip.channels {
			idx, found := b.by_path[ch.target]
			if !found do continue
			val := _animation_channel_sample(&ch, n.time)
			pv := &out[idx]
			switch ch.path {
			case .Position: pv.pos = val.xyz; pv.pos_w = 1
			case .Rotation: pv.rot = val; pv.rot_w = 1
			case .Scale:    pv.scl = val.xyz; pv.scl_w = 1
			}
		}
	case Mixer_Playable:
		for inp in n.inputs {
			if inp.weight <= PLAYABLE_WEIGHT_EPS do continue
			child := make([]Pose_Value, len(b.slots), allocator)
			_eval_node(g, inp.node, b, child, path_weight * inp.weight, scripts, allocator)
			_pose_accumulate(out, child, inp.weight)
		}
	case Layer_Mixer_Playable:
		_pose_set_default(out, b)
		for inp in n.inputs {
			if inp.weight <= PLAYABLE_WEIGHT_EPS do continue
			child := make([]Pose_Value, len(b.slots), allocator)
			_eval_node(g, inp.node, b, child, path_weight * inp.weight, scripts, allocator)
			_pose_blend_over(out, child, inp.weight)
		}
	case Script_Playable:
		if scripts != nil {
			append(scripts, Script_Invocation{script = v, time = n.time, weight = path_weight})
		}
	}
}

// Mixer accumulation: children are normalized (their own weight sums clamped
// to 1) before adding, so nested over-weighted mixers cannot amplify values.
@(private = "file")
_pose_accumulate :: proc(out, child: []Pose_Value, w: f32) {
	for i in 0 ..< len(out) {
		c := &child[i]
		o := &out[i]
		if c.pos_w > PLAYABLE_WEIGHT_EPS {
			cw := min(c.pos_w, 1)
			o.pos += (w * cw / c.pos_w) * c.pos
			o.pos_w += w * cw
		}
		if c.scl_w > PLAYABLE_WEIGHT_EPS {
			cw := min(c.scl_w, 1)
			o.scl += (w * cw / c.scl_w) * c.scl
			o.scl_w += w * cw
		}
		if c.rot_w > PLAYABLE_WEIGHT_EPS {
			cw := min(c.rot_w, 1)
			q := (1.0 / c.rot_w) * c.rot
			if o.rot_w > PLAYABLE_WEIGHT_EPS && linalg.dot(o.rot, q) < 0 do q = -q
			o.rot += (w * cw) * q
			o.rot_w += w * cw
		}
	}
}

// The layer stack's base: the default pose, fully weighted, for every property
// any clip animates. Layers then blend over this.
@(private = "file")
_pose_set_default :: proc(out: []Pose_Value, b: ^Animation_Binding) {
	for i in 0 ..< len(out) {
		s := &b.slots[i]
		o := &out[i]
		if .Position in s.animated {
			o.pos = s.default_pos
			o.pos_w = 1
		}
		if .Rotation in s.animated {
			o.rot = s.default_rot
			o.rot_w = 1
		}
		if .Scale in s.animated {
			o.scl = s.default_scl
			o.scl_w = 1
		}
	}
}

// Blend a layer's pose over the running result. A layer covering a channel at
// full weight replaces it, a partially-weighted layer (mid cross-fade, or a
// deliberate layer weight below 1) lerps toward the layer's value.
@(private = "file")
_pose_blend_over :: proc(out, child: []Pose_Value, layer_w: f32) {
	for i in 0 ..< len(out) {
		c := &child[i]
		o := &out[i]
		if c.pos_w > PLAYABLE_WEIGHT_EPS {
			eff := layer_w * min(c.pos_w, 1)
			o.pos = linalg.lerp(o.pos, c.pos / c.pos_w, eff)
			o.pos_w = 1
		}
		if c.scl_w > PLAYABLE_WEIGHT_EPS {
			eff := layer_w * min(c.scl_w, 1)
			o.scl = linalg.lerp(o.scl, c.scl / c.scl_w, eff)
			o.scl_w = 1
		}
		if c.rot_w > PLAYABLE_WEIGHT_EPS {
			eff := layer_w * min(c.rot_w, 1)
			q := (1.0 / c.rot_w) * c.rot
			if linalg.dot(o.rot, q) < 0 do q = -q
			r := linalg.lerp(o.rot, q, eff)
			if l := linalg.length(r); l > PLAYABLE_WEIGHT_EPS do o.rot = r / l
			o.rot_w = 1
		}
	}
}

// --- Output -------------------------------------------------------------------------

// Write the pose to the bound transforms. Per property: full weight writes the
// value, partial weight blends toward the bind-time default, zero weight (a
// property some clip animates but nothing covered this evaluation) rests AT
// the default. Slots whose handle died re-resolve here — that covers
// reparent/delete/reload of the target.
animation_pose_apply :: proc(b: ^Animation_Binding, pose: []Pose_Value) {
	w := engine.ctx_world()
	for i in 0 ..< len(pose) {
		s := &b.slots[i]
		if !s.resolved || !engine.pool_valid(&w.transforms, engine.Handle(s.target)) {
			_binding_resolve(b, s)
			if !s.resolved do continue
		}
		t := engine.pool_get(&w.transforms, engine.Handle(s.target))
		if t == nil do continue
		p := &pose[i]
		if .Position in s.animated do t.position = _finalize_vec(p.pos, p.pos_w, s.default_pos)
		if .Rotation in s.animated do t.rotation = _finalize_quat(p.rot, p.rot_w, s.default_rot)
		if .Scale in s.animated do t.scale = _finalize_vec(p.scl, p.scl_w, s.default_scl)
	}
}

// Run every collected script callback. Called AFTER animation_pose_apply so
// callbacks never observe a half-evaluated frame.
playable_scripts_fire :: proc(scripts: []Script_Invocation) {
	for s in scripts {
		if s.script.process != nil do s.script.process(s.script.user_data, s.time, s.weight)
	}
}

@(private = "file")
_finalize_vec :: proc(acc: [3]f32, w: f32, def: [3]f32) -> [3]f32 {
	if w <= PLAYABLE_WEIGHT_EPS do return def
	if w >= 1 do return (1.0 / w) * acc
	return acc + (1 - w) * def
}

@(private = "file")
_finalize_quat :: proc(acc: [4]f32, w: f32, def: [4]f32) -> [4]f32 {
	if w <= PLAYABLE_WEIGHT_EPS do return def
	q := acc
	if w < 1 {
		d := def
		if linalg.dot(q, d) < 0 do d = -d
		q += (1 - w) * d
	}
	if l := linalg.length(q); l > PLAYABLE_WEIGHT_EPS do return (1.0 / l) * q
	return def
}
