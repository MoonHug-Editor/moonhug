package animation

// AnimationClip asset: keyframe curves that animate transform
// position/rotation/scale — or any animatable component field (numbers,
// vectors, ints, enums, bools, references, strings) via property channels
// (clip_property.odin) — over time. Clips are JSON files under assets/
// (".anim"), cached by guid like materials. The Animation component
// (component_Animation.odin) plays one — a single-clip player, not
// Mecanim: no state machines, no blending, script-level Play/Stop.
//
// Channels target transforms by NAME PATH relative to the Animation owner:
// "" is the owner itself, "Body/Arm" walks children by name (the curve
// binding paths). "Assets/Extract Assets" turns glTF animations into .anim
// files whose paths mirror the glTF node hierarchy.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:log"
import "core:mem"
import "core:reflect"
import "moonhug:packages/engine"
import "core:math"
import "core:math/linalg"
import "core:strings"

// Once clamps at length and stops; Loop wraps.
Animation_Wrap :: enum u8 {
	Once,
	Loop,
}

// Which transform property a channel writes, and in which form. Position,
// Rotation and Scale are the glTF target paths: Rotation holds quaternions,
// slerped between keys. Euler is the rotation too, as euler angles in degrees
// (x, y, z, the inspector's order): three lanes that interpolate, mask and
// split like a Position row. Recording makes Euler rows, model clips keep
// Rotation rows. A clip may hold both for one transform: the Rotation row
// gives the quaternion, the Euler lanes replace their angles on top of it.
Animation_Path :: enum u8 {
	Position,
	Rotation,
	Scale,
	Euler,
}

// One curve: keyframe times plus values for a single target property.
//
// A channel with a non-empty `component` is a PROPERTY channel (bound by
// path + component type + property name): `component` is the
// component's type guid, `field` a dotted path to a leaf on it
// ("emission.rate.value_min"). The live field's typeid at bind time is the
// authority for how many lanes apply, discrete vs continuous, and the write
// conversion (clip_property.odin).
//
// `values` holds one typed array per row, parallel to `times`
// (Channel_Values). Float rows also carry per-key interpolation: `modes` and
// `tangents`, both optional and parallel to `times` when present.
//
// A float row of 2, 3 or 4 lanes animates only the lanes outside
// `lanes_off` (clip_property.odin, animation_channel_lanes_off).
Animation_Channel :: struct {
	target:    string, // name path relative to the playing owner ("" = owner)
	path:      Animation_Path,
	component: string, // component type guid, "" = transform channel
	field:     string, // dotted field path on the component
	// Every key holds (Step) while `modes` is absent. A channel with `modes`
	// ignores it.
	step:      bool,
	times:     [dynamic]f32,
	values:    Channel_Values,
	// Per-key interpolation of a float row. A key past the end of `modes` is
	// Linear (or Step, see `step`).
	modes:     [dynamic]Key_Mode `json:"modes,omitempty"`,
	// In and out slopes per lane of a Free key, in value units per second. A
	// Free key past the end of `tangents` has flat tangents.
	tangents:  [dynamic][2][4]f32 `json:"tangents,omitempty"`,
	// The lanes this row does not animate. A write leaves them as the field
	// holds them. Empty, the default, animates every lane. Only a float row
	// of 2, 3 or 4 lanes reads it, never a Rotation row or a scalar row. On
	// disk the key is `lanes`, one bool per lane x, y, z, w that is true when
	// the lane animates, absent when every lane animates
	// (_channel_lanes_marshal).
	lanes_off: Channel_Lanes_Off `json:"lanes,omitempty"`,
}

// A set of value lanes by index: 0 x, 1 y, 2 z, 3 w.
Lane_Set :: bit_set[0 ..< 4; u8]

// Animation_Channel.lanes_off: the lanes a row does not animate. Its own type
// so the JSON form (the lanes that DO animate) has a marshaler of its own.
Channel_Lanes_Off :: distinct Lane_Set

// The keys of one row, one array per value kind. A row animates one field, so
// all its keys share a type:
//   - floats: f32 fields, vectors, colours, quaternions. xyz for position and
//     scale, xyzw for rotation, the leading lanes for property channels.
//     Interpolated and blended
//   - i64: ints, enums and bools. Exact, held between keys
//   - PPtr: asset and sub-asset references. A bare Asset_GUID field reads as
//     a PPtr with local id 0. Held
//   - string: owned by the row, allocated with the row's own allocator. Held
//
// On disk the variant is told by the element type (_channel_values_unmarshal).
// The zero value is an empty float row.
Channel_Values :: union #no_nil {
	[dynamic][4]f32,
	[dynamic]i64,
	[dynamic]engine.PPtr,
	[dynamic]string,
}

// One key's value, the scalar counterpart of Channel_Values. A string is
// borrowed from wherever it was read.
Channel_Value :: union #no_nil {
	[4]f32,
	i64,
	engine.PPtr,
	string,
}

// How a float row interpolates from a key to the next one:
//   - Linear: straight toward the neighbour
//   - Smooth: tangents from the neighbouring keys (Catmull-Rom style), flat at
//     the first and last key. Computed at sample time, nothing stored
//   - Step: holds the key's value until the next key
//   - Free: the key's own tangents (Animation_Channel.tangents)
// A segment between two Linear keys is a lerp, any other segment a cubic
// Hermite curve. Rotation rows slerp and ignore tangents.
Key_Mode :: enum u8 {
	Linear,
	Smooth,
	Step,
	Free,
}

// Whether the channel animates a component field instead of the transform.
animation_channel_is_property :: proc(ch: ^Animation_Channel) -> bool {
	return len(ch.component) > 0
}

@(typ_guid={guid = "0a4f3b1c-8e57-4c2d-9b6a-5d1e7f2c8a90", menu_assets_create = {menu_name = "Animation", file_name = "New Animation.anim", order = -5}})
AnimationClip :: struct {
	length:   f32, // seconds; set from the last keyframe at import
	// Baked from the .meta's Animation_Clip_Settings at import — authored
	// there, never here. A source .anim carries only `length` and `channels`.
	//
	// Frames per second the editor snaps keys and the playhead to. Authoring
	// only — evaluation is continuous in seconds. 0 in a file predates the
	// field, so readers go through animation_clip_frame_rate.
	frame_rate: f32,
	wrap:     Animation_Wrap,
	cycle_offset: f32,
	// Edited as a dopesheet in the Animation window, never as reflected rows —
	// a clip has hundreds of channels each holding two parallel key arrays.
	channels: [dynamic]Animation_Channel `inspect:"-"`,
}

// The clip's authoring frame rate, defaulted for a clip saved before the
// field existed (a zero would make every frame conversion divide by zero).
ANIMATION_FRAME_RATE_DEFAULT :: f32(60)

animation_clip_frame_rate :: proc(c: ^AnimationClip) -> f32 {
	if c == nil || c.frame_rate <= 0 do return ANIMATION_FRAME_RATE_DEFAULT
	return c.frame_rate
}

// `t` quantized to the clip's frame grid, so a key the editor places lands on
// a frame boundary.
animation_snap_to_frame :: proc(c: ^AnimationClip, t: f32) -> f32 {
	fps := animation_clip_frame_rate(c)
	if fps <= 0 do return t
	return math.round(t * fps) / fps
}

// How far key `k` may move in time without passing a neighbour, which would
// reorder the channel and corrupt it. A neighbour that is itself selected is
// NOT a bound: it moves by the same delta, so a run of adjacent selected keys
// slides as a block. `selected` is parallel to `times`.
animation_key_bounds :: proc(times: []f32, selected: []bool, k: int, length: f32) -> (lo, hi: f32) {
	lo, hi = 0, length
	if k < 0 || k >= len(times) do return
	for i := k - 1; i >= 0; i -= 1 {
		if i < len(selected) && selected[i] do continue
		lo = times[i]
		break
	}
	for i := k + 1; i < len(times); i += 1 {
		if i < len(selected) && selected[i] do continue
		hi = times[i]
		break
	}
	return
}

type_reset_AnimationClip :: proc(c: ^AnimationClip) {
	type_cleanup_AnimationClip(c)
	c.length = 1
	c.frame_rate = ANIMATION_FRAME_RATE_DEFAULT
}

// --- Cache (mirrors material.odin) ------------------------------------------------

animation_clip_cache: map[engine.PPtr]AnimationClip
_animation_clip_cache_ready: bool
// The entries the cache made itself (animation_clip_load,
// animation_clip_preview): default-allocator memory, freed under the default
// allocator. An entry put in directly (tests) is the caller's memory and is
// freed under the context allocator of the unload or shutdown.
// type_cleanup_AnimationClip frees a clip's strings with the context allocator,
// its arrays with their own.
_animation_clip_owned: map[engine.PPtr]bool

// ImportersInit is the asset-layer init phase both binaries run (the editor
// via phase_editor_run, the app via app_init) — same slot the audio package
// uses for its importer.
@(phase={key=ImportersInit, order=2})
animation_package_init :: proc() {
	if !_animation_clip_cache_ready do animation_clip_cache_init()
}

animation_clip_cache_init :: proc() {
	animation_clip_cache = make(map[engine.PPtr]AnimationClip)
	_animation_clip_owned = make(map[engine.PPtr]bool, runtime.default_allocator())
	_animation_clip_cache_ready = true
}

// Frees cache entry `clip` under the allocator that owns its strings.
@(private = "file")
_animation_clip_entry_free :: proc(ref: engine.PPtr, clip: ^AnimationClip) {
	// Set at proc scope: a context change inside a block ends with the block.
	owned := ref in _animation_clip_owned
	context.allocator = owned ? runtime.default_allocator() : context.allocator
	if owned do delete_key(&_animation_clip_owned, ref)
	type_cleanup_AnimationClip(clip)
}

animation_clip_cache_shutdown :: proc() {
	for ref, &clip in animation_clip_cache {
		_animation_clip_entry_free(ref, &clip)
	}
	delete(animation_clip_cache)
	animation_clip_cache = nil
	delete(_animation_clip_owned)
	_animation_clip_owned = nil
	_animation_clip_cache_ready = false
}

// Clips hold no GPU resources — loads work headless in contexts that
// initialized the cache.
// `ref` names a standalone .anim ({guid, 0}) or a clip inside a model
// ({model guid, clip id}).
animation_clip_load :: proc(ref: engine.PPtr) -> (^AnimationClip, bool) {
	if clip, ok := &animation_clip_cache[ref]; ok {
		return clip, true
	}
	if !_animation_clip_cache_ready do return nil, false

	// A CACHE ENTRY OUTLIVES THE CALL, so it never borrows the caller's
	// allocator. A clip first loaded under a temp allocator left the cache
	// holding channels that the frame's free_all reclaimed, and every later
	// load returned that dangling entry from the cache — the scrub preview
	// then posed from freed memory and froze. The Playable Graph window builds
	// the authored shape into temp memory, which is how it got reached.
	// The file's bytes are read into temp memory and are unaffected.
	context.allocator = runtime.default_allocator()

	// The ARTIFACT, not the source: the importer bakes the .meta's settings
	// into it, so the runtime never opens a meta. A standalone .anim is its
	// asset's main artifact, a clip inside a model (engine.Mesh_Clip) the
	// model's sub-asset file for the clip's id. engine.artifact_load imports
	// a missing file in the editor and reports it once in a game.
	if ref.local_id != 0 && !engine.asset_guid_is_empty(ref.guid) {
		if _, iok := engine.mesh_clip_index(ref.guid, ref.local_id); !iok {
			engine.artifact_fail(ref.guid, ref.local_id, "the model has no such clip (gone from the model, or an orphan to remap)")
			return nil, false
		}
	}
	clip: AnimationClip
	parse :: proc(data: []byte, clip: ^AnimationClip) -> bool {
		if json.unmarshal(data, clip, .JSON, context.allocator) == nil {
			if msg, vok := animation_clip_validate(clip); !vok {
				log.errorf("[Clip] %s: the file is not loaded", msg)
			} else {
				return true
			}
		}
		type_cleanup_AnimationClip(clip)
		return false
	}
	if !engine.artifact_load(ref.guid, ref.local_id, "clip", &clip, parse) do return nil, false
	animation_clip_cache[ref] = clip
	_animation_clip_owned[ref] = true
	return &animation_clip_cache[ref], true
}

animation_clip_unload :: proc(ref: engine.PPtr) {
	if clip, ok := &animation_clip_cache[ref]; ok {
		_animation_clip_entry_free(ref, clip)
		delete_key(&animation_clip_cache, ref)
	}
}

// Replace the cached clip with a deep copy of `clip` — the editor's live
// preview of unsaved asset-document edits (mirrors material_preview): the
// scrub preview and any playing Animation component sample the edited values
// immediately, while the file keeps the last saved state.
animation_clip_preview :: proc(ref: engine.PPtr, clip: AnimationClip) {
	if !_animation_clip_cache_ready do return
	// The deep copy below becomes a cache entry, so it owns its memory for the
	// same reason animation_clip_load's does.
	context.allocator = runtime.default_allocator()
	// Settings are BAKED, so the edited document does not carry them: it holds
	// length and channels, and wrap, frame rate and cycle offset came from the
	// .meta at import. Keep the imported values rather than taking the
	// document's zeros, or previewing an unsaved key edit would quietly turn a
	// looping clip into a one-shot.
	wrap, rate, offset := clip.wrap, clip.frame_rate, clip.cycle_offset
	if old, ok := &animation_clip_cache[ref]; ok {
		wrap, rate, offset = old.wrap, old.frame_rate, old.cycle_offset
		_animation_clip_entry_free(ref, old)
	}
	cp := AnimationClip{length = clip.length, wrap = wrap, frame_rate = rate, cycle_offset = offset}
	cp.channels = make([dynamic]Animation_Channel, 0, len(clip.channels))
	for &ch in clip.channels {
		c := Animation_Channel{
			target    = strings.clone(ch.target),
			path      = ch.path,
			component = strings.clone(ch.component),
			field     = strings.clone(ch.field),
			step      = ch.step,
			lanes_off = ch.lanes_off,
		}
		c.times = make([dynamic]f32, len(ch.times))
		copy(c.times[:], ch.times[:])
		c.values = animation_channel_values_clone(ch.values)
		if len(ch.modes) > 0 {
			c.modes = make([dynamic]Key_Mode, len(ch.modes))
			copy(c.modes[:], ch.modes[:])
		}
		if len(ch.tangents) > 0 {
			c.tangents = make([dynamic][2][4]f32, len(ch.tangents))
			copy(c.tangents[:], ch.tangents[:])
		}
		append(&cp.channels, c)
	}
	animation_clip_cache[ref] = cp
	_animation_clip_owned[ref] = true
}

// A changed, removed or reimported clip drops its cached copy, so the next
// load picks up the new file or artifact — settings changed in the inspector
// apply without a restart. A reimported MODEL rebakes every clip it holds,
// each cached under {model guid, clip id}, so every entry with the guid goes.
@(asset_on_changed)
asset_on_changed_animation_clip :: proc(guid: engine.Asset_GUID, path: string, change: engine.Asset_Change) {
	owned := make([dynamic]engine.PPtr, context.temp_allocator)
	for k in animation_clip_cache do if k.guid == guid do append(&owned, k)
	for k in owned do animation_clip_unload(k)
}

// Frees what a clip owns and leaves it zeroed (plugins/engine/docs/Components.md,
// "Lifecycle procs"). The strings are freed with the context allocator, the
// arrays with their own: the caller runs this under the allocator that owns
// the clip (a cache entry's is the default allocator, a document's the
// document's).
type_cleanup_AnimationClip :: proc(clip: ^AnimationClip) {
	for &ch in clip.channels {
		delete(ch.target)
		delete(ch.component)
		delete(ch.field)
		delete(ch.times)
		animation_channel_values_delete(&ch.values)
		delete(ch.modes)
		delete(ch.tangents)
	}
	delete(clip.channels)
	clip^ = {}
}

// --- Row values ---------------------------------------------------------------------
//
// Every change to a row's keys goes through these, so `values`, `modes` and
// `tangents` stay parallel to `times`.

// The float row of a channel. A channel of another kind is a caller bug.
animation_channel_floats :: proc(ch: ^Animation_Channel) -> ^[dynamic][4]f32 {
	f, ok := &ch.values.([dynamic][4]f32)
	fmt.assertf(ok, "animation: channel %q %q holds %v keys, not floats", ch.target, ch.field, reflect.union_variant_typeid(ch.values))
	return f
}

// Whether a channel's keys are floats (interpolated, blended, plotted).
animation_channel_is_float :: proc(ch: ^Animation_Channel) -> bool {
	_, ok := ch.values.([dynamic][4]f32)
	return ok
}

animation_channel_values_len :: proc(v: Channel_Values) -> int {
	switch a in v {
	case [dynamic][4]f32:     return len(a)
	case [dynamic]i64:        return len(a)
	case [dynamic]engine.PPtr: return len(a)
	case [dynamic]string:     return len(a)
	}
	unreachable()
}

// An empty row of the kind `v` belongs to, on context.allocator.
animation_channel_values_make :: proc(v: Channel_Value) -> Channel_Values {
	switch _ in v {
	case [4]f32:      return make([dynamic][4]f32)
	case i64:         return make([dynamic]i64)
	case engine.PPtr: return make([dynamic]engine.PPtr)
	case string:      return make([dynamic]string)
	}
	unreachable()
}

// A deep copy on context.allocator. Strings are cloned.
animation_channel_values_clone :: proc(v: Channel_Values) -> Channel_Values {
	switch a in v {
	case [dynamic][4]f32:
		c := make([dynamic][4]f32, len(a))
		copy(c[:], a[:])
		return c
	case [dynamic]i64:
		c := make([dynamic]i64, len(a))
		copy(c[:], a[:])
		return c
	case [dynamic]engine.PPtr:
		c := make([dynamic]engine.PPtr, len(a))
		copy(c[:], a[:])
		return c
	case [dynamic]string:
		c := make([dynamic]string, len(a))
		for str, i in a do c[i] = strings.clone(str, c.allocator)
		return c
	}
	unreachable()
}

// Frees a row (its strings with it) and leaves it an empty float row.
animation_channel_values_delete :: proc(v: ^Channel_Values) {
	switch &a in v {
	case [dynamic][4]f32:     delete(a)
	case [dynamic]i64:        delete(a)
	case [dynamic]engine.PPtr: delete(a)
	case [dynamic]string:
		for str in a do delete(str, a.allocator)
		delete(a)
	}
	v^ = [dynamic][4]f32{}
}

// Key `k`'s value. A string is borrowed from the row.
animation_channel_value :: proc(ch: ^Animation_Channel, k: int) -> Channel_Value {
	switch a in ch.values {
	case [dynamic][4]f32:     return a[k]
	case [dynamic]i64:        return a[k]
	case [dynamic]engine.PPtr: return a[k]
	case [dynamic]string:     return a[k]
	}
	unreachable()
}

// `v` as the row's kind. Floats and ints convert into each other (the first
// lane, rounded), so a float row on an int field and an int row on a float
// field both key. Any other mismatch is a caller bug.
@(private = "file")
_channel_value_as_row :: proc(ch: ^Animation_Channel, v: Channel_Value) -> Channel_Value {
	switch _ in ch.values {
	case [dynamic][4]f32:
		#partial switch x in v {
		case [4]f32: return x
		case i64:    return [4]f32{f32(x), 0, 0, 0}
		}
	case [dynamic]i64:
		#partial switch x in v {
		case i64:    return x
		case [4]f32: return i64(math.round(x.x))
		}
	case [dynamic]engine.PPtr:
		if x, ok := v.(engine.PPtr); ok do return x
	case [dynamic]string:
		if x, ok := v.(string); ok do return x
	}
	fmt.panicf("animation: a %v key cannot go into channel %q %q, which holds %v keys",
		reflect.union_variant_typeid(v), ch.target, ch.field, reflect.union_variant_typeid(ch.values))
}

// Sets key `k`'s value. A string is cloned with the row's allocator and the
// old one freed.
animation_channel_set_value :: proc(ch: ^Animation_Channel, k: int, v: Channel_Value) {
	v := _channel_value_as_row(ch, v)
	switch &a in ch.values {
	case [dynamic][4]f32:     a[k] = v.([4]f32)
	case [dynamic]i64:        a[k] = v.(i64)
	case [dynamic]engine.PPtr: a[k] = v.(engine.PPtr)
	case [dynamic]string:
		if a[k] == v.(string) do return
		delete(a[k], a.allocator)
		a[k] = strings.clone(v.(string), a.allocator)
	}
}

// Inserts a key at index `idx` (the times stay sorted: the caller picks the
// index). A string is cloned with the row's allocator. When the channel has
// `modes`, the new key takes the mode of the key before it (the key after it
// at the front). A Free key gets the curve's slope at `t` on both sides, so
// a key added to an imported cubic curve keeps its shape.
animation_channel_insert_key :: proc(ch: ^Animation_Channel, idx: int, t: f32, v: Channel_Value) {
	mode := Key_Mode.Linear
	slope: [4]f32
	if len(ch.modes) > 0 && idx <= len(ch.modes) {
		src := idx > 0 ? idx - 1 : 0
		mode = ch.modes[src]
		if mode == .Free do slope = _animation_channel_slope(ch, t)
	}

	inject_at(&ch.times, idx, t)
	_channel_values_inject(ch, idx, v)
	if len(ch.modes) > 0 && idx <= len(ch.modes) {
		inject_at(&ch.modes, idx, mode)
	}
	if len(ch.tangents) > 0 && idx <= len(ch.tangents) {
		inject_at(&ch.tangents, idx, [2][4]f32{slope, slope})
	} else if mode == .Free {
		// A Free key past the end of `tangents` is flat, so the gap fills
		// with flat entries before this key's own.
		for len(ch.tangents) < idx do append(&ch.tangents, [2][4]f32{})
		append(&ch.tangents, [2][4]f32{slope, slope})
	}
}

// Inserts `v` into the row alone at `idx`, converted to the row's kind. A
// string is cloned with the row's allocator.
_channel_values_inject :: proc(ch: ^Animation_Channel, idx: int, v: Channel_Value) {
	v := _channel_value_as_row(ch, v)
	switch &a in ch.values {
	case [dynamic][4]f32:     inject_at(&a, idx, v.([4]f32))
	case [dynamic]i64:        inject_at(&a, idx, v.(i64))
	case [dynamic]engine.PPtr: inject_at(&a, idx, v.(engine.PPtr))
	case [dynamic]string:
		if a.allocator.procedure == nil do a.allocator = context.allocator
		inject_at(&a, idx, strings.clone(v.(string), a.allocator))
	}
}

// Removes key `idx` from every parallel array that reaches it.
animation_channel_remove_key :: proc(ch: ^Animation_Channel, idx: int) {
	ordered_remove(&ch.times, idx)
	switch &a in ch.values {
	case [dynamic][4]f32:     ordered_remove(&a, idx)
	case [dynamic]i64:        ordered_remove(&a, idx)
	case [dynamic]engine.PPtr: ordered_remove(&a, idx)
	case [dynamic]string:
		delete(a[idx], a.allocator)
		ordered_remove(&a, idx)
	}
	if idx < len(ch.modes) do ordered_remove(&ch.modes, idx)
	if idx < len(ch.tangents) do ordered_remove(&ch.tangents, idx)
}

// --- Row values on disk ------------------------------------------------------------
//
// `values` stays one JSON array whatever the row's kind, and the element type
// tells the kind:
//   - an array ([x, y, z, w]): floats
//   - a number: i64
//   - a string: strings
//   - an object ({"local_id": ..., "guid": ...}): PPtr
//   - an empty array: floats
// A float row writes exactly the array of [x, y, z, w] arrays a clip has
// always held, so every .anim and every baked artifact reads unchanged.

@(phase={key=SerializationInit, order=1})
animation_clip_serialization_init :: proc() {
	@(static) done := false
	if done do return
	done = true
	json.register_user_marshaler(Channel_Values, _channel_values_marshal)
	json.register_user_unmarshaler(Channel_Values, _channel_values_unmarshal)
	json.register_user_marshaler(Channel_Lanes_Off, _channel_lanes_marshal)
	json.register_user_unmarshaler(Channel_Lanes_Off, _channel_lanes_unmarshal)
}

// `lanes` on disk: four bools, x to w, true for a lane that animates. The
// field is omitted (omitempty) when no lane is off, so only a row with a
// disabled lane writes the key.
@(private = "file")
_channel_lanes_marshal :: proc(w: io.Writer, v: any, opt: ^json.Marshal_Options) -> json.Marshal_Error {
	off := (cast(^Channel_Lanes_Off)v.data)^
	on: [4]bool
	for l in 0 ..< 4 do on[l] = l not_in off
	return json.marshal_to_writer(w, on, opt)
}

// Reads up to four bools. A lane the array does not reach animates.
@(private = "file")
_channel_lanes_unmarshal :: proc(p: ^json.Parser, v: any) -> json.Unmarshal_Error {
	on := [4]bool{true, true, true, true}
	if err := json.unmarshal_value(p, any{&on, typeid_of([4]bool)}); err != nil do return err
	off: Channel_Lanes_Off
	for l in 0 ..< 4 do if !on[l] do off += {l}
	(cast(^Channel_Lanes_Off)v.data)^ = off
	return nil
}

// The active variant through the plain writer, so a float row writes the
// bytes the array writer has always produced.
@(private = "file")
_channel_values_marshal :: proc(w: io.Writer, v: any, opt: ^json.Marshal_Options) -> json.Marshal_Error {
	tid := reflect.union_variant_typeid(v)
	assert(tid != nil, "animation: Channel_Values is #no_nil")
	return json.marshal_to_writer(w, any{v.data, tid}, opt)
}

// Peeks the first element on a copy of the parser to pick the variant, then
// reads the array straight into it. The destination is never read: unmarshal
// targets can be uninitialized memory (dynamic-array slots).
@(private = "file")
_channel_values_unmarshal :: proc(p: ^json.Parser, v: any) -> json.Unmarshal_Error {
	tid := typeid_of([dynamic][4]f32)
	if p.curr_token.kind == .Open_Bracket {
		peek := p^
		if _, err := json.advance_token(&peek); err != nil do return err
		#partial switch peek.curr_token.kind {
		case .Integer, .Float: tid = typeid_of([dynamic]i64)
		case .String:          tid = typeid_of([dynamic]string)
		case .Open_Brace:      tid = typeid_of([dynamic]engine.PPtr)
		}
	}
	mem.zero(v.data, size_of(Channel_Values))
	if err := json.unmarshal_value(p, any{v.data, tid}); err != nil do return err
	reflect.set_union_variant_typeid(v, tid)
	return nil
}

// --- Sampling ---------------------------------------------------------------------

// Write every channel's value at `time` into the owner's transform hierarchy
// (and, for property channels, into the targeted component fields).
// Channels whose target path doesn't resolve, or that hold no keys, are
// skipped.
animation_clip_apply :: proc(clip: ^AnimationClip, owner: engine.Transform_Handle, time: f32) {
	w := engine.ctx_world()
	// Transform rows gather per transform first (Clip_TRS), so split lanes and
	// the rotation forms combine by the one rule, then write over the
	// transform's own values.
	trs := make(map[engine.Transform_Handle]Clip_TRS, context.temp_allocator)
	for &ch in clip.channels {
		// A channel with no keys has nothing to say: sampling it yields zeros,
		// which would collapse a scale or snap a position to the origin. Same
		// treatment as an unresolved target.
		if len(ch.times) == 0 do continue
		tH, ok := _animation_resolve_target(owner, ch.target)
		if !ok do continue
		if animation_channel_is_property(&ch) {
			ptr, kind, leaf_tid, pok := _prop_locate(tH, ch.component, ch.field)
			if !pok do continue
			_prop_write_value(ptr, kind, leaf_tid, _animation_channel_sample_value(&ch, time), animation_channel_lanes_off(&ch, kind))
			continue
		}
		entry := trs[tH]
		animation_trs_add(&entry, &ch, time)
		trs[tH] = entry
	}
	for tH, entry in trs {
		t := engine.pool_get(&w.transforms, engine.Handle(tH))
		if t == nil do continue
		t.position = animation_trs_lanes_over(entry.pos, entry.pos_lanes, t.position)
		t.scale = animation_trs_lanes_over(entry.scl, entry.scl_lanes, t.scale)
		if animation_trs_has_rotation(entry) do t.rotation = animation_trs_rotation(entry, t.rotation)
	}
}

// The normalized quaternion for euler angles `e` (degrees, x y z), what an
// Euler row writes.
animation_quat_from_euler :: proc(e: [3]f32) -> [4]f32 {
	q := engine.quat_from_euler_xyz(e.x, e.y, e.z)
	if l := linalg.length(q); l > 0.0001 do q = (1.0 / l) * q
	return q
}

// Walk children by name along a "/"-separated path. Empty path = the owner.
_animation_resolve_target :: proc(owner: engine.Transform_Handle, path: string) -> (engine.Transform_Handle, bool) {
	w := engine.ctx_world()
	cur := owner
	if len(path) == 0 do return cur, engine.pool_valid(&w.transforms, engine.Handle(cur))
	rest := path
	for len(rest) > 0 {
		name := rest
		if slash := strings.index_byte(rest, '/'); slash >= 0 {
			name = rest[:slash]
			rest = rest[slash + 1:]
		} else {
			rest = ""
		}
		t := engine.pool_get(&w.transforms, engine.Handle(cur))
		if t == nil do return {}, false
		found := false
		for child in t.children {
			ct := engine.pool_get(&w.transforms, child.handle)
			if ct != nil && ct.name == name {
				cur = engine.Transform_Handle(child.handle)
				found = true
				break
			}
		}
		if !found do return {}, false
	}
	return cur, true
}

// Value of a float row at `time`: clamped outside the key range, else
// interpolated between the bracketing keys per their modes (Key_Mode).
// Rotation rows slerp, or hold on a Step key. A row of another kind is a
// caller bug: _animation_channel_sample_value samples any row.
_animation_channel_sample :: proc(ch: ^Animation_Channel, time: f32) -> [4]f32 {
	vals := animation_channel_floats(ch)[:]
	n := len(ch.times)
	if n == 0 do return {}
	if time <= ch.times[0] do return vals[0]
	if time >= ch.times[n - 1] do return vals[n - 1]

	lo, hi := _animation_key_bracket(ch.times[:], time)
	v, _ := _animation_segment_eval(ch, vals, lo, hi, time)
	return v
}

// Value of any row at `time`. Float rows interpolate as
// _animation_channel_sample does, the other kinds hold the last key at or
// before `time` (the first key before it). A string is borrowed from the row.
_animation_channel_sample_value :: proc(ch: ^Animation_Channel, time: f32) -> Channel_Value {
	switch vals in ch.values {
	case [dynamic][4]f32:
		return _animation_channel_sample(ch, time)
	case [dynamic]i64:
		if len(vals) == 0 do return i64(0)
		return vals[_animation_key_hold(ch.times[:], time)]
	case [dynamic]engine.PPtr:
		if len(vals) == 0 do return engine.PPtr{}
		return vals[_animation_key_hold(ch.times[:], time)]
	case [dynamic]string:
		if len(vals) == 0 do return ""
		return vals[_animation_key_hold(ch.times[:], time)]
	}
	unreachable()
}

// Slope of a float row at `time`, in value units per second: the derivative
// of the segment `time` falls in, 0 outside the key range, on a Step segment
// and on rotation rows. On a key the segment after it counts, or the one
// before it with `from_left` (and always at the last key).
_animation_channel_slope :: proc(ch: ^Animation_Channel, time: f32, from_left := false) -> [4]f32 {
	vals := animation_channel_floats(ch)[:]
	n := len(ch.times)
	if n < 2 || time < ch.times[0] || time > ch.times[n - 1] do return {}
	lo, hi := _animation_key_bracket(ch.times[:], time)
	if from_left && lo > 0 && time == ch.times[lo] {
		lo, hi = lo - 1, lo
	}
	_, d := _animation_segment_eval(ch, vals, lo, hi, time)
	return d
}

// The bracketing keys of `time`, which lies inside the key range: the last
// key at or before it and the one after.
@(private = "file")
_animation_key_bracket :: proc(times: []f32, time: f32) -> (lo, hi: int) {
	lo, hi = 0, len(times) - 1
	for lo + 1 < hi {
		mid := (lo + hi) / 2
		if times[mid] <= time do lo = mid
		else do hi = mid
	}
	return
}

// The key a held row shows at `time`: the last key at or before it, the
// first key before the first key's time.
_animation_key_hold :: proc(times: []f32, time: f32) -> int {
	n := len(times)
	if n == 0 || time <= times[0] do return 0
	if time >= times[n - 1] do return n - 1
	lo, _ := _animation_key_bracket(times, time)
	return lo
}

// The interpolation mode of key `k`. A key past the end of `modes` is Linear,
// or Step when the channel has no `modes` and sets `step`.
_animation_key_mode :: proc(ch: ^Animation_Channel, k: int) -> Key_Mode {
	if k < len(ch.modes) do return ch.modes[k]
	if len(ch.modes) == 0 && ch.step do return .Step
	return .Linear
}

// The straight-line slope from key `a` to key `b` of a float row, in value
// units per second. 0 when `b` is not later than `a`.
animation_key_slope :: proc(times: []f32, vals: [][4]f32, a, b: int) -> [4]f32 {
	dt := times[b] - times[a]
	if dt <= 0 do return {}
	return (vals[b] - vals[a]) / dt
}

// The tangents a Smooth key `k` has: the slope between its two neighbours on
// both sides, flat at the first and last key.
animation_key_smooth_tangents :: proc(times: []f32, vals: [][4]f32, k: int) -> (tin, tout: [4]f32) {
	if k > 0 && k < len(vals) - 1 {
		tin = animation_key_slope(times, vals, k - 1, k + 1)
		tout = tin
	}
	return
}

// In and out slopes of key `k` of a float row, in value units per second:
//   - Linear and Step: the slope toward the neighbour on that side
//   - Smooth: animation_key_smooth_tangents
//   - Free: the stored tangents, flat past the end of `tangents`
_animation_key_tangents :: proc(ch: ^Animation_Channel, vals: [][4]f32, k: int) -> (tin, tout: [4]f32) {
	n := len(vals)
	switch _animation_key_mode(ch, k) {
	case .Linear, .Step:
		if k > 0 do tin = animation_key_slope(ch.times[:], vals, k - 1, k)
		if k < n - 1 do tout = animation_key_slope(ch.times[:], vals, k, k + 1)
	case .Smooth:
		tin, tout = animation_key_smooth_tangents(ch.times[:], vals, k)
	case .Free:
		if k < len(ch.tangents) {
			tin = ch.tangents[k][0]
			tout = ch.tangents[k][1]
		}
	}
	return
}

// Value and slope (per second) of the segment from key `lo` to key `hi` at
// `time`, which lies between them.
@(private = "file")
_animation_segment_eval :: proc(ch: ^Animation_Channel, vals: [][4]f32, lo, hi: int, time: f32) -> (v, d: [4]f32) {
	ma := _animation_key_mode(ch, lo)
	if ma == .Step do return vals[lo], {}

	span := ch.times[hi] - ch.times[lo]
	if span <= 0 do return vals[hi], {}
	s := (time - ch.times[lo]) / span
	if ch.path == .Rotation && !animation_channel_is_property(ch) {
		a := engine.quat_to_native(vals[lo])
		b := engine.quat_to_native(vals[hi])
		return engine.quat_from_native(linalg.quaternion_slerp(a, b, s)), {}
	}
	mb := _animation_key_mode(ch, hi)
	if ma == .Linear && (mb == .Linear || mb == .Step) {
		return linalg.lerp(vals[lo], vals[hi], s), (vals[hi] - vals[lo]) / span
	}

	// Cubic Hermite with A's out slope and B's in slope, scaled to the segment.
	_, out_a := _animation_key_tangents(ch, vals, lo)
	in_b, _ := _animation_key_tangents(ch, vals, hi)
	m0 := out_a * span
	m1 := in_b * span
	s2 := s * s
	s3 := s2 * s
	h00 := 2 * s3 - 3 * s2 + 1
	h10 := s3 - 2 * s2 + s
	h01 := -2 * s3 + 3 * s2
	h11 := s3 - s2
	v = h00 * vals[lo] + h10 * m0 + h01 * vals[hi] + h11 * m1
	d00 := 6 * s2 - 6 * s
	d10 := 3 * s2 - 4 * s + 1
	d01 := -6 * s2 + 6 * s
	d11 := 3 * s2 - 2 * s
	d = (d00 * vals[lo] + d10 * m0 + d01 * vals[hi] + d11 * m1) / span
	return
}

// Play position for a raw time per the wrap mode; done=true when a Once clip
// ran past its length.
animation_wrap_time :: proc(time, length: f32, wrap: Animation_Wrap) -> (t: f32, done: bool) {
	if length <= 0 do return 0, wrap == .Once
	switch wrap {
	case .Loop:
		return math.mod(time, length), false
	case .Once:
		if time >= length do return length, true
		return time, false
	}
	return time, false
}
