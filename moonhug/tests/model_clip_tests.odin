package tests

// Clips inside a model (docs/AnimationComponent.md "Clips inside a model"):
// the mesh importer bakes every glTF animation to the model's _a<i>.bin
// fan-out and lists it in the model's settings with a stable id and its own
// guid, the AssetDB resolves that guid to the model, the clip loader reads
// the fan-out, and the catalog carries the identity so a build and an export
// resolve it too. Nothing is extracted.

import "base:runtime"
import "core:encoding/uuid"
import "core:os"
import "core:strings"
import "core:testing"
import "../engine"
import "../engine/catalog"
import "moonhug:engine_editor/asset_pipeline"
import anim "moonhug:packages/animation"
import animation_editor "moonhug:packages/animation/editor"

BOX_ANIM_GLTF :: "moonhug/tests/fixtures/meshes/box_animated.gltf"

@(test)
test_mesh_import_bakes_clips_with_stable_identity :: proc(t: ^testing.T) {
	artifact := "moonhug/tests/fixtures/meshes/_box_anim_artifact.bin"
	part0 := engine.mesh_part_artifact_path(artifact, 0, context.temp_allocator)
	clip0 := engine.mesh_clip_artifact_path(artifact, 0, context.temp_allocator)
	defer os.remove(artifact)
	defer os.remove(part0)
	defer os.remove(clip0)

	asset_pipeline.gltf_clip_baker = animation_editor.bake_gltf_clip
	ms := engine.MeshSettings{scale = 1}
	testing.expect(t, asset_pipeline._import_mesh(BOX_ANIM_GLTF, artifact, &ms), "import failed")
	testing.expect(t, len(ms.clips) >= 1, "the animated box lists at least one clip")
	if len(ms.clips) == 0 do return
	testing.expect(t, os.exists(clip0), "clip 0 baked to the _a0 fan-out")
	testing.expect(t, ms.clips[0].guid != {}, "a clip gets its own guid")

	// One id space for parts and clips: a sub-asset id is unique within its model.
	for c in ms.clips {
		for p in ms.parts do testing.expect(t, c.id != p.id, "clip and part ids collide")
	}

	// A reimport keeps id AND guid, matched by name — the guid is what scenes hold.
	first := ms.clips[0]
	testing.expect(t, asset_pipeline._import_mesh(BOX_ANIM_GLTF, artifact, &ms), "reimport failed")
	testing.expect(t, len(ms.clips) >= 1 && ms.clips[0].id == first.id, "clip id survives reimport")
	testing.expect(t, len(ms.clips) >= 1 && ms.clips[0].guid == first.guid, "clip guid survives reimport")
	testing.expect(t, len(ms.clips) >= 1 && ms.clips[0].name == first.name, "clip name survives reimport")
}

// The whole path a clip reference takes: AssetDB sub-guid, the runtime loader,
// the catalog round trip, and an export that ships the owner's fan-out for a
// scene that names only the clip.
@(test)
test_model_clip_resolves_loads_and_exports :: proc(t: ^testing.T) {
	src_dir :: "moonhug/tests/fixtures/_model_clip_tmp"
	gltf :: src_dir + "/box.gltf"
	scene :: src_dir + "/boot.scene"
	data_dir :: src_dir + "_data"
	os.make_directory(src_dir)
	bytes, rerr := os.read_entire_file(BOX_ANIM_GLTF, context.temp_allocator)
	testing.expect(t, rerr == nil)
	if rerr != nil do return
	testing.expect(t, os.write_entire_file(gltf, bytes) == nil)
	// Placeholder so the scan registers the scene, rewritten once the clip guid exists.
	testing.expect(t, os.write_entire_file(scene, transmute([]byte)string("{}")) == nil)
	defer {
		_remove_tree(src_dir)
		_remove_tree(data_dir)
		_remove_tree("library")
	}

	asset_pipeline.asset_pipeline_init()
	asset_pipeline.gltf_clip_baker = animation_editor.bake_gltf_clip
	engine.asset_db_init(src_dir)
	_ = asset_pipeline.asset_pipeline_import_asset(gltf)

	model_raw, mok := engine.asset_db_get_guid(gltf)
	testing.expect(t, mok, "model registered")
	if !mok do return
	model := engine.Asset_GUID(model_raw)
	clips := engine.mesh_clips(model)
	testing.expect(t, len(clips) >= 1, "model lists its clips")
	if len(clips) == 0 do return
	clip_guid := clips[0].guid

	// The sub guid resolves to its owner, and back from (owner, id).
	sub, is_sub := engine.asset_db_get_sub(clip_guid)
	testing.expect(t, is_sub && sub.owner == model && sub.id == clips[0].id, "clip guid registered as the model's sub-asset")
	path, pok := engine.asset_db_get_path(uuid.Identifier(clip_guid))
	testing.expect(t, pok && path == gltf, "a clip guid's path is its owner's")
	back, bok := engine.asset_db_sub_guid(model, clips[0].id)
	testing.expect(t, bok && back == clip_guid, "(owner, id) maps back to the clip guid")

	// The runtime loads it from the owner's fan-out. animation_clip_load
	// allocates the clip under the default allocator and the cache frees
	// under the ambient one, so the whole exchange runs under default here.
	{
		context.allocator = runtime.default_allocator()
		anim.animation_clip_cache_init()
		clip, cok := anim.animation_clip_load(clip_guid)
		testing.expect(t, cok && clip != nil && len(clip.channels) > 0, "clip loads by its own guid with channels")
		anim.animation_clip_cache_shutdown()
	}

	// A scene that references only the clip, by guid, the way a component field does.
	scene_text := strings.concatenate({"{\"clip\": \"", uuid.to_string(uuid.Identifier(clip_guid), context.temp_allocator), "\"}"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(scene, transmute([]byte)scene_text) == nil)
	model_key, kok := engine.asset_pipeline_artifact_key(model)
	testing.expect(t, kok)
	model_key = strings.clone(model_key, context.temp_allocator)

	// Catalog round trip keeps the identity.
	testing.expect(t, engine.asset_catalog_write(), "catalog writes")
	engine.asset_db_shutdown()
	testing.expect(t, engine.asset_db_init_from_catalog("library/catalog.json"), "catalog pipeline restores")
	sub2, ok2 := engine.asset_db_get_sub(clip_guid)
	testing.expect(t, ok2 && sub2.owner == model && sub2.id == clips[0].id, "sub-asset survives the catalog")
	idx, iok := engine.mesh_clip_index(model, clips[0].id)
	testing.expect(t, iok && idx == 0, "clip index resolves from catalog settings")
	engine.asset_db_shutdown()

	// An export whose boot scene names only the clip ships the owner and its clip fan-out.
	testing.expect(t, catalog.export_from("library/catalog.json", data_dir, boot_scene = scene), "export succeeds")
	shipped := strings.concatenate({data_dir, "/artifacts/", model_key[:2], "/", model_key, "_a0.bin"}, context.temp_allocator)
	testing.expect(t, os.exists(shipped), "the referenced clip's fan-out ships with its owner")
	cat_bytes, cerr := os.read_entire_file(data_dir + "/catalog.json", context.temp_allocator)
	testing.expect(t, cerr == nil)
	if cf, pok2 := catalog.parse(cat_bytes); pok2 {
		entry, has := cf.assets[uuid.to_string(uuid.Identifier(clip_guid), context.temp_allocator)]
		testing.expect(t, has && entry.sub == i64(clips[0].id), "the exported catalog carries the clip as a sub entry")
	} else {
		testing.expect(t, false, "exported catalog parses")
	}
}
