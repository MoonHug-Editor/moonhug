package animation

// Unity's LEGACY Animation component, complete: N layers of M clips playing on
// this transform's hierarchy through a PlayableGraph (playable_graph.odin,
// docs/PlayableGraph.md) — play, cross-fade, queued play, per-layer stacking.
// Still no state machines: animation logic is ordinary gameplay code calling
// this API.
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

import "moonhug:engine"

// Unity's component-level WrapMode: Default defers to the clip's own wrap.
Animation_Wrap_Mode :: enum u8 {
	Default,
	Once,
	Loop,
}

// One AUTHORED layer: the clips gameplay plays on it. Purely declarative —
// clips do not start by themselves (only `clip` + play_automatically does
// that). Listing a clip here lets the play/cross_fade API resolve its layer,
// so call sites can omit the layer argument.
Animation_Layer :: struct {
	clips: [dynamic]engine.Asset_GUID `ext:"anim"`,
}

// One playing clip on a layer. `weight` moves linearly from `fade_from` toward
// `fade_target` over `fade_dur` seconds (real time, like Unity — fades ignore
// state speed). A Once clip that ran past its end holds its final pose
// (`done`) until everything is done or something replaces it.
Anim_State :: struct {
	clip:        engine.Asset_GUID,
	node:        Playable_Handle,
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

@(component)
@(typ_guid={guid = "5b8c2f4e-1d3a-4e6b-8f90-7a2c4d6e8b13"})
Animation :: struct {
	using base:         engine.CompData `inspect:"-"`,
	clip:               engine.Asset_GUID `ext:"anim"`,
	play_automatically: bool,
	wrap_mode:          Animation_Wrap_Mode,
	speed:              f32,
	// Authored layers, each holding the clips gameplay plays on it. The layer
	// index in this list is the runtime layer index — higher overrides lower
	// where it animates. play/cross_fade called without a layer resolve the
	// clip's layer here (unlisted clips land on layer 0).
	layers:             [dynamic]Animation_Layer,

	time:    f32 `json:"-" inspect:"-"`, // layer 0's leading state, for inspection
	playing: bool `json:"-" inspect:"-"`,
	started: bool `json:"-" inspect:"-"`, // play_automatically consumed on first tick

	graph:       Playable_Graph `json:"-" inspect:"-"`,
	binding:     Animation_Binding `json:"-" inspect:"-"`,
	rt_layers:   [dynamic]Anim_Layer `json:"-" inspect:"-"`, // playback state per layer
	graph_ready: bool `json:"-" inspect:"-"`,
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
// The runtime side (`graph`, `binding`, `rt_layers`) is guarded by graph_ready:
// it is built lazily by _anim_ensure_graph, so a component that never ticked has
// none of it, and freeing unconditionally would delete arrays that were never
// made. engine.comp_zero at the end clears graph_ready along with every freed pointer,
// which is what makes a second call safe — the guards all read false and the
// nil checks all short-circuit.
cleanup_Animation :: proc(a: ^Animation) {
	if a.graph_ready {
		playable_graph_destroy(&a.graph)
		animation_binding_destroy(&a.binding)
		for &l in a.rt_layers do delete(l.states)
		delete(a.rt_layers)
	}
	if a.layers != nil {
		for &l in a.layers do delete(l.clips)
		delete(a.layers)
	}
	engine.comp_zero(a)
}

// The layer a clip is authored on, for calls that do not pass one explicitly.
@(private = "file")
_anim_layer_of :: proc(a: ^Animation, clip: engine.Asset_GUID, layer: int) -> int {
	if layer >= 0 do return layer
	for &l, li in a.layers {
		for c in l.clips {
			if c == clip do return li
		}
	}
	return 0
}

// --- Graph bookkeeping --------------------------------------------------------------

@(private = "file")
_anim_ensure_graph :: proc(a: ^Animation) {
	if a.graph_ready do return
	playable_graph_init(&a.graph)
	animation_binding_init(&a.binding, a.owner)
	a.rt_layers = make([dynamic]Anim_Layer)
	a.graph.root = playable_add(&a.graph, Layer_Mixer_Playable{})
	a.graph_ready = true
}

// Layers are dense 0..idx so the root's input order IS the layer order.
@(private = "file")
_anim_layer :: proc(a: ^Animation, idx: int) -> ^Anim_Layer {
	for len(a.rt_layers) <= idx {
		mixer := playable_add(&a.graph, Mixer_Playable{})
		playable_connect(&a.graph, a.graph.root, mixer, 1)
		append(&a.rt_layers, Anim_Layer{mixer = mixer, states = make([dynamic]Anim_State)})
	}
	return &a.rt_layers[idx]
}

@(private = "file")
_anim_state_find :: proc(l: ^Anim_Layer, clip: engine.Asset_GUID) -> int {
	for &st, i in l.states {
		if st.clip == clip do return i
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

@(private = "file")
_anim_state_remove :: proc(a: ^Animation, l: ^Anim_Layer, i: int) {
	playable_remove(&a.graph, l.states[i].node)
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

			clip, ok := animation_clip_load(st.clip)
			if !ok {
				i += 1
				continue
			}
			if !st.done do st.time += dt * a.speed
			wrap := clip.wrap
			#partial switch a.wrap_mode {
			case .Once: wrap = .Once
			case .Loop: wrap = .Loop
			}
			t, done := animation_wrap_time(st.time, clip.length, wrap)
			if done do st.done = true

			if node := playable_node(&a.graph, st.node); node != nil do node.time = t
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

	pose := playable_graph_evaluate(&a.graph, &a.binding)
	animation_pose_apply(&a.binding, pose)

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
