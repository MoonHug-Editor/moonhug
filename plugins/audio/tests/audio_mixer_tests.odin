package audio_tests

// The Audio Mixer at runtime (audio/mixer_runtime.odin): tracks routed to a
// group are mixed through its volume and effects and every parent's, driven
// through the deviceless mixer with mix.Generate and measured at the output
// and at each group's level.

import "core:encoding/json"
import "core:encoding/uuid"
import "core:math"
import "core:os"
import "core:testing"
import sdl "vendor:sdl3"
import mix "vendor:sdl3/mixer"
import asset_pipeline "moonhug:editor/assets"
import "moonhug:registration"
import "moonhug:packages/engine"
import audio "moonhug:packages/audio"
import common "moonhug:tests/common"

@(private = "file")
_GUID :: engine.Asset_GUID{0 = 0x3a, 15 = 0x01}

@(private = "file")
_MUSIC :: engine.PPtr{guid = _GUID, local_id = 2}
@(private = "file")
_DIALOGUE :: engine.PPtr{guid = _GUID, local_id = 3}

// Master, and Music and Dialogue under it, with `music_effects` on Music.
@(private = "file")
_mixer :: proc(master_db, music_db: f32, music_effects: ..audio.Mixer_Effect) -> audio.AudioMixer {
	m: audio.AudioMixer
	m.groups = make([dynamic]audio.Mixer_Group, context.temp_allocator)
	fx := make([dynamic]audio.Mixer_Effect, context.temp_allocator)
	append(&fx, ..music_effects)
	append(&m.groups,
		audio.Mixer_Group{id = 1, name = "Master", volume = master_db},
		audio.Mixer_Group{id = 2, parent = 1, name = "Music", volume = music_db, effects = fx},
		audio.Mixer_Group{id = 3, parent = 1, name = "Dialogue"},
	)
	m.next_id = 4
	return m
}

// A looping stereo tone at `hz`, amplitude `amp`, on a track of its own.
@(private = "file")
_tone :: proc(hz, amp: f32) -> (^mix.Track, ^mix.Audio) {
	mixer := audio._audio_state.mixer
	RATE :: 44100
	frames := RATE / 10 * 10 // a whole number of cycles of the tones used
	pcm := make([]f32, frames * 2, context.temp_allocator)
	for i in 0 ..< frames {
		s := amp * math.sin(2 * math.PI * hz * f32(i) / RATE)
		pcm[2 * i], pcm[2 * i + 1] = s, s
	}
	spec := sdl.AudioSpec{format = .F32, channels = 2, freq = RATE}
	a := mix.LoadRawAudio(mixer, raw_data(pcm), uint(len(pcm) * size_of(f32)), spec)
	t := mix.CreateTrack(mixer)
	_ = mix.SetTrackAudio(t, a)
	props := sdl.CreateProperties()
	defer sdl.DestroyProperties(props)
	_ = sdl.SetNumberProperty(props, mix.PROP_PLAY_LOOPS_NUMBER, -1)
	_ = mix.PlayTrack(t, props)
	return t, a
}

// Mixes `seconds` and gives the loudest output sample of the last tenth.
@(private = "file")
_render :: proc(seconds: f32) -> f32 {
	mixer := audio._audio_state.mixer
	buf: [4096]f32 // 2048 stereo frames, about 46 ms
	blocks := int(seconds * 44100 / 2048) + 1
	tail := max(blocks / 10, 2)
	peak: f32
	for b in 0 ..< blocks {
		n := mix.Generate(mixer, raw_data(buf[:]), i32(size_of(buf)))
		if n <= 0 do break
		if b >= blocks - tail do peak = max(peak, audio.peak_of(buf[:int(n) / size_of(f32)]))
	}
	return peak
}

@(private = "file")
_close :: proc(a, b: f32, tolerance: f32 = 0.01) -> bool {
	return abs(a - b) <= tolerance
}

@(test)
test_mixer_volume_goes_through_every_parent :: proc(t: ^testing.T) {
	audio.mixer_init_headless()
	defer audio.mixer_runtime_reset()
	m := _mixer(-6.0206, -6.0206) // each halves
	audio.mixer_preview(_GUID, &m)

	track, a := _tone(220, 0.8)
	defer {
		mix.DestroyTrack(track)
		mix.DestroyAudio(a)
	}
	testing.expectf(t, _close(_render(0.2), 0.8), "unrouted, the tone plays as it is")

	testing.expect(t, audio.mixer_route(track, _MUSIC), "routed to Music")
	out := _render(0.2)
	testing.expectf(t, _close(out, 0.2), "Music and the Master each halve it: %v", out)
	testing.expectf(t, _close(audio.mixer_level(_MUSIC), -7.96, 0.2), "Music's level is after its own volume: %v dB", audio.mixer_level(_MUSIC))

	audio.mixer_set_volume(_MUSIC, 0)
	testing.expectf(t, _close(_render(0.2), 0.4), "a runtime volume replaces the asset's")
	testing.expect_value(t, audio.mixer_volume(_MUSIC), 0)
	audio.mixer_clear_volumes()
	testing.expect(t, _close(_render(0.2), 0.2), "and goes back to it")

	// An edit of the asset is heard at once, the routing kept.
	m.groups[1].mute = true
	audio.mixer_preview(_GUID, &m)
	testing.expectf(t, _render(0.2) < 0.001, "a muted group is silent")

	testing.expect(t, audio.mixer_route(track, {}), "unset output")
	testing.expect(t, _close(_render(0.2), 0.8), "plays straight to the output again")
	testing.expect(t, !audio.mixer_route(track, {guid = _GUID, local_id = 99}), "a group that is not there is no route")
}

@(test)
test_mixer_low_pass_and_high_pass :: proc(t: ^testing.T) {
	audio.mixer_init_headless()
	defer audio.mixer_runtime_reset()
	m := _mixer(0, 0, audio.Mixer_Low_Pass{cutoff = 500})
	audio.mixer_preview(_GUID, &m)

	high, ha := _tone(8000, 0.5)
	defer {
		mix.DestroyTrack(high)
		mix.DestroyAudio(ha)
	}
	audio.mixer_route(high, _MUSIC)
	out := _render(0.2)
	testing.expectf(t, out < 0.02, "a low pass at 500 Hz muffles 8 kHz: %v", out)
	_ = mix.StopTrack(high, 0)

	low, la := _tone(100, 0.5)
	defer {
		mix.DestroyTrack(low)
		mix.DestroyAudio(la)
	}
	audio.mixer_route(low, _MUSIC)
	out = _render(0.2)
	testing.expectf(t, _close(out, 0.5, 0.03), "and lets 100 Hz through: %v", out)

	// The same group as a high pass: the other way round.
	m.groups[1].effects[0] = audio.Mixer_High_Pass{cutoff = 2000}
	audio.mixer_preview(_GUID, &m)
	out = _render(0.2)
	testing.expectf(t, out < 0.02, "a high pass at 2 kHz thins out 100 Hz: %v", out)
}

@(test)
test_mixer_duck_turns_music_down_while_dialogue_plays :: proc(t: ^testing.T) {
	audio.mixer_init_headless()
	defer audio.mixer_runtime_reset()
	m := _mixer(0, 0, audio.Mixer_Duck{by = 3, threshold = -30, ratio = 4, attack = 20, release = 100})
	audio.mixer_preview(_GUID, &m)

	music, ma := _tone(220, 0.5)
	defer {
		mix.DestroyTrack(music)
		mix.DestroyAudio(ma)
	}
	audio.mixer_route(music, _MUSIC)
	_render(0.3)
	alone := audio.mixer_level(_MUSIC)
	testing.expectf(t, _close(alone, -6.02, 0.2), "music alone plays at its level: %v dB", alone)

	// Dialogue at -6 dB is 24 dB over the threshold: music goes 18 dB down.
	dialogue, da := _tone(330, 0.5)
	defer {
		mix.DestroyAudio(da)
	}
	audio.mixer_route(dialogue, _DIALOGUE)
	_render(0.5)
	ducked := audio.mixer_level(_MUSIC)
	testing.expectf(t, _close(ducked, alone - 18, 1.5), "under dialogue, music is turned down 18 dB: %v dB", ducked)

	// Dialogue stops: music comes back.
	mix.DestroyTrack(dialogue)
	_render(1.0)
	testing.expectf(t, _close(audio.mixer_level(_MUSIC), alone, 0.5), "music comes back after dialogue: %v dB", audio.mixer_level(_MUSIC))
}

@(test)
test_mixer_effect_zero_fields_mean_defaults :: proc(t: ^testing.T) {
	lp := audio.mixer_effect_defaults(audio.Mixer_Low_Pass{}).(audio.Mixer_Low_Pass)
	testing.expect_value(t, lp.cutoff, 5000)
	testing.expect_value(t, lp.resonance, 1)
	duck := audio.mixer_effect_defaults(audio.Mixer_Duck{by = 3}).(audio.Mixer_Duck)
	testing.expect(t, duck.by == 3 && duck.threshold == -30 && duck.ratio == 4 && duck.attack == 50 && duck.release == 400, "a duck's zeros are its defaults")

	// A mixer read with its groups out of order or ids repeated is put right.
	m: audio.AudioMixer
	append(&m.groups,
		audio.Mixer_Group{id = 1, name = "Master"},
		audio.Mixer_Group{id = 1, parent = 1, name = "Copy"},
		audio.Mixer_Group{id = 5, parent = 9, name = "Lost"},
	)
	defer delete(m.groups)
	audio.type_on_validate_AudioMixer(&m)
	testing.expect(t, m.groups[1].id != 1, "a repeated id gets a new one")
	testing.expect_value(t, m.groups[2].parent, 1)
	testing.expect(t, m.next_id > m.groups[1].id && m.next_id > 5, "next_id is past every id")
}

// An AudioSource end to end: its clip loops, plays through its output group,
// a low-pass filter on its object muffles it, and occlusion turns it down.
@(test)
test_audio_source_loops_through_its_output_and_filters :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	registration.register_importers()
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	audio.mixer_init_headless()
	defer audio.mixer_runtime_reset()

	src_dir :: "moonhug/tests/fixtures/_audio_mixer_tmp"
	wav :: src_dir + "/probe.wav"
	os.make_directory(src_dir)
	testing.expect(t, _write_test_wav(wav))
	defer {
		audio.clip_cache_shutdown()
		os.remove(wav)
		os.remove(wav + ".meta")
		os.remove(src_dir)
		_remove_tree(engine.library_dir())
	}
	asset_pipeline.asset_pipeline_init()
	asset_pipeline.asset_pipeline_ensure_import_meta(wav)
	Meta :: struct {
		guid: string,
	}
	meta: Meta
	meta_data, _ := os.read_entire_file(wav + ".meta", context.temp_allocator)
	testing.expect(t, json.unmarshal(meta_data, &meta, allocator = context.temp_allocator) == nil)
	raw_guid, _ := uuid.read(meta.guid)
	testing.expect(t, asset_pipeline.asset_pipeline_import_asset(wav))

	m := _mixer(0, 0)
	audio.mixer_preview(_GUID, &m)
	owner := engine.transform_new("Speaker")
	_, ptr := engine.transform_add_comp(owner, .AudioSource)
	src := cast(^audio.AudioSource)ptr
	src.clip = engine.PPtr{guid = engine.Asset_GUID(raw_guid)}
	src.output = _MUSIC
	src.loop = true
	src.play_on_awake = false
	testing.expect(t, audio.audio_play(src), "the source plays")

	// The clip is 0.1 s: half a second later it plays on, through Music.
	_render(0.5)
	testing.expect(t, audio.audio_is_playing(src), "a looping source plays past its clip's end")
	clear := audio.mixer_level(_MUSIC)
	testing.expectf(t, _close(clear, -6.02, 0.5), "through Music, at the clip's level: %v dB", clear)

	// A low pass at 100 Hz on its object muffles the 440 Hz clip.
	_, lp_ptr := engine.transform_add_comp(owner, .AudioLowPassFilter)
	lp := cast(^audio.AudioLowPassFilter)lp_ptr
	lp.cutoff = 100
	audio.audio_update(1.0 / 60)
	_render(0.3)
	muffled := audio.mixer_level(_MUSIC)
	testing.expectf(t, muffled < clear - 12, "the low pass muffles it: %v dB from %v dB", muffled, clear)
	lp.enabled = false
	audio.audio_update(1.0 / 60)
	_render(0.3)
	testing.expectf(t, _close(audio.mixer_level(_MUSIC), clear, 0.5), "and disabled lets it through again: %v dB", audio.mixer_level(_MUSIC))

	// Fully occluded at half volume: 6 dB down, and muffled.
	src.occlusion = {amount = 1, cutoff = 20000, volume = 0.5, frame = audio.audio_frame() + 1}
	audio.audio_update(1.0 / 60)
	_render(0.3)
	testing.expectf(t, _close(audio.mixer_level(_MUSIC), clear - 6.02, 0.5), "occlusion turns it down: %v dB", audio.mixer_level(_MUSIC))
	// Nothing sets it for two frames: clear again.
	audio.audio_update(1.0 / 60)
	audio.audio_update(1.0 / 60)
	_render(0.3)
	testing.expectf(t, _close(audio.mixer_level(_MUSIC), clear, 0.5), "occlusion no one sets fades out: %v dB", audio.mixer_level(_MUSIC))

	src.loop = false
	testing.expect(t, audio.audio_play(src), "played again without loop")
	_render(0.5)
	testing.expect(t, !audio.audio_is_playing(src), "and it stops at the clip's end")
}
