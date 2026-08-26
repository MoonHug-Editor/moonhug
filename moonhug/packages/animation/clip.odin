package animation

// Unity-style AnimationClip asset: keyframe curves that animate transform
// position/rotation/scale over time. Clips are JSON files under assets/
// (".anim"), cached by guid like materials. The Animation component
// (component_Animation.odin) plays one — Unity's LEGACY clip player, not
// Mecanim: no state machines, no blending, script-level Play/Stop.
//
// Channels target transforms by NAME PATH relative to the Animation owner:
// "" is the owner itself, "Body/Arm" walks children by name (Unity's curve
// binding paths). "Assets/Extract Assets" turns glTF animations into .anim
// files whose paths mirror the glTF node hierarchy.

import "core:encoding/json"
import "moonhug:engine"
import "core:encoding/uuid"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:strings"

// Unity WrapMode subset. Once clamps at length and stops; Loop wraps.
Animation_Wrap :: enum u8 {
	Once,
	Loop,
}

// Which transform property a channel writes (glTF target paths; Unity curves
// bind arbitrary properties — transforms cover the imported set).
Animation_Path :: enum u8 {
	Position,
	Rotation,
	Scale,
}

// One curve: keyframe times plus values for a single target property.
// Values pack into [4]f32 — xyz for position/scale, xyzw quat for rotation.
Animation_Channel :: struct {
	target: string, // name path relative to the playing owner ("" = owner)
	path:   Animation_Path,
	step:   bool, // STEP interpolation: hold the previous key (else lerp/slerp)
	times:  [dynamic]f32,
	values: [dynamic][4]f32,
}

@(typ_guid={guid = "0a4f3b1c-8e57-4c2d-9b6a-5d1e7f2c8a90", makeProcName=make_pAnimationClip, menu_assets_create = {menu_name = "Animation", file_name = "New Animation.anim", order = -5}})
AnimationClip :: struct {
	length:   f32, // seconds; set from the last keyframe at import
	wrap:     Animation_Wrap,
	channels: [dynamic]Animation_Channel,
}

make_pAnimationClip :: proc() -> any {
	c := new(AnimationClip)
	c.length = 1
	return c^
}

// --- Cache (mirrors material.odin) ------------------------------------------------

animation_clip_cache: map[engine.Asset_GUID]AnimationClip
_animation_clip_cache_ready: bool

// ImportersInit is the asset-layer init phase both binaries run (the editor
// via phase_editor_run, the app via app_init) — same slot the audio package
// uses for its importer.
@(phase={key=ImportersInit, order=2})
animation_package_init :: proc() {
	if !_animation_clip_cache_ready do animation_clip_cache_init()
	engine.asset_db_add_path_changed_hook(animation_clip_path_changed)
	if !_timeline_cache_ready do timeline_cache_init()
	engine.asset_db_add_path_changed_hook(timeline_path_changed)
	register_builtin_tracks()
	engine.register_pointer_type(Track_Binding)
}

animation_clip_cache_init :: proc() {
	animation_clip_cache = make(map[engine.Asset_GUID]AnimationClip)
	_animation_clip_cache_ready = true
}

animation_clip_cache_shutdown :: proc() {
	for _, &clip in animation_clip_cache {
		_animation_clip_destroy(&clip)
	}
	delete(animation_clip_cache)
	animation_clip_cache = nil
	_animation_clip_cache_ready = false
}

// Clips hold no GPU resources — loads work headless in contexts that
// initialized the cache.
animation_clip_load :: proc(guid: engine.Asset_GUID) -> (^AnimationClip, bool) {
	if clip, ok := &animation_clip_cache[guid]; ok {
		return clip, true
	}
	if !_animation_clip_cache_ready do return nil, false

	path, path_ok := engine.asset_db_get_path(uuid.Identifier(guid))
	if !path_ok do return nil, false
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil do return nil, false

	clip: AnimationClip
	if json.unmarshal(data, &clip, .JSON, context.allocator) != nil {
		_animation_clip_destroy(&clip)
		return nil, false
	}
	animation_clip_cache[guid] = clip
	return &animation_clip_cache[guid], true
}

animation_clip_unload :: proc(guid: engine.Asset_GUID) {
	if clip, ok := &animation_clip_cache[guid]; ok {
		_animation_clip_destroy(clip)
		delete_key(&animation_clip_cache, guid)
	}
}

// Replace the cached clip with a deep copy of `clip` — the editor's live
// preview of unsaved asset-document edits (mirrors material_preview): the
// scrub preview and any playing Animation component sample the edited values
// immediately, while the file keeps the last saved state.
animation_clip_preview :: proc(guid: engine.Asset_GUID, clip: AnimationClip) {
	if !_animation_clip_cache_ready do return
	if old, ok := &animation_clip_cache[guid]; ok {
		_animation_clip_destroy(old)
	}
	cp := AnimationClip{length = clip.length, wrap = clip.wrap}
	cp.channels = make([dynamic]Animation_Channel, 0, len(clip.channels))
	for &ch in clip.channels {
		c := Animation_Channel{target = strings.clone(ch.target), path = ch.path, step = ch.step}
		c.times = make([dynamic]f32, len(ch.times))
		copy(c.times[:], ch.times[:])
		c.values = make([dynamic][4]f32, len(ch.values))
		copy(c.values[:], ch.values[:])
		append(&cp.channels, c)
	}
	animation_clip_cache[guid] = cp
}

// Cache invalidation for external file changes, called from asset_db_refresh.
animation_clip_path_changed :: proc(path: string) {
	if !strings.has_suffix(path, ".anim") do return
	if guid, ok := engine.asset_db_get_guid(path); ok {
		animation_clip_unload(engine.Asset_GUID(guid))
	}
}

_animation_clip_destroy :: proc(clip: ^AnimationClip) {
	for &ch in clip.channels {
		delete(ch.target)
		delete(ch.times)
		delete(ch.values)
	}
	delete(clip.channels)
	clip^ = {}
}

// --- Sampling ---------------------------------------------------------------------

// Write every channel's value at `time` into the owner's transform hierarchy.
// Channels whose target path doesn't resolve are skipped.
animation_clip_apply :: proc(clip: ^AnimationClip, owner: engine.Transform_Handle, time: f32) {
	w := engine.ctx_world()
	for &ch in clip.channels {
		tH, ok := _animation_resolve_target(owner, ch.target)
		if !ok do continue
		t := engine.pool_get(&w.transforms, engine.Handle(tH))
		if t == nil do continue
		v := _animation_channel_sample(&ch, time)
		switch ch.path {
		case .Position: t.position = v.xyz
		case .Rotation: t.rotation = v
		case .Scale:    t.scale = v.xyz
		}
	}
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

// Value at `time`: clamped outside the key range, held (step) or
// interpolated (lerp, slerp for rotations) between the bracketing keys.
_animation_channel_sample :: proc(ch: ^Animation_Channel, time: f32) -> [4]f32 {
	n := len(ch.times)
	if n == 0 do return {}
	if time <= ch.times[0] do return ch.values[0]
	if time >= ch.times[n - 1] do return ch.values[n - 1]

	// Binary search for the last key at or before `time`.
	lo, hi := 0, n - 1
	for lo + 1 < hi {
		mid := (lo + hi) / 2
		if ch.times[mid] <= time do lo = mid
		else do hi = mid
	}
	if ch.step do return ch.values[lo]

	span := ch.times[hi] - ch.times[lo]
	k := span > 0 ? (time - ch.times[lo]) / span : 0
	if ch.path == .Rotation {
		a := engine.quat_to_native(ch.values[lo])
		b := engine.quat_to_native(ch.values[hi])
		return engine.quat_from_native(linalg.quaternion_slerp(a, b, k))
	}
	return linalg.lerp(ch.values[lo], ch.values[hi], k)
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
