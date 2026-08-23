package asset_pipeline

// Texture import: today a validated copy of the source bytes into the
// artifact (decode happens at load). Settings (engine.TextureSettings) ride
// the artifact key, so a settings change re-imports.

import "core:fmt"
import "core:os"
import "moonhug:engine"

_import_texture :: proc(source_path: string, artifact_path: string, settings: rawptr) -> bool {
	data, read_err := os.read_entire_file(source_path, context.temp_allocator)
	if read_err != nil {
		fmt.printf("[Pipeline] Failed to read texture: %s\n", source_path)
		return false
	}

	engine._ensure_artifact_dir(artifact_path)

	if write_err := os.write_entire_file(artifact_path, data); write_err != nil {
		fmt.printf("[Pipeline] Failed to write artifact: %s\n", artifact_path)
		return false
	}

	fmt.printf("[Pipeline] Imported texture: %s -> %s\n", source_path, artifact_path)
	return true
}
