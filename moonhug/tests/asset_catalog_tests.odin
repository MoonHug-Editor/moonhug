package tests

// The asset catalog round trip (docs/AssetPipeline.md "Asset catalog"):
// the auto-written catalog restores the AssetDB + artifact index under the
// catalog pipeline, catalog.export_from stages a self-contained relocatable data dir
// (boot scene stamped), and under the catalog pipeline refresh no-ops and runtime
// imports are refused.

import "core:encoding/json"
import "core:encoding/uuid"
import "core:os"
import "core:strings"
import "core:testing"
import "../engine"
import "moonhug:engine_editor/asset_pipeline"
import "../engine/catalog"

@(test)
test_asset_catalog_round_trip :: proc(t: ^testing.T) {
	src_dir :: "moonhug/tests/fixtures/_catalog_tmp"
	png :: src_dir + "/probe.png"
	cat :: src_dir + "/catalog.json"
	os.make_directory(src_dir)
	data, rerr := os.read_entire_file("moonhug/packages/app/assets/textures/circle-256.png", context.temp_allocator)
	testing.expect(t, rerr == nil)
	if rerr != nil do return
	testing.expect(t, os.write_entire_file(png, data) == nil)
	defer {
		os.remove(png)
		os.remove(png + ".meta")
		os.remove(cat)
		os.remove(src_dir)
		_remove_tree("library")
	}

	// Live mode: scan the fixture dir and import (mints meta + artifact).
	asset_pipeline.asset_pipeline_init()
	engine.asset_db_init(src_dir)
	_ = asset_pipeline.asset_pipeline_import_asset(png)

	raw_guid, gok := engine.asset_db_get_guid(png)
	testing.expect(t, gok, "scan should register the fixture")
	if !gok do return
	guid := engine.Asset_GUID(raw_guid)
	live_artifact, aok := engine.asset_pipeline_artifact_path(guid)
	testing.expect(t, aok, "import should index an artifact")
	live_artifact = strings.clone(live_artifact, context.temp_allocator)

	testing.expect(t, engine.asset_catalog_write(cat), "write should snapshot the db")
	engine.asset_db_shutdown()

	// Catalog pipeline: everything resolves from the catalog file alone.
	testing.expect(t, engine.asset_db_init_from_catalog(cat), "catalog pipeline should load the catalog")
	defer engine.asset_db_shutdown()

	path, pok := engine.asset_db_get_path(raw_guid)
	testing.expect(t, pok && path == png, "guid should resolve to the source path")
	catalog_artifact, cok := engine.asset_pipeline_artifact_path(guid)
	testing.expect(t, cok && catalog_artifact == live_artifact, "artifact key should survive the round trip")

	// The catalog is authoritative: no repair imports, no rescans.
	testing.expect(t, !asset_pipeline.asset_pipeline_import_asset(png), "catalog pipeline should refuse imports")
	asset_pipeline.asset_db_refresh() // no-op by contract — must not scan or crash
	still, sok := engine.asset_db_get_path(raw_guid)
	testing.expect(t, sok && still == png, "refresh under catalog pipeline should change nothing")
}

// catalog.export_from: sources + artifacts copied into a self-contained data
// dir with a RELOCATABLE catalog, boot scene stamped. Proven by deleting the
// originals — every resolve must come from the export alone (including baked
// import settings, since no .meta ships). Runs the same catalog-driven path
// run configs use (rc.export_data), just without the "moonhug" root prefix
// because tests already run from the repo root.
@(test)
test_asset_catalog_export_is_self_contained :: proc(t: ^testing.T) {
	src_dir :: "moonhug/tests/fixtures/_catalog_export_tmp"
	png :: src_dir + "/probe.png"
	data_dir :: src_dir + "_data"
	os.make_directory(src_dir)
	data, rerr := os.read_entire_file("moonhug/packages/app/assets/textures/circle-256.png", context.temp_allocator)
	testing.expect(t, rerr == nil)
	if rerr != nil do return
	testing.expect(t, os.write_entire_file(png, data) == nil)
	defer {
		os.remove(png)
		os.remove(png + ".meta")
		os.remove(src_dir)
		_remove_tree(data_dir)
		_remove_tree("library")
	}

	asset_pipeline.asset_pipeline_init()
	engine.asset_db_init(src_dir)
	_ = asset_pipeline.asset_pipeline_import_asset(png)
	raw_guid, gok := engine.asset_db_get_guid(png)
	testing.expect(t, gok)
	if !gok do return
	guid := engine.Asset_GUID(raw_guid)

	// The editor's auto-maintained catalog, then the config-side export from it.
	testing.expect(t, engine.asset_catalog_write(), "in-place catalog should write")
	engine.asset_db_shutdown()
	testing.expect(t, catalog.export_from("library/catalog.json", data_dir, boot_scene = png),
		"export from the catalog should succeed")

	// Sever the working tree: source, meta and library all gone.
	os.remove(png)
	os.remove(png + ".meta")
	_remove_tree("library")

	cat := data_dir + "/catalog.json"
	testing.expect(t, engine.asset_db_init_from_catalog(cat), "catalog pipeline from the export")
	defer engine.asset_db_shutdown()

	path, pok := engine.asset_db_get_path(raw_guid)
	testing.expect(t, pok && strings.has_prefix(path, data_dir), "path should point into the data dir")
	testing.expect(t, pok && os.exists(path), "copied source should exist")

	artifact, aok := engine.asset_pipeline_artifact_path(guid)
	testing.expect(t, aok && strings.has_prefix(artifact, data_dir), "artifact should point into the data dir")
	testing.expect(t, aok && os.exists(artifact), "copied artifact should exist")

	// The pinned boot asset survived as a guid stamp.
	testing.expect_value(t, engine.asset_db_boot_scene(), guid)

	// Settings come from the catalog, not a .meta (none shipped).
	settings, sok := engine.asset_pipeline_get_settings(path, context.temp_allocator)
	testing.expect(t, sok, "baked settings should resolve")
	if ts, is_tex := settings.(engine.TextureSettings); sok && is_tex {
		testing.expect(t, ts.pixels_per_unit > 0, "texture settings should carry real values")
	} else if sok {
		testing.expect(t, false, "settings should materialize as TextureSettings")
	}

	testing.expect(t, !asset_pipeline.asset_pipeline_import_asset(path), "catalog pipeline should refuse imports")
}

// The export ships the boot scene's dependency CLOSURE, not the whole catalog:
// an asset the scene references by guid ships, one under a `resources` folder
// ships, an unreferenced one does not. Folders on the way to shipped assets
// ship too, so the exported tree keeps its shape. Proven the same way as the
// self-contained test: the originals are deleted before the export is read.
@(test)
test_asset_catalog_export_ships_dependency_closure :: proc(t: ^testing.T) {
	src_dir :: "moonhug/tests/fixtures/_catalog_closure_tmp"
	used :: src_dir + "/used.png"
	unused :: src_dir + "/unused.png"
	res_dir :: src_dir + "/" + catalog.RESOURCES_DIR
	by_path :: res_dir + "/by_path.png"
	scene :: src_dir + "/boot.scene"
	data_dir :: src_dir + "_data"
	os.make_directory(src_dir)
	os.make_directory(res_dir)
	png, rerr := os.read_entire_file("moonhug/packages/app/assets/textures/circle-256.png", context.temp_allocator)
	testing.expect(t, rerr == nil)
	if rerr != nil do return
	for p in ([]string{used, unused, by_path}) do testing.expect(t, os.write_entire_file(p, png) == nil)
	// A placeholder scene: the guid of `used` is not known until the scan
	// mints it, so the file is rewritten below.
	testing.expect(t, os.write_entire_file(scene, transmute([]byte)string("{}")) == nil)
	defer {
		_remove_tree(src_dir)
		_remove_tree(data_dir)
		_remove_tree("library")
	}

	asset_pipeline.asset_pipeline_init()
	engine.asset_db_init(src_dir)
	for p in ([]string{used, unused, by_path}) do _ = asset_pipeline.asset_pipeline_import_asset(p)
	used_guid, uok := engine.asset_db_get_guid(used)
	unused_guid, nok := engine.asset_db_get_guid(unused)
	by_path_guid, bok := engine.asset_db_get_guid(by_path)
	res_guid, fok := engine.asset_db_get_guid(res_dir)
	testing.expect(t, uok && nok && bok && fok, "scan should register every fixture, the folder included")
	if !(uok && nok && bok && fok) do return

	// The scene references `used` the way a serialized component does: its
	// guid as a string, somewhere in the text.
	scene_text := strings.concatenate({"{\"sprite\": {\"guid\": \"", uuid.to_string(used_guid, context.temp_allocator), "\"}}"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(scene, transmute([]byte)scene_text) == nil)

	testing.expect(t, engine.asset_catalog_write(), "in-place catalog should write")
	engine.asset_db_shutdown()
	testing.expect(t, catalog.export_from("library/catalog.json", data_dir, boot_scene = scene), "export should succeed")

	_remove_tree(src_dir)
	_remove_tree("library")

	testing.expect(t, engine.asset_db_init_from_catalog(data_dir + "/catalog.json"), "catalog pipeline from the export")
	defer engine.asset_db_shutdown()

	_, has_used := engine.asset_db_get_path(used_guid)
	_, has_unused := engine.asset_db_get_path(unused_guid)
	_, has_by_path := engine.asset_db_get_path(by_path_guid)
	_, has_res := engine.asset_db_get_path(res_guid)
	testing.expect(t, has_used, "an asset the boot scene references ships")
	testing.expect(t, !has_unused, "an asset nothing references does not ship")
	testing.expect(t, has_by_path, "an asset under a resources folder ships")
	testing.expect(t, has_res, "the resources folder itself ships")
	testing.expect(t, os.exists(data_dir + "/" + used), "referenced source is copied")
	testing.expect(t, !os.exists(data_dir + "/" + unused), "unreferenced source is not copied")
	artifact, aok := engine.asset_pipeline_artifact_path(engine.Asset_GUID(used_guid))
	testing.expect(t, aok && os.exists(artifact), "referenced artifact is copied")
}

@(test)
test_asset_catalog_export_rejects_unknown_boot_scene :: proc(t: ^testing.T) {
	src_dir :: "moonhug/tests/fixtures/_catalog_boot_tmp"
	png :: src_dir + "/probe.png"
	data_dir :: src_dir + "_data"
	os.make_directory(src_dir)
	data, rerr := os.read_entire_file("moonhug/packages/app/assets/textures/circle-256.png", context.temp_allocator)
	testing.expect(t, rerr == nil)
	if rerr != nil do return
	testing.expect(t, os.write_entire_file(png, data) == nil)
	defer {
		os.remove(png)
		os.remove(png + ".meta")
		os.remove(src_dir)
		_remove_tree(data_dir)
		_remove_tree("library")
	}

	asset_pipeline.asset_pipeline_init()
	engine.asset_db_init(src_dir)
	_ = asset_pipeline.asset_pipeline_import_asset(png)
	testing.expect(t, engine.asset_catalog_write())
	engine.asset_db_shutdown()

	testing.expect(t, !catalog.export_from("library/catalog.json", data_dir, boot_scene = "assets/not_in_catalog.scene"),
		"a boot scene missing from the catalog should fail the export")
}

@(test)
test_asset_catalog_version_mismatch_rejected :: proc(t: ^testing.T) {
	src_dir :: "moonhug/tests/fixtures/_catalog_ver_tmp"
	cat :: src_dir + "/catalog.json"
	os.make_directory(src_dir)
	defer {
		os.remove(cat)
		os.remove(src_dir)
	}

	stale := catalog.File{version = catalog.VERSION + 1}
	data, merr := json.marshal(stale, {spec = .JSON}, context.temp_allocator)
	testing.expect(t, merr == nil)
	testing.expect(t, os.write_entire_file(cat, data) == nil)

	testing.expect(t, !engine.asset_db_init_from_catalog(cat), "future catalog version should be rejected")
}
