package audio_tests

// A clip whose import settings say `stream` loads without decoding: it is
// read from its file while it plays. Both load paths, the direct one and the
// worker job a scene load starts, read the setting.

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
test_streamed_clip_loads_and_plays :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	registration.register_importers()
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	audio.mixer_init_headless()

	src_dir :: "moonhug/tests/fixtures/_audio_stream_tmp"
	wav :: src_dir + "/probe.wav"
	os.make_directory(src_dir)
	testing.expect(t, _write_test_wav(wav), "fixture wav written")
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
	// The asset database knows the clip, as the editor's and a game's know
	// every asset: the settings are found from the guid.
	engine.asset_db_init(src_dir)
	defer engine.asset_db_shutdown()
	Meta :: struct {
		guid: string,
	}
	meta: Meta
	meta_data, _ := os.read_entire_file(wav + ".meta", context.temp_allocator)
	testing.expect(t, json.unmarshal(meta_data, &meta, allocator = context.temp_allocator) == nil)
	raw_guid, _ := uuid.read(meta.guid)
	guid := engine.Asset_GUID(raw_guid)

	s, sok := engine.asset_pipeline_get_settings(wav)
	testing.expect(t, sok, "the clip has settings")
	if !sok do return
	defer free(s.data)
	as := s.(audio.AudioSettings)
	as.stream = true
	testing.expect(t, asset_pipeline.asset_pipeline_save_settings(wav, as))
	testing.expect(t, asset_pipeline.asset_pipeline_import_asset(wav), "the clip imports")

	// Directly.
	clip, ok := audio.clip_load(guid)
	testing.expect(t, ok && clip.streamed, "a streamed clip")
	if !ok do return
	testing.expect_value(t, clip.frames, i64(_FRAMES))

	// It plays: the mixer reads samples from the file.
	testing.expect(t, audio.play_clip(guid), "the streamed clip plays")
	buf: [4096]u8
	n := mix.Generate(audio._audio_state.mixer, raw_data(buf[:]), i32(len(buf)))
	testing.expect(t, n > 0, "the mixer generates from it")
	samples := ([^]f32)(raw_data(buf[:]))[:int(n) / size_of(f32)]
	loud := false
	for x in samples do if abs(x) > 0.01 do loud = true
	testing.expect(t, loud, "and what it generates is the clip, not silence")
	audio._one_shots_clear()

	// Through a load job, as a scene load starts one.
	audio.clip_unload(guid)
	audio.clip_load_start(guid)
	clip, ok = audio.clip_load(guid) // waits for the job
	testing.expect(t, ok && clip.streamed, "a job loads it streamed too")
}
