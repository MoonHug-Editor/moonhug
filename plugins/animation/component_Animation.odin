package animation

// Plays clips on this transform's hierarchy through a PlayableGraph
// (playable_graph.odin) — play, cross-fade, queued play, per-layer stacking,
// and 1D blends. See docs/AnimationComponent.md.
//
// No state machine: what follows what is ordinary gameplay code calling this
// API. What the component holds is the list of states that CAN be played.
//
// The component is a DRIVER: it owns every stateful thing (state times, fade
// progress, the queue) and restructures its graph between evaluations —
// cross_fade adds a clip node, a finished fade-out removes one. The graph
// itself stays a pure evaluator.
//
// Fades are weight-continuous, which is what makes interruption smooth with no
// snapshot machinery: cross-fading to C mid A->B fade just retargets — A and B
// fade to 0 FROM THEIR CURRENT WEIGHTS while C fades in. Weights on a layer
// sum to 1 whenever they summed to 1 before, and the first fade-in on an empty
// layer blends up from the default pose.
//
// The editor never simulates: clips advance only in the app, per-frame
// (animation_tick, the @(update) subscriber below).

import "core:encoding/json"
import "core:slice"
import "moonhug:engine"
import serialization "moonhug:engine/serialization"

// Unity's component-level WrapMode: Default defers to the clip's own wrap.
Animation_Wrap_Mode :: enum u8 {
	Default,
	Once,
	Loop,
}

// --- Authored states ----------------------------------------------------------------
//
// A layer holds a TREE of entries. An entry is one state gameplay can play: a
// clip, or a blend whose children are clips. The tree is the AUTHORED shape and
// is not the graph — the graph holds only what is currently playing, and a blend
// becomes a mixer with all its children at once. Nothing here starts by itself
// (only `clip` + play_automatically does that).
//
// The tree is stored FLAT, with `parent` naming another entry's id. A union of
// entry kinds that held its own children would be recursive, which serializes
// and undoes badly here — one array per layer is one undo edit and one JSON
// array, and it still draws as a tree.

// Plays one clip.
@(typ_guid={guid = "3d9b41f7-64ac-4a55-9c02-b8e1d7f5a630"})
Clip_Entry :: struct {
	clip: engine.Asset_GUID `ext:"anim"`,
}

// Blends its children along one axis. `value` is the position on that axis:
// authored here as the starting value, moved at runtime by animation_blend_set.
// One field, one source of truth — the runtime reads it every tick rather than
// copying it, so an inspector slider and a gameplay call do the same thing.
@(typ_guid={guid = "8c5e2a06-1f3d-4b78-a9e4-05c6b2d94871"})
Blend1D_Entry :: struct {
	value: f32,
}

// #no_nil, with the clip first so the zero value is inert: a nil union marshals
// to bare `null`, which the generic union serializer cannot read back, and the
// whole owning component is then preserved verbatim as an unknown one — the
// object reads "Missing Component" and every field vanishes because one variant
// was unset. A Clip_Entry with no clip assigned is the natural zero here, and it
// is what an author gets when they add a state before picking its clip.
Anim_Entry_Variant :: union #no_nil {
	Clip_Entry,
	Blend1D_Entry,
}

// `id` is minted on add and never reused, so a play call keeps working across
// edits that reorder or delete siblings. `pos` places the entry in its PARENT's
// blend space (1D reads x), which is what lets one child work under any blend
// kind without knowing which it is.
Anim_Entry :: struct {
	id:      i32,
	parent:  i32, // 0 = directly on the layer
	pos:     [2]f32,
	name:    string,
	variant: Anim_Entry_Variant,
}

// One AUTHORED layer. The layer index in `Animation.layers` is the runtime layer
// index — higher overrides lower where it animates.
Animation_Layer :: struct {
	entries: [dynamic]Anim_Entry,
}

// One child of a playing blend. `length` is cached at build time because the
// blended cycle rate reads it every frame.
Anim_Blend_Child :: struct {
	clip:   engine.Asset_GUID,
	node:   Playable_Handle,
	pos:    f32,
	length: f32,
}

// One playing state on a layer: a clip, or a blend and its children. `weight`
// moves linearly from `fade_from` toward `fade_target` over `fade_dur` seconds
// (real time, like Unity — fades ignore state speed). A Once state that ran past
// its end holds its final pose (`done`) until everything is done or something
// replaces it.
//
// A blend runs on `phase`, a shared 0..1 position through the cycle, rather than
// on `time`: its children have different lengths, and sampling them at the same
// absolute seconds slides them out of step within a second or two.
Anim_State :: struct {
	entry:       i32, // authored entry, 0 for a clip played by guid
	clip:        engine.Asset_GUID,
	node:        Playable_Handle, // clip node, or the blend's mixer
	is_blend:    bool,
	kids:        [dynamic]Anim_Blend_Child,
	phase:       f32,
	time:        f32,
	weight:      f32,
	fade_from:   f32,
	fade_target: f32,
	fade_t:      f32,
	fade_dur:    f32, // 0 = not fading
	done:        bool,
}

Anim_Layer :: struct {
	mixer:      Playable_Handle,
	states:     [dynamic]Anim_State,
	queue_clip: engine.Asset_GUID,
	queue_fade: f32,
	queued:     bool,
}

@(component={menu="Animation/Animation"})
@(typ_guid={guid = "5b8c2f4e-1d3a-4e6b-8f90-7a2c4d6e8b13"})
Animation :: struct {
	using base:         engine.CompData `inspect:"-"`,
	clip:               engine.Asset_GUID `ext:"anim"`,
	play_automatically: bool,
	wrap_mode:          Animation_Wrap_Mode,
	speed:              f32,
	// Authored layers, each a tree of states. play/cross_fade called without a
	// layer resolve the clip's layer here (unlisted clips land on layer 0).
	// Drawn by the States tree (editor/inspector_animation.odin), not by the
	// reflected field loop — a tree of arrays of unions is what those rows draw
	// worst.
	layers:             [dynamic]Animation_Layer `inspect:"-"`,

	time:    f32 `json:"-" inspect:"-"`, // layer 0's leading state, for inspection
	playing: bool `json:"-" inspect:"-"`,
	// A timeline's animation track is driving this component: its own
	// playback stands down so the two never write the same transforms in one
	// frame (Unity's Animator-under-Timeline rule). Set every tick by the
	// track, cleared when it stops driving.
	timeline_driven: bool `json:"-" inspect:"-"`,
	started: bool `json:"-" inspect:"-"`, // play_automatically consumed on first tick

	graph:       Playable_Graph `json:"-" inspect:"-"`,
	rt_layers:   [dynamic]Anim_Layer `json:"-" inspect:"-"`, // playback state per layer
	graph_ready: bool `json:"-" inspect:"-"`,
}

// A union only serializes through the guid-tagged form once it is registered
// here. Without this the default marshaler writes the ACTIVE VARIANT'S FIELDS
// with no tag, which reads back as the union's zero variant — a blend saved and
// loaded would come back a clip, quietly.
@(phase={key=SerializationInit, order=2})
animation_serialization_init :: proc() {
	@(static) done := false
	if done do return
	done = true
	json.register_user_marshaler(Anim_Entry_Variant, serialization.union_marshal)
	json.register_user_unmarshaler(Anim_Entry_Variant, serialization.union_unmarshal)
	engine.register_pointer_type(Clip_Entry)
	engine.register_pointer_type(Blend1D_Entry)
	engine.register_pointer_type(Anim_Entry_Variant)
}

reset_Animation :: proc(comp: ^Animation) {
	comp.play_automatically = true
	comp.speed = 1
}

on_destroy_Animation :: proc(a: ^Animation) {
	cleanup_Animation(a)
}

// Releases everything the component owns. Reached two ways, and BOTH matter:
// component destruction (on_destroy_Animation), and a value being replaced
// under it — undo calls type_cleanup before unmarshalling a restored value, and
// type_cleanup dispatches on the `cleanup_<Type>` name. Without this proc the
// undo path silently orphaned `layers` and every nested `clips` on each restore.
//
// The runtime side (`graph`, `rt_layers`) is guarded by graph_ready:
// it is built lazily by _anim_ensure_graph, so a component that never ticked has
// none of it, and freeing unconditionally would delete arrays that were never
// made. engine.comp_zero at the end clears graph_ready along with every freed pointer,
// which is what makes a second call safe — the guards all read false and the
// nil checks all short-circuit.
cleanup_Animation :: proc(a: ^Animation) {
	if a.graph_ready {
		playable_graph_destroy(&a.graph)
		for &l in a.rt_layers {
			for &st in l.states do delete(st.kids)
			delete(l.states)
		}
		delete(a.rt_layers)
	}
	if a.layers != nil {
		for &l in a.layers {
			for &e in l.entries do delete(e.name)
			delete(l.entries)
		}
		delete(a.layers)
	}
	engine.comp_zero(a)
}

// --- Authored tree lookups ------------------------------------------------------------

// The entry with this id, and the layer it sits on.
@(private)
_anim_entry_find :: proc(a: ^Animation, id: i32) -> (layer: int, entry: ^Anim_Entry) {
	if id == 0 do return 0, nil
	for &l, li in a.layers {
		for &e in l.entries {
			if e.id == id do return li, &e
		}
	}
	return 0, nil
}

// The entry with this id, or nil. The inspector and gameplay both address
// states by id, so this is the shared way in.
animation_entry :: proc(a: ^Animation, id: i32) -> ^Anim_Entry {
	_, e := _anim_entry_find(a, id)
	return e
}

// The state named `name`, for gameplay that would rather not hold ids. Names are
// not enforced unique — the first match wins, like the rest of the editor's
// by-name lookups.
animation_find :: proc(a: ^Animation, name: string) -> (id: i32, ok: bool) {
	for &l in a.layers {
		for &e in l.entries {
			if e.name == name do return e.id, true
		}
	}
	return 0, false
}

// Next free entry id, taken over every layer so an id names one entry in the
// whole component. Ids are never reused, so deleting a sibling cannot silently
// repoint a play call.
animation_entry_next_id :: proc(a: ^Animation) -> i32 {
	top := i32(0)
	for &l in a.layers {
		for &e in l.entries {
			if e.id > top do top = e.id
		}
	}
	return top + 1
}

// The layer a clip is authored on, for calls that do not pass one explicitly.
// Clips inside a blend count: the blend is what plays, but the layer is the same.
@(private = "file")
_anim_layer_of :: proc(a: ^Animation, clip: engine.Asset_GUID, layer: int) -> int {
	if layer >= 0 do return layer
	for &l, li in a.layers {
		for &e in l.entries {
			if c, is_clip := e.variant.(Clip_Entry); is_clip && c.clip == clip do return li
		}
	}
	return 0
}

// --- Graph bookkeeping --------------------------------------------------------------

@(private = "file")
_anim_ensure_graph :: proc(a: ^Animation) {
	if a.graph_ready do return
	playable_graph_init(&a.graph)
	graph_output_add(&a.graph, a.owner)
	a.rt_layers = make([dynamic]Anim_Layer)
	graph_output(&a.graph).root = playable_add(&a.graph, Layer_Mixer_Playable{})
	a.graph_ready = true
}

// Layers are dense 0..idx so the root's input order IS the layer order.
@(private = "file")
_anim_layer :: proc(a: ^Animation, idx: int) -> ^Anim_Layer {
	for len(a.rt_layers) <= idx {
		mixer := playable_add(&a.graph, Mixer_Playable{})
		playable_connect(&a.graph, graph_output(&a.graph).root, mixer, 1)
		append(&a.rt_layers, Anim_Layer{mixer = mixer, states = make([dynamic]Anim_State)})
	}
	return &a.rt_layers[idx]
}

// A clip played by guid and the same clip played through its authored entry are
// the SAME state: matching on both keys keeps a Play(guid) from stacking a
// second copy beside a running entry.
@(private = "file")
_anim_state_find :: proc(l: ^Anim_Layer, clip: engine.Asset_GUID) -> int {
	for &st, i in l.states {
		if !st.is_blend && st.clip == clip do return i
	}
	return -1
}

@(private = "file")
_anim_state_find_entry :: proc(l: ^Anim_Layer, entry: i32) -> int {
	for &st, i in l.states {
		if st.entry == entry do return i
	}
	return -1
}

@(private = "file")
_anim_state_add :: proc(a: ^Animation, l: ^Anim_Layer, clip: engine.Asset_GUID, weight: f32) -> ^Anim_State {
	node := playable_add(&a.graph, Clip_Playable{clip = clip})
	playable_connect(&a.graph, l.mixer, node, weight)
	append(&l.states, Anim_State{clip = clip, node = node, weight = weight})
	return &l.states[len(l.states) - 1]
}

// Build the nodes for one authored entry. A clip is one leaf. A blend is a mixer
// with EVERY child built at once — that is what makes a blend a single state
// with a single weight, and it is the one place the authored tree and the graph
// differ in shape.
//
// Nested blends are not built: a child that is itself a blend is skipped rather
// than flattened, so the graph never silently means something other than the
// tree. Returns the new state's index, or -1 when the entry produced nothing.
@(private = "file")
_anim_state_add_entry :: proc(a: ^Animation, l: ^Anim_Layer, li: int, id: i32, weight: f32) -> int {
	_, e := _anim_entry_find(a, id)
	if e == nil do return -1

	switch v in e.variant {
	case Clip_Entry:
		if v.clip == {} do return -1
		node := playable_add(&a.graph, Clip_Playable{clip = v.clip})
		playable_connect(&a.graph, l.mixer, node, weight)
		append(&l.states, Anim_State{entry = id, clip = v.clip, node = node, weight = weight})

	case Blend1D_Entry:
		mixer := playable_add(&a.graph, Mixer_Playable{})
		playable_connect(&a.graph, l.mixer, mixer, weight)
		st := Anim_State{
			entry    = id,
			node     = mixer,
			weight   = weight,
			is_blend = true,
			kids     = make([dynamic]Anim_Blend_Child),
		}
		for &kid in a.layers[li].entries {
			if kid.parent != id do continue
			ce, is_clip := kid.variant.(Clip_Entry)
			if !is_clip || ce.clip == {} do continue
			length := f32(1)
			if c, ok := animation_clip_load(ce.clip); ok do length = max(c.length, PLAYABLE_WEIGHT_EPS)
			node := playable_add(&a.graph, Clip_Playable{clip = ce.clip})
			playable_connect(&a.graph, mixer, node, 0)
			append(&st.kids, Anim_Blend_Child{clip = ce.clip, node = node, pos = kid.pos.x, length = length})
		}
		// Sorted by position, so the 1D rule can walk neighbours in order
		// whatever order the entries were authored in.
		slice.sort_by(st.kids[:], proc(x, y: Anim_Blend_Child) -> bool {
			return x.pos < y.pos
		})
		append(&l.states, st)
	}
	return len(l.states) - 1
}

@(private = "file")
_anim_state_remove :: proc(a: ^Animation, l: ^Anim_Layer, i: int) {
	st := &l.states[i]
	for &k in st.kids do playable_remove(&a.graph, k.node)
	delete(st.kids)
	playable_remove(&a.graph, st.node)
	ordered_remove(&l.states, i)
}

@(private = "file")
_anim_fade_start :: proc(st: ^Anim_State, target, duration: f32) {
	st.fade_from = st.weight
	st.fade_target = target
	st.fade_t = 0
	st.fade_dur = duration
}

// --- API ----------------------------------------------------------------------------

// Restart the default clip from t=0 (Unity Animation.Play rewinds a stopped
// clip). Other clips on layer 0 stop instantly.
animation_play :: proc(a: ^Animation) {
	a.time = 0
	a.playing = true
	a.started = true
	if a.clip == {} do return
	animation_play_clip(a, a.clip)
}

// Play a clip immediately at full weight, stopping everything else on the
// layer (Unity Play with the default StopSameLayer).
animation_play_clip :: proc(a: ^Animation, clip: engine.Asset_GUID, layer := -1) {
	if clip == {} do return
	_anim_ensure_graph(a)
	l := _anim_layer(a, _anim_layer_of(a, clip, layer))
	for i := len(l.states) - 1; i >= 0; i -= 1 {
		if l.states[i].clip != clip do _anim_state_remove(a, l, i)
	}
	st: ^Anim_State
	if i := _anim_state_find(l, clip); i >= 0 do st = &l.states[i]
	if st == nil do st = _anim_state_add(a, l, clip, 1)
	st.time = 0
	st.weight = 1
	st.fade_dur = 0
	st.done = false
	a.playing = true
	a.started = true
}

// Play an AUTHORED state by id — a clip or a blend. `duration` 0 cuts, above 0
// cross-fades, and everything else on the layer leaves from its current weight.
// Playback starts at the beginning: a state asked for is a state from the top.
animation_play_entry :: proc(a: ^Animation, id: i32, duration: f32 = 0) {
	li, e := _anim_entry_find(a, id)
	if e == nil do return
	_anim_ensure_graph(a)
	l := _anim_layer(a, li)

	i := _anim_state_find_entry(l, id)
	if i < 0 do i = _anim_state_add_entry(a, l, li, id, duration > 0 ? 0 : 1)
	if i < 0 do return

	st := &l.states[i]
	st.time = 0
	st.phase = 0
	st.done = false

	if duration <= 0 {
		// Cut: every other state goes now. Removing from the end keeps the
		// indices below `i` stable, and `i` itself shifts down by one for each
		// earlier removal.
		keep := i
		for j := len(l.states) - 1; j >= 0; j -= 1 {
			if j == keep do continue
			_anim_state_remove(a, l, j)
			if j < keep do keep -= 1
		}
		st = &l.states[keep]
		st.weight = 1
		st.fade_dur = 0
	} else {
		for &other, j in l.states {
			if j != i do _anim_fade_start(&other, 0, duration)
		}
		_anim_fade_start(&l.states[i], 1, duration)
	}
	a.playing = true
	a.started = true
}

// Move a blend along its axis. The value lives on the authored entry and the
// runtime reads it every tick, so this and an inspector slider are the same
// edit. Setting it on a state that is not playing decides where it starts.
animation_blend_set :: proc(a: ^Animation, id: i32, value: f32) {
	_, e := _anim_entry_find(a, id)
	if e == nil do return
	if b, ok := &e.variant.(Blend1D_Entry); ok do b.value = value
}

animation_blend_get :: proc(a: ^Animation, id: i32) -> f32 {
	_, e := _anim_entry_find(a, id)
	if e == nil do return 0
	if b, ok := &e.variant.(Blend1D_Entry); ok do return b.value
	return 0
}

// Fade `clip` in over `duration` while everything else on the layer fades out
// from its CURRENT weight (Unity Animation.CrossFade). Calling this mid-fade
// is the interruption case and is smooth by construction.
animation_cross_fade :: proc(a: ^Animation, clip: engine.Asset_GUID, duration: f32 = 0.3, layer := -1) {
	if clip == {} do return
	if duration <= 0 {
		animation_play_clip(a, clip, layer)
		return
	}
	_anim_ensure_graph(a)
	l := _anim_layer(a, _anim_layer_of(a, clip, layer))
	target: ^Anim_State
	for &st in l.states {
		if st.clip == clip {
			target = &st
			continue
		}
		_anim_fade_start(&st, 0, duration)
	}
	if target == nil {
		target = _anim_state_add(a, l, clip, 0)
	}
	target.done = false
	_anim_fade_start(target, 1, duration)
	a.playing = true
	a.started = true
}

// Cross-fade to `clip` when the layer's current clips finish (Unity
// CrossFadeQueued with CompleteOthers). With nothing playing it fades in now.
// A looping current clip never finishes, so the queue never fires — same as
// Unity. One pending entry per layer, the newest wins.
animation_cross_fade_queued :: proc(a: ^Animation, clip: engine.Asset_GUID, duration: f32 = 0.3, layer := -1) {
	if clip == {} do return
	_anim_ensure_graph(a)
	li := _anim_layer_of(a, clip, layer)
	l := _anim_layer(a, li)
	if len(l.states) == 0 {
		animation_cross_fade(a, clip, duration, li)
		return
	}
	l.queue_clip = clip
	l.queue_fade = duration
	l.queued = true
}

// Stop everything and rewind (Unity Animation.Stop). Transforms keep their
// last written values.
animation_stop :: proc(a: ^Animation) {
	a.time = 0
	a.playing = false
	a.started = true
	if !a.graph_ready do return
	for &l in a.rt_layers {
		for i := len(l.states) - 1; i >= 0; i -= 1 do _anim_state_remove(a, &l, i)
		l.queued = false
	}
}

// --- Tick ---------------------------------------------------------------------------

// Per-frame advance + evaluate + apply for every enabled Animation component.
// Unity animates in Update, not FixedUpdate.
@(update={order=2})
animation_tick :: proc(dt: f32) {
	w := engine.ctx_world()
	it := engine.pool_iterator(animations(w))
	for a, _ in engine.pool_next(&it) {
		if !a.enabled do continue
		if a.timeline_driven do continue // a timeline track owns this object
		if !engine.pool_valid(&w.transforms, engine.Handle(a.owner)) do continue
		if !a.started {
			a.started = true
			a.playing = a.play_automatically
		}
		if a.playing && (!a.graph_ready || _anim_total_states(a) == 0) {
			if a.clip == {} do continue
			animation_play_clip(a, a.clip)
		}
		if !a.playing || !a.graph_ready do continue
		_anim_comp_tick(a, dt)
	}
}

// The component-level wrap overrides the clip's own, Default defers to it.
@(private = "file")
_anim_wrap :: proc(a: ^Animation, clip_wrap: Animation_Wrap) -> Animation_Wrap {
	#partial switch a.wrap_mode {
	case .Once: return .Once
	case .Loop: return .Loop
	}
	return clip_wrap
}

// Advance one blend state and weight its children.
//
// Children share a normalized `phase` instead of running on their own clocks,
// and the phase advances at the BLENDED cycle length, so a walk of 1.07s
// blending into a run of 0.77s keeps its footfalls together and speeds up as it
// leans toward the run. Sampling both at the same absolute seconds instead is
// what makes blended locomotion slide.
//
// False means the state produced nothing this frame (no children, or none of
// their clips loaded) and should be left alone.
@(private = "file")
_anim_blend_advance :: proc(a: ^Animation, st: ^Anim_State, dt: f32) -> bool {
	if len(st.kids) == 0 do return false

	_, e := _anim_entry_find(a, st.entry)
	if e == nil do return false
	value := f32(0)
	if b, ok := &e.variant.(Blend1D_Entry); ok do value = b.value

	cycle := _anim_blend1d_weights(a, st, value)
	if cycle <= 0 do return false

	// Wrap follows the first child's clip, the same "defer to the clip" rule a
	// single-clip state uses — a blend has no clip of its own to ask.
	wrap := Animation_Wrap.Loop
	if c, ok := animation_clip_load(st.kids[0].clip); ok do wrap = c.wrap
	wrap = _anim_wrap(a, wrap)

	if !st.done do st.phase += dt * a.speed / cycle
	p, done := animation_wrap_time(st.phase, 1, wrap)
	if done do st.done = true

	for &k in st.kids {
		if node := playable_node(&a.graph, k.node); node != nil do node.time = p * k.length
	}
	return true
}

// Unity's 1D rule: the two children bracketing `value` share the weight, the
// ends clamp. Returns the blended cycle length, which is what the phase
// advances against.
@(private = "file")
_anim_blend1d_weights :: proc(a: ^Animation, st: ^Anim_State, value: f32) -> f32 {
	for &k in st.kids do playable_set_input_weight(&a.graph, st.node, k.node, 0)

	last := len(st.kids) - 1
	if value <= st.kids[0].pos {
		playable_set_input_weight(&a.graph, st.node, st.kids[0].node, 1)
		return st.kids[0].length
	}
	if value >= st.kids[last].pos {
		playable_set_input_weight(&a.graph, st.node, st.kids[last].node, 1)
		return st.kids[last].length
	}
	for i in 0 ..< last {
		lo, hi := st.kids[i], st.kids[i + 1]
		if value < lo.pos || value > hi.pos do continue
		span := hi.pos - lo.pos
		k := span > 0 ? (value - lo.pos) / span : 0
		playable_set_input_weight(&a.graph, st.node, lo.node, 1 - k)
		playable_set_input_weight(&a.graph, st.node, hi.node, k)
		return lo.length + (hi.length - lo.length) * k
	}
	return st.kids[0].length
}

@(private = "file")
_anim_total_states :: proc(a: ^Animation) -> int {
	if !a.graph_ready do return 0
	n := 0
	for &l in a.rt_layers do n += len(l.states)
	return n
}

@(private = "file")
_anim_comp_tick :: proc(a: ^Animation, dt: f32) {
	all_done := true
	any_state := false

	for li in 0 ..< len(a.rt_layers) {
		l := &a.rt_layers[li]

		i := 0
		for i < len(l.states) {
			st := &l.states[i]

			if st.fade_dur > 0 {
				st.fade_t += dt
				k := st.fade_t / st.fade_dur
				if k >= 1 {
					k = 1
					st.fade_dur = 0
				}
				st.weight = st.fade_from + (st.fade_target - st.fade_from) * k
			}
			// A finished fade-out leaves the layer entirely.
			if st.fade_dur == 0 && st.fade_target == 0 && st.weight <= PLAYABLE_WEIGHT_EPS {
				_anim_state_remove(a, l, i)
				continue
			}

			if st.is_blend {
				if !_anim_blend_advance(a, st, dt) {
					i += 1
					continue
				}
			} else {
				clip, ok := animation_clip_load(st.clip)
				if !ok {
					i += 1
					continue
				}
				if !st.done do st.time += dt * a.speed
				t, done := animation_wrap_time(st.time, clip.length, _anim_wrap(a, clip.wrap))
				if done do st.done = true
				if node := playable_node(&a.graph, st.node); node != nil do node.time = t
			}
			playable_set_input_weight(&a.graph, l.mixer, st.node, st.weight)

			any_state = true
			if !st.done do all_done = false
			i += 1
		}

		// The queue fires when every clip still meant to be heard has finished
		// (fading-out states do not block it).
		if l.queued && len(l.states) > 0 {
			ready := true
			for &st in l.states {
				if st.fade_target == 0 && st.fade_dur > 0 do continue
				if !st.done do ready = false
			}
			if ready {
				l.queued = false
				animation_cross_fade(a, l.queue_clip, l.queue_fade, li)
				all_done = false
			}
		}
	}

	if !any_state do return

	playable_graph_tick(&a.graph)

	// Mirror layer 0's leading state for inspection/back-compat.
	if len(a.rt_layers) > 0 {
		lead_w := f32(-1)
		for &st in a.rt_layers[0].states {
			if st.weight > lead_w {
				lead_w = st.weight
				a.time = st.time
			}
		}
	}
	// Every state done (Once clips at their ends): freeze — the final pose was
	// just applied and nothing overwrites it. Matches the pre-graph runtime.
	if all_done do a.playing = false
}
