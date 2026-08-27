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
import seq "moonhug:packages/sequencer"
import audio "moonhug:packages/audio"
import audio_editor "moonhug:packages/audio/editor"
import "moonhug:editor/inspector"
import "moonhug:editor/undo"
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

	_, draw_ := engine.transform_add_comp(root, .PlayableDirector)
	d := cast(^seq.PlayableDirector)draw_
	d.enabled = true
	d.wrap = .Once
	d.duration = 2
	defer seq.director_teardown(d)
	_mk_audio_track(root, {handle = owned.handle}, seq.Timeline_Clip{start = 0.5, duration = 1, asset = clip_guid})

	// Before the span: silent.
	for _ in 0 ..< 3 do seq.director_tick(d, 0.1) // t = 0.3
	testing.expect(t, !audio.audio_is_playing(src), "silent before the span")

	// Crossing the start plays the clip's asset on the source.
	for _ in 0 ..< 4 do seq.director_tick(d, 0.1) // t = 0.7
	testing.expect(t, audio.audio_is_playing(src), "span start must play")
	testing.expect(t, src.clip == clip_guid, "the clip's asset lands on the source")

	// Leaving the span stops it.
	for _ in 0 ..< 10 do seq.director_tick(d, 0.1) // t = 1.7
	testing.expect(t, !audio.audio_is_playing(src), "leaving the span must stop")

	// Scrubbing is silent.
	seq.director_set_time(d, 0.7)
	testing.expect(t, !audio.audio_is_playing(src), "scrub must not play audio")
}

// A director binding to an AudioSource (an EXT-pool component) must survive
// the Simulate round trip — serialize the scene, reload it in place.
@(test)
test_audio_binding_survives_serialize_roundtrip :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	seq.register_builtin_tracks()
	audio.audio_track_init()

	root := engine.transform_new("Stage")
	engine.scene_set_root(tc.scene, root)
	speaker := engine.transform_new("Speaker", root)
	owned, raw := engine.transform_add_comp(speaker, .AudioSource)
	src := cast(^audio.AudioSource)raw
	src.enabled = true
	want_lid := owned.local_id
	testing.expect(t, want_lid != 0, "the AudioSource must have a local id")

	comp_owned, draw_ := engine.transform_add_comp(root, .PlayableDirector)
	d := cast(^seq.PlayableDirector)draw_
	d.enabled = true

	// Bind the way the window's ref picker does — the picker resolves the
	// owner's ROOT SCENE from the inspector owner stack, so the window must
	// push it: with an empty stack the scene comes back nil and the picker
	// records no local_id at all (the binding then dies on scene reload).
	undo.push_component_owner(comp_owned.handle)
	picker_scene := inspector.ref_local_owner_root_scene()
	undo.pop_owner()
	testing.expect(t, picker_scene != nil, "the picker must resolve a scene from the owner stack")
	empty_stack_scene := inspector.ref_local_owner_root_scene()
	testing.expect(t, empty_stack_scene == nil, "no owner pushed = no scene = no local_id minted")
	minted := engine.sm_local_id_get_or_mint(picker_scene, owned.handle)
	testing.expect_value(t, minted, want_lid)
	_mk_audio_track(root, {local_id = minted, handle = owned.handle},
		seq.Timeline_Clip{start = 0, duration = 1})
	_ = comp_owned

	bytes, ok := engine.scene_serialize(tc.scene)
	testing.expect(t, ok, "snapshot should capture")
	if !ok do return
	defer delete(bytes)
	reloaded := engine.scene_reload_in_place_bytes(tc.scene, bytes)
	testing.expect(t, reloaded != nil, "restore should load")
	if reloaded == nil do return
	tc.scene = reloaded

	d2: ^seq.PlayableDirector
	{
		it := engine.pool_iterator(seq.playable_directors(&tc.world))
		for dd, _ in engine.pool_next(&it) do d2 = dd
	}
	testing.expect(t, d2 != nil)
	if d2 == nil do return
	tracks := seq.director_tracks(d2)
	testing.expect_value(t, len(tracks), 1)
	if len(tracks) != 1 do return
	testing.expect_value(t, tracks[0].target.local_id, want_lid)
	testing.expect(t, engine.world_pool_valid(&tc.world, tracks[0].target.handle),
		"the AudioSource binding must re-resolve after restore")
}

// The editor preview's PLAY button: director_preview_step advances with real
// crossings (audio sounds — Unity's Timeline preview), the per-frame restore
// (preview_end with playing=true) leaves the voice alone, and the final
// preview_end silences. A static scrub stays silent.
@(test)
test_audio_preview_play :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	audio_editor.audio_importers_init()
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	audio.mixer_init_headless()
	anim.animation_clip_cache_init()
	defer anim.animation_clip_cache_shutdown()
	audio.audio_track_init()

	src_dir :: "moonhug/tests/fixtures/_audio_preview_tmp"
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

	_, draw_ := engine.transform_add_comp(root, .PlayableDirector)
	d := cast(^seq.PlayableDirector)draw_
	d.enabled = true
	d.wrap = .Once
	d.duration = 2
	defer seq.director_teardown(d)
	_mk_audio_track(root, {handle = owned.handle}, seq.Timeline_Clip{start = 0.5, duration = 1, asset = clip_guid})

	// The window's preview-play frame loop: step, render, per-frame restore.
	step :: proc(d: ^seq.PlayableDirector, time: f32) {
		seq.director_preview_step(d, time)
		seq.director_preview_end(d, playing = true)
	}

	step(d, 0.3)
	testing.expect(t, !audio.audio_is_playing(src), "silent before the span")

	step(d, 0.7) // crosses 0.5
	testing.expect(t, audio.audio_is_playing(src), "preview play must sound at the clip start")
	testing.expect(t, src.clip == clip_guid, "the clip's asset lands on the source")

	step(d, 0.9) // the per-frame restore must not kill the voice
	testing.expect(t, audio.audio_is_playing(src), "the voice survives per-frame restore while playing")

	step(d, 1.7) // leaving the span stops through the track's own logic
	testing.expect(t, !audio.audio_is_playing(src), "leaving the span must stop")

	// Pause/stop: the real preview_end silences whatever still plays.
	step(d, 0.7)
	testing.expect(t, audio.audio_is_playing(src), "playing again inside the span")
	seq.director_preview_end(d)
	testing.expect(t, !audio.audio_is_playing(src), "preview end must silence")

	// A static scrub stays silent, playing flag or not.
	seq.director_set_time(d, 0.7)
	testing.expect(t, !audio.audio_is_playing(src), "scrub must not play audio")
}

// Build a track NODE with clip NODES under `owner` (timeline-as-prefab).
@(private = "file")
_mk_audio_track :: proc(owner: engine.Transform_Handle, target: engine.Ref_Local, clips: ..seq.Timeline_Clip) -> engine.Transform_Handle {
	node := engine.transform_new("audio", owner)
	_, tc := engine.transform_get_or_add_comp(node, seq.TimelineTrack)
	tc.kind = strings.clone("audio")
	tc.target = target
	for c in clips {
		cn := engine.transform_new("clip", node)
		_, cc := engine.transform_get_or_add_comp(cn, seq.TimelineClip)
		cc.start = c.start
		cc.duration = c.duration
		cc.asset = c.asset
	}
	return node
}
