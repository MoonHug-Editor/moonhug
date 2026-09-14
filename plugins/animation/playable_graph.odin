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
Playable_Clip :: struct {
	clip: engine.Asset_GUID,
}

// Blends its inputs by weight. Input weights sum to 1 in normal play — a sum
// below 1 blends the remainder from the default pose, above 1 normalizes.
Playable_Mixer :: struct {}

// Stacks layer poses bottom-up: the result starts as the default pose and
// each input blends over the running result by its weight, so a higher layer
// overrides lower ones wherever it animates a channel.
Playable_Layer_Mixer :: struct {}

// Leaf: a callback with a local time. Timeline markers are the zero-duration
// case. on_play/on_pause are for drivers; evaluation only collects `process`.
Playable_Script :: struct {
	user_data: rawptr,
	on_play:   proc(data: rawptr),
	on_pause:  proc(data: rawptr),
	process:   proc(data: rawptr, time: f32, weight: f32),
}

Playable_Kind :: union {
	Playable_Clip,
	Playable_Mixer,
	Playable_Layer_Mixer,
	Playable_Script,
}

Playable_Node :: struct {
	alive:   bool,
	time:    f32, // local time, written by the driver (already wrapped for clips)
	speed:   f32, // scales the local time at evaluation: samples read time * speed
	inputs:  [dynamic]Playable_Input,
	kind:    Playable_Kind,
}

// The node's local time as evaluation reads it. speed 0 is the zero value of
// a node built without playable_add — treat it as 1 so such nodes still play.
playable_node_time :: proc(n: ^Playable_Node) -> f32 {
	return n.speed != 0 ? n.time * n.speed : n.time
}

// One sink: a subtree root and the target it writes to. A graph holds several,
// so a single evaluation can pose more than one object — which is what lets
// weights blend across targets instead of the last write winning.
Graph_Output :: struct {
	root:    Playable_Handle,
	binding: Animation_Binding,
}

Playable_Graph :: struct {
	nodes:      [dynamic]Playable_Node,
	free_slots: [dynamic]Playable_Handle,
	outputs:    [dynamic]Graph_Output,
}

playable_graph_init :: proc(g: ^Playable_Graph) {
	g.nodes = make([dynamic]Playable_Node)
	g.free_slots = make([dynamic]Playable_Handle)
	g.outputs = make([dynamic]Graph_Output)
}

playable_graph_destroy :: proc(g: ^Playable_Graph) {
	for &n in g.nodes do delete(n.inputs)
	delete(g.nodes)
	delete(g.free_slots)
	for &o in g.outputs do animation_binding_destroy(&o.binding)
	delete(g.outputs)
	g^ = {}
}

// Add an output bound to `owner`'s hierarchy and return its index. Outputs are
// added when a driver builds its graph and never removed, so an index stays
// valid — but a `^Graph_Output` does NOT survive another add, the same rule
// pooled pointers follow.
graph_output_add :: proc(g: ^Playable_Graph, owner: engine.Transform_Handle) -> int {
	append(&g.outputs, Graph_Output{})
	idx := len(g.outputs) - 1
	animation_binding_init(&g.outputs[idx].binding, owner)
	return idx
}

graph_output :: proc(g: ^Playable_Graph, idx := 0) -> ^Graph_Output {
	if idx < 0 || idx >= len(g.outputs) do return nil
	return &g.outputs[idx]
}

playable_node :: proc(g: ^Playable_Graph, h: Playable_Handle) -> ^Playable_Node {
	idx := int(h) - 1
	if idx < 0 || idx >= len(g.nodes) do return nil
	n := &g.nodes[idx]
	return n.alive ? n : nil
}

playable_add :: proc(g: ^Playable_Graph, kind: Playable_Kind, speed: f32 = 1) -> Playable_Handle {
	if len(g.free_slots) > 0 {
		h := pop(&g.free_slots)
		n := &g.nodes[int(h) - 1]
		inputs := n.inputs
		clear(&inputs)
		n^ = Playable_Node{alive = true, speed = speed, inputs = inputs, kind = kind}
		return h
	}
	append(&g.nodes, Playable_Node{alive = true, speed = speed, inputs = make([dynamic]Playable_Input), kind = kind})
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
	// Any output rooted at the removed node goes empty rather than dangling —
	// an empty root evaluates to the default pose.
	for &o in g.outputs do if o.root == h do o.root = {}
}

playable_connect :: proc(g: ^Playable_Graph, parent, child: Playable_Handle, weight: f32 = 1) {
	p := playable_node(g, parent)
	if p == nil do return
	append(&p.inputs, Playable_Input{node = child, weight = weight})
}

// Detach `child` from `parent` without freeing it — for moving a subtree to a
// different parent, which playable_remove cannot do (it kills the node).
playable_disconnect :: proc(g: ^Playable_Graph, parent, child: Playable_Handle) {
	p := playable_node(g, parent)
	if p == nil do return
	for i := len(p.inputs) - 1; i >= 0; i -= 1 {
		if p.inputs[i].node == child do ordered_remove(&p.inputs, i)
	}
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

// The clip node's clip length in seconds. false for non-clip nodes and
// unloadable clips.
playable_clip_length :: proc(g: ^Playable_Graph, h: Playable_Handle) -> (f32, bool) {
	n := playable_node(g, h)
	if n == nil do return 0, false
	c, is_clip := n.kind.(Playable_Clip)
	if !is_clip do return 0, false
	clip, ok := animation_clip_load(c.clip)
	if !ok do return 0, false
	return clip.length, true
}

// Whether a Once-wrapped clip node has played past its end (at its scaled
// local time). Drivers and the director poll this — evaluation stays pure,
// so there is no callback.
playable_node_done :: proc(g: ^Playable_Graph, h: Playable_Handle) -> bool {
	n := playable_node(g, h)
	if n == nil do return true
	c, is_clip := n.kind.(Playable_Clip)
	if !is_clip do return false
	clip, ok := animation_clip_load(c.clip)
	if !ok do return true
	if clip.wrap != .Once do return false
	return playable_node_time(n) >= clip.length
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

// One accumulated property channel: value = sum(w_i * v_i), w = sum(w_i) for
// continuous kinds. Discrete kinds carry the dominant contributor instead —
// val is that contributor's raw value, w its effective weight.
Prop_Value :: struct {
	val: [4]f32,
	w:   f32,
}

// One evaluation result: the transform pose plus the property channel values,
// parallel to the binding's slots and prop_slots.
Pose :: struct {
	trs:   []Pose_Value,
	props: []Prop_Value,
}

// One bound property channel target (clip_property.odin). The location meta
// (type key, byte offset, kind) caches at resolve — only the component base
// pointer is fetched per apply, since pools relocate. The default is captured
// at bind time like transform slots.
Prop_Slot :: struct {
	key:         string, // owned "target\x1fcomponent\x1ffield" — the by_prop map key aliases it
	target_path: string, // slices into key
	component:   string, // slices into key
	field:       string, // slices into key
	target:      engine.Transform_Handle,
	loc:         Prop_Location,
	resolved:    bool,
	default:     [4]f32,
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
	owner:      engine.Transform_Handle,
	slots:      [dynamic]Binding_Slot,
	by_path:    map[string]i32,
	prop_slots: [dynamic]Prop_Slot,
	by_prop:    map[string]i32,
}

animation_binding_init :: proc(b: ^Animation_Binding, owner: engine.Transform_Handle) {
	b.owner = owner
	b.slots = make([dynamic]Binding_Slot)
	b.by_path = make(map[string]i32)
	b.prop_slots = make([dynamic]Prop_Slot)
	b.by_prop = make(map[string]i32)
}

animation_binding_destroy :: proc(b: ^Animation_Binding) {
	for &s in b.slots do delete(s.path)
	delete(b.slots)
	delete(b.by_path)
	for &s in b.prop_slots do delete(s.key)
	delete(b.prop_slots)
	delete(b.by_prop)
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

// The by_prop map key for a property channel. Unit separator — target paths
// contain '/' and names are user text.
@(private = "file")
_prop_key :: proc(target, component, field: string, allocator := context.temp_allocator) -> string {
	return strings.concatenate({target, "\x1f", component, "\x1f", field}, allocator)
}

@(private = "file")
_prop_binding_slot :: proc(b: ^Animation_Binding, target, component, field: string) {
	key := _prop_key(target, component, field)
	if idx, ok := b.by_prop[key]; ok {
		s := &b.prop_slots[idx]
		if !s.resolved do _prop_resolve(b, s)
		return
	}
	owned := strings.clone(key)
	s := Prop_Slot{
		key         = owned,
		target_path = owned[:len(target)],
		component   = owned[len(target) + 1:][:len(component)],
		field       = owned[len(target) + len(component) + 2:],
	}
	append(&b.prop_slots, s)
	sp := &b.prop_slots[len(b.prop_slots) - 1]
	_prop_resolve(b, sp)
	b.by_prop[sp.key] = i32(len(b.prop_slots) - 1)
}

@(private = "file")
_prop_resolve :: proc(b: ^Animation_Binding, s: ^Prop_Slot) {
	s.resolved = false
	tH, ok := _animation_resolve_target(b.owner, s.target_path)
	if !ok do return
	loc, mok := _prop_meta(s.component, s.field)
	if !mok do return
	_, base := engine.transform_get_comp_key(tH, loc.type_key)
	if base == nil do return
	s.target = tH
	s.loc = loc
	s.resolved = true
	s.default = _prop_read(rawptr(uintptr(base) + loc.offset), loc.kind, loc.leaf)
}

// The prop slot's live field pointer, or nil when the component is gone.
// Valid only for the current frame.
@(private = "file")
_prop_slot_ptr :: proc(s: ^Prop_Slot) -> rawptr {
	_, base := engine.transform_get_comp_key(s.target, s.loc.type_key)
	if base == nil do return nil
	return rawptr(uintptr(base) + s.loc.offset)
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
	for &s in b.prop_slots {
		if !s.resolved || !engine.pool_valid(&w.transforms, engine.Handle(s.target)) {
			_prop_resolve(b, &s)
			continue
		}
		ptr := _prop_slot_ptr(&s)
		if ptr == nil {
			s.resolved = false
			continue
		}
		s.default = _prop_read(ptr, s.loc.kind, s.loc.leaf)
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
	for &s in b.prop_slots {
		if !s.resolved || !engine.pool_valid(&w.transforms, engine.Handle(s.target)) do continue
		ptr := _prop_slot_ptr(&s)
		if ptr == nil do continue
		_prop_write(ptr, s.loc.kind, s.loc.leaf, s.default)
	}
}

// --- Evaluation ---------------------------------------------------------------------

Script_Invocation :: struct {
	script: Playable_Script,
	time:   f32,
	weight: f32,
}

// Ensure every clip node REACHABLE FROM `root` has binding slots for its
// channels, so the pose buffer size is fixed before evaluation. Cache-hit
// cheap after the first call.
//
// Reachability, not the whole node list: with several outputs each binding
// covers only its own subtree. Binding a sibling output's clips would size the
// pose for channels this target never writes, and resolve their name paths
// against the wrong root.
@(private = "file")
_graph_bind :: proc(g: ^Playable_Graph, root: Playable_Handle, b: ^Animation_Binding) {
	if len(g.nodes) == 0 do return
	seen := make([]bool, len(g.nodes), context.temp_allocator)
	stack := make([dynamic]Playable_Handle, 0, 8, context.temp_allocator)
	append(&stack, root)
	for len(stack) > 0 {
		h := pop(&stack)
		n := playable_node(g, h)
		if n == nil do continue
		if seen[int(h) - 1] do continue
		seen[int(h) - 1] = true
		for input in n.inputs do append(&stack, input.node)

		c, is_clip := n.kind.(Playable_Clip)
		if !is_clip do continue
		clip, ok := animation_clip_load(c.clip)
		if !ok do continue
		for &ch in clip.channels {
			if animation_channel_is_property(&ch) {
				_prop_binding_slot(b, ch.target, ch.component, ch.field)
				continue
			}
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

// Pull the pose for the subtree at `root` at the nodes' current local times.
// Pure: mutates nothing but the returned buffer (and the optional script
// collection).
playable_graph_evaluate :: proc(
	g: ^Playable_Graph,
	root: Playable_Handle,
	b: ^Animation_Binding,
	scripts: ^[dynamic]Script_Invocation = nil,
	allocator := context.temp_allocator,
) -> Pose {
	_graph_bind(g, root, b)
	out := _pose_make(b, allocator)
	if playable_node(g, root) != nil {
		_eval_node(g, root, b, out, 1, scripts, allocator)
	}
	return out
}

// One full frame for every output: evaluate and apply each, then fire the
// scripts collected across all of them. Scripts fire after the LAST apply, so
// a callback never observes a frame where some targets are posed and others
// are not.
playable_graph_tick :: proc(g: ^Playable_Graph) {
	scripts := make([dynamic]Script_Invocation, context.temp_allocator)
	for i in 0 ..< len(g.outputs) {
		o := &g.outputs[i]
		pose := playable_graph_evaluate(g, o.root, &o.binding, &scripts)
		animation_pose_apply(&o.binding, pose)
	}
	playable_scripts_fire(scripts[:])
}

@(private = "file")
_pose_make :: proc(b: ^Animation_Binding, allocator: runtime.Allocator) -> Pose {
	return {
		trs   = make([]Pose_Value, len(b.slots), allocator),
		props = make([]Prop_Value, len(b.prop_slots), allocator),
	}
}

@(private = "file")
_eval_node :: proc(
	g: ^Playable_Graph,
	h: Playable_Handle,
	b: ^Animation_Binding,
	out: Pose,
	path_weight: f32,
	scripts: ^[dynamic]Script_Invocation,
	allocator: runtime.Allocator,
) {
	n := playable_node(g, h)
	if n == nil do return
	switch v in n.kind {
	case Playable_Clip:
		clip, ok := animation_clip_load(v.clip)
		if !ok do return
		t := playable_node_time(n)
		for &ch in clip.channels {
			// No keys, nothing to contribute: sampling would write zeros over
			// the pose (see animation_clip_apply).
			if len(ch.times) == 0 do continue
			val := _animation_channel_sample(&ch, t)
			if animation_channel_is_property(&ch) {
				idx, found := b.by_prop[_prop_key(ch.target, ch.component, ch.field)]
				if !found do continue
				out.props[idx] = {val, 1}
				continue
			}
			idx, found := b.by_path[ch.target]
			if !found do continue
			pv := &out.trs[idx]
			switch ch.path {
			case .Position: pv.pos = val.xyz; pv.pos_w = 1
			case .Rotation: pv.rot = val; pv.rot_w = 1
			case .Scale:    pv.scl = val.xyz; pv.scl_w = 1
			}
		}
	case Playable_Mixer:
		for inp in n.inputs {
			if inp.weight <= PLAYABLE_WEIGHT_EPS do continue
			child := _pose_make(b, allocator)
			_eval_node(g, inp.node, b, child, path_weight * inp.weight, scripts, allocator)
			_pose_accumulate(out, child, inp.weight, b)
		}
	case Playable_Layer_Mixer:
		_pose_set_default(out, b)
		for inp in n.inputs {
			if inp.weight <= PLAYABLE_WEIGHT_EPS do continue
			child := _pose_make(b, allocator)
			_eval_node(g, inp.node, b, child, path_weight * inp.weight, scripts, allocator)
			_pose_blend_over(out, child, inp.weight, b)
		}
	case Playable_Script:
		if scripts != nil {
			append(scripts, Script_Invocation{script = v, time = playable_node_time(n), weight = path_weight})
		}
	}
}

// Mixer accumulation: children are normalized (their own weight sums clamped
// to 1) before adding, so nested over-weighted mixers cannot amplify values.
// Continuous property channels follow the same weighted-sum rule — discrete
// ones (bool/int/enum) cannot lerp, so the DOMINANT contributor wins,
// carrying its raw value and effective weight.
@(private = "file")
_pose_accumulate :: proc(out, child: Pose, w: f32, b: ^Animation_Binding) {
	for i in 0 ..< len(out.props) {
		c := &child.props[i]
		o := &out.props[i]
		if c.w <= PLAYABLE_WEIGHT_EPS do continue
		cw := min(c.w, 1)
		if prop_kind_discrete(b.prop_slots[i].loc.kind) {
			if eff := w * cw; eff > o.w {
				o.val = c.val
				o.w = eff
			}
			continue
		}
		o.val += (w * cw / c.w) * c.val
		o.w += w * cw
	}
	for i in 0 ..< len(out.trs) {
		c := &child.trs[i]
		o := &out.trs[i]
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
_pose_set_default :: proc(out: Pose, b: ^Animation_Binding) {
	for i in 0 ..< len(out.props) {
		if !b.prop_slots[i].resolved do continue
		out.props[i] = {b.prop_slots[i].default, 1}
	}
	for i in 0 ..< len(out.trs) {
		s := &b.slots[i]
		o := &out.trs[i]
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
// deliberate layer weight below 1) lerps toward the layer's value. Discrete
// property channels replace when the layer is the dominant contributor.
@(private = "file")
_pose_blend_over :: proc(out, child: Pose, layer_w: f32, b: ^Animation_Binding) {
	for i in 0 ..< len(out.props) {
		c := &child.props[i]
		o := &out.props[i]
		if c.w <= PLAYABLE_WEIGHT_EPS do continue
		eff := layer_w * min(c.w, 1)
		if prop_kind_discrete(b.prop_slots[i].loc.kind) {
			if eff >= 0.5 do o.val = c.val
		} else {
			o.val = linalg.lerp(o.val, (1.0 / c.w) * c.val, eff)
		}
		o.w = 1
	}
	for i in 0 ..< len(out.trs) {
		c := &child.trs[i]
		o := &out.trs[i]
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

// --- A graph with exactly one output --------------------------------------------------
//
// What a driver posing a SINGLE target needs, so it does not repeat the
// init/destroy/tick plumbing. A driver with several targets holds a
// Playable_Graph directly and adds an output per target.

Playable_Output :: struct {
	graph: Playable_Graph,
}

playable_output_init :: proc(o: ^Playable_Output, owner: engine.Transform_Handle) {
	playable_graph_init(&o.graph)
	graph_output_add(&o.graph, owner)
}

playable_output_destroy :: proc(o: ^Playable_Output) {
	playable_graph_destroy(&o.graph)
}

// The single output's root, assignable — where the owner hangs its tree.
playable_output_root :: proc(o: ^Playable_Output) -> ^Playable_Handle {
	return &o.graph.outputs[0].root
}

playable_output_binding :: proc(o: ^Playable_Output) -> ^Animation_Binding {
	return &o.graph.outputs[0].binding
}

playable_output_tick :: proc(o: ^Playable_Output) {
	playable_graph_tick(&o.graph)
}

// --- Output -------------------------------------------------------------------------

// Write the pose to the bound transforms. Per property: full weight writes the
// value, partial weight blends toward the bind-time default, zero weight (a
// property some clip animates but nothing covered this evaluation) rests AT
// the default. Slots whose handle died re-resolve here — that covers
// reparent/delete/reload of the target.
animation_pose_apply :: proc(b: ^Animation_Binding, pose: Pose) {
	w := engine.ctx_world()
	for i in 0 ..< len(pose.trs) {
		s := &b.slots[i]
		if !s.resolved || !engine.pool_valid(&w.transforms, engine.Handle(s.target)) {
			_binding_resolve(b, s)
			if !s.resolved do continue
		}
		t := engine.pool_get(&w.transforms, engine.Handle(s.target))
		if t == nil do continue
		p := &pose.trs[i]
		if .Position in s.animated do t.position = _finalize_vec(p.pos, p.pos_w, s.default_pos)
		if .Rotation in s.animated do t.rotation = _finalize_quat(p.rot, p.rot_w, s.default_rot)
		if .Scale in s.animated do t.scale = _finalize_vec(p.scl, p.scl_w, s.default_scl)
	}
	for i in 0 ..< len(pose.props) {
		s := &b.prop_slots[i]
		if !s.resolved || !engine.pool_valid(&w.transforms, engine.Handle(s.target)) {
			_prop_resolve(b, s)
			if !s.resolved do continue
		}
		ptr := _prop_slot_ptr(s)
		if ptr == nil {
			s.resolved = false
			continue
		}
		p := &pose.props[i]
		_prop_write(ptr, s.loc.kind, s.loc.leaf, _finalize_prop(p.val, p.w, s.default, prop_kind_discrete(s.loc.kind)))
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

// Property channel finalize: continuous follows _finalize_vec, discrete
// writes the accumulated winner only when it is the dominant contributor
// against the default (the winner's raw value rides in acc unscaled).
@(private = "file")
_finalize_prop :: proc(acc: [4]f32, w: f32, def: [4]f32, discrete: bool) -> [4]f32 {
	if discrete do return w >= 0.5 ? acc : def
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

// --- Who owns a graph -----------------------------------------------------------------
//
// Several things own a Playable_Graph now: an Animation component, a
// TimelineAnimator, the arena shared by one director's animation tracks, and
// the editor's scrub preview. A viewer should not name any of them — it asks
// which graph belongs to a selected object and shows what it gets.
//
// Providers register instead, the same shape the track registry and the
// director drive checks use. Lower `order` wins, so the most live source is
// found first.

Graph_Source :: struct {
	graph: ^Playable_Graph,
	label: string, // shown as the source, e.g. "runtime graph (live)"
	live:  bool,   // real weights and times, not a shape rebuilt from authored data
	order: int,    // the winning provider's order, so a caller can compare objects
}

Graph_Provider :: struct {
	order: int,
	fn:    proc(owner: engine.Transform_Handle) -> (Graph_Source, bool),
}

@(private = "file")
_graph_providers: [dynamic]Graph_Provider

// Process-global, so never the caller's allocator.
playable_graph_register_provider :: proc(order: int, fn: proc(owner: engine.Transform_Handle) -> (Graph_Source, bool)) {
	context.allocator = runtime.default_allocator()
	if _graph_providers == nil do _graph_providers = make([dynamic]Graph_Provider)
	append(&_graph_providers, Graph_Provider{order = order, fn = fn})
}

// The graph to show for `owner`: the lowest-order provider that claims it.
playable_graph_for_object :: proc(owner: engine.Transform_Handle) -> (Graph_Source, bool) {
	best: Graph_Source
	best_order := max(int)
	found := false
	for p in _graph_providers {
		if p.order >= best_order do continue
		src, ok := p.fn(owner)
		if !ok do continue
		src.order = p.order
		best, best_order, found = src, p.order, true
	}
	return best, found
}

// The runtime graphs this package owns. The editor registers its own for the
// scrub preview and the authored shape.
@(phase={key=ImportersInit, order=5})
playable_graph_providers_init :: proc() {
	@(static) done := false
	if done do return
	done = true

	// A TimelineAnimator outranks an Animation on the same object: it is the
	// more concrete driver, so it is the one actually posing.
	playable_graph_register_provider(10, proc(owner: engine.Transform_Handle) -> (Graph_Source, bool) {
		_, a := engine.transform_get_comp(owner, TimelineAnimator)
		if a == nil || !a.graph_ready do return {}, false
		return {graph = &a.graph, label = "TimelineAnimator (live)", live = true}, true
	})
	playable_graph_register_provider(20, proc(owner: engine.Transform_Handle) -> (Graph_Source, bool) {
		_, a := engine.transform_get_comp(owner, Animation)
		if a == nil || !a.graph_ready do return {}, false
		return {graph = &a.graph, label = "Animation runtime graph (live)", live = true}, true
	})
	// A director's animation tracks share one arena, which is where a
	// standalone timeline's blending actually happens.
	playable_graph_register_provider(30, proc(owner: engine.Transform_Handle) -> (Graph_Source, bool) {
		g := animation_director_graph(owner)
		if g == nil do return {}, false
		return {graph = g, label = "timeline tracks (live)", live = true}, true
	})
}
