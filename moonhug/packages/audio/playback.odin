package audio

// Playback: one lazily created SDL3_mixer device mixer, one track per
// playing AudioSource. Headless contexts (tests, tooling) fall back to a
// deviceless mixer — loading and decoding work, nothing is audible.
//
// The @(update) subscriber lands in the generated per-frame dispatcher, so
// sources tick in play mode (editor) and always (app), like Unity.

import "base:runtime"
import "core:fmt"
import sdl "vendor:sdl3"
import mix "vendor:sdl3/mixer"
import engine "moonhug:engine"

_audio_state: struct {
	lib_ready: bool,
	mixer:     ^mix.Mixer,
}

_mix_lib_ensure :: proc() {
	if _audio_state.lib_ready do return
	_audio_state.lib_ready = true
	if !mix.Init() {
		fmt.printf("[Audio] SDL3_mixer init failed: %s\n", sdl.GetError())
	}
}

// Tests/tooling: pin the process to a deviceless mixer before anything
// creates the device one. Loading works, mix.Generate drives playback,
// nothing is audible.
mixer_init_headless :: proc() -> bool {
	if _audio_state.mixer != nil do return true
	_mix_lib_ensure()
	_audio_state.mixer = _create_deviceless_mixer()
	return _audio_state.mixer != nil
}

// CreateMixer requires an explicit spec (nil returns no mixer).
_create_deviceless_mixer :: proc() -> ^mix.Mixer {
	spec := sdl.AudioSpec{format = .F32, channels = 2, freq = 44100}
	return mix.CreateMixer(&spec)
}

_mixer_ensure :: proc() -> bool {
	if _audio_state.mixer != nil do return true
	_mix_lib_ensure()
	m := mix.CreateMixerDevice(sdl.AUDIO_DEVICE_DEFAULT_PLAYBACK, nil)
	if m == nil do m = _create_deviceless_mixer()
	_audio_state.mixer = m
	return m != nil
}

// Start (or restart) the source's clip on its track.
audio_play :: proc(src: ^AudioSource, fade_in_ms: i64 = 0) -> bool {
	clip, ok := clip_load(src.clip)
	if !ok do return false
	if src.track == nil {
		src.track = mix.CreateTrack(_audio_state.mixer)
		if src.track == nil do return false
	}
	if !mix.SetTrackAudio(src.track, clip.audio) do return false
	_ = mix.SetTrackGain(src.track, src.volume)
	_ = mix.SetTrackLoops(src.track, src.loop ? -1 : 0)
	props: sdl.PropertiesID
	if fade_in_ms > 0 {
		props = sdl.CreateProperties()
		_ = sdl.SetNumberProperty(props, mix.PROP_PLAY_FADE_IN_MILLISECONDS_NUMBER, sdl.Sint64(fade_in_ms))
	}
	defer if props != 0 do sdl.DestroyProperties(props)
	return mix.PlayTrack(src.track, props)
}

audio_stop :: proc(src: ^AudioSource, fade_out_ms: i64 = 0) {
	if src.track == nil do return
	frames: sdl.Sint64
	if fade_out_ms > 0 do frames = mix.TrackMSToFrames(src.track, sdl.Sint64(fade_out_ms))
	_ = mix.StopTrack(src.track, frames)
}

audio_is_playing :: proc(src: ^AudioSource) -> bool {
	return src.track != nil && bool(mix.TrackPlaying(src.track))
}

// --- One-shots ---------------------------------------------------------------

// Fire-and-forget transient tracks — no component owns them, the update
// sweep frees each one when its playback ends.

_One_Shot :: struct {
	track:    ^mix.Track,
	position: [3]f32,
	volume:   f32,
	spatial:  bool,
}

_one_shots: [dynamic]_One_Shot

// The last known listener (refreshed by audio_update) — lets a one-shot
// spatialize on its very first frame.
_listener: struct {
	pos: [3]f32,
	rot: [4]f32,
	ok:  bool,
}

// 2D one-shot at plain volume.
play_clip :: proc(guid: engine.Asset_GUID, volume: f32 = 1) -> bool {
	return _one_shot_start(guid, {}, volume, spatial = false)
}

// Unity's PlayClipAtPoint: a one-shot spatialized at a world position
// (full blend, default 1/500 distances).
play_clip_at_point :: proc(guid: engine.Asset_GUID, position: [3]f32, volume: f32 = 1) -> bool {
	return _one_shot_start(guid, position, volume, spatial = true)
}

_one_shot_start :: proc(guid: engine.Asset_GUID, position: [3]f32, volume: f32, spatial: bool) -> bool {
	clip, ok := clip_load(guid)
	if !ok do return false
	track := mix.CreateTrack(_audio_state.mixer)
	if track == nil do return false
	if !mix.SetTrackAudio(track, clip.audio) || !mix.PlayTrack(track, 0) {
		mix.DestroyTrack(track)
		return false
	}
	shot := _One_Shot{track, position, volume, spatial}
	_one_shot_apply(&shot)
	context.allocator = runtime.default_allocator()
	append(&_one_shots, shot)
	return true
}

_one_shot_apply :: proc(shot: ^_One_Shot) {
	sp := Spatial_Gains{1, 1, 1}
	if shot.spatial && _listener.ok {
		sp = spatial_gains(_listener.pos, _listener.rot, shot.position, 1, 500, 1)
	}
	_ = mix.SetTrackGain(shot.track, shot.volume * sp.gain)
	stereo := mix.StereoGains{sp.left, sp.right}
	_ = mix.SetTrackStereo(shot.track, &stereo)
}

_one_shots_clear :: proc() {
	for shot in _one_shots {
		mix.DestroyTrack(shot.track)
	}
	clear(&_one_shots)
}

// Inspector action buttons — auditioning a source without entering play
// mode (the editor's generated registration wires these to the component).

@(inspector_button={label="Play", row=0})
audio_btn_play :: proc(src: ^AudioSource) {
	_ = audio_play(src)
}

@(inspector_button={label="Stop", row=0})
audio_btn_stop :: proc(src: ^AudioSource) {
	audio_stop(src)
}

// --- Asset preview ---------------------------------------------------------

// One shared preview track, independent of any component — the asset
// inspector's Play button.

_preview_track: ^mix.Track
_preview_guid: engine.Asset_GUID

preview_play :: proc(guid: engine.Asset_GUID) -> bool {
	clip, ok := clip_load(guid)
	if !ok do return false
	if _preview_track == nil {
		_preview_track = mix.CreateTrack(_audio_state.mixer)
		if _preview_track == nil do return false
	}
	if !mix.SetTrackAudio(_preview_track, clip.audio) do return false
	_preview_guid = guid
	return mix.PlayTrack(_preview_track, 0)
}

preview_stop :: proc() {
	if _preview_track != nil do _ = mix.StopTrack(_preview_track, 0)
}

// True only while THIS asset previews — the pane's playhead check.
preview_playing :: proc(guid := engine.Asset_GUID{}) -> bool {
	if _preview_track == nil || !mix.TrackPlaying(_preview_track) do return false
	return guid == {} || guid == _preview_guid
}

// Playhead in sample frames of the previewed clip.
preview_position :: proc() -> i64 {
	if _preview_track == nil do return 0
	return i64(mix.GetTrackPlaybackPosition(_preview_track))
}

preview_seek :: proc(frames: i64) {
	if _preview_track != nil do _ = mix.SetTrackPlaybackPosition(_preview_track, frames)
}

@(update={order=3})
audio_update :: proc(dt: f32) {
	context.allocator = runtime.default_allocator()
	w := engine.ctx_world()
	if w == nil do return

	// The ear: the first enabled AudioListener with a live transform.
	_listener.ok = false
	_listener.rot = engine.QUAT_IDENTITY
	if lpool := audio_listeners(w); lpool != nil {
		lit := engine.pool_iterator(lpool)
		for l, _ in engine.pool_next(&lit) {
			if !l.enabled || !engine.pool_valid(&w.transforms, engine.Handle(l.owner)) do continue
			lw := engine.transform_world(l.owner)
			_listener.pos = lw.position
			_listener.rot = lw.rotation
			_listener.ok = true
			break
		}
	}

	// One-shots: reap the finished, respatialize the rest. Before the
	// sources loop — a world with no AudioSource still owns one-shots.
	for i := len(_one_shots) - 1; i >= 0; i -= 1 {
		shot := &_one_shots[i]
		if !mix.TrackPlaying(shot.track) {
			mix.DestroyTrack(shot.track)
			unordered_remove(&_one_shots, i)
			continue
		}
		_one_shot_apply(shot)
	}

	pool := audio_sources(w)
	if pool == nil do return
	it := engine.pool_iterator(pool)
	for src, _ in engine.pool_next(&it) {
		if !engine.pool_valid(&w.transforms, engine.Handle(src.owner)) do continue
		if !src.enabled {
			// Unity: a disabled source stops, and play-on-awake replays on
			// re-enable.
			if src.started {
				audio_stop(src)
				src.started = false
			}
			continue
		}
		if src.play_on_awake && !src.started {
			src.started = true
			audio_play(src)
		}
		if src.track == nil do continue

		// Live controls apply every frame — inspector edits are audible.
		sp := Spatial_Gains{1, 1, 1}
		if _listener.ok && src.spatial_blend > 0 {
			sw := engine.transform_world(src.owner)
			sp = spatial_gains(_listener.pos, _listener.rot, sw.position,
				src.min_distance, src.max_distance, src.spatial_blend)
		}
		gain := src.mute ? 0 : src.volume * sp.gain
		_ = mix.SetTrackGain(src.track, gain)
		stereo := mix.StereoGains{sp.left, sp.right}
		_ = mix.SetTrackStereo(src.track, &stereo)
		_ = mix.SetTrackFrequencyRatio(src.track, max(src.pitch, 0.01))
	}
}

@(phase={key=ExitingPlayMode})
audio_exiting_play_mode :: proc() {
	_one_shots_clear()
	if _audio_state.mixer != nil do _ = mix.StopAllTracks(_audio_state.mixer, 0)
}
