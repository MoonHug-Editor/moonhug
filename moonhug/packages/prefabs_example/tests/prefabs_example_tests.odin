package prefabs_example_tests

// Invariant tests over this package's OWN committed assets — the editable
// prefab/variant chain in ../assets (see ../prefabs_example.odin). These are
// the counterpart to the hermetic fixture tests in moonhug/tests: those pin
// the MECHANISM with known values, these validate real editor-authored FILES.
// Edit the scenes freely — expectations are derived from the files, never
// hardcoded, so a test fails only when an edit removes the structure it
// exercises (its guard assertion says which).
//
// Tests that MUTATE files first copy the chain into a temp dir. Read-only
// tests run directly on the committed assets.

import "core:fmt"
import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:testing"
import "moonhug:engine"
import sprites "moonhug:packages/sprites"
import "moonhug:engine_editor/asset_pipeline"
import common "moonhug:tests/common"

ASSETS :: "moonhug/packages/prefabs_example/assets"

// Every .scene under assets/ — a scene added in the editor joins the
// glob-driven tests without touching test code.
@(private = "file")
_scene_paths :: proc(dir := ASSETS) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	d, err := os.open(dir)
	if err != nil do return out[:]
	defer os.close(d)
	files, rerr := os.read_dir(d, -1, context.temp_allocator)
	if rerr != nil do return out[:]
	for f in files {
		if f.type == .Directory || !strings.has_suffix(f.name, ".scene") do continue
		append(&out, strings.concatenate({dir, "/", f.name}, context.temp_allocator))
	}
	return out[:]
}

// The chain's root-variant scene, found by STRUCTURE rather than by name: the
// scene whose file carries a root NS (`transform_parent == 0`) with a color
// override. Renaming the scenes in the editor never touches test code — same
// rule as _scene_paths and the file-derived expectations.
@(private = "file")
_find_root_variant_path :: proc(t: ^testing.T, dir := ASSETS) -> (path: string, ok: bool) {
	for p in _scene_paths(dir) {
		sf, lok := engine.scene_file_load(p)
		if !lok do continue
		defer engine.scene_file_destroy(&sf)
		for &ns in sf.nested_scenes {
			if ns.transform_parent != 0 do continue
			for ov in ns.overrides {
				if ov.property_path != "color" do continue
				if arr, is_arr := ov.value.(json.Array); is_arr && len(arr) >= 4 {
					return p, true
				}
			}
		}
	}
	testing.expect(t, false, "the chain should contain a root-variant scene with a color override (the test-bed structure)")
	return "", false
}

// The scene that NESTS `nested_path` — matched on the nested scene's GUID, not
// on a filename, so renames don't reach test code.
@(private = "file")
_find_host_path_for :: proc(t: ^testing.T, nested_path: string, dir := ASSETS) -> (path: string, ok: bool) {
	want, gok := engine.asset_db_get_guid(nested_path)
	if !gok {
		testing.expectf(t, false, "%s should be registered in the asset db", nested_path)
		return "", false
	}
	for p in _scene_paths(dir) {
		if p == nested_path do continue
		sf, lok := engine.scene_file_load(p)
		if !lok do continue
		defer engine.scene_file_destroy(&sf)
		for &ns in sf.nested_scenes {
			if ns.source_prefab == engine.Asset_GUID(want) do return p, true
		}
	}
	testing.expectf(t, false, "a host scene nesting %s should exist (the chain's test-bed structure)", nested_path)
	return "", false
}

@(private = "file")
_find_sprite :: proc(w: ^engine.World, s: ^engine.Scene, nested_only := false) -> (^sprites.SpriteRenderer, engine.Transform_Handle) {
	it := engine.pool_iterator(&w.transforms)
	for tr, ih in engine.pool_next(&it) {
		if tr.scene != s do continue
		if nested_only && !tr.nested_owned do continue
		th := ih
		th.type_key = .Transform
		h := engine.Transform_Handle(th)
		_, sr := engine.transform_get_comp(h, sprites.SpriteRenderer)
		if sr != nil do return sr, h
	}
	return nil, {}
}

@(private = "file")
_color_close :: proc(a, b: [4]f32) -> bool {
	d := a - b
	return d.x * d.x + d.y * d.y + d.z * d.z + d.w * d.w < 0.0001
}

// Every committed scene must re-serialize byte-identical to its disk bytes,
// loaded sequentially in one world so slots recycle between scenes. This is
// the format-drift guard the hermetic tests cannot provide: it fails when the
// serializer changes shape relative to what the editor last saved.
@(test)
test_prefabs_example_byte_stable :: proc(t: ^testing.T) {
	engine.asset_db_init(ASSETS)
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	paths := _scene_paths()
	testing.expect(t, len(paths) >= 5, "the chain scenes should be present")

	for pass in 0 ..< 2 {
		for path in paths {
			disk, rerr := os.read_entire_file(path, context.temp_allocator)
			testing.expectf(t, rerr == nil, "read %s", path)

			s := engine.scene_load_single_path(path)
			testing.expectf(t, s != nil, "pass %d: load %s", pass, path)
			if s == nil do continue
			tc.scene = s
			engine.sm_scene_set_active(s)

			data, ok := engine.scene_serialize(s)
			testing.expectf(t, ok, "pass %d: serialize %s", pass, path)
			if !ok do continue
			defer delete(data)
			if string(data) != string(disk) {
				di := 0
				for di < min(len(data), len(disk)) && data[di] == disk[di] do di += 1
				testing.expectf(t, false,
					"pass %d: %s not byte-stable (disk %d bytes, serialized %d, first diff at %d: %q)",
					pass, path, len(disk), len(data), di,
					string(data[di:min(di + 40, len(data))]))
			}
		}
	}
}

// Saving any of the scenes UNCHANGED must not invent overrides.
@(test)
test_prefabs_example_no_spurious_overrides :: proc(t: ^testing.T) {
	engine.asset_db_init(ASSETS)
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	// Saves land OUTSIDE assets/ so the committed files stay untouched.
	tmp := "moonhug/packages/prefabs_example/tests/_tmp_save.scene"
	defer os.remove(tmp)

	for path in _scene_paths() {
		s := engine.scene_load_single_path(path)
		testing.expectf(t, s != nil, "load %s", path)
		if s == nil do continue
		tc.scene = s
		engine.sm_scene_set_active(s)

		before := 0
		for &ns in s.nested_scenes do before += len(ns.overrides)
		testing.expectf(t, engine.scene_save(s, tmp), "save %s", path)
		after := 0
		for &ns in s.nested_scenes do after += len(ns.overrides)
		testing.expectf(t, after == before,
			"%s: spurious overrides captured on unchanged save: %d -> %d", path, before, after)
	}
}

// Editing the root variant's inherited content and saving must propagate into
// a freshly loaded host. Mutates files, so it runs on a temp copy of the chain.
@(test)
test_prefabs_example_variant_edit_propagates :: proc(t: ^testing.T) {
	dir := "moonhug/packages/prefabs_example/tests/_tmp_propagate"
	os.make_directory(dir)
	copied := make([dynamic]string, context.temp_allocator)
	defer {
		for f in copied do os.remove(f)
		os.remove(dir)
	}
	for src in _scene_paths() {
		for suffix in ([]string{"", ".meta"}) {
			from := strings.concatenate({src, suffix}, context.temp_allocator)
			to := strings.concatenate({dir, "/", from[strings.last_index_byte(from, '/') + 1:]}, context.temp_allocator)
			data, e := os.read_entire_file(from, context.temp_allocator)
			if e != nil do continue
			testing.expectf(t, os.write_entire_file(to, data) == nil, "copy %s", to)
			append(&copied, to)
		}
	}

	engine.asset_db_init(dir)
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	// Both resolved by structure inside the COPY: the root variant carries the
	// color override, the host is the scene that NESTS it by guid.
	bv_path, bvok := _find_root_variant_path(t, dir)
	if !bvok do return
	host_path, hok := _find_host_path_for(t, bv_path, dir)
	if !hok do return
	new_color := [4]f32{0.111, 0.222, 0.333, 1}

	// EDITOR FLOW: open the variant single, edit inherited content, save.
	variant := engine.scene_load_single_path(bv_path)
	testing.expectf(t, variant != nil, "%s should load", bv_path)
	if variant == nil do return
	tc.scene = variant
	engine.sm_scene_set_active(variant)
	sr, _ := _find_sprite(&tc.world, variant, nested_only = true)
	testing.expect(t, sr != nil, "the root variant should have inherited sprite content")
	if sr == nil do return
	sr.color = new_color
	testing.expect(t, engine.scene_save(variant, bv_path), "variant save")

	// A fresh host load must show the edit in its nested copy.
	host := engine.scene_load_single_path(host_path)
	testing.expect(t, host != nil, "host should load")
	if host == nil do return
	tc.scene = host
	found := false
	it := engine.pool_iterator(&tc.world.transforms)
	for tr, ih in engine.pool_next(&it) {
		if tr.scene != host do continue
		th := ih
		th.type_key = .Transform
		h := engine.Transform_Handle(th)
		_, hsr := engine.transform_get_comp(h, sprites.SpriteRenderer)
		if hsr != nil && _color_close(hsr.color, new_color) do found = true
	}
	testing.expect(t, found, "edited variant color must appear in the host's nested copy")
}

// The value of the root variant's root-NS color override, read from the file —
// never hardcoded, the scenes are editable.
@(private = "file")
_deep_override_from_file :: proc(t: ^testing.T) -> (val: [4]f32, ok: bool) {
	vpath, vok := _find_root_variant_path(t)
	if !vok do return
	sf, lok := engine.scene_file_load(vpath)
	testing.expectf(t, lok, "load %s", vpath)
	if !lok do return
	defer engine.scene_file_destroy(&sf)
	for &ns in sf.nested_scenes {
		if ns.transform_parent != 0 do continue
		for ov in ns.overrides {
			if ov.property_path != "color" do continue
			arr, is_arr := ov.value.(json.Array)
			if !is_arr || len(arr) < 4 do continue
			for k in 0 ..< 4 do val[k] = f32(arr[k].(json.Float))
			ok = true
		}
	}
	testing.expect(t, ok, "the root variant should carry a root-NS color override (the chain's test-bed structure)")
	return
}

// A variant's DEEP override must apply when the variant is NESTED, not only
// opened top-level. Read-only: instantiates into the bootstrap scene.
@(test)
test_prefabs_example_deep_override_applies_when_nested :: proc(t: ^testing.T) {
	engine.asset_db_init(ASSETS)
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	want, wok := _deep_override_from_file(t)
	if !wok do return

	vpath, vok := _find_root_variant_path(t)
	if !vok do return
	bv_guid, gok := engine.asset_db_get_guid(vpath)
	testing.expectf(t, gok, "%s registered", vpath)
	if !gok do return

	root := engine.Transform_Handle(tc.scene.root.handle)
	nested := engine.scene_instantiate_guid_nested(engine.Asset_GUID(bv_guid), root)
	testing.expectf(t, nested != {}, "nesting %s should succeed", vpath)
	if nested == {} do return

	found := false
	it := engine.pool_iterator(&tc.world.transforms)
	for tr, ih in engine.pool_next(&it) {
		if tr.scene != tc.scene do continue
		th := ih
		th.type_key = .Transform
		h := engine.Transform_Handle(th)
		_, sr := engine.transform_get_comp(h, sprites.SpriteRenderer)
		if sr != nil && _color_close(sr.color, want) do found = true
	}
	testing.expect(t, found, "the deep color override must apply to nested content")
}

// Reverting the deep override must move the live value OFF the override
// (back to the inherited baseline). Read-only: revert mutates the live world,
// nothing is saved.
@(test)
test_prefabs_example_deep_override_revert :: proc(t: ^testing.T) {
	engine.asset_db_init(ASSETS)
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	vpath, vok := _find_root_variant_path(t)
	if !vok do return
	loaded := engine.scene_load_single_path(vpath)
	testing.expectf(t, loaded != nil, "%s loads", vpath)
	if loaded == nil do return
	tc.scene = loaded
	engine.sm_scene_set_active(loaded)

	root_ns: ^engine.NestedScene = nil
	for &ns in loaded.nested_scenes {
		if engine.nested_scene_is_root_variant(loaded, &ns) {
			root_ns = &ns
			break
		}
	}
	testing.expect(t, root_ns != nil, "root variant NS")
	if root_ns == nil do return

	target: engine.PPtr
	override_color: [4]f32
	has := false
	for ov in root_ns.overrides {
		if ov.property_path != "color" do continue
		arr, is_arr := ov.value.(json.Array)
		if !is_arr || len(arr) < 4 do continue
		for k in 0 ..< 4 do override_color[k] = f32(arr[k].(json.Float))
		target = ov.target
		has = true
	}
	testing.expect(t, has, "the root variant should carry a root-NS color override (the chain's test-bed structure)")
	if !has do return

	// The live sprite the override is applied to.
	target_h: engine.Transform_Handle
	it := engine.pool_iterator(&tc.world.transforms)
	for tr, ih in engine.pool_next(&it) {
		if tr.scene != loaded do continue
		th := ih
		th.type_key = .Transform
		h := engine.Transform_Handle(th)
		_, sr := engine.transform_get_comp(h, sprites.SpriteRenderer)
		if sr != nil && _color_close(sr.color, override_color) {
			target_h = h
			break
		}
	}
	testing.expect(t, target_h != {}, "override should be applied to a live sprite before revert")
	if target_h == {} do return

	engine.nested_scene_revert_override(loaded, root_ns, target, "color")
	_, sr := engine.transform_get_comp(target_h, sprites.SpriteRenderer)
	testing.expect(t, sr != nil)
	if sr != nil {
		testing.expect(t, !_color_close(sr.color, override_color),
			fmt.tprintf("after revert color must leave the override %v, got %v", override_color, sr.color))
	}
}
