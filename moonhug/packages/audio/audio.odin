package audio

// Audio importer: copies source bytes into the artifact (no transcode yet).
// Fully self-contained — the settings type, its defaults (factory) and the
// importer logic all live here. Scene/meta records key on the type guid
// below — never change it.

import "core:os"
import "core:fmt"
import engine "moonhug:engine"

@(typ_guid={guid="ec017cc2-7267-45b4-ae80-d6861094d27a", makeProcName=make_pAudioSettings})
AudioSettings :: struct {
	volume: f32,
}

make_pAudioSettings :: proc() -> any {
	p := new(AudioSettings)
	p.volume = 1.0
	return p^
}

_AUDIO_EXTS := []string{".mp3", ".wav", ".ogg"}

@(phase={key=ImportersInit, order=1})
audio_importers_init :: proc() {
	@(static) done := false
	if done do return
	done = true
	engine.importer_register({
		name         = "audio",
		version      = 1,
		extensions   = _AUDIO_EXTS,
		settings_tid = typeid_of(AudioSettings),
		run          = _import_audio,
	})
}

// The pipeline creates the artifact directory before calling run.
_import_audio :: proc(source_path: string, artifact_path: string, settings: rawptr) -> bool {
	data, read_err := os.read_entire_file(source_path, context.temp_allocator)
	if read_err != nil {
		fmt.printf("[Pipeline] Failed to read audio: %s\n", source_path)
		return false
	}
	if write_err := os.write_entire_file(artifact_path, data); write_err != nil {
		fmt.printf("[Pipeline] Failed to write artifact: %s\n", artifact_path)
		return false
	}
	fmt.printf("[Pipeline] Imported audio: %s -> %s\n", source_path, artifact_path)
	return true
}
