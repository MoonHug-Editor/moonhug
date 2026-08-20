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

_mixer_ensure :: proc() -> bool {
	if _audio_state.mixer != nil do return true
	_mix_lib_ensure()
	m := mix.CreateMixerDevice(sdl.AUDIO_DEVICE_DEFAULT_PLAYBACK, nil)
	if m == nil do m = mix.CreateMixer(nil)
	_audio_state.mixer = m
	return m != nil
}

// Start (or restart) the source's clip on its track.
audio_play :: proc(src: ^AudioSource) -> bool {
	clip, ok := clip_load(src.clip)
	if !ok do return false
	if src.track == nil {
		src.track = mix.CreateTrack(_audio_state.mixer)
		if src.track == nil do return false
	}
	if !mix.SetTrackAudio(src.track, clip.audio) do return false
	_ = mix.SetTrackGain(src.track, src.volume)
	_ = mix.SetTrackLoops(src.track, src.loop ? -1 : 0)
	return mix.PlayTrack(src.track, 0)
}

audio_stop :: proc(src: ^AudioSource) {
	if src.track != nil do _ = mix.StopTrack(src.track, 0)
}

audio_is_playing :: proc(src: ^AudioSource) -> bool {
	return src.track != nil && bool(mix.TrackPlaying(src.track))
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
	pool := audio_sources(w)
	if pool == nil do return

	// The ear: the first enabled AudioListener with a live transform.
	listener_pos: [3]f32
	listener_rot := engine.QUAT_IDENTITY
	has_listener := false
	if lpool := audio_listeners(w); lpool != nil {
		lit := engine.pool_iterator(lpool)
		for l, _ in engine.pool_next(&lit) {
			if !l.enabled || !engine.pool_valid(&w.transforms, engine.Handle(l.owner)) do continue
			lw := engine.transform_world(l.owner)
			listener_pos = lw.position
			listener_rot = lw.rotation
			has_listener = true
			break
		}
	}

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
		if has_listener && src.spatial_blend > 0 {
			sw := engine.transform_world(src.owner)
			sp = spatial_gains(listener_pos, listener_rot, sw.position,
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
	if _audio_state.mixer != nil do _ = mix.StopAllTracks(_audio_state.mixer, 0)
}
