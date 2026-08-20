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

@(update={order=3})
audio_update :: proc(dt: f32) {
	context.allocator = runtime.default_allocator()
	w := engine.ctx_world()
	if w == nil do return
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
		if src.track != nil do _ = mix.SetTrackGain(src.track, src.volume)
	}
}

@(phase={key=ExitingPlayMode})
audio_exiting_play_mode :: proc() {
	if _audio_state.mixer != nil do _ = mix.StopAllTracks(_audio_state.mixer, 0)
}
