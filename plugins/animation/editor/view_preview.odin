package animation_editor

// The Animation window's scrub preview in the main loop: the graph built from
// the component's authored states, the pose applied before the scene and game
// views render and restored after, and the preview of an authored state from
// the inspector's States tree.

import im "moonhug:external/odin-imgui"
import engine "moonhug:packages/engine"
import anim "moonhug:packages/animation"

// The scrub graph's single output binding.
@(private = "file")
_pv_binding :: proc() -> ^anim.Animation_Binding {
	o := anim.graph_output(&_pv.graph)
	return o != nil ? &o.binding : nil
}

// The scrub preview's live graph, for the Playable Graph visualizer — nil
// unless the preview is on for `owner` and its graph exists.
@(private)
_pv_preview_graph :: proc(owner: engine.Transform_Handle) -> ^anim.Playable_Graph {
	if !_pv.active || !_pv.ready || _pv.owner != owner do return nil
	return &_pv.graph
}

// --- Preview apply/restore (main loop hooks) --------------------------------------------

// A fingerprint of the component's authored state tree, so the preview graph
// rebuilds when it is edited while previewing.
@(private = "file")
_pv_authored_sig :: proc(a: ^anim.Animation) -> u64 {
	sig := u64(0xcbf29ce484222325)
	_pv_sig_mix(&sig, a.clip)
	for &l in a.layers {
		sig ~= 0x9e37
		for &e in l.entries {
			// Structure too, not just the clip set: moving a clip into a blend
			// changes the graph's shape without changing which clips it holds.
			sig = (sig ~ u64(u32(e.id))) * 0x100000001b3
			sig = (sig ~ u64(u32(e.parent))) * 0x100000001b3
			if c, is_clip := e.kind.(anim.Animation_Entry_Clip); is_clip do _pv_sig_mix(&sig, c.clip)
		}
	}
	return sig
}

// A fingerprint of the clip's rows: which fields they drive and in which
// lanes, what the binding is built from.
@(private = "file")
_pv_rows_sig :: proc(clip: ^anim.AnimationClip) -> u64 {
	sig := u64(0xcbf29ce484222325)
	for &ch in clip.channels {
		for s in ([]string{ch.target, ch.component, ch.field}) {
			for b in transmute([]u8)s do sig = (sig ~ u64(b)) * 0x100000001b3
			sig = (sig ~ 0xff) * 0x100000001b3
		}
		sig = (sig ~ u64(ch.path)) * 0x100000001b3
		for l in 0 ..< 4 do if l in ch.lanes_off do sig = (sig ~ u64(0x10 + l)) * 0x100000001b3
	}
	return sig
}

@(private = "file")
_pv_sig_mix :: proc(sig: ^u64, g: engine.PPtr) {
	// Asset_GUID is a distinct [16]u8: transmute, not cast — an array type
	// conversion is not a cast in Odin.
	bytes := transmute([16]u8)g.guid
	for b in bytes do sig^ = (sig^ ~ u64(b)) * 0x100000001b3
	sig^ = (sig^ ~ u64(g.local_id)) * 0x100000001b3
}

// The scrub preview evaluates the component's FULL authored graph — every
// state, blend children under their blend's mixer — with the scrubbed clip at
// weight 1 and everything else at 0. The zero-weight nodes cost nothing (the
// evaluator skips them) and change nothing in the pose, and because the graph
// comes from the same builder the driver uses, the Playable Graph window shows
// the topology the component actually plays, with live weights.
//
// A clip inside a blend is lit along its whole chain: the clip under the
// blend's mixer, and that mixer under the layer mixer. Lighting only the leaf
// would leave its blend at 0 under the layer, and nothing would reach the pose.
@(private = "file")
_pv_build_graph :: proc(a: ^anim.Animation) {
	leaves := make([dynamic]anim.Animation_Authored_Leaf, context.temp_allocator)
	anim.animation_graph_build_authored(a, &_pv.graph, _pv.owner, 0, &leaves)
	_pv.node = {}

	if _pv.entry != 0 {
		// A state lights its whole chain: for a blend that is its mixer under
		// the layer, with the 1D rule weighting the children every frame.
		if _pv.entry_kids == nil do _pv.entry_kids = make([dynamic]anim.Animation_Blend_Child)
		clear(&_pv.entry_kids)
		for l in leaves {
			if l.entry != _pv.entry do continue
			_pv.entry_top, _pv.entry_layer = l.top, l.layer
			append(&_pv.entry_kids, l.child)
		}
		if _pv.entry_top != {} {
			anim.playable_set_input_weight(&_pv.graph, _pv.entry_layer, _pv.entry_top, 1)
			// A clip state IS its node, so light it under the layer directly.
			// A blend's children are weighted per frame by the 1D rule.
			if len(_pv.entry_kids) == 1 && _pv.entry_kids[0].node == _pv.entry_top {
				_pv.node = _pv.entry_top
			}
		}
		_pv.graph_sig = _pv_authored_sig(a)
		_pv.ready = true
		return
	}

	for l in leaves {
		if l.clip != _pv.clip do continue
		_pv.node = l.node
		anim.playable_set_input_weight(&_pv.graph, l.under, l.node, 1)
		anim.playable_set_input_weight(&_pv.graph, l.layer, l.top, 1)
		break
	}
	_pv.graph_sig = _pv_authored_sig(a)
	_pv.ready = true
}

// Advance the previewed state and write its times into the graph. A blend runs
// on a shared phase at the blended cycle length, exactly as it does when the
// driver plays it — the same two procs do the work in both places.
@(private = "file")
_pv_entry_tick :: proc(a: ^anim.Animation, dt: f32) {
	if _pv.entry_top == {} || len(_pv.entry_kids) == 0 do return

	// A single clip whose node IS the top: an ordinary clip state.
	if _pv.node != {} {
		k := _pv.entry_kids[0]
		if !_pv.entry_done do _pv.entry_clock += dt
		t, done := anim.animation_wrap_time(_pv.entry_clock, k.length, k.wrap)
		if done do _pv.entry_done = true
		if n := anim.playable_node(&_pv.graph, _pv.node); n != nil do n.time = t
		return
	}

	value := anim.animation_blend_get(a, _pv.entry)
	cycle := anim.animation_blend1d_weights(&_pv.graph, _pv.entry_top, _pv.entry_kids[:], value)
	if cycle <= 0 do return
	if !_pv.entry_done do _pv.entry_clock += dt / cycle
	p, done := anim.animation_wrap_time(_pv.entry_clock, 1, _pv.entry_kids[0].wrap)
	if done do _pv.entry_done = true
	anim.animation_blend_sample(&_pv.graph, _pv.entry_kids[:], p)
}

// Apply the preview pose for this frame's scene/game render. Runs in the main
// loop after the window UI set the scrub state, right before the world renders.
animation_preview_apply :: proc() {
	if !_pv.active do return
	w := engine.ctx_world()
	if !engine.pool_valid(&w.transforms, engine.Handle(_pv.owner)) do _pv_preview_off()
	if _pv.entry == 0 && _pv.clip == {} do _pv_preview_off()
	if !_pv.active {
		_pv_preview_off()
		return
	}
	_, a := engine.transform_get_comp(_pv.owner, anim.Animation)
	if a == nil {
		_pv_preview_off()
		return
	}

	clip: ^anim.AnimationClip
	if _pv.entry == 0 {
		c, ok := anim.animation_clip_load(_pv.clip)
		if !ok do return
		clip = c
	}

	if _pv.ready && _pv.graph_sig != _pv_authored_sig(a) do _pv_teardown()
	// The binding takes each row's lanes when the graph binds: a row added,
	// removed or with a lane toggled since then rebinds, or the pose and its
	// restore would keep writing lanes the clip no longer drives.
	if _pv.ready && clip != nil && _pv.rows_sig != _pv_rows_sig(clip) do _pv_teardown()
	if !_pv.ready {
		_pv_build_graph(a)
		if clip != nil do _pv.rows_sig = _pv_rows_sig(clip)
	}

	if _pv.entry != 0 {
		_pv_entry_tick(a, im.GetIO().DeltaTime)
	} else if n := anim.playable_node(&_pv.graph, _pv.node); n != nil {
		n.time = clamp(_pv.time, 0, clip.length)
	}

	anim.animation_binding_refresh_defaults(_pv_binding())
	anim.playable_graph_tick(&_pv.graph)
	_pv.applied = true
}

// Restore the authored pose after the scene/game render. The world spends the
// rest of the frame — saves, undo, inspector — at authored values.
animation_preview_restore :: proc() {
	if !_pv.applied do return
	_pv.applied = false
	anim.animation_binding_write_defaults(_pv_binding())
}

// --- Previewing an authored STATE (the inspector's States tree) -------------
//
// The tree plays a state in edit mode through the window's preview rather than
// its own: one preview means one poser, so a scrub and a state can never fight
// over the same object. Entering state mode ends any scrub, and picking a clip
// in the window ends the state.

// Play an authored state on `owner` in edit mode, from its start.
preview_play_entry :: proc(owner: engine.Transform_Handle, id: i32) {
	if _pv.owner != owner {
		_pv_deselect_all()
		_pv.owner = owner
		_pv.clip = {}
	}
	_pv_teardown()
	_pv.entry = id
	_pv.entry_clock = 0
	_pv.entry_done = false
	_pv.playing = false // the transport drives the clip scrub, not this
	_pv.active = true
}

// The state being previewed on `owner`, or 0.
preview_entry :: proc(owner: engine.Transform_Handle) -> i32 {
	if !_pv.active || _pv.owner != owner do return 0
	return _pv.entry
}

preview_stop_entry :: proc() {
	if _pv.entry == 0 do return
	_pv_preview_off()
	_pv_teardown()
}
