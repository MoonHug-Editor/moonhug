package audio_tests

// One-shot lifecycle: play_clip spawns a transient track, Generate drives
// the deviceless mixer through the clip, and the update sweep frees the
// finished track. Fades ride the same track APIs.

import "core:encoding/json"
import "core:encoding/uuid"
import "core:os"
import "core:testing"
import "moonhug:registration"
import mix "vendor:sdl3/mixer"
import "moonhug:packages/engine"
import asset_pipeline "moonhug:editor/assets"
import audio "moonhug:packages/audio"
import common "moonhug:tests/common"

@(test)
test_one_shot_lifecycle :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	registration.register_importers()
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	audio.mixer_init_headless()

	src_dir :: "moonhug/tests/fixtures/_audio_shot_tmp"
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
	guid := engine.Asset_GUID(raw_guid)
	testing.expect(t, asset_pipeline.asset_pipeline_import_asset(wav))

	// Spawn a 2D one-shot and a spatial one (no listener: it plays centered).
	testing.expect(t, audio.play_clip(guid, 0.8), "2D one-shot starts")
	testing.expect(t, audio.play_clip_at_point(guid, {5, 0, 0}), "spatial one-shot starts")
	testing.expect_value(t, len(audio._one_shots), 2)

	// Drive the deviceless mixer through the whole clip (0.1 s), then let
	// the update sweep reap the finished tracks.
	mixer := audio._audio_state.mixer
	buf: [16384]u8
	for _ in 0 ..< 200 {
		if mix.Generate(mixer, raw_data(buf[:]), i32(len(buf))) <= 0 do break
		still := false
		for shot in audio._one_shots {
			if mix.TrackPlaying(shot.track) do still = true
		}
		if !still do break
	}
	audio.audio_update(1.0 / 60.0)
	testing.expect_value(t, len(audio._one_shots), 0)

	// Fade smoke test: a faded stop keeps the track playing while it fades.
	owner := engine.transform_new("Speaker")
	_, ptr := engine.transform_add_comp(owner, .AudioSource)
	src := cast(^audio.AudioSource)ptr
	src.clip = engine.PPtr{guid = guid}
	testing.expect(t, audio.audio_play(src, fade_in_ms = 20), "fade-in play starts")
	audio.audio_stop(src, fade_out_ms = 30)
	testing.expect(t, audio.audio_is_playing(src), "faded stop is still audible")
	audio.audio_stop(src)
	testing.expect(t, !audio.audio_is_playing(src), "hard stop is immediate")
}

// At most MAX_ONE_SHOTS play at once: one past that takes the place of the
// quietest. Ended voices' tracks are reused by the next one-shots.
@(test)
test_one_shot_voice_cap_and_reuse :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	registration.register_importers()
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	audio.mixer_init_headless()

	src_dir :: "moonhug/tests/fixtures/_audio_cap_tmp"
	wav :: src_dir + "/probe.wav"
	os.make_directory(src_dir)
	testing.expect(t, _write_test_wav(wav))
	defer {
		audio._one_shots_clear()
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
	guid := engine.Asset_GUID(raw_guid)
	testing.expect(t, asset_pipeline.asset_pipeline_import_asset(wav))
	audio._one_shots_clear()

	// Louder each time: the first ones are the quietest.
	extra :: 6
	for i in 0 ..< audio.MAX_ONE_SHOTS + extra {
		testing.expectf(t, audio.play_clip(guid, f32(i + 1) / 100), "one-shot %d starts", i)
	}
	testing.expect_value(t, len(audio._one_shots), audio.MAX_ONE_SHOTS)
	quietest := max(f32)
	for shot in audio._one_shots do quietest = min(quietest, shot.volume)
	testing.expectf(t, abs(quietest - f32(extra + 1) / 100) < 0.0001, "the %d quietest gave their place, the quietest left is %v", extra, quietest)
	// Each new one-shot past the cap plays on the track of the voice it
	// replaced: nothing is left over in the pool.
	testing.expect_value(t, len(audio._free_one_shot_tracks), 0)

	// Play the clip through: every voice ends, and its track goes to the pool.
	mixer := audio._audio_state.mixer
	buf: [16384]u8
	for _ in 0 ..< 400 {
		if mix.Generate(mixer, raw_data(buf[:]), i32(len(buf))) <= 0 do break
		still := false
		for shot in audio._one_shots do if mix.TrackPlaying(shot.track) do still = true
		if !still do break
	}
	audio.audio_update(1.0 / 60.0)
	testing.expect_value(t, len(audio._one_shots), 0)
	pooled := len(audio._free_one_shot_tracks)
	testing.expect_value(t, pooled, audio.MAX_ONE_SHOTS)

	// The next one-shot takes a pooled track instead of making one.
	reused := audio._free_one_shot_tracks[pooled - 1]
	testing.expect(t, audio.play_clip(guid), "a one-shot after the burst starts")
	testing.expect(t, len(audio._one_shots) == 1 && audio._one_shots[0].track == reused, "it plays on a pooled track")
}
