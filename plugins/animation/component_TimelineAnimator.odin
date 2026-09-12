package animation

// TimelineAnimator (docs/TimelineAnimator.md): an animation state machine one
// level above clips, where a state plays a whole TIMELINE instead of a single
// clip.
//
// This file is the component and its graph SKELETON. It owns ONE graph with
// one output per bound target, a layer mixer at each output's root, and one
// mixer per layer under that. States, cross-fade and the play API attach to
// those layer mixers and land on top of this structure.
//
// One graph is the requirement everything rests on: weights blend only inside
// a single evaluation, because a partial weight resolves against the
// bind-time default pose. Two timelines evaluating and applying separately do
// not cross-fade, the second write replaces the first.

import "moonhug:engine"
import seq "moonhug:packages/sequencer"

// A key bound to an output component in the scene. The component's TYPE
// decides the output kind — an Animation receives a pose, an AudioSource
// receives audio — so nothing declares a kind anywhere.
Target_Binding :: struct {
	key:    string,
	target: engine.Ref_Local,
}

// One authored layer. Layer order is override order: a higher layer replaces a
// lower one wherever it animates a channel, which is what
// Layer_Mixer_Playable already does with its inputs.
//
// `weight` is zero-neutral like the director's `speed` — a layer added in the
// inspector starts at full strength rather than silent.
Animator_Layer :: struct {
	name:   string,
	weight: f32,
	states: [dynamic]Timeline_State,
}

// One state: a whole timeline played as a unit.
//
// `timeline` points at a root carrying a PlayableDirector, two ways:
//   * CROSS-ASSET (guid set) — a prefab. The animator instances it and owns
//     the instance, so the prefab system supplies authoring, variants and
//     per-instance overrides.
//   * LOCAL (guid zero, local_id set) — a timeline already in this scene.
//     Adopted where it stands and never destroyed, so a timeline can be
//     authored in place without making an asset first.
Timeline_State :: struct {
	name:     string,
	timeline: engine.PPtr,
	speed:    f32, // 0 runs at 1
	wrap:     seq.Timeline_Wrap,
	fade:     f32, // default cross-fade duration INTO this state
}

// A layer's presence in the graph: one mixer per output, parallel to
// `graph.outputs`. States attach to these.
Animator_Layer_Runtime :: struct {
	mixers: [dynamic]Playable_Handle,
	states: [dynamic]Animator_State_Runtime,
}

// A state's live half: the instantiated timeline, the mixers its tracks hang
// under (one per output), and its own playhead.
Animator_State_Runtime :: struct {
	root:   engine.Transform_Handle, // the timeline's root
	owned:  bool,                    // instanced by this animator, so destroyed by it
	dir:    engine.Handle,           // its PlayableDirector
	mixers: [dynamic]Playable_Handle, // parallel to graph.outputs
	time:   f32,
	weight: f32,
	// Weight moves linearly from `fade_from` toward `fade_target` over
	// `fade_dur` seconds of real time. 0 duration means not fading.
	fade_from:   f32,
	fade_target: f32,
	fade_t:      f32,
	fade_dur:    f32,
	done:        bool, // a Once timeline ran past its end
}

@(component={menu="Animation/TimelineAnimator"})
@(typ_guid={guid = "0959886b-dc83-491c-9843-df105c69e01d"})
TimelineAnimator :: struct {
	using base: engine.CompData `inspect:"-"`,

	speed:   f32, // playback speed, 0 runs at 1
	layers:  [dynamic]Animator_Layer,
	targets: [dynamic]Target_Binding,

	// Runtime, built lazily by _ta_ensure_graph and guarded by graph_ready, so
	// a component that never ticked owns nothing and cleanup frees nothing.
	graph:       Playable_Graph `json:"-" inspect:"-"`,
	rt:          [dynamic]Animator_Layer_Runtime `json:"-" inspect:"-"`,
	// Parallel to `graph.outputs`: the `targets` index each output came from,
	// so a key resolves to an output. An index, not the key string, because
	// the string belongs to `targets` and moves when that list is edited.
	out_target:  [dynamic]int `json:"-" inspect:"-"`,
	graph_ready: bool `json:"-" inspect:"-"`,
}

reset_TimelineAnimator :: proc(a: ^TimelineAnimator) {
	a.speed = 1
}

on_destroy_TimelineAnimator :: proc(a: ^TimelineAnimator) {
	cleanup_TimelineAnimator(a)
}

// Reached two ways, and both matter: component destruction, and a value being
// replaced under it — undo calls type_cleanup before unmarshalling a restored
// value. comp_zero clears graph_ready along with every freed pointer, which is
// what makes a second call safe.
cleanup_TimelineAnimator :: proc(a: ^TimelineAnimator) {
	if a.graph_ready {
		// Hand every claimed target back first: a component destroyed while
		// holding them would leave them suppressed forever.
		_ta_claim_targets(a, false)
		playable_graph_destroy(&a.graph)
		for &l in a.rt {
			for &st in l.states {
				animation_director_unadopt(st.root)
				if st.owned && st.root != {} do engine.transform_destroy(st.root)
				delete(st.mixers)
			}
			delete(l.states)
			delete(l.mixers)
		}
		delete(a.rt)
		delete(a.out_target)
	}
	if a.layers != nil {
		for &l in a.layers {
			delete(l.name)
			for &st in l.states do delete(st.name)
			delete(l.states)
		}
		delete(a.layers)
	}
	if a.targets != nil {
		for &tb in a.targets do delete(tb.key)
		delete(a.targets)
	}
	engine.comp_zero(a)
}

// --- Graph skeleton -------------------------------------------------------------------

// The transform an output writes to: the bound component's owner. An unbound
// or dead reference yields no output, and the keys naming it fail to resolve.
@(private = "file")
_ta_target_transform :: proc(tb: ^Target_Binding) -> (engine.Transform_Handle, bool) {
	w := engine.ctx_world()
	if !engine.world_pool_valid(w, tb.target.handle) do return {}, false
	base := cast(^engine.CompData)engine.world_pool_get(w, tb.target.handle)
	if base == nil do return {}, false
	if !engine.pool_valid(&w.transforms, engine.Handle(base.owner)) do return {}, false
	return base.owner, true
}

@(private = "file")
_ta_layer_weight :: proc(l: ^Animator_Layer) -> f32 {
	return l.weight != 0 ? l.weight : 1
}

@(private = "file")
_ta_ensure_graph :: proc(a: ^TimelineAnimator) {
	if a.graph_ready do return
	playable_graph_init(&a.graph)
	a.rt = make([dynamic]Animator_Layer_Runtime)
	a.out_target = make([dynamic]int)

	// One output per bound target, built from the authored list rather than
	// from what states happen to reach. Every binding then captures its
	// default pose at the same deterministic moment, and an output nothing
	// feeds costs one empty pose.
	for &tb, ti in a.targets {
		tH, ok := _ta_target_transform(&tb)
		if !ok do continue
		idx := graph_output_add(&a.graph, tH)
		root := playable_add(&a.graph, Layer_Mixer_Playable{})
		graph_output(&a.graph, idx).root = root
		append(&a.out_target, ti)
	}

	// Every layer gets a mixer under every output's layer mixer. Input order
	// IS layer order, so a later layer overrides an earlier one.
	for &l in a.layers {
		lr := Animator_Layer_Runtime{
			mixers = make([dynamic]Playable_Handle, 0, len(a.graph.outputs)),
		}
		for oi in 0 ..< len(a.graph.outputs) {
			m := playable_add(&a.graph, Mixer_Playable{})
			playable_connect(&a.graph, graph_output(&a.graph, oi).root, m, _ta_layer_weight(&l))
			append(&lr.mixers, m)
		}
		lr.states = make([dynamic]Animator_State_Runtime, 0, len(l.states))
		for &stateDesc in l.states {
			append(&lr.states, _ta_build_state(a, &stateDesc, lr.mixers[:]))
		}
		append(&a.rt, lr)
	}
	a.graph_ready = true
}

// Instantiate a state's timeline and wire it in:
//   * one mixer per output, under this layer's mixer, starting at weight 0,
//   * the prefab instanced as a child of the animator,
//   * its director adopted, so its tracks build into THIS graph under those
//     mixers and it stops ticking itself.
// An empty or unloadable timeline yields a state with no instance, which stays
// silent rather than failing the build.
@(private = "file")
_ta_build_state :: proc(a: ^TimelineAnimator, desc: ^Timeline_State, layer_mixers: []Playable_Handle) -> Animator_State_Runtime {
	st := Animator_State_Runtime{
		mixers = make([dynamic]Playable_Handle, 0, len(layer_mixers)),
	}
	for lm in layer_mixers {
		m := playable_add(&a.graph, Mixer_Playable{})
		playable_connect(&a.graph, lm, m, 0)
		append(&st.mixers, m)
	}
	st.root, st.owned = _ta_state_root(a, desc)
	if st.root == {} do return st
	if dh, d := engine.transform_get_comp(st.root, seq.PlayableDirector); d != nil {
		st.dir = dh.handle
	}
	animation_director_adopt(st.root, a, st.mixers[:])
	return st
}

// The timeline's root for a state, and whether this animator owns it. A
// cross-asset reference is instanced here; a local one is found in the
// animator's own scene and left alone.
@(private = "file")
_ta_state_root :: proc(a: ^TimelineAnimator, desc: ^Timeline_State) -> (engine.Transform_Handle, bool) {
	if !engine.asset_guid_is_empty(desc.timeline.guid) {
		return engine.scene_instantiate_guid(desc.timeline.guid, a.owner), true
	}
	if desc.timeline.local_id == 0 do return {}, false
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(a.owner))
	if t == nil || t.scene == nil do return {}, false
	h, ok := engine.scene_find_selectable_transform_local_id(t.scene, desc.timeline.local_id)
	if !ok do return {}, false
	return h, false
}

// Drop the graph so the next tick rebuilds it — for a targets or layers edit,
// which changes the output set and the mixer shape.
timeline_animator_rebuild :: proc(a: ^TimelineAnimator) {
	if !a.graph_ready do return
	playable_graph_destroy(&a.graph)
	for &l in a.rt {
		for &st in l.states {
			animation_director_unadopt(st.root)
			if st.owned && st.root != {} do engine.transform_destroy(st.root)
			delete(st.mixers)
		}
		delete(l.states)
		delete(l.mixers)
	}
	delete(a.rt)
	delete(a.out_target)
	a.rt = nil
	a.out_target = nil
	a.graph_ready = false
}

// The output index for a key, or -1. Resolution goes through `targets`, so a
// key nothing binds simply has no output.
timeline_animator_output_for_key :: proc(a: ^TimelineAnimator, key: string) -> int {
	for ti, oi in a.out_target {
		if ti < len(a.targets) && a.targets[ti].key == key do return oi
	}
	return -1
}

// The transform behind a key, for a track resolving its target through this
// animator. False when the key names nothing or its binding is dead.
timeline_animator_target_for_key :: proc(a: ^TimelineAnimator, key: string) -> (engine.Transform_Handle, bool) {
	oi := timeline_animator_output_for_key(a, key)
	if oi < 0 do return {}, false
	o := graph_output(&a.graph, oi)
	if o == nil do return {}, false
	return o.binding.owner, true
}

// The mixer a state on `layer` attaches to for `output`.
timeline_animator_layer_mixer :: proc(a: ^TimelineAnimator, layer, output: int) -> Playable_Handle {
	if layer < 0 || layer >= len(a.rt) do return {}
	lr := &a.rt[layer]
	if output < 0 || output >= len(lr.mixers) do return {}
	return lr.mixers[output]
}

// Whether any state carries weight. An animator holding states that are all
// silent applies nothing: the graph would evaluate to an empty pose, and
// writing that every frame would push bind-time defaults over whatever else
// poses the target. Having states is not the same as playing one.
@(private = "file")
_ta_has_content :: proc(a: ^TimelineAnimator) -> bool {
	for &lr in a.rt {
		for &st in lr.states do if st.weight > PLAYABLE_WEIGHT_EPS do return true
	}
	return false
}

// Layer weights are authored data and can change between frames, so they are
// pushed every tick rather than only at build.
@(private = "file")
_ta_sync_layer_weights :: proc(a: ^TimelineAnimator) {
	for &l, li in a.layers {
		if li >= len(a.rt) do break
		w := _ta_layer_weight(&l)
		for m, oi in a.rt[li].mixers {
			o := graph_output(&a.graph, oi)
			if o == nil do continue
			playable_set_input_weight(&a.graph, o.root, m, w)
		}
	}
}

// An Animation bound as a target stops driving itself for as long as this
// animator has something to play — the higher level overriding the lower one.
//
// An IDLE animator releases it instead. Claiming unconditionally would mean
// that adding a TimelineAnimator and binding a target silently freezes the
// object until states exist, and every level is supposed to work with nothing
// above it configured.
@(private = "file")
_ta_claim_targets :: proc(a: ^TimelineAnimator, claim: bool) {
	w := engine.ctx_world()
	if w == nil do return
	for ti in a.out_target {
		if ti < 0 || ti >= len(a.targets) do continue
		h := a.targets[ti].target.handle
		if h.type_key != .Animation do continue
		if !engine.world_pool_valid(w, h) do continue
		comp := cast(^Animation)engine.world_pool_get(w, h)
		if comp != nil do comp.timeline_driven = claim
	}
}

// Advance every playing state and push its time into its timeline.
//
// The director is evaluated directly rather than ticked: director_run skips it
// (the animation package registers a drive check for adopted directors), so
// the animator owns its time the way a control track owns a nested timeline's.
// Evaluating makes its tracks set weights and times in THIS graph, and nothing
// is applied until the animator flushes.
@(private = "file")
_ta_advance_states :: proc(a: ^TimelineAnimator, dt: f32) {
	w := engine.ctx_world()
	speed := a.speed != 0 ? a.speed : 1
	for &lr, li in a.rt {
		if li >= len(a.layers) do continue
		for &st, si in lr.states {
			if si >= len(a.layers[li].states) do continue
			desc := &a.layers[li].states[si]
			if st.weight <= PLAYABLE_WEIGHT_EPS do continue
			if st.root == {} do continue
			if !engine.world_pool_valid(w, st.dir) do continue
			d := cast(^seq.PlayableDirector)engine.world_pool_get(w, st.dir)
			if d == nil do continue

			st.time += dt * speed * (desc.speed != 0 ? desc.speed : 1)
			length := seq.director_duration(d, seq.director_tracks(d))
			if length > 0 {
				switch desc.wrap {
				case .Loop:
					for st.time >= length do st.time -= length
				case .Once:
					// A Once state reports done at its end and stays there, so
					// gameplay can hand back to whatever should follow it. It
					// keeps evaluating: the driver decides when to leave, not
					// the state.
					if st.time >= length {
						st.time = length
						st.done = true
					}
				}
			}
			seq.director_evaluate_at(d, st.time, .Play)
		}
	}
}

@(update={order=2})
timeline_animator_tick :: proc(dt: f32) {
	w := engine.ctx_world()
	it := engine.pool_iterator(timeline_animators(w))
	for a, _ in engine.pool_next(&it) {
		if !engine.pool_valid(&w.transforms, engine.Handle(a.owner)) do continue
		if !a.enabled {
			// A disabled animator owns nothing, so whatever it held plays
			// itself again.
			if a.graph_ready do _ta_claim_targets(a, false)
			continue
		}
		_ta_ensure_graph(a)
		_ta_sync_layer_weights(a)
		// Fades advance BEFORE the content check, or a fade starting from
		// weight 0 would never get a first frame: it would read as idle, the
		// tick would skip, and the fade would sit at 0 forever.
		_ta_advance_fades(a, dt)
		active := _ta_has_content(a)
		_ta_claim_targets(a, active)
		if !active do continue
		_ta_advance_states(a, dt)
		playable_graph_tick(&a.graph)
	}
}

// --- Weight and cross-fade ------------------------------------------------------------
//
// A state has ONE weight, written to one mixer input per output it reaches.
// Nothing multiplies weights by hand: a mixer input weight propagates down the
// whole subtree during evaluation, so setting it scales every track and every
// clip inside that state's timeline.
//
// Fades are weight-continuous, the rule component_Animation already uses:
// cross-fading to C in the middle of an A to B fade retargets A and B toward 0
// FROM THEIR CURRENT WEIGHTS while C rises. Weights that summed to 1 still sum
// to 1, and interruption needs no snapshot machinery.

// Opaque: layer in the high 16 bits, state index in the low 16.
State_Id :: distinct i32
STATE_ID_NONE :: State_Id(-1)

@(private = "file")
_state_id :: proc(layer, index: int) -> State_Id {
	return State_Id(i32(layer) << 16 | i32(index) & 0xFFFF)
}

@(private = "file")
_state_split :: proc(id: State_Id) -> (layer, index: int) {
	return int(i32(id) >> 16), int(i32(id) & 0xFFFF)
}

@(private = "file")
_ta_state_rt :: proc(a: ^TimelineAnimator, id: State_Id) -> ^Animator_State_Runtime {
	li, si := _state_split(id)
	if li < 0 || li >= len(a.rt) do return nil
	lr := &a.rt[li]
	if si < 0 || si >= len(lr.states) do return nil
	return &lr.states[si]
}

@(private = "file")
_ta_fade_start :: proc(st: ^Animator_State_Runtime, target, duration: f32) {
	st.fade_from = st.weight
	st.fade_target = target
	st.fade_t = 0
	st.fade_dur = duration
}

// Push a state's weight into the graph: the same number on every output it
// reaches, so one fade moves the whole performance.
@(private = "file")
_ta_push_weight :: proc(a: ^TimelineAnimator, li: int, st: ^Animator_State_Runtime) {
	if li < 0 || li >= len(a.rt) do return
	lr := &a.rt[li]
	for m, oi in st.mixers {
		if oi >= len(lr.mixers) do break
		playable_set_input_weight(&a.graph, lr.mixers[oi], m, st.weight)
	}
}

@(private = "file")
_ta_advance_fades :: proc(a: ^TimelineAnimator, dt: f32) {
	for &lr, li in a.rt {
		for &st in lr.states {
			if st.fade_dur > 0 {
				st.fade_t += dt
				k := st.fade_t / st.fade_dur
				if k >= 1 {
					k = 1
					st.fade_dur = 0
				}
				st.weight = st.fade_from + (st.fade_target - st.fade_from) * k
			}
			_ta_push_weight(a, li, &st)
		}
	}
}

// --- API ------------------------------------------------------------------------------

// Resolve a state name once, then use the handle. Names are per layer, and the
// first match wins when two layers use the same name.
animator_find :: proc(a: ^TimelineAnimator, name: string) -> (State_Id, bool) {
	for &l, li in a.layers {
		for &st, si in l.states do if st.name == name do return _state_id(li, si), true
	}
	return STATE_ID_NONE, false
}

// Play `s` on its layer, fading every other state there out from its CURRENT
// weight. `fade` of -1 takes the state's authored duration, which is the point
// of authoring one, and anything at or below 0 is a hard cut.
//
// The target ALWAYS starts from time 0. Play means play, and a finished
// one-shot that resumed where it stopped would report done again on the next
// tick and never be seen. Resuming mid-state would be a separate argument if
// anything ever needs it.
//
// There is no separate cross-fade entry point: a cut is a fade of length 0.
animator_play :: proc(a: ^TimelineAnimator, s: State_Id, fade: f32 = -1) {
	_ta_ensure_graph(a)
	li, si := _state_split(s)
	if li < 0 || li >= len(a.rt) || li >= len(a.layers) do return
	lr := &a.rt[li]
	if si < 0 || si >= len(lr.states) || si >= len(a.layers[li].states) do return

	dur := fade
	if dur < 0 do dur = a.layers[li].states[si].fade
	if dur <= 0 {
		for &st, i in lr.states {
			st.fade_dur = 0
			st.fade_target = i == si ? 1 : 0
			st.weight = st.fade_target
			if i == si {
				st.time = 0
				st.done = false
			}
			_ta_push_weight(a, li, &st)
		}
		return
	}
	for &st, i in lr.states {
		_ta_fade_start(&st, i == si ? 1 : 0, dur)
		if i != si do continue
		st.time = 0
		st.done = false
	}
}

// Silence every state. Timelines keep their playheads, and whatever was posed
// last stays posed — nothing rewinds and nothing is destroyed.
animator_stop :: proc(a: ^TimelineAnimator) {
	if !a.graph_ready do return
	for &lr, li in a.rt {
		for &st in lr.states {
			st.fade_dur = 0
			st.fade_target = 0
			st.weight = 0
			_ta_push_weight(a, li, &st)
		}
	}
}

// The leading state on a layer: the one carrying the most weight, its playhead
// as a fraction of its timeline, and whether a Once timeline has finished.
animator_state :: proc(a: ^TimelineAnimator, layer := 0) -> (s: State_Id, normalized: f32, done: bool) {
	s = STATE_ID_NONE
	if layer < 0 || layer >= len(a.rt) do return
	lr := &a.rt[layer]
	best := f32(0)
	bi := -1
	for &st, i in lr.states {
		if st.weight > best {
			best = st.weight
			bi = i
		}
	}
	if bi < 0 do return
	st := &lr.states[bi]
	s = _state_id(layer, bi)
	done = st.done
	if length := _ta_state_length(st); length > 0 do normalized = st.time / length
	return
}

// A layer's weight, applied to every output. Authored `weight` is the default
// this overrides until the next rebuild.
animator_layer_weight :: proc(a: ^TimelineAnimator, layer: int, w: f32) {
	if layer < 0 || layer >= len(a.rt) do return
	lr := &a.rt[layer]
	for m, oi in lr.mixers {
		o := graph_output(&a.graph, oi)
		if o == nil do continue
		playable_set_input_weight(&a.graph, o.root, m, w)
	}
	if layer < len(a.layers) do a.layers[layer].weight = w
}

// The state's timeline length, or 0 when it has no live director.
@(private = "file")
_ta_state_length :: proc(st: ^Animator_State_Runtime) -> f32 {
	w := engine.ctx_world()
	if w == nil || !engine.world_pool_valid(w, st.dir) do return 0
	d := cast(^seq.PlayableDirector)engine.world_pool_get(w, st.dir)
	if d == nil do return 0
	return seq.director_duration(d, seq.director_tracks(d))
}

// --- Authoring validation -------------------------------------------------------------
//
// Found once when the graph is built, not per frame. Authored data being wrong
// is not an invariant violation, so these are reported rather than fatal — but
// they are reported EARLY, because the alternative is a character that silently
// never moves.

Animator_Problem_Kind :: enum u8 {
	Unbound_Key,     // a track asks for a key `targets` does not bind
	Overlapping_Pose, // two bound targets pose the same transforms
}

Animator_Problem :: struct {
	kind: Animator_Problem_Kind,
	key:  string, // borrowed from the component's own data
}

// Whether `anc` is `h` or an ancestor of it.
@(private = "file")
_ta_is_ancestor :: proc(anc, h: engine.Transform_Handle) -> bool {
	w := engine.ctx_world()
	cur := h
	for i := 0; i < 256; i += 1 {
		if cur == anc do return true
		t := engine.pool_get(&w.transforms, engine.Handle(cur))
		if t == nil || t.parent.handle == {} do return false
		cur = engine.Transform_Handle(t.parent.handle)
	}
	return false
}

// Every key the animator's states ask for, and every pair of pose targets that
// would clobber each other. Allocates into `allocator`.
timeline_animator_problems :: proc(a: ^TimelineAnimator, allocator := context.temp_allocator) -> []Animator_Problem {
	out := make([dynamic]Animator_Problem, allocator)
	w := engine.ctx_world()

	// Keys asked for by a state's tracks but bound by nothing.
	for &lr in a.rt {
		for &st in lr.states {
			if st.root == {} || !engine.world_pool_valid(w, st.dir) do continue
			d := cast(^seq.PlayableDirector)engine.world_pool_get(w, st.dir)
			if d == nil do continue
			for &tv in seq.director_tracks(d) {
				_, tr := engine.transform_get_comp(tv.node, TrackAnimation)
				if tr == nil || tr.key == "" do continue
				if timeline_animator_output_for_key(a, tr.key) >= 0 do continue
				append(&out, Animator_Problem{kind = .Unbound_Key, key = tr.key})
			}
		}
	}

	// Two pose outputs whose subtrees overlap write the same transforms, and
	// the later apply wins. Checked between bound targets, since that is where
	// an author can see and fix it.
	for i in 0 ..< len(a.out_target) {
		oi := graph_output(&a.graph, i)
		if oi == nil do continue
		for j in i + 1 ..< len(a.out_target) {
			oj := graph_output(&a.graph, j)
			if oj == nil do continue
			overlaps := _ta_is_ancestor(oi.binding.owner, oj.binding.owner) ||
			            _ta_is_ancestor(oj.binding.owner, oi.binding.owner)
			if !overlaps do continue
			ti := a.out_target[j]
			if ti >= 0 && ti < len(a.targets) {
				append(&out, Animator_Problem{kind = .Overlapping_Pose, key = a.targets[ti].key})
			}
		}
	}
	return out[:]
}
