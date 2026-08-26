package audio_tests

// The audio package end to end: the importer decodes the source, bakes the
// settings volume into a float32 WAV artifact, and clip_load serves the
// artifact through the guid-keyed cache. Headless — the mixer falls back to
// a deviceless instance, nothing is audible.

import "core:encoding/json"
import "core:encoding/uuid"
import "core:math"
import "core:os"
import "core:strings"
import "core:testing"
import "moonhug:engine"
import "moonhug:engine_editor/asset_pipeline"
import anim "moonhug:packages/animation"
import audio "moonhug:packages/audio"
import audio_editor "moonhug:packages/audio/editor"
import common "moonhug:tests/common"

_SAMPLE_RATE :: 22050
_FRAMES :: 2205 // 0.1 s
_AMPLITUDE :: 0.5

// Minimal mono PCM16 WAV with a 440 Hz sine at _AMPLITUDE peak.
_write_test_wav :: proc(path: string) -> bool {
	data_size := u32(_FRAMES * 2)
	out := make([dynamic]u8, 0, int(data_size) + 44, context.temp_allocator)
	w_u16 :: proc(out: ^[dynamic]u8, v: u16) { append(out, u8(v), u8(v >> 8)) }
	w_u32 :: proc(out: ^[dynamic]u8, v: u32) {
		append(out, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
	}
	append(&out, "RIFF")
	w_u32(&out, 36 + data_size)
	append(&out, "WAVE")
	append(&out, "fmt ")
	w_u32(&out, 16)
	w_u16(&out, 1) // PCM
	w_u16(&out, 1) // mono
	w_u32(&out, _SAMPLE_RATE)
	w_u32(&out, _SAMPLE_RATE * 2)
	w_u16(&out, 2)
	w_u16(&out, 16)
	append(&out, "data")
	w_u32(&out, data_size)
	for i in 0 ..< _FRAMES {
		s := _AMPLITUDE * math.sin(2 * math.PI * 440 * f64(i) / _SAMPLE_RATE)
		v := i16(s * 32767)
		w_u16(&out, u16(v))
	}
	return os.write_entire_file(path, out[:]) == nil
}

_peak :: proc(pcm: []f32) -> f32 {
	peak: f32
	for s in pcm {
		if abs(s) > peak do peak = abs(s)
	}
	return peak
}

_remove_tree :: proc(dir: string) {
	handle, err := os.open(dir)
	if err != nil do return
	entries, rerr := os.read_dir(handle, -1, context.temp_allocator)
	os.close(handle)
	if rerr != nil do return
	for entry in entries {
		full := strings.concatenate({dir, "/", entry.name}, context.temp_allocator)
		if entry.type == .Directory do _remove_tree(full)
		else do os.remove(full)
	}
	os.remove(dir)
}

@(test)
test_import_bakes_volume_and_clip_loads :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	audio_editor.audio_importers_init()
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	audio.mixer_init_headless()

	src_dir :: "moonhug/tests/fixtures/_audio_tmp"
	wav :: src_dir + "/probe.wav"
	os.make_directory(src_dir)
	testing.expect(t, _write_test_wav(wav), "fixture wav written")
	defer {
		audio.clip_cache_shutdown()
		os.remove(wav)
		os.remove(wav + ".meta")
		os.remove(src_dir)
		_remove_tree("library")
	}

	asset_pipeline.asset_pipeline_init()
	asset_pipeline.asset_pipeline_ensure_import_meta(wav)

	Meta :: struct {
		guid: string,
	}
	meta: Meta
	meta_data, mrerr := os.read_entire_file(wav + ".meta", context.temp_allocator)
	testing.expect(t, mrerr == nil)
	if mrerr != nil do return
	testing.expect(t, json.unmarshal(meta_data, &meta, allocator = context.temp_allocator) == nil)
	raw_guid, perr := uuid.read(meta.guid)
	testing.expect(t, perr == nil)
	if perr != nil do return
	guid := engine.Asset_GUID(raw_guid)

	// Import at volume 1: the artifact is a decodable float WAV with the
	// source's peak.
	testing.expect(t, asset_pipeline.asset_pipeline_import_asset(wav), "first import should run")
	p1, ok1 := engine.asset_pipeline_artifact_path(guid)
	testing.expect(t, ok1)
	if !ok1 do return
	p1 = strings.clone(p1, context.temp_allocator)

	pcm1, spec1, dok1 := audio.decode_file_f32(p1)
	testing.expect(t, dok1, "artifact decodes")
	if !dok1 do return
	defer delete(pcm1)
	testing.expect_value(t, spec1.freq, _SAMPLE_RATE)
	testing.expect_value(t, spec1.channels, 1)
	testing.expect_value(t, len(pcm1), _FRAMES)
	testing.expect(t, abs(_peak(pcm1) - _AMPLITUDE) < 0.02, "peak matches the source amplitude")

	// The clip cache serves the first artifact by guid.
	clip1, cok1 := audio.clip_load(guid)
	testing.expect(t, cok1, "clip_load resolves the guid")
	if !cok1 do return
	testing.expect_value(t, clip1.frames, i64(_FRAMES))

	// Halving the settings volume bakes half the gain into a NEW artifact.
	s, sok := engine.asset_pipeline_get_settings(wav)
	testing.expect(t, sok)
	if !sok do return
	defer free(s.data) // the caller owns the settings instance
	as := s.(audio.AudioSettings)
	as.volume = 0.5
	testing.expect(t, asset_pipeline.asset_pipeline_save_settings(wav, as))
	testing.expect(t, asset_pipeline.asset_pipeline_import_asset(wav), "volume change should import")
	p2, ok2 := engine.asset_pipeline_artifact_path(guid)
	testing.expect(t, ok2)
	if !ok2 do return
	testing.expect(t, p2 != p1, "changed volume should produce a different artifact key")

	pcm2, _, dok2 := audio.decode_file_f32(p2)
	testing.expect(t, dok2)
	if !dok2 do return
	defer delete(pcm2)
	testing.expect(t, abs(_peak(pcm2) - _AMPLITUDE * 0.5) < 0.02, "half volume baked into the PCM")

	// The reimport hook evicted the stale clip — the next load serves the
	// new master.
	testing.expect(t, guid not_in audio.clip_cache, "reimport evicts the cached clip")
	clip, cok := audio.clip_load(guid)
	testing.expect(t, cok, "clip_load reloads after eviction")
	if !cok do return
	testing.expect_value(t, clip.sample_rate, i32(_SAMPLE_RATE))
	testing.expect_value(t, clip.channels, i32(1))
	testing.expect_value(t, clip.frames, i64(_FRAMES))

	// Second load is the cached instance.
	clip2, _ := audio.clip_load(guid)
	testing.expect(t, clip == clip2, "cache hit returns the same clip")

	// Unknown guids miss.
	_, miss := audio.clip_load(engine.Asset_GUID{})
	testing.expect(t, !miss)

	// Normalize scales the peak to 1 before volume applies.
	as.volume = 1
	as.normalize = true
	testing.expect(t, asset_pipeline.asset_pipeline_save_settings(wav, as))
	testing.expect(t, asset_pipeline.asset_pipeline_import_asset(wav), "normalize change should import")
	p3, ok3 := engine.asset_pipeline_artifact_path(guid)
	testing.expect(t, ok3)
	if !ok3 do return
	pcm3, _, dok3 := audio.decode_file_f32(p3)
	testing.expect(t, dok3)
	if !dok3 do return
	defer delete(pcm3)
	testing.expect(t, abs(_peak(pcm3) - 1.0) < 0.02, "normalized peak hits 1")
}

@(test)
test_audiosource_component :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	audio_editor.audio_importers_init()
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	tH := engine.transform_new("Speaker")
	_, ptr := engine.transform_add_comp(tH, .AudioSource)
	testing.expect(t, ptr != nil, "AudioSource attaches like any component")
	if ptr == nil do return
	src := cast(^audio.AudioSource)ptr

	// Unity defaults via reset.
	testing.expect_value(t, src.volume, f32(1))
	testing.expect_value(t, src.play_on_awake, true)
	testing.expect_value(t, src.loop, false)
	testing.expect(t, src.clip == {}, "no clip by default")
}

// The audio timeline track: a clip span starts the bound AudioSource with
// the clip's asset, leaving the span stops it, scrubbing is silent.
@(test)
test_audio_timeline_track :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	audio_editor.audio_importers_init()
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	audio.mixer_init_headless()
	anim.animation_clip_cache_init()
	defer anim.animation_clip_cache_shutdown()
	anim.timeline_cache_init()
	defer anim.timeline_cache_shutdown()
	audio.audio_track_init()

	src_dir :: "moonhug/tests/fixtures/_audio_track_tmp"
	wav :: src_dir + "/probe.wav"
	os.make_directory(src_dir)
	testing.expect(t, _write_test_wav(wav))
	defer {
		audio.clip_cache_shutdown()
		os.remove(wav)
		os.remove(wav + ".meta")
		os.remove(src_dir)
		_remove_tree("library")
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
	clip_guid := engine.Asset_GUID(raw_guid)
	testing.expect(t, asset_pipeline.asset_pipeline_import_asset(wav))

	root := engine.transform_new("Stage")
	engine.scene_set_root(tc.scene, root)
	owned, raw := engine.transform_add_comp(root, .AudioSource)
	src := cast(^audio.AudioSource)raw
	src.enabled = true
	src.volume = 1
	src.pitch = 1
	src.play_on_awake = false

	tl := anim.Timeline{duration = 2}
	tl.tracks = make([dynamic]anim.Timeline_Track)
	track := anim.Timeline_Track{kind = strings.clone("audio"), name = strings.clone("music")}
	track.clips = make([dynamic]anim.Timeline_Clip)
	append(&track.clips, anim.Timeline_Clip{start = 0.5, duration = 1, asset = clip_guid})
	append(&tl.tracks, track)
	tl_guid: engine.Asset_GUID
	tl_guid[0] = 0xDD
	anim.timeline_cache[tl_guid] = tl

	_, draw_ := engine.transform_add_comp(root, .PlayableDirector)
	d := cast(^anim.PlayableDirector)draw_
	d.enabled = true
	d.wrap = .Once
	d.timeline = {guid = tl_guid}
	append(&d.bindings, anim.Track_Binding{track = 0, target = {handle = owned.handle}})

	// Before the span: silent.
	for _ in 0 ..< 3 do anim.director_tick(d, 0.1) // t = 0.3
	testing.expect(t, !audio.audio_is_playing(src), "silent before the span")

	// Crossing the start plays the clip's asset on the source.
	for _ in 0 ..< 4 do anim.director_tick(d, 0.1) // t = 0.7
	testing.expect(t, audio.audio_is_playing(src), "span start must play")
	testing.expect(t, src.clip == clip_guid, "the clip's asset lands on the source")

	// Leaving the span stops it.
	for _ in 0 ..< 10 do anim.director_tick(d, 0.1) // t = 1.7
	testing.expect(t, !audio.audio_is_playing(src), "leaving the span must stop")

	// Scrubbing is silent.
	anim.director_set_time(d, 0.7)
	testing.expect(t, !audio.audio_is_playing(src), "scrub must not play audio")
}
