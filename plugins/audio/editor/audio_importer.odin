package audio_editor

// Audio importer registration + run proc (editor-side, plugins/audio/docs/assets/AudioClip.md):
// decodes the source to float32 PCM (audio.decode_file_f32), applies the
// import settings (volume gain, normalize) and writes a float32 WAV
// artifact — playback loads the ARTIFACT, so every consumer hears the
// mastered result. A compressed source the settings leave as it is (volume
// 1, no normalize) is copied instead: decoded, three minutes of mp3 are
// about 60 MB in the library and in an exported game. The settings type stays in the runtime package
// (packages/audio/audio.odin): the catalog pipeline materializes settings
// in game binaries too.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import asset_pipeline "moonhug:editor/assets"
import audio "moonhug:packages/audio"

_AUDIO_EXTS := []string{".mp3", ".wav", ".ogg"}

@(importer)
audio_importer :: proc() -> asset_pipeline.Importer_Desc {
	return {
		name         = "audio",
		version      = 3,
		extensions   = _AUDIO_EXTS,
		settings_tid = typeid_of(audio.AudioSettings),
		run          = _import_audio,
	}
}

// The pipeline creates the artifact directory before calling run.
_import_audio :: proc(source_path: string, artifact_path: string, settings: rawptr) -> bool {
	volume: f32 = 1
	normalize := false
	if settings != nil {
		s := cast(^audio.AudioSettings)settings
		volume = s.volume
		normalize = s.normalize
	}

	if audio_import_copies(source_path, volume, normalize) {
		data, rerr := os.read_entire_file(source_path, context.allocator)
		if rerr != nil {
			fmt.printf("[Pipeline] Failed to read audio: %s\n", source_path)
			return false
		}
		defer delete(data)
		if os.write_entire_file(artifact_path, data) != nil {
			fmt.printf("[Pipeline] Failed to write artifact: %s\n", artifact_path)
			return false
		}
		fmt.printf("[Pipeline] Imported audio as it is: %s -> %s\n", source_path, artifact_path)
		return true
	}

	pcm, spec, ok := audio.decode_file_f32(source_path)
	if !ok {
		fmt.printf("[Pipeline] Failed to decode audio: %s\n", source_path)
		return false
	}
	defer delete(pcm)

	gain := volume
	if normalize {
		peak: f32
		for s in pcm {
			if abs(s) > peak do peak = abs(s)
		}
		if peak > 0 do gain = volume / peak
	}
	if gain != 1 {
		for &s in pcm do s *= gain
	}

	if !audio._write_wav_f32(artifact_path, pcm, spec) {
		fmt.printf("[Pipeline] Failed to write artifact: %s\n", artifact_path)
		return false
	}
	fmt.printf("[Pipeline] Imported audio: %s -> %s\n", source_path, artifact_path)
	return true
}


// Whether the importer copies the source instead of decoding it: a
// compressed file (mp3, ogg) whose settings change nothing in it. The mixer
// reads either kind of artifact by its content.
audio_import_copies :: proc(source_path: string, volume: f32, normalize: bool) -> bool {
	if normalize || volume != 1 do return false
	ext := strings.to_lower(filepath.ext(source_path), context.temp_allocator)
	return ext == ".mp3" || ext == ".ogg"
}
