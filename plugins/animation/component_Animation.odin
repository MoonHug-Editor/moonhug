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

import "core:slice"
import "moonhug:engine"

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

// One child of a playing blend. `length` and `wrap` are cached at build time:
// the blended cycle rate reads one and the phase wrap the other every frame.
Anim_Blend_Child :: struct {
	clip:   engine.Asset_GUID,
	node:   Playable_Handle,
	pos:    f32,
	length: f32,
	wrap:   Animation_Wrap,
}

// A playing clip: its own clock, in seconds.
Clip_State :: struct {
	clip: engine.Asset_GUID,
	time: f32,
}

// A playing blend and its children. It runs on `phase`, a shared 0..1 position
// through the cycle, rather than on a clock in seconds: the children have
// different lengths, and sampling them at the same absolute seconds slides them
// out of step within a second or two.
Blend_State :: struct {
	kids:  [dynamic]Anim_Blend_Child,
	phase: f32,
}

// What a state IS, so neither kind carries the other's fields. Runtime only —
// never serialized, so no guid and no marshaler, unlike the authored
// Anim_Entry_Variant. #no_nil for the same reason that one is: the zero value
// has to be inert rather than a variant-less hole.
Animation_State_Kind :: union #no_nil {
	Clip_State,
	Blend_State,
}

// One playing state on a layer. `weight` moves linearly from `fade_from` toward
// `fade_target` over `fade_dur` seconds (real time, like Unity — fades ignore
// state speed). A Once state that ran past its end holds its final pose
// (`done`) until everything is done or something replaces it.
Animation_State_Runtime :: struct {
	entry:       i32, // authored entry, 0 for a clip played by guid
	node:        Playable_Handle, // clip node, or the blend's mixer
	kind:        Animation_State_Kind,
	weight:      f32,
	fade_from:   f32,
	fade_target: f32,
	fade_t:      f32,
	fade_dur:    f32, // 0 = not fading
	done:        bool,
}

// The clip a CLIP state plays. A blend has no clip of its own, so guid-keyed
// calls (play, cross_fade) never match one.
@(private = "file")
_anim_state_clip :: proc(st: ^Animation_State_Runtime) -> (engine.Asset_GUID, bool) {
	if c, is := &st.kind.(Clip_State); is do return c.clip, true
	return {}, false
}

// Rewind to the start, whichever clock the kind runs on.
@(private = "file")
_anim_state_rewind :: proc(st: ^Animation_State_Runtime) {
	switch &k in st.kind {
	case Clip_State:  k.time = 0
	case Blend_State: k.phase = 0
	}
	st.done = false
}

Animation_Layer_Runtime :: struct {
	mixer:      Playable_Handle,
	states:     [dynamic]Animation_State_Runtime,
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
	rt_layers:   [dynamic]Animation_Layer_Runtime `json:"-" inspect:"-"`, // playback state per layer
	graph_ready: bool `json:"-" inspect:"-"`,
}

// Anim_Entry_Variant's guid-tagged marshaler pair is registered through the
// generated unions_generated.odin: union_gen emits it for every union whose
// variants all carry @(typ_guid), so nothing here has to remember. The
// variants' pointer types come with their @(typ_guid).

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
			for &st in l.states {
				if b, is := &st.kind.(Blend_State); is do delete(b.kids)
			}
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
	a.rt_layers = make([dynamic]Animation_Layer_Runtime)
	graph_output(&a.graph).root = playable_add(&a.graph, Layer_Mixer_Playable{})
	a.graph_ready = true
}

// Layers are dense 0..idx so the root's input order IS the layer order.
@(private = "file")
_anim_layer :: proc(a: ^Animation, idx: int) -> ^Animation_Layer_Runtime {
	for len(a.rt_layers) <= idx {
		mixer := playable_add(&a.graph, Mixer_Playable{})
		playable_connect(&a.graph, graph_output(&a.graph).root, mixer, 1)
		append(&a.rt_layers, Animation_Layer_Runtime{mixer = mixer, states = make([dynamic]Animation_State_Runtime)})
	}
	return &a.rt_layers[idx]
}

// A clip played by guid and the same clip played through its authored entry are
// the SAME state: matching on both keys keeps a Play(guid) from stacking a
// second copy beside a running entry.
@(private = "file")
_anim_state_find :: proc(l: ^Animation_Layer_Runtime, clip: engine.Asset_GUID) -> int {
	for &st, i in l.states {
		if c, is := _anim_state_clip(&st); is && c == clip do return i
	}
	return -1
}

@(private = "file")
_anim_state_find_entry :: proc(l: ^Animation_Layer_Runtime, entry: i32) -> int {
	for &st, i in l.states {
		if st.entry == entry do return i
	}
	return -1
}

@(private = "file")
_anim_state_add :: proc(a: ^Animation, l: ^Animation_Layer_Runtime, clip: engine.Asset_GUID, weight: f32) -> ^Animation_State_Runtime {
	node := playable_add(&a.graph, Clip_Playable{clip = clip})
	playable_connect(&a.graph, l.mixer, node, weight)
	append(&l.states, Animation_State_Runtime{kind = Clip_State{clip = clip}, node = node, weight = weight})
	return &l.states[len(l.states) - 1]
}

// --- Tree to graph ------------------------------------------------------------------
//
// Every reader of the authored tree builds graph nodes through
// animation_entry_build: the driver when a state plays, the Playable Graph
// window and the scrub preview when they draw the authored shape. One builder,
// so all three agree on what the tree means — three hand-rolled copies drifted
// the moment blends arrived.

// One authored entry as graph nodes under `parent`. A clip is one leaf. A blend
// is a mixer with EVERY child leaf built at once — that is what makes a blend a
// single state with a single weight, and it is the one place the authored tree
// and the graph differ in shape.
//
// `weight` is the entry's own input weight under `parent`, `kid_w` the weight of
// a blend's children under its mixer (the driver passes 0 and lets the 1D rule
// set them each tick). Every clip leaf built is appended to `leaves`, a blend's
// sorted by position so the 1D rule can walk neighbours whatever order they
// were authored in.
//
// Nested blends are not built: a child that is itself a blend is skipped rather
// than flattened, so the graph never silently means something other than the
// tree. Returns 0 when nothing was built.
animation_entry_build :: proc(
	a: ^Animation, g: ^Playable_Graph, li: int, id: i32,
	parent: Playable_Handle, weight, kid_w: f32,
	leaves: ^[dynamic]Anim_Blend_Child,
) -> (node: Playable_Handle, is_blend: bool) {
	_, e := _anim_entry_find(a, id)
	if e == nil do return {}, false

	switch v in e.variant {
	case Clip_Entry:
		if v.clip == {} do return {}, false
		node = playable_add(g, Clip_Playable{clip = v.clip})
		playable_connect(g, parent, node, weight)
		length, wrap := _anim_clip_info(v.clip)
		append(leaves, Anim_Blend_Child{clip = v.clip, node = node, length = length, wrap = wrap})
		return node, false

	case Blend1D_Entry:
		node = playable_add(g, Mixer_Playable{})
		playable_connect(g, parent, node, weight)
		first := len(leaves)
		for &kid in a.layers[li].entries {
			if kid.parent != id do continue
			ce, is_clip := kid.variant.(Clip_Entry)
			if !is_clip || ce.clip == {} do continue
			leaf := playable_add(g, Clip_Playable{clip = ce.clip})
			playable_connect(g, node, leaf, kid_w)
			length, wrap := _anim_clip_info(ce.clip)
			append(leaves, Anim_Blend_Child{clip = ce.clip, node = leaf, pos = kid.pos.x, length = length, wrap = wrap})
		}
		slice.sort_by((leaves^)[first:], proc(x, y: Anim_Blend_Child) -> bool {
			return x.pos < y.pos
		})
		return node, true
	}
	return {}, false
}

// What a blend child needs from its clip, read once at build.
@(private = "file")
_anim_clip_info :: proc(clip: engine.Asset_GUID) -> (length: f32, wrap: Animation_Wrap) {
	if c, ok := animation_clip_load(clip); ok do return max(c.length, PLAYABLE_WEIGHT_EPS), c.wrap
	return 1, .Loop
}

// A clip leaf of the full authored graph, where it hangs, and everything the 1D
// rule needs — `child` is exactly what a playing blend holds, so a preview can
// weight a blend it built itself through animation_blend1d_weights.
Authored_Leaf :: struct {
	using child: Anim_Blend_Child, // clip, node, pos, length, wrap
	entry: i32,             // the TOP-LEVEL entry it belongs to, 0 for the default clip
	under: Playable_Handle, // its parent: a blend's mixer, or the layer mixer
	top:   Playable_Handle, // what hangs from the layer mixer: that blend mixer, or the clip node
	layer: Playable_Handle, // the layer mixer
}

// The FULL authored shape into an empty `g`, every state present whether it
// plays or not: layer mixer root, one mixer per layer (at least layer 0), the
// default `clip` on layer 0 unless an entry there already names it, then every
// top-level entry through animation_entry_build. Layer inputs are 1, entries
// and blend children get `w`.
//
// The Playable Graph window draws this when nothing is playing, and the scrub
// preview evaluates it. The driver builds the same nodes through the same
// primitive, only for the states that play.
animation_graph_build_authored :: proc(a: ^Animation, g: ^Playable_Graph, owner: engine.Transform_Handle, w: f32, leaves: ^[dynamic]Authored_Leaf = nil) {
	playable_graph_init(g)
	graph_output_add(g, owner)
	root := playable_add(g, Layer_Mixer_Playable{})
	graph_output(g).root = root

	kids := make([dynamic]Anim_Blend_Child, context.temp_allocator)
	n_layers := max(len(a.layers), 1)
	for li in 0 ..< n_layers {
		mixer := playable_add(g, Mixer_Playable{})
		playable_connect(g, root, mixer, 1)

		if li == 0 && a.clip != {} && !_anim_layer_names_clip(a, 0, a.clip) {
			node := playable_add(g, Clip_Playable{clip = a.clip})
			playable_connect(g, mixer, node, w)
			if leaves != nil {
				length, wrap := _anim_clip_info(a.clip)
				append(leaves, Authored_Leaf{
					child = {clip = a.clip, node = node, length = length, wrap = wrap},
					under = mixer, top = node, layer = mixer,
				})
			}
		}
		if li >= len(a.layers) do continue

		for &e in a.layers[li].entries {
			if e.parent != 0 do continue
			clear(&kids)
			top, is_blend := animation_entry_build(a, g, li, e.id, mixer, w, w, &kids)
			if top == {} || leaves == nil do continue
			for k in kids {
				append(leaves, Authored_Leaf{
					child = k, entry = e.id,
					under = is_blend ? top : mixer, top = top, layer = mixer,
				})
			}
		}
	}
}

// Whether a top-level clip entry on layer `li` names `clip`.
@(private = "file")
_anim_layer_names_clip :: proc(a: ^Animation, li: int, clip: engine.Asset_GUID) -> bool {
	if li >= len(a.layers) do return false
	for &e in a.layers[li].entries {
		if e.parent != 0 do continue
		if c, is_clip := e.variant.(Clip_Entry); is_clip && c.clip == clip do return true
	}
	return false
}

// Add a playing state for an authored entry. Returns its index, or -1 when the
// entry produced nothing.
@(private = "file")
_anim_state_add_entry :: proc(a: ^Animation, l: ^Animation_Layer_Runtime, li: int, id: i32, weight: f32) -> int {
	kids := make([dynamic]Anim_Blend_Child)
	node, is_blend := animation_entry_build(a, &a.graph, li, id, l.mixer, weight, 0, &kids)
	if node == {} {
		delete(kids)
		return -1
	}
	st := Animation_State_Runtime{entry = id, node = node, weight = weight}
	if is_blend {
		st.kind = Blend_State{kids = kids}
	} else {
		st.kind = Clip_State{clip = kids[0].clip}
		delete(kids)
	}
	append(&l.states, st)
	return len(l.states) - 1
}

@(private = "file")
_anim_state_remove :: proc(a: ^Animation, l: ^Animation_Layer_Runtime, i: int) {
	st := &l.states[i]
	if b, is := &st.kind.(Blend_State); is {
		for &k in b.kids do playable_remove(&a.graph, k.node)
		delete(b.kids)
	}
	playable_remove(&a.graph, st.node)
	ordered_remove(&l.states, i)
}

@(private = "file")
_anim_fade_start :: proc(st: ^Animation_State_Runtime, target, duration: f32) {
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
		if c, is := _anim_state_clip(&l.states[i]); !is || c != clip do _anim_state_remove(a, l, i)
	}
	st: ^Animation_State_Runtime
	if i := _anim_state_find(l, clip); i >= 0 do st = &l.states[i]
	if st == nil do st = _anim_state_add(a, l, clip, 1)
	_anim_state_rewind(st)
	st.weight = 1
	st.fade_dur = 0
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

	// A cut removes every other state FIRST, so whatever survives is found or
	// added afterwards and no index has to be tracked across removals — the
	// same order animation_play_clip uses.
	if duration <= 0 {
		for j := len(l.states) - 1; j >= 0; j -= 1 {
			if l.states[j].entry != id do _anim_state_remove(a, l, j)
		}
	}

	i := _anim_state_find_entry(l, id)
	if i < 0 do i = _anim_state_add_entry(a, l, li, id, duration > 0 ? 0 : 1)
	if i < 0 do return

	st := &l.states[i]
	_anim_state_rewind(st)
	if duration <= 0 {
		st.weight = 1
		st.fade_dur = 0
	} else {
		for &other, j in l.states {
			if j != i do _anim_fade_start(&other, 0, duration)
		}
		_anim_fade_start(st, 1, duration)
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
	target: ^Animation_State_Runtime
	for &st in l.states {
		if c, is := _anim_state_clip(&st); is && c == clip {
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
_anim_blend_advance :: proc(a: ^Animation, st: ^Animation_State_Runtime, b: ^Blend_State, dt: f32) -> bool {
	if len(b.kids) == 0 do return false

	_, e := _anim_entry_find(a, st.entry)
	if e == nil do return false
	value := f32(0)
	if v, ok := &e.variant.(Blend1D_Entry); ok do value = v.value

	cycle := animation_blend1d_weights(&a.graph, st.node, b.kids[:], value)
	if cycle <= 0 do return false

	// Wrap follows the first child's clip, the same "defer to the clip" rule a
	// single-clip state uses — a blend has no clip of its own to ask. Cached on
	// the child at build, like its length.
	wrap := _anim_wrap(a, b.kids[0].wrap)

	if !st.done do b.phase += dt * a.speed / cycle
	p, done := animation_wrap_time(b.phase, 1, wrap)
	if done do st.done = true

	animation_blend_sample(&a.graph, b.kids[:], p)
	return true
}

// Sample every child of a blend at one normalized phase. The editor's preview
// drives a blend through this and the weights proc without a playing state.
animation_blend_sample :: proc(g: ^Playable_Graph, kids: []Anim_Blend_Child, phase: f32) {
	for &k in kids {
		if node := playable_node(g, k.node); node != nil do node.time = phase * k.length
	}
}

// The 1D rule: the two children bracketing `value` share the weight, the ends
// clamp. Returns the blended cycle length, which is what the phase advances
// against. `kids` must be sorted by position — animation_entry_build does that.
//
// Takes a graph and a mixer rather than a playing state, so the editor's
// preview weights a blend it built itself the same way the driver does.
animation_blend1d_weights :: proc(g: ^Playable_Graph, mixer: Playable_Handle, kids: []Anim_Blend_Child, value: f32) -> f32 {
	if len(kids) == 0 do return 0
	for &k in kids do playable_set_input_weight(g, mixer, k.node, 0)

	last := len(kids) - 1
	if value <= kids[0].pos {
		playable_set_input_weight(g, mixer, kids[0].node, 1)
		return kids[0].length
	}
	if value >= kids[last].pos {
		playable_set_input_weight(g, mixer, kids[last].node, 1)
		return kids[last].length
	}
	for i in 0 ..< last {
		lo, hi := kids[i], kids[i + 1]
		if value < lo.pos || value > hi.pos do continue
		span := hi.pos - lo.pos
		k := span > 0 ? (value - lo.pos) / span : 0
		playable_set_input_weight(g, mixer, lo.node, 1 - k)
		playable_set_input_weight(g, mixer, hi.node, k)
		return lo.length + (hi.length - lo.length) * k
	}
	return kids[0].length
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

			advanced := false
			switch &k in st.kind {
			case Blend_State:
				advanced = _anim_blend_advance(a, st, &k, dt)
			case Clip_State:
				if clip, ok := animation_clip_load(k.clip); ok {
					if !st.done do k.time += dt * a.speed
					t, done := animation_wrap_time(k.time, clip.length, _anim_wrap(a, clip.wrap))
					if done do st.done = true
					if node := playable_node(&a.graph, st.node); node != nil do node.time = t
					advanced = true
				}
			}
			// Nothing to sample this frame (a clip that will not load, a blend
			// with no children): leave the state alone rather than weighting a
			// node that holds no pose.
			if !advanced {
				i += 1
				continue
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
			if st.weight <= lead_w do continue
			lead_w = st.weight
			// A blend has no clock in seconds, so its normalized phase stands
			// in. This field is for inspection only.
			switch k in st.kind {
			case Clip_State:  a.time = k.time
			case Blend_State: a.time = k.phase
			}
		}
	}
	// Every state done (Once clips at their ends): freeze — the final pose was
	// just applied and nothing overwrites it. Matches the pre-graph runtime.
	if all_done do a.playing = false
}
