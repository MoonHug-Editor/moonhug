package animation_editor

// The .anim importer (docs/AnimationComponent.md).
//
// A clip needs no format conversion — the source is already the runtime shape —
// so this exists for its SETTINGS. Making the clip importer-backed is what puts
// wrap, frame rate, cycle offset and the trim range in the .meta instead of the
// file, which is what lets extraction rewrite a clip without losing them.
//
// The artifact is the source with the settings baked in, so the runtime reads
// one file and never opens a meta.

import "core:encoding/json"
import "core:os"
import "moonhug:engine"
import "moonhug:engine/serialization"
import "moonhug:engine_editor/asset_pipeline"
import "moonhug:engine/log"
import anim "moonhug:packages/animation"
import cgltf "vendor:cgltf"

@(phase={key=ImportersInit, order=1, mode=Editor})
animation_importers_init :: proc() {
	@(static) done := false
	if done do return
	done = true
	asset_pipeline.importer_register({
		name         = "animation",
		version      = 1,
		extensions   = {".anim"},
		settings_tid = typeid_of(anim.Animation_Clip_Settings),
		run          = _import_animation,
	})
	engine.asset_pipeline_add_reimport_hook(anim.animation_clip_reimported)
	// The mesh importer hands every glTF animation here, so a model's clips
	// bake to its own artifacts and need no extraction to be played.
	asset_pipeline.gltf_clip_baker = bake_gltf_clip
}

// One glTF animation to one clip artifact, the same bytes _import_animation
// writes for a standalone .anim, so the runtime loader reads both alike.
// `settings` is the clip's entry in the model's meta (engine.Mesh_Clip), a
// JSON value because the type is this package's. Overlaid on defaults, so an
// entry from before a field existed still picks up that field's default.
bake_gltf_clip :: proc(data: ^cgltf.data, an: ^cgltf.animation, settings: json.Value, out_path: string) -> bool {
	clip, ok := anim.animation_clip_from_gltf(data, an)
	if !ok do return false
	s := anim.Animation_Clip_Settings{frame_rate = anim.ANIMATION_FRAME_RATE_DEFAULT}
	if settings != nil {
		engine._settings_overlay(any{&s, typeid_of(anim.Animation_Clip_Settings)}, settings)
	}
	anim.animation_clip_apply_settings(&clip, s)
	return serialization.write_asset_to_path(
		out_path, engine.get_guid_by_type_key(engine.TypeKey.AnimationClip), clip)
}

@(private = "file")
_import_animation :: proc(source_path, artifact_path: string, settings: rawptr) -> bool {
	data, read_err := os.read_entire_file(source_path, context.temp_allocator)
	if read_err != nil {
		log.errorf("[Pipeline] Failed to read clip: %s", source_path)
		return false
	}

	clip: anim.AnimationClip
	if json.unmarshal(data, &clip, .JSON, context.allocator) != nil {
		log.errorf("[Pipeline] Failed to parse clip: %s", source_path)
		return false
	}
	defer anim.animation_clip_destroy(&clip)

	// Settings are absent for a clip whose meta predates them: the defaults
	// then apply, which is the clip as authored.
	s := anim.Animation_Clip_Settings{frame_rate = anim.ANIMATION_FRAME_RATE_DEFAULT}
	if settings != nil do s = (cast(^anim.Animation_Clip_Settings)settings)^
	anim.animation_clip_apply_settings(&clip, s)

	return serialization.write_asset_to_path(
		artifact_path, engine.get_guid_by_type_key(engine.TypeKey.AnimationClip), clip)
}
