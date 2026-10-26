package animation_tests

// Clips inside a model (plugins/animation/docs/AnimationComponent.md "Clips inside a model"):
// the mesh importer bakes every glTF animation to a sub-asset file beside the
// model's artifact, named by the clip's stable id, and lists it in the
// model's settings. The clip loader reads that file for {model guid, clip id},
// and the catalog carries the identity so a build and an export resolve it
// too. Nothing is extracted.

import "base:runtime"
import "core:encoding/json"
import "core:encoding/uuid"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "moonhug:packages/engine"
import "moonhug:libs/catalog"
import asset_pipeline "moonhug:editor/assets"
import "moonhug:packages/engine/editor/importers"
import anim "moonhug:packages/animation"
import animation_editor "moonhug:packages/animation/editor"
import mesh_editor "moonhug:packages/engine/editor/mesh_editor"
import common "moonhug:tests/common"
import "moonhug:libs/log"

BOX_ANIM_GLTF :: "moonhug/tests/fixtures/meshes/box_animated.gltf"

@(test)
test_mesh_import_bakes_clips_with_stable_identity :: proc(t: ^testing.T) {
	// Its own folder, removed whole: the import writes a part file per glTF
	// mesh and a clip file per animation, more than the test names.
	tmp :: "moonhug/tests/fixtures/_model_clip_import_tmp"
	artifact := tmp + "/box_anim.bin"
	defer common.remove_tree(tmp)

	importers.gltf_clip_baker = animation_editor.bake_gltf_clip
	ms := engine.MeshSettings{scale = 1}
	testing.expect(t, importers._import_mesh(BOX_ANIM_GLTF, artifact, &ms), "import failed")
	testing.expect(t, len(ms.clips) >= 1, "the animated box lists at least one clip")
	if len(ms.clips) == 0 do return
	testing.expect(t, os.exists(engine.artifact_sub_path(artifact, ms.clips[0].id, context.temp_allocator)), "clip 0 baked to its sub-asset file, named by its id")
	testing.expect(t, ms.clips[0].id != 0, "a clip gets an id")

	// One id space for parts and clips: a sub-asset id is unique within its model.
	for c in ms.clips {
		for p in ms.parts do testing.expect(t, c.id != p.id, "clip and part ids collide")
	}

	// A reimport keeps the id, matched by name — the id is what scenes hold.
	first := ms.clips[0]
	testing.expect(t, importers._import_mesh(BOX_ANIM_GLTF, artifact, &ms), "reimport failed")
	testing.expect(t, len(ms.clips) >= 1 && ms.clips[0].id == first.id, "clip id survives reimport")
	testing.expect(t, len(ms.clips) >= 1 && ms.clips[0].name == first.name, "clip name survives reimport")

	// Settings in the entry reach the bake, and a clip the model lost stays
	// as an orphan with its id, after every real clip.
	ms2 := engine.MeshSettings{scale = 1}
	ms2.clips = make([dynamic]engine.Mesh_Clip, context.temp_allocator)
	ghost := engine.Mesh_Clip{id = 7, name = "Ghost"}
	append(&ms2.clips, ghost)
	loop_v, perr := json.parse(transmute([]byte)string(`{"wrap": 1}`), .JSON, true, context.temp_allocator)
	testing.expect(t, perr == nil)
	append(&ms2.clips, engine.Mesh_Clip{id = 9, name = first.name, settings = loop_v})
	testing.expect(t, importers._import_mesh(BOX_ANIM_GLTF, artifact, &ms2), "import with settings failed")
	testing.expect(t, len(ms2.clips) == 2, "one real clip, one orphan")
	if len(ms2.clips) == 2 {
		testing.expect(t, ms2.clips[0].name == first.name && ms2.clips[0].id == 9 && !ms2.clips[0].orphan, "the real clip keeps its identity, first")
		testing.expect(t, ms2.clips[1].name == "Ghost" && ms2.clips[1].id == 7 && ms2.clips[1].orphan, "the lost clip stays as an orphan, last")
	}
	baked, berr := os.read_entire_file(engine.artifact_sub_path(artifact, 9, context.temp_allocator), context.temp_allocator)
	testing.expect(t, berr == nil && strings.contains(string(baked), "\"wrap\": 1"), "the entry's wrap setting is baked into the clip")
}

// The whole path a clip reference takes: {model guid, clip id} through the
// runtime loader, the catalog round trip, and an export that ships the
// model's clip fan-out for a scene that references the clip.
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
	// Placeholder so the scan registers the scene, rewritten once the clip id exists.
	testing.expect(t, os.write_entire_file(scene, transmute([]byte)string("{}")) == nil)
	defer {
		common.remove_tree(src_dir)
		common.remove_tree(data_dir)
		common.remove_tree(engine.library_dir())
	}

	asset_pipeline.asset_pipeline_init()
	importers.gltf_clip_baker = animation_editor.bake_gltf_clip
	engine.asset_db_init(src_dir)
	_ = asset_pipeline.asset_pipeline_import_asset(gltf)

	model_raw, mok := engine.asset_db_get_guid(gltf)
	testing.expect(t, mok, "model registered")
	if !mok do return
	model := engine.Asset_GUID(model_raw)
	clips := engine.mesh_clips(model)
	testing.expect(t, len(clips) >= 1, "model lists its clips")
	if len(clips) == 0 do return
	clip := engine.PPtr{guid = model, local_id = clips[0].id}

	// The runtime loader reads the model's fan-out for the clip. The cache
	// allocates the clip under the default allocator and the cache frees
	// under the ambient one, so the whole exchange runs under default here.
	{
		context.allocator = runtime.default_allocator()
		anim.animation_clip_cache_init()
		c, cok := anim.animation_clip_load(clip)
		testing.expect(t, cok && c != nil && len(c.channels) > 0, "a clip inside a model loads by {model, id} with channels")
		anim.animation_clip_cache_shutdown()
	}

	// A scene that references the clip the way a component field does.
	model_str := uuid.to_string(uuid.Identifier(model), context.temp_allocator)
	scene_text := strings.concatenate({"{\"clip\": {\"guid\": \"", model_str, "\", \"local_id\": ", fmt.tprintf("%d", clips[0].id), "}}"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(scene, transmute([]byte)scene_text) == nil)
	model_key, kok := engine.asset_pipeline_artifact_key(model)
	testing.expect(t, kok)
	model_key = strings.clone(model_key, context.temp_allocator)

	// Catalog round trip keeps the clip resolvable from the baked settings.
	testing.expect(t, catalog.build_to_file("", {src_dir}, engine.library_dir(), engine.asset_catalog_path()), "the catalog builds from the files")
	engine.asset_db_shutdown()
	testing.expect(t, engine.asset_db_init_from_catalog(engine.asset_catalog_path()), "catalog pipeline restores")
	idx, iok := engine.mesh_clip_index(model, clips[0].id)
	testing.expect(t, iok && idx == 0, "clip index resolves from catalog settings")
	engine.asset_db_shutdown()

	// An export whose boot scene references the clip ships the model and its clip fan-out.
	testing.expect(t, catalog.export_from(engine.asset_catalog_path(), data_dir, boot_scene = scene), "export succeeds")
	shipped := strings.concatenate({data_dir, "/artifacts/", model_key[:2], "/", model_key, fmt.tprintf("_s%d.bin", clips[0].id)}, context.temp_allocator)
	testing.expect(t, os.exists(shipped), "the referenced clip's fan-out ships with its model")
	cat_bytes, cerr := os.read_entire_file(data_dir + "/catalog.json", context.temp_allocator)
	testing.expect(t, cerr == nil)
	if cf, pok2 := catalog.parse(cat_bytes); pok2 {
		_, has := cf.assets[model_str]
		testing.expect(t, has, "the exported catalog carries the model")
	} else {
		testing.expect(t, false, "exported catalog parses")
	}
}

// A game cannot import, so a mesh part or clip file its export left out is a
// load error, and it says so once instead of drawing nothing or holding the
// rest pose in silence. The catalog pipeline refuses imports the way a game
// binary does. A reimport of the model gives a failed clip its next try.
@(test)
test_missing_artifacts_are_reported_once :: proc(t: ^testing.T) {
	src_dir :: "moonhug/tests/fixtures/_model_missing_tmp"
	gltf :: src_dir + "/box.gltf"
	os.make_directory(src_dir)
	bytes, rerr := os.read_entire_file(BOX_ANIM_GLTF, context.temp_allocator)
	testing.expect(t, rerr == nil)
	if rerr != nil do return
	testing.expect(t, os.write_entire_file(gltf, bytes) == nil)
	defer {
		common.remove_tree(src_dir)
		common.remove_tree(engine.library_dir())
	}

	asset_pipeline.asset_pipeline_init()
	importers.gltf_clip_baker = animation_editor.bake_gltf_clip
	engine.asset_db_init(src_dir)
	_ = asset_pipeline.asset_pipeline_import_asset(gltf)
	raw, ok := engine.asset_db_get_guid(gltf)
	testing.expect(t, ok, "model registered")
	if !ok {
		engine.asset_db_shutdown()
		return
	}
	model := engine.Asset_GUID(raw)
	clips := engine.mesh_clips(model)
	parts := engine.mesh_parts(model)
	testing.expect(t, len(clips) >= 1 && len(parts) >= 1, "the model has a clip and a part")
	if len(clips) == 0 || len(parts) == 0 {
		engine.asset_db_shutdown()
		return
	}
	clip_id, part_id := clips[0].id, parts[0].id
	testing.expect(t, catalog.build_to_file("", {src_dir}, engine.library_dir(), engine.asset_catalog_path()))
	engine.asset_db_shutdown()

	testing.expect(t, engine.asset_db_init_from_catalog(engine.asset_catalog_path()), "catalog pipeline")
	defer engine.asset_db_shutdown()
	whole, wok := engine.asset_pipeline_artifact_path(model)
	testing.expect(t, wok)
	if !wok do return
	whole = strings.clone(whole, context.temp_allocator)
	testing.expect(t, os.remove(engine.artifact_sub_path(whole, clip_id, context.temp_allocator)) == nil, "drop the clip file")
	testing.expect(t, os.remove(engine.artifact_sub_path(whole, part_id, context.temp_allocator)) == nil, "drop the part file")

	logged :: proc(prefix, has: string) -> int {
		n := 0
		for e in log.entries do if strings.has_prefix(e.message, prefix) && strings.contains(e.message, has) do n += 1
		return n
	}

	context.allocator = runtime.default_allocator()
	anim.animation_clip_cache_init()
	defer anim.animation_clip_cache_shutdown()
	ref := engine.PPtr{guid = model, local_id = clip_id}
	for _ in 0 ..< 3 {
		_, lok := anim.animation_clip_load(ref)
		testing.expect(t, !lok, "a clip whose file is gone does not load")
	}
	testing.expect_value(t, logged("[Animation]", "is missing or unreadable"), 1)

	for _ in 0 ..< 2 do _, _ = anim.animation_clip_load(engine.PPtr{guid = model, local_id = 424242})
	testing.expect_value(t, logged("[Animation]", "has no clip 424242"), 1)

	for _ in 0 ..< 2 {
		_, gok := engine.mesh_geometry(model, 1)
		testing.expect(t, !gok, "a part whose file is gone does not load")
	}
	testing.expect_value(t, logged("[Mesh]", "is missing or unreadable"), 1)

	// A reimport clears the mark: the next load reads, fails and says so again.
	anim.animation_clip_reimported(model)
	_, _ = anim.animation_clip_load(ref)
	testing.expect_value(t, logged("[Animation]", "is missing or unreadable"), 2)
}

// The project view lists a model's sub-assets through the ONE model provider
// (plugins/engine/editor/mesh_editor): its parts, then its clips. The failure it
// guards: a second provider for .glb replaced this one, and the clips never
// showed while the parts did.
@(test)
test_model_provider_lists_parts_then_clips :: proc(t: ^testing.T) {
	src_dir :: "moonhug/tests/fixtures/_model_provider_tmp"
	gltf :: src_dir + "/box.gltf"
	os.make_directory(src_dir)
	bytes, rerr := os.read_entire_file(BOX_ANIM_GLTF, context.temp_allocator)
	testing.expect(t, rerr == nil)
	if rerr != nil do return
	testing.expect(t, os.write_entire_file(gltf, bytes) == nil)
	defer {
		common.remove_tree(src_dir)
		common.remove_tree(engine.library_dir())
	}

	asset_pipeline.asset_pipeline_init()
	importers.gltf_clip_baker = animation_editor.bake_gltf_clip
	engine.asset_db_init(src_dir)
	defer engine.asset_db_shutdown()
	testing.expect(t, asset_pipeline.asset_pipeline_import_asset(gltf), "import")

	raw, ok := engine.asset_db_get_guid(gltf)
	testing.expect(t, ok)
	if !ok do return
	model := engine.Asset_GUID(raw)
	parts := engine.mesh_parts(model)
	clips := engine.mesh_clips(model)
	testing.expect(t, len(parts) >= 1 && len(clips) >= 1, "the fixture has parts and a clip")

	rows := mesh_editor._model_sub_assets(gltf, context.temp_allocator)
	testing.expect_value(t, len(rows), len(parts) + len(clips))
	if len(rows) == len(parts) + len(clips) {
		for p, i in parts do testing.expect(t, rows[i].id == p.id, "parts come first, in order")
		for c, i in clips do testing.expect(t, rows[len(parts) + i].id == c.id, "clips follow the parts, in order")
	}
}

// The parts and clips caches store what they read, so a reimport must drop
// them: it rewrites both lists in the model's meta. The failure it guards: a
// model read before its first import kept its empty clip list for the whole
// session. Also proves the caches cache at all, which they did not while
// their readiness was a nil check on a lazily allocated map.
@(test)
test_model_clip_list_refreshes_after_reimport :: proc(t: ^testing.T) {
	src_dir :: "moonhug/tests/fixtures/_model_clip_cache_tmp"
	gltf :: src_dir + "/box.gltf"
	os.make_directory(src_dir)
	bytes, rerr := os.read_entire_file(BOX_ANIM_GLTF, context.temp_allocator)
	testing.expect(t, rerr == nil)
	if rerr != nil do return
	testing.expect(t, os.write_entire_file(gltf, bytes) == nil)
	defer {
		common.remove_tree(src_dir)
		common.remove_tree(engine.library_dir())
	}

	engine.mesh_cache_init()
	defer engine.mesh_cache_shutdown()
	asset_pipeline.asset_pipeline_init()
	importers.gltf_clip_baker = animation_editor.bake_gltf_clip
	engine.asset_db_init(src_dir)
	defer engine.asset_db_shutdown()

	raw, ok := engine.asset_db_get_guid(gltf)
	testing.expect(t, ok)
	if !ok do return
	model := engine.Asset_GUID(raw)

	// Read before the clips exist, the way the project view does at startup.
	before := engine.mesh_clips(model)
	testing.expect(t, len(before) == 0, "no clips before the first import")

	testing.expect(t, asset_pipeline.asset_pipeline_import_asset(gltf), "import")
	clips := engine.mesh_clips(model)
	testing.expect(t, len(clips) >= 1, "the clip list is re-read after the import")

	// The cache is live: a second read returns the SAME storage. An uncached
	// read allocates a fresh slice every call, so the pointers would differ.
	testing.expect(t, len(clips) > 0 && raw_data(engine.mesh_clips(model)) == raw_data(clips), "clips are served from the cache")
	parts := engine.mesh_parts(model)
	testing.expect(t, len(parts) > 0 && raw_data(engine.mesh_parts(model)) == raw_data(parts), "parts are served from the cache")
}

// The startup import ends with a sweep that deletes artifact files the index
// does not reference. A baked clip is a fan-out of its model's key, so it
// must survive, like a mesh part. The failure it guards: the sweep knew only
// one fan-out suffix and deleted every clip at each launch, so every model
// clip loaded as nothing and its preview stayed in the rest pose.
@(test)
test_stale_artifact_sweep_keeps_clip_fan_out :: proc(t: ^testing.T) {
	src_dir :: "moonhug/tests/fixtures/_model_clip_sweep_tmp"
	gltf :: src_dir + "/box.gltf"
	os.make_directory(src_dir)
	bytes, rerr := os.read_entire_file(BOX_ANIM_GLTF, context.temp_allocator)
	testing.expect(t, rerr == nil)
	if rerr != nil do return
	testing.expect(t, os.write_entire_file(gltf, bytes) == nil)
	defer {
		common.remove_tree(src_dir)
		common.remove_tree(engine.library_dir())
	}

	asset_pipeline.asset_pipeline_init()
	importers.gltf_clip_baker = animation_editor.bake_gltf_clip
	engine.asset_db_init(src_dir)
	defer engine.asset_db_shutdown()
	testing.expect(t, asset_pipeline.asset_pipeline_import_asset(gltf), "import")

	raw, ok := engine.asset_db_get_guid(gltf)
	testing.expect(t, ok)
	if !ok do return
	whole, wok := engine.asset_pipeline_artifact_path(engine.Asset_GUID(raw))
	testing.expect(t, wok)
	if !wok do return
	whole = strings.clone(whole, context.temp_allocator)
	clip0 := engine.artifact_sub_path(whole, engine.mesh_clips(engine.Asset_GUID(raw))[0].id, context.temp_allocator)
	part0 := engine.artifact_sub_path(whole, engine.mesh_parts(engine.Asset_GUID(raw))[0].id, context.temp_allocator)
	testing.expect(t, os.exists(clip0), "the import bakes clip 0")

	engine._cleanup_stale_artifacts()
	testing.expect(t, os.exists(whole), "the model's artifact survives the sweep")
	testing.expect(t, os.exists(part0), "its mesh part survives the sweep")
	testing.expect(t, os.exists(clip0), "its baked clip survives the sweep")
}
