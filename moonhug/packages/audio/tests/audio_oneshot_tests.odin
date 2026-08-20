package audio_tests

// One-shot lifecycle: play_clip spawns a transient track, Generate drives
// the deviceless mixer through the clip, and the update sweep frees the
// finished track. Fades ride the same track APIs.

import "core:encoding/json"
import "core:encoding/uuid"
import "core:os"
import "core:testing"
import mix "vendor:sdl3/mixer"
import "moonhug:engine"
import audio "moonhug:packages/audio"
import common "moonhug:tests/common"

@(test)
test_one_shot_lifecycle :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
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
		_remove_tree("library")
	}

	engine.asset_pipeline_init()
	engine.asset_pipeline_ensure_import_meta(wav)
	Meta :: struct {
		guid: string,
	}
	meta: Meta
	meta_data, _ := os.read_entire_file(wav + ".meta", context.temp_allocator)
	testing.expect(t, json.unmarshal(meta_data, &meta, allocator = context.temp_allocator) == nil)
	raw_guid, _ := uuid.read(meta.guid)
	guid := engine.Asset_GUID(raw_guid)
	testing.expect(t, engine.asset_pipeline_import_asset(wav))

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
	src.clip = guid
	testing.expect(t, audio.audio_play(src, fade_in_ms = 20), "fade-in play starts")
	audio.audio_stop(src, fade_out_ms = 30)
	testing.expect(t, audio.audio_is_playing(src), "faded stop is still audible")
	audio.audio_stop(src)
	testing.expect(t, !audio.audio_is_playing(src), "hard stop is immediate")
}
