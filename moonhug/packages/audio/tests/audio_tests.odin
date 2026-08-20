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
import audio "moonhug:packages/audio"
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
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

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

	engine.asset_pipeline_init()
	engine.asset_pipeline_ensure_import_meta(wav)

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
	testing.expect(t, engine.asset_pipeline_import_asset(wav), "first import should run")
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
	testing.expect(t, engine.asset_pipeline_save_settings(wav, as))
	testing.expect(t, engine.asset_pipeline_import_asset(wav), "volume change should import")
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
}

@(test)
test_audiosource_component :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
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
