package audio

// Audio importer: copies source bytes into the artifact (no transcode yet).
// AudioSettings stays in the engine's ImportSettings union — a closed union
// referenced by the pipeline, so settings types cannot live in packages.

import "core:os"
import "core:fmt"
import engine "moonhug:engine"

_AUDIO_EXTS := []string{".mp3", ".wav", ".ogg"}

@(phase={key=ImportersInit, order=1})
audio_importers_init :: proc() {
	@(static) done := false
	if done do return
	done = true
	engine.importer_register({
		name             = "audio",
		version          = 1,
		extensions       = _AUDIO_EXTS,
		default_settings = _default_settings,
		run              = _import_audio,
	})
}

_default_settings :: proc() -> engine.ImportSettings {
	return engine.default_audio_settings()
}

// The pipeline creates the artifact directory before calling run.
_import_audio :: proc(source_path: string, artifact_path: string, settings: engine.ImportSettings) -> bool {
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
