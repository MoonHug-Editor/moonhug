package audio

// Playback: one SDL3_mixer device mixer, opened at engine start, one track
// per playing AudioSource. Headless contexts (tests, tooling) run no engine
// start: the first use creates a deviceless mixer. Loading and decoding work,
// nothing is audible.
//
// The @(update) subscriber lands in the generated per-frame dispatcher, so
// sources tick in play mode (editor) and always (app).

import "base:runtime"
import "core:fmt"
import sdl "vendor:sdl3"
import mix "vendor:sdl3/mixer"
import engine "moonhug:packages/engine"

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
// Whoever asks for a mixer FIRST decides whether a playback device opens, and
// clip_load asks on its own through _mixer_ensure. So a test that opens a
// deviceless mixer in its own body is not enough: anything that loaded a clip
// earlier in the process already opened the device, and every later
// mixer_init_headless returns that one. Set this before any of it runs
// (audio/tests declares it at @(init)) and no device is ever opened.
@(private)
_force_deviceless: bool

// Never open a playback DEVICE in this process. A test binary says so once at
// startup: a device mixer is driven by its own audio callback, so mix.Generate
// pulls nothing from it and a test that steps a clip by hand hangs on tracks
// that never finish — besides playing the fixtures out loud.
audio_force_deviceless :: proc() {
	_force_deviceless = true
}

mixer_init_headless :: proc() -> bool {
	_force_deviceless = true
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
	m: ^mix.Mixer
	if !_force_deviceless do m = mix.CreateMixerDevice(sdl.AUDIO_DEVICE_DEFAULT_PLAYBACK, nil)
	if m == nil do m = _create_deviceless_mixer()
	_audio_state.mixer = m
	return m != nil
}

// When the playback device opens. Opening it takes about 190 ms and closing it
// about 150 ms, so the first sound must not pay for it mid-game, and an
// editor that plays nothing should not pay for it at all:
// - A built game opens it at engine start.
// - The editor opens it when Play starts.
// - Anything else opens it on first use: a clip load or a sound calls
//   _mixer_ensure (an audio clip previewed in the editor, a test).
@(phase={key=EngineInit, order=20, mode=App})
engine_init_audio_device :: proc() {
	_mixer_ensure()
}

@(phase={key=EnteredPlayMode, mode=Editor})
audio_entered_play_mode :: proc() {
	_mixer_ensure()
}

// Start (or restart) the source's clip on its track.
audio_play :: proc(src: ^AudioSource, fade_in_ms: i64 = 0) -> bool {
	clip, ok := clip_load(engine.asset_key(src.clip))
	if !ok do return false
	if src.track == nil {
		src.track = mix.CreateTrack(_audio_state.mixer)
		if src.track == nil do return false
	}
	_source_route(src)
	if !mix.SetTrackAudio(src.track, clip.audio) do return false
	_ = mix.SetTrackGain(src.track, src.volume)
	// Starting a track sets its loop count from the options: SetTrackLoops
	// on a stopped track does nothing.
	props := sdl.CreateProperties()
	defer sdl.DestroyProperties(props)
	_ = sdl.SetNumberProperty(props, mix.PROP_PLAY_LOOPS_NUMBER, src.loop ? -1 : 0)
	if fade_in_ms > 0 {
		_ = sdl.SetNumberProperty(props, mix.PROP_PLAY_FADE_IN_MILLISECONDS_NUMBER, sdl.Sint64(fade_in_ms))
	}
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

// Fire-and-forget voices: no component owns them. At most MAX_ONE_SHOTS
// play at once: a new one past that takes the place of the quietest. A voice
// that ends goes back to a pool of tracks the next one-shot reuses, so a
// burst of sounds does not create and destroy a track each.

_One_Shot :: struct {
	track:    ^mix.Track,
	position: [3]f32,
	volume:   f32,
	spatial:  bool,
}

_one_shots: [dynamic]_One_Shot

// The most one-shots that play at once.
MAX_ONE_SHOTS :: 64

// Tracks of one-shots that ended, with no audio on them, for the next ones.
_free_one_shot_tracks: [dynamic]^mix.Track

// The last known listener (refreshed by audio_update) — lets a one-shot
// spatialize on its very first frame.
_listener: struct {
	pos:   [3]f32,
	rot:   [4]f32,
	owner: engine.Transform_Handle,
	ok:    bool,
}

// The ear this frame: the first enabled AudioListener's world position and
// rotation, and its object. ok is false with none.
audio_listener :: proc() -> (pos: [3]f32, rot: [4]f32, owner: engine.Transform_Handle, ok: bool) {
	return _listener.pos, _listener.rot, _listener.owner, _listener.ok
}

// 2D one-shot at plain volume, through the mixer group `output` names.
play_clip :: proc(guid: engine.Asset_GUID, volume: f32 = 1, output := engine.PPtr{}) -> bool {
	return _one_shot_start(guid, {}, volume, spatial = false, output = output)
}

// A one-shot spatialized at a world position
// (full blend, default 1/500 distances).
play_clip_at_point :: proc(guid: engine.Asset_GUID, position: [3]f32, volume: f32 = 1, output := engine.PPtr{}) -> bool {
	return _one_shot_start(guid, position, volume, spatial = true, output = output)
}

_one_shot_start :: proc(guid: engine.Asset_GUID, position: [3]f32, volume: f32, spatial: bool, output: engine.PPtr) -> bool {
	clip, ok := clip_load(guid)
	if !ok do return false
	// Ended voices first, so a full list is full of sounds still playing.
	_one_shots_reap()
	if len(_one_shots) >= MAX_ONE_SHOTS {
		quietest := 0
		for &shot, i in _one_shots {
			if _one_shot_level(&shot) < _one_shot_level(&_one_shots[quietest]) do quietest = i
		}
		_one_shot_release(_one_shots[quietest].track)
		unordered_remove(&_one_shots, quietest)
	}
	track := pop(&_free_one_shot_tracks) if len(_free_one_shot_tracks) > 0 else mix.CreateTrack(_audio_state.mixer)
	if track == nil do return false
	// A pooled track keeps the group of the shot before.
	mixer_route(track, output)
	if !mix.SetTrackAudio(track, clip.audio) || !mix.PlayTrack(track, 0) {
		_one_shot_release(track)
		return false
	}
	shot := _One_Shot{track, position, volume, spatial}
	_one_shot_apply(&shot)
	context.allocator = runtime.default_allocator()
	append(&_one_shots, shot)
	return true
}

@(private = "file")
_one_shot_gains :: proc(shot: ^_One_Shot) -> Spatial_Gains {
	if shot.spatial && _listener.ok do return spatial_gains(_listener.pos, _listener.rot, shot.position, 1, 500, 1)
	return Spatial_Gains{1, 1, 1}
}

// How loud a one-shot is at the listener: the one a full list gives up.
@(private = "file")
_one_shot_level :: proc(shot: ^_One_Shot) -> f32 {
	return shot.volume * _one_shot_gains(shot).gain
}

_one_shot_apply :: proc(shot: ^_One_Shot) {
	sp := _one_shot_gains(shot)
	_ = mix.SetTrackGain(shot.track, shot.volume * sp.gain)
	stereo := mix.StereoGains{sp.left, sp.right}
	_ = mix.SetTrackStereo(shot.track, &stereo)
}

// Stops a one-shot's track and puts it in the pool, its audio taken off, so
// a reimport can free the audio. A full pool frees it instead.
@(private = "file")
_one_shot_release :: proc(track: ^mix.Track) {
	_ = mix.StopTrack(track, 0)
	_ = mix.SetTrackAudio(track, nil)
	if len(_free_one_shot_tracks) >= MAX_ONE_SHOTS {
		mix.DestroyTrack(track)
		return
	}
	context.allocator = runtime.default_allocator()
	append(&_free_one_shot_tracks, track)
}

// Ended one-shots go back to the pool.
@(private = "file")
_one_shots_reap :: proc() {
	for i := len(_one_shots) - 1; i >= 0; i -= 1 {
		if mix.TrackPlaying(_one_shots[i].track) do continue
		_one_shot_release(_one_shots[i].track)
		unordered_remove(&_one_shots, i)
	}
}

// Stops every one-shot. Their tracks stay in the pool.
_one_shots_clear :: proc() {
	for shot in _one_shots do _one_shot_release(shot.track)
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

// Late: the ear and every source spatialize from the transforms the frame
// tick finished moving.
@(late_update)
audio_update :: proc(dt: f32) {
	context.allocator = runtime.default_allocator()
	_audio_frame += 1
	w := engine.ctx_world()
	if w == nil do return

	// The ear: the first enabled AudioListener with a live transform.
	_listener.ok = false
	_listener.owner = {}
	_listener.rot = engine.QUAT_IDENTITY
	if lpool := audio_listeners(w); lpool != nil {
		lit := engine.pool_iterator(lpool)
		for l, _ in engine.pool_next(&lit) {
			if !l.enabled || !engine.pool_valid(&w.transforms, engine.Handle(l.owner)) do continue
			lw := engine.transform_world(l.owner)
			_listener.pos = lw.position
			_listener.rot = lw.rotation
			_listener.owner = l.owner
			_listener.ok = true
			break
		}
	}

	// One-shots: reap the finished, respatialize the rest. Before the
	// sources loop — a world with no AudioSource still owns one-shots.
	_one_shots_reap()
	for &shot in _one_shots do _one_shot_apply(&shot)

	pool := audio_sources(w)
	if pool == nil do return
	it := engine.pool_iterator(pool)
	for src, _ in engine.pool_next(&it) {
		if !engine.pool_valid(&w.transforms, engine.Handle(src.owner)) do continue
		if !src.enabled {
			// A disabled source stops, and play-on-awake replays on
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
		if src.routed != src.output || src.routed_gen != _route_gen do _source_route(src)
		_source_filters_apply(src)
		source_apply_gains(src.track, src, 1)
	}
}

// Routes the source's own track to its output.
@(private)
_source_route :: proc(src: ^AudioSource) {
	mixer_route(src.track, src.output)
	src.routed = src.output
	src.routed_gen = _route_gen
}

// Writes a source's live controls onto ONE mixer track: volume × `weight` ×
// spatial attenuation (mute wins), stereo pan, pitch. The source's own track
// passes weight 1; the timeline's per-clip voices pass the clip weight, which
// is what makes an overlap a crossfade and an ease a fade.
source_apply_gains :: proc(track: ^mix.Track, src: ^AudioSource, weight: f32) {
	if track == nil do return
	sp := Spatial_Gains{1, 1, 1}
	if _listener.ok && src.spatial_blend > 0 {
		sw := engine.transform_world(src.owner)
		sp = spatial_gains(_listener.pos, _listener.rot, sw.position,
			src.min_distance, src.max_distance, src.spatial_blend)
	}
	gain := src.mute ? 0 : src.volume * weight * sp.gain
	if _occluded(src) {
		_, occluded_volume := occlusion_at(src.occlusion)
		gain *= occluded_volume
	}
	_ = mix.SetTrackGain(track, gain)
	stereo := mix.StereoGains{sp.left, sp.right}
	_ = mix.SetTrackStereo(track, &stereo)
	_ = mix.SetTrackFrequencyRatio(track, max(src.pitch, 0.01))
}

// A fresh mixer track playing `guid` from `seconds` in, through the mixer
// group `output` names, or nil. The timeline's clip voices are made here; the
// caller owns the track.
voice_start :: proc(guid: engine.Asset_GUID, seconds: f32, output := engine.PPtr{}) -> ^mix.Track {
	clip, ok := clip_load(guid)
	if !ok do return nil
	if !_mixer_ensure() do return nil
	track := mix.CreateTrack(_audio_state.mixer)
	if track == nil do return nil
	mixer_route(track, output)
	if !mix.SetTrackAudio(track, clip.audio) || !mix.PlayTrack(track, 0) {
		mix.DestroyTrack(track)
		return nil
	}
	voice_seek(track, seconds)
	return track
}

voice_seek :: proc(track: ^mix.Track, seconds: f32) {
	frames := mix.TrackMSToFrames(track, sdl.Sint64(seconds * 1000))
	_ = mix.SetTrackPlaybackPosition(track, frames)
}

// Playhead in seconds into the voice's clip.
voice_position :: proc(track: ^mix.Track) -> f32 {
	if track == nil do return 0
	return f32(mix.TrackFramesToMS(track, mix.GetTrackPlaybackPosition(track))) / 1000
}

@(phase={key=ExitingPlayMode})
audio_exiting_play_mode :: proc() {
	_one_shots_clear()
	if _audio_state.mixer != nil do _ = mix.StopAllTracks(_audio_state.mixer, 0)
}
