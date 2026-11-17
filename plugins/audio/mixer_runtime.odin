package audio

// How an Audio Mixer plays (mixer.odin is the asset):
//
// - A mixer is loaded on first use, and each of its groups is a node here.
//   A node gets an SDL3_mixer group the first time a track is routed to it,
//   and the tracks routed there are mixed into that group.
// - A group's callback gets its tracks mixed together and runs its chain on
//   them: the group's volume and effects, then its parent's, up to the Master.
//   A filter or a gain on the sum of the children is the same as on each
//   child, so each SDL group carries the whole path with its own filter
//   state, and the parents need no SDL group of their own.
// - After each stage of a node the loudest sample is kept, its level, which
//   meters read and a Duck listens to. Once per mix pass, after every group
//   (the mixer's post-mix callback), the levels fall back and each Duck
//   moves its gain toward the level of the group it listens to.
// - The callbacks run on the audio thread, inside the mixer's lock. The main
//   thread changes what they read only while it holds that lock.
//
// The runtime volume of a group (mixer_set_volume) is kept apart from the
// asset: it lasts until play stops, and an edit of the asset keeps it.

import "base:runtime"
import "core:c"
import "core:math"
import sdl "vendor:sdl3"
import mix "vendor:sdl3/mixer"
import engine "moonhug:packages/engine"

@(private)
_Node :: struct {
	id:           i64,
	parent:       ^_Node,
	volume:       f32, // dB, the asset's
	override:     f32, // dB, set by mixer_set_volume when has_override
	has_override: bool,
	mute:         bool,
	gain:         f32, // what the volume stage multiplies by
	effects:      [dynamic]_Fx,
	// This node's stages, then each parent's: what its SDL group runs.
	chain:        [dynamic]_Stage,
	group:        ^mix.Group,
	// Audio thread: the loudest sample this pass after the node's stages,
	// and that level held with a fall.
	peak:         f32,
	level:        f32,
}

@(private)
_Fx_Kind :: enum u8 {
	Low_Pass,
	High_Pass,
	Duck,
}

@(private)
_Fx :: struct {
	kind:      _Fx_Kind,
	// Low_Pass, High_Pass: what the coefficients are made from, at the
	// mixer's rate.
	cutoff:    f32,
	q:         f32,
	coeffs:    Biquad_Coeffs,
	// Duck:
	by:        ^_Node,
	threshold: f32,
	ratio:     f32,
	attack:    f32, // seconds
	release:   f32,
	gain:      f32, // where the duck is now, audio thread
}

// The volume of `node`, one of its effects, or its level, on one SDL group's
// path. A filter keeps its state per stage.
@(private)
_Stage :: struct {
	node:  ^_Node,
	what:  int, // _STAGE_VOLUME, _STAGE_LEVEL, or an effect's index
	state: Biquad_State,
}

@(private)
_STAGE_VOLUME :: -1
@(private)
_STAGE_LEVEL :: -2

@(private)
_Mixer :: struct {
	guid:  engine.Asset_GUID,
	nodes: [dynamic]^_Node, // the asset's order, Master first
	rate:  f32, // the mix rate its filters were made for
}

// Every mixer loaded, default allocator. The audio thread walks it.
@(private)
_mixers: [dynamic]^_Mixer

@(private)
_post_mix_installed: ^mix.Mixer

// Goes up each time a group is destroyed, and the tracks routed to it play
// straight to the output: a source routed before then routes again.
@(private)
_route_gen: u64

// Routes `track` through the group `output` names: a group of an Audio
// Mixer, its file's guid and the group's id. Unset, or a group that is not
// there, plays the track straight to the output.
mixer_route :: proc(track: ^mix.Track, output: engine.PPtr) -> bool {
	if track == nil || !_mixer_ensure() do return false
	n := _node_of(output)
	if n == nil {
		_ = mix.SetTrackGroup(track, nil)
		return output == {}
	}
	_ensure_post_mix()
	if n.group == nil {
		n.group = mix.CreateGroup(_audio_state.mixer)
		if n.group == nil do return false
		_ = mix.SetGroupPostMixCallback(n.group, transmute(mix.GroupMixCallback)_group_mix, n)
	}
	return bool(mix.SetTrackGroup(track, n.group))
}

// Sets the volume of the group `group` names, in dB, while the game runs.
// The asset keeps its own: play stopping, or mixer_clear_volumes, goes back
// to it.
mixer_set_volume :: proc(group: engine.PPtr, db: f32) {
	n := _node_of(group)
	if n == nil do return
	_lock()
	defer _unlock()
	n.override = db
	n.has_override = true
	_node_gain(n)
}

// The volume of the group `group` names, in dB: the one set while the game
// runs, else the asset's. 0 for a group that is not there.
mixer_volume :: proc(group: engine.PPtr) -> f32 {
	n := _node_of(group)
	if n == nil do return 0
	return n.has_override ? n.override : n.volume
}

// Every group back to its asset's volume.
mixer_clear_volumes :: proc() {
	_lock()
	defer _unlock()
	for mx in _mixers do for n in mx.nodes {
		n.has_override = false
		_node_gain(n)
	}
}

// How loud the group `group` names plays now, in dB after its volume and
// effects: -80 for silence or a group that is not there.
mixer_level :: proc(group: engine.PPtr) -> f32 {
	n := _node_of(group)
	if n == nil do return -80
	_lock()
	defer _unlock()
	return gain_to_db(n.level)
}

// Editor: an open mixer's values replace the loaded ones, so an edit is
// heard at once, saved or not.
mixer_preview :: proc(guid: engine.Asset_GUID, m: ^AudioMixer) {
	_mixer_apply(_mixer_find(guid, create = true), m)
}

// The file of a loaded mixer changed: it is read again. A mixer removed
// plays no more, its tracks go straight to the output.
@(asset_on_changed={ext = "mixer"})
asset_on_changed_audio_mixer :: proc(guid: engine.Asset_GUID, path: string, change: engine.Asset_Change) {
	mx := _mixer_find(guid, create = false)
	if mx == nil do return
	if change == .Removed {
		_mixer_drop(mx)
		return
	}
	if m, ok := engine.asset_load_as(guid, AudioMixer); ok {
		_mixer_apply(mx, &m)
		type_cleanup_AudioMixer(&m)
	}
}

// Every mixer dropped, its SDL groups destroyed. Tests start from nothing.
mixer_runtime_reset :: proc() {
	for len(_mixers) > 0 do _mixer_drop(_mixers[len(_mixers) - 1])
}

@(phase={key=ExitingPlayMode})
audio_mixer_exiting_play_mode :: proc() {
	mixer_clear_volumes()
}

// --- Loading -----------------------------------------------------------------

@(private)
_node_of :: proc(ref: engine.PPtr) -> ^_Node {
	if ref.guid == {} || ref.local_id == 0 do return nil
	mx := _mixer_find(ref.guid, create = false)
	if mx == nil {
		m, ok := engine.asset_load_as(ref.guid, AudioMixer)
		if !ok do return nil
		mx = _mixer_find(ref.guid, create = true)
		_mixer_apply(mx, &m)
		type_cleanup_AudioMixer(&m)
	}
	// Made before the device opened, at another rate.
	if rate := _mix_rate(); mx.rate != rate {
		_lock()
		defer _unlock()
		mx.rate = rate
		for n in mx.nodes do for &fx in n.effects do _fx_coeffs(&fx, rate)
	}
	for n in mx.nodes do if n.id == i64(ref.local_id) do return n
	return nil
}

@(private)
_mixer_find :: proc(guid: engine.Asset_GUID, create: bool) -> ^_Mixer {
	for mx in _mixers do if mx.guid == guid do return mx
	if !create do return nil
	context.allocator = runtime.default_allocator()
	mx := new(_Mixer)
	mx.guid = guid
	_lock()
	defer _unlock()
	append(&_mixers, mx)
	return mx
}

@(private)
_mixer_drop :: proc(mx: ^_Mixer) {
	context.allocator = runtime.default_allocator()
	_lock()
	defer _unlock()
	for n in mx.nodes do _node_free(n)
	delete(mx.nodes)
	for x, i in _mixers do if x == mx {
		ordered_remove(&_mixers, i)
		break
	}
	free(mx)
}

@(private)
_node_free :: proc(n: ^_Node) {
	// Its tracks go straight to the output.
	if n.group != nil {
		mix.DestroyGroup(n.group)
		_route_gen += 1
	}
	delete(n.effects)
	delete(n.chain)
	free(n)
}

// Makes the loaded mixer `mx` what `m` says. Groups that stay keep their
// node, their SDL group and their tracks. When no group or effect came or
// went, the filters keep their state, so a value dragged in the inspector
// plays on without a click.
@(private)
_mixer_apply :: proc(mx: ^_Mixer, m: ^AudioMixer) {
	context.allocator = runtime.default_allocator()
	rate := _mix_rate()
	_lock()
	defer _unlock()
	mx.rate = rate

	same := len(mx.nodes) == len(m.groups)
	if same do for g, i in m.groups {
		n := mx.nodes[i]
		parent_id: i64 = n.parent != nil ? n.parent.id : 0
		if n.id != g.id || parent_id != g.parent || len(n.effects) != len(g.effects) {
			same = false
			break
		}
		for e, k in g.effects do if _fx_kind(e) != n.effects[k].kind {
			same = false
			break
		}
		if !same do break
	}

	if !same {
		nodes := make([dynamic]^_Node, 0, len(m.groups))
		for g in m.groups {
			n: ^_Node
			for x, i in mx.nodes do if x != nil && x.id == g.id {
				n = x
				mx.nodes[i] = nil
				break
			}
			if n == nil {
				n = new(_Node)
				n.id = g.id
			}
			append(&nodes, n)
		}
		for x in mx.nodes do if x != nil do _node_free(x)
		delete(mx.nodes)
		mx.nodes = nodes
		for n, i in mx.nodes {
			n.parent = nil
			for p in mx.nodes do if p.id == m.groups[i].parent && p != n do n.parent = p
			resize(&n.effects, len(m.groups[i].effects))
			for &fx in n.effects do fx = {gain = 1}
		}
	}

	for n, i in mx.nodes {
		g := &m.groups[i]
		n.volume = g.volume
		n.mute = g.mute
		_node_gain(n)
		for e, k in g.effects {
			fx := &n.effects[k]
			fx.kind = _fx_kind(e)
			switch v in mixer_effect_defaults(e) {
			case Mixer_Low_Pass:
				fx.cutoff, fx.q = v.cutoff, v.resonance
				_fx_coeffs(fx, rate)
			case Mixer_High_Pass:
				fx.cutoff, fx.q = v.cutoff, v.resonance
				_fx_coeffs(fx, rate)
			case Mixer_Duck:
				fx.by = nil
				for x in mx.nodes do if x.id == v.by && x != n do fx.by = x
				fx.threshold, fx.ratio = v.threshold, v.ratio
				fx.attack, fx.release = v.attack / 1000, v.release / 1000
			}
		}
	}

	if !same {
		for n in mx.nodes {
			clear(&n.chain)
			for at := n; at != nil; at = at.parent {
				append(&n.chain, _Stage{node = at, what = _STAGE_VOLUME})
				for _, k in at.effects do append(&n.chain, _Stage{node = at, what = k})
				append(&n.chain, _Stage{node = at, what = _STAGE_LEVEL})
			}
		}
	}
}

@(private)
_fx_kind :: proc(e: Mixer_Effect) -> _Fx_Kind {
	switch _ in e {
	case Mixer_Low_Pass:  return .Low_Pass
	case Mixer_High_Pass: return .High_Pass
	case Mixer_Duck:      return .Duck
	}
	return .Low_Pass
}

@(private)
_fx_coeffs :: proc(fx: ^_Fx, rate: f32) {
	if fx.kind == .Duck do return
	fx.coeffs = biquad_make(fx.cutoff, fx.q, rate, high = fx.kind == .High_Pass)
}

@(private)
_node_gain :: proc(n: ^_Node) {
	n.gain = n.mute ? 0 : db_to_gain(n.has_override ? n.override : n.volume)
}

// The rate the mixer mixes at, for the filters' coefficients. Before the
// mixer exists, the one devices use most.
@(private)
_mix_rate :: proc() -> f32 {
	spec: sdl.AudioSpec
	if _audio_state.mixer != nil && mix.GetMixerFormat(_audio_state.mixer, &spec) && spec.freq > 0 do return f32(spec.freq)
	return 48000
}

@(private)
_lock :: proc() {
	if _audio_state.mixer != nil do mix.LockMixer(_audio_state.mixer)
}

@(private)
_unlock :: proc() {
	if _audio_state.mixer != nil do mix.UnlockMixer(_audio_state.mixer)
}

// Needs the mixer: a mixer edited in the editor before anything plays opens
// no device.
@(private)
_ensure_post_mix :: proc() {
	if _audio_state.mixer == nil || _post_mix_installed == _audio_state.mixer do return
	_post_mix_installed = _audio_state.mixer
	_ = mix.SetPostMixCallback(_audio_state.mixer, transmute(mix.PostMixCallback)_post_mix, nil)
}

// --- The audio thread --------------------------------------------------------

// One SDL group's tracks, mixed: its node's path to the Master.
@(private)
_group_mix :: proc "c" (userdata: rawptr, group: ^mix.Group, spec: ^sdl.AudioSpec, pcm: ^c.float, samples: c.int) {
	n := (^_Node)(userdata)
	if n == nil || pcm == nil || samples <= 0 || spec == nil do return
	buf := ([^]f32)(pcm)[:samples]
	ch := int(spec.channels)
	for &st in n.chain {
		at := st.node
		switch st.what {
		case _STAGE_VOLUME:
			gain_run(buf, at.gain)
		case _STAGE_LEVEL:
			at.peak = max(at.peak, peak_of(buf))
		case:
			fx := &at.effects[st.what]
			switch fx.kind {
			case .Low_Pass, .High_Pass:
				biquad_run(buf, ch, fx.coeffs, &st.state)
			case .Duck:
				gain_run(buf, fx.gain)
			}
		}
	}
}

// Once per mix pass, after every group: levels fall, ducks move.
@(private)
_post_mix :: proc "c" (userdata: rawptr, m: ^mix.Mixer, spec: ^sdl.AudioSpec, pcm: ^c.float, samples: c.int) {
	if spec == nil || spec.channels <= 0 || spec.freq <= 0 do return
	dt := f32(samples) / f32(spec.channels) / f32(spec.freq)
	// The level halves in about 35 ms once the sound stops.
	fall := math.exp(-dt / 0.05)
	for mx in _mixers do for n in mx.nodes {
		n.level = max(n.peak, n.level * fall)
		n.peak = 0
	}
	for mx in _mixers do for n in mx.nodes do for &fx in n.effects {
		if fx.kind != .Duck do continue
		target: f32 = 1
		if fx.by != nil {
			over := gain_to_db(fx.by.level) - fx.threshold
			if over > 0 do target = db_to_gain(-over * (1 - 1 / fx.ratio))
		}
		t := target < fx.gain ? fx.attack : fx.release
		k := math.exp(-dt / max(t, 0.001))
		fx.gain = target + (fx.gain - target) * k
	}
}
