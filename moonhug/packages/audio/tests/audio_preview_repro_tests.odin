package audio_tests

// The editor Apply path with the preview pane open: waveform cached,
// preview playing, clip cached — then save + reimport fires the hooks.
// The tracking allocator catches any hook freeing with the caller's
// allocator (hooks run under whatever allocator the reimport caller has).

import "core:encoding/json"
import "core:encoding/uuid"
import "core:os"
import "core:testing"
import "moonhug:engine"
import audio "moonhug:packages/audio"
import audio_editor "moonhug:packages/audio/editor"
import common "moonhug:tests/common"

@(test)
test_preview_apply_reimport :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	src_dir :: "moonhug/tests/fixtures/_audio_prev_tmp"
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

	// The editor-only hook the pane registers (EditorInit in the editor).
	engine.asset_pipeline_add_reimport_hook(audio_editor._wave_evict)

	testing.expect(t, engine.asset_pipeline_import_asset(wav))

	// Pane state: waveform cached + preview playing + clip cached.
	_, wok := audio_editor._waveform_get(guid)
	testing.expect(t, wok, "waveform computes")
	testing.expect(t, audio.preview_play(guid), "preview starts")

	// Apply: save changed settings, reimport, hooks fire.
	s, sok := engine.asset_pipeline_get_settings(wav)
	testing.expect(t, sok)
	if !sok do return
	defer free(s.data)
	as := s.(audio.AudioSettings)
	as.volume = 0.25
	testing.expect(t, engine.asset_pipeline_save_settings(wav, as))
	testing.expect(t, engine.asset_pipeline_import_asset(wav), "apply reimports")

	// The frame after: the pane recomputes and playback can restart.
	wf2, wok2 := audio_editor._waveform_get(guid)
	testing.expect(t, wok2, "waveform recomputes after eviction")
	testing.expect(t, wf2.frames == i64(_FRAMES))
	testing.expect(t, audio.preview_play(guid), "preview restarts on the new master")
	audio.preview_stop()
}
