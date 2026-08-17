package tests

// Content-addressed artifact pipeline (README "library"): keys hash source
// bytes + settings + importer version, ArtifactDB.json maps guid -> key, and
// a setting toggled back is a cache hit on the old artifact. Headless — the
// texture importer decodes and writes blobs, no GPU.
//
// Tests run from the repo root where no library/ exists (the binaries chdir
// into moonhug/), so the whole tree this creates is removed at the end.

import "core:encoding/json"
import "core:encoding/uuid"
import "core:os"
import "core:strings"
import "core:testing"
import "../engine"

@(private = "file")
_remove_tree :: proc(dir: string) {
	handle, err := os.open(dir)
	if err != nil do return
	entries, rerr := os.read_dir(handle, -1, context.temp_allocator)
	os.close(handle)
	if rerr != nil do return
	for entry in entries {
		full := strings.concatenate({dir, "/", entry.name}, context.temp_allocator)
		if entry.type == .Directory {
			_remove_tree(full)
		} else {
			os.remove(full)
		}
	}
	os.remove(dir)
}

@(test)
test_artifact_content_addressing :: proc(t: ^testing.T) {
	src_dir :: "moonhug/tests/fixtures/_pipeline_tmp"
	png :: src_dir + "/probe.png"
	os.make_directory(src_dir)
	data, rerr := os.read_entire_file("moonhug/packages/app/assets/textures/circle-256.png", context.temp_allocator)
	testing.expect(t, rerr == nil)
	if rerr != nil do return
	testing.expect(t, os.write_entire_file(png, data) == nil)
	defer {
		os.remove(png)
		os.remove(png + ".meta")
		os.remove(src_dir)
		_remove_tree("library")
	}

	engine.asset_pipeline_init()
	engine.asset_pipeline_ensure_import_meta(png)

	// The minted guid, straight from the meta.
	Meta :: struct {
		guid: string,
	}
	meta: Meta
	meta_data, mrerr := os.read_entire_file(png + ".meta", context.temp_allocator)
	testing.expect(t, mrerr == nil)
	if mrerr != nil do return
	testing.expect(t, json.unmarshal(meta_data, &meta, allocator = context.temp_allocator) == nil)
	raw_guid, perr := uuid.read(meta.guid)
	testing.expect(t, perr == nil)
	if perr != nil do return
	guid := engine.Asset_GUID(raw_guid)

	// First import: artifact created under the fan-out layout, indexed by guid.
	testing.expect(t, engine.asset_pipeline_import_asset(png), "first import should run")
	p1, ok1 := engine.asset_pipeline_artifact_path(guid)
	testing.expect(t, ok1)
	if !ok1 do return
	p1 = strings.clone(p1, context.temp_allocator)
	testing.expect(t, strings.has_prefix(p1, "library/artifacts/"), "artifact should live under library/artifacts")
	rest := strings.trim_prefix(p1, "library/artifacts/")
	testing.expect(t, len(rest) > 3 && rest[2] == '/', "fan-out folder should be the key's first two hex chars")
	testing.expect(t, strings.has_prefix(rest[3:], rest[:2]), "file name should start with its fan-out prefix")
	testing.expect(t, os.exists(p1))

	// Unchanged source + settings: one stat, no re-import.
	testing.expect(t, !engine.asset_pipeline_import_asset(png), "unchanged asset should be fresh")

	// A settings change is a different key — the old artifact stays.
	s, sok := engine.asset_pipeline_get_settings(png)
	testing.expect(t, sok)
	if !sok do return
	defer free(s.data) // the caller owns the settings instance
	ts := s.(engine.TextureSettings)
	original_ppu := ts.pixels_per_unit
	ts.pixels_per_unit = 50
	testing.expect(t, engine.asset_pipeline_save_settings(png, ts))
	testing.expect(t, engine.asset_pipeline_import_asset(png), "settings change should import")
	p2, ok2 := engine.asset_pipeline_artifact_path(guid)
	testing.expect(t, ok2)
	if !ok2 do return
	p2 = strings.clone(p2, context.temp_allocator)
	testing.expect(t, p2 != p1, "changed settings should produce a different artifact key")
	testing.expect(t, os.exists(p2))
	testing.expect(t, os.exists(p1), "the previous artifact is retained until GC")

	// Toggling the setting back is a cache HIT: the index re-points to the
	// first artifact without running the importer.
	ts.pixels_per_unit = original_ppu
	testing.expect(t, engine.asset_pipeline_save_settings(png, ts))
	testing.expect(t, engine.asset_pipeline_import_asset(png), "toggle back should re-point the index")
	p3, ok3 := engine.asset_pipeline_artifact_path(guid)
	testing.expect(t, ok3)
	if ok3 {
		testing.expect(t, p3 == p1, "the original key should be hit, not re-imported")
	}
}

// A failed shader import must leave the index on the last GOOD artifact —
// that is what keeps materials rendering with the previous pipelines while
// the source has a compile error (shader.odin relies on it).
@(test)
test_shader_failed_import_keeps_last_good_artifact :: proc(t: ^testing.T) {
	// The shader toolchain is an optional dependency (authoring only) — skip
	// when it isn't installed.
	state, _, _, exec_err := os.process_exec({command = []string{"glslc", "--version"}}, context.temp_allocator)
	if exec_err != nil || !state.exited || state.exit_code != 0 do return

	src_dir :: "moonhug/tests/fixtures/_pipeline_tmp"
	glsl :: src_dir + "/probe.glsl"
	os.make_directory(src_dir)
	data, rerr := os.read_entire_file("moonhug/packages/app/assets/shaders/stripes.glsl", context.temp_allocator)
	testing.expect(t, rerr == nil)
	if rerr != nil do return
	testing.expect(t, os.write_entire_file(glsl, data) == nil)
	defer {
		os.remove(glsl)
		os.remove(glsl + ".meta")
		os.remove(src_dir)
		_remove_tree("library")
	}

	engine.asset_pipeline_init()
	engine.asset_pipeline_ensure_import_meta(glsl)

	Meta :: struct {
		guid: string,
	}
	meta: Meta
	meta_data, mrerr := os.read_entire_file(glsl + ".meta", context.temp_allocator)
	testing.expect(t, mrerr == nil)
	if mrerr != nil do return
	testing.expect(t, json.unmarshal(meta_data, &meta, allocator = context.temp_allocator) == nil)
	raw_guid, perr := uuid.read(meta.guid)
	testing.expect(t, perr == nil)
	if perr != nil do return
	guid := engine.Asset_GUID(raw_guid)

	testing.expect(t, engine.asset_pipeline_import_asset(glsl), "first import should run")
	p1, ok1 := engine.asset_pipeline_artifact_path(guid)
	testing.expect(t, ok1)
	if !ok1 do return
	p1 = strings.clone(p1, context.temp_allocator)
	testing.expect(t, os.exists(p1))

	// Break the source. The importer fails (glslc rejects it) and the index
	// must still resolve to the good artifact.
	testing.expect(t, os.write_entire_file(glsl, transmute([]u8)string("not valid glsl {")) == nil)
	testing.expect(t, !engine.asset_pipeline_import_asset(glsl), "broken source should fail the importer")
	p2, ok2 := engine.asset_pipeline_artifact_path(guid)
	testing.expect(t, ok2, "guid should still resolve after a failed import")
	if ok2 {
		testing.expect(t, p2 == p1, "index should keep the last good artifact")
		testing.expect(t, os.exists(p2))
	}
}
