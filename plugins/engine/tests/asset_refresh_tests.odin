package engine_tests

// The editor's refresh keeps the asset database in line with the files when
// something outside the editor changes them, a git checkout for one: a meta
// rewritten on disk reimports the asset with its settings, a refresh with
// nothing changed imports nothing, and a new file is left to import when
// first needed.

import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "moonhug:packages/engine"
import asset_pipeline "moonhug:editor/assets"
import assets "moonhug:libs/assets"

@(test)
test_refresh_reimports_an_asset_whose_meta_changed_on_disk :: proc(t: ^testing.T) {
	dir :: "moonhug/tests/fixtures/_refresh_tmp"
	png :: dir + "/probe.png"
	os.make_directory(dir)
	defer {
		_remove_tree(dir)
		_remove_tree(engine.library_dir())
	}
	data, rerr := os.read_entire_file("moonhug/tests/fixtures/textures/circle-256.png", context.temp_allocator)
	testing.expect(t, rerr == nil)
	if rerr != nil do return
	testing.expect(t, os.write_entire_file(png, data) == nil)

	asset_pipeline.asset_pipeline_init()
	engine.asset_db_init(dir)
	defer engine.asset_db_shutdown()
	testing.expect(t, asset_pipeline.asset_pipeline_import_asset(png), "the first import")
	raw, gok := engine.asset_db_get_guid(png)
	testing.expect(t, gok)
	if !gok do return
	guid := engine.Asset_GUID(raw)
	key_of :: proc(g: engine.Asset_GUID) -> string {
		k, _ := engine.asset_pipeline_artifact_key(g)
		return strings.clone(k, context.temp_allocator)
	}
	first := key_of(guid)

	// Nothing changed: the refresh imports nothing.
	asset_pipeline.asset_db_refresh()
	testing.expect_value(t, key_of(guid), first)

	// The meta changes outside the editor, the way a checkout rewrites it.
	time.sleep(5 * time.Millisecond)
	meta, merr := os.read_entire_file(png + ".meta", context.temp_allocator)
	testing.expect(t, merr == nil)
	if merr != nil do return
	text := string(meta)
	from, to := `"filter": 0`, `"filter": 1`
	if !strings.contains(text, from) do from, to = to, from
	changed, _ := strings.replace_all(text, from, to, context.temp_allocator)
	testing.expect(t, changed != text, "the meta names a filter to flip")
	testing.expect(t, os.write_entire_file(png + ".meta", changed) == nil)

	asset_pipeline.asset_db_refresh()
	testing.expect(t, key_of(guid) != first, "the refresh reimported the asset with the meta's new settings")

	// A new file is registered by the refresh and imports when first needed.
	second := dir + "/second.png"
	testing.expect(t, os.write_entire_file(second, data) == nil)
	asset_pipeline.asset_db_refresh()
	raw2, ok2 := engine.asset_db_get_guid(second)
	testing.expect(t, ok2, "the new file is registered")
	_, imported := engine.asset_pipeline_artifact_key(engine.Asset_GUID(raw2))
	testing.expect(t, !imported, "and not imported yet")

	// Its meta, written by that refresh, is no change for the next one.
	asset_pipeline.asset_db_refresh()
	_, imported = engine.asset_pipeline_artifact_key(engine.Asset_GUID(raw2))
	testing.expect(t, !imported, "the refresh's own meta write imports nothing")
}

// The scan records which entries are folders, so a lookup needs no file
// system call (the Project view's search asks for every hit). A folder made
// later shows up as one after the next refresh, and an unchanged folder does
// not read as changed.
@(test)
test_asset_db_knows_folders :: proc(t: ^testing.T) {
	dir :: "moonhug/tests/fixtures/_folders_tmp"
	os.make_directory(dir)
	os.make_directory(dir + "/sub")
	defer {
		_remove_tree(dir)
		_remove_tree(engine.library_dir())
	}
	data, rerr := os.read_entire_file("moonhug/tests/fixtures/textures/circle-256.png", context.temp_allocator)
	testing.expect(t, rerr == nil)
	if rerr != nil do return
	testing.expect(t, os.write_entire_file(dir + "/sub/probe.png", data) == nil)

	asset_pipeline.asset_pipeline_init()
	engine.asset_db_init(dir)
	defer engine.asset_db_shutdown()
	testing.expect(t, assets.asset_db_is_dir(dir + "/sub"), "a folder")
	testing.expect(t, !assets.asset_db_is_dir(dir + "/sub/probe.png"), "a file")
	testing.expect(t, !assets.asset_db_is_dir(dir + "/missing"), "nothing there")

	os.make_directory(dir + "/later")
	asset_pipeline.asset_db_refresh()
	testing.expect(t, assets.asset_db_is_dir(dir + "/later"), "a folder made later")
	testing.expect_value(t, asset_pipeline.asset_db_last_refresh.created, 1)
	testing.expect_value(t, asset_pipeline.asset_db_last_refresh.modified, 0) // the unchanged folder and file
}
