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

@(private = "file")
_find_sprite :: proc(w: ^engine.World, s: ^engine.Scene, nested_only := false) -> (^engine.SpriteRenderer, engine.Transform_Handle) {
	for i in 0 ..< len(w.transforms.slots) {
		slot := &w.transforms.slots[i]
		if !slot.alive || slot.data.scene != s do continue
		if nested_only && !slot.data.nested_owned do continue
		h := engine.Transform_Handle(engine.Handle{index = u32(i), generation = slot.generation, type_key = .Transform})
		_, sr := engine.transform_get_comp(h, engine.SpriteRenderer)
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

// Editing bullet_Variant's inherited content and saving must propagate into a
// freshly loaded host. Mutates files, so it runs on a temp copy of the chain.
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

	bv_path := strings.concatenate({dir, "/bullet_Variant.scene"}, context.temp_allocator)
	host_path := strings.concatenate({dir, "/host.scene"}, context.temp_allocator)
	new_color := [4]f32{0.111, 0.222, 0.333, 1}

	// EDITOR FLOW: open the variant single, edit inherited content, save.
	variant := engine.scene_load_single_path(bv_path)
	testing.expect(t, variant != nil, "bullet_Variant should load")
	if variant == nil do return
	tc.scene = variant
	engine.sm_scene_set_active(variant)
	sr, _ := _find_sprite(&tc.world, variant, nested_only = true)
	testing.expect(t, sr != nil, "bullet_Variant should have inherited sprite content")
	if sr == nil do return
	sr.color = new_color
	testing.expect(t, engine.scene_save(variant, bv_path), "variant save")

	// A fresh host load must show the edit in its nested copy.
	host := engine.scene_load_single_path(host_path)
	testing.expect(t, host != nil, "host should load")
	if host == nil do return
	tc.scene = host
	found := false
	for i in 0 ..< len(tc.world.transforms.slots) {
		slot := &tc.world.transforms.slots[i]
		if !slot.alive || slot.data.scene != host do continue
		h := engine.Transform_Handle(engine.Handle{index = u32(i), generation = slot.generation, type_key = .Transform})
		_, hsr := engine.transform_get_comp(h, engine.SpriteRenderer)
		if hsr != nil && _color_close(hsr.color, new_color) do found = true
	}
	testing.expect(t, found, "edited variant color must appear in the host's nested copy")
}

// The value of bullet_Variant's root-NS color override, read from the file —
// never hardcoded, the scenes are editable.
@(private = "file")
_deep_override_from_file :: proc(t: ^testing.T) -> (val: [4]f32, ok: bool) {
	sf, lok := engine.scene_file_load(strings.concatenate({ASSETS, "/bullet_Variant.scene"}, context.temp_allocator))
	testing.expect(t, lok, "load bullet_Variant file")
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
	testing.expect(t, ok, "bullet_Variant should carry a root-NS color override (the chain's test-bed structure)")
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

	bv_guid, gok := engine.asset_db_get_guid(strings.concatenate({ASSETS, "/bullet_Variant.scene"}, context.temp_allocator))
	testing.expect(t, gok, "bullet_Variant registered")
	if !gok do return

	root := engine.Transform_Handle(tc.scene.root.handle)
	nested := engine.scene_instantiate_guid_nested(engine.Asset_GUID(bv_guid), root)
	testing.expect(t, nested != {}, "nesting bullet_Variant should succeed")
	if nested == {} do return

	found := false
	for i in 0 ..< len(tc.world.transforms.slots) {
		slot := &tc.world.transforms.slots[i]
		if !slot.alive || slot.data.scene != tc.scene do continue
		h := engine.Transform_Handle(engine.Handle{index = u32(i), generation = slot.generation, type_key = .Transform})
		_, sr := engine.transform_get_comp(h, engine.SpriteRenderer)
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

	loaded := engine.scene_load_single_path(strings.concatenate({ASSETS, "/bullet_Variant.scene"}, context.temp_allocator))
	testing.expect(t, loaded != nil, "bullet_Variant loads")
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
	testing.expect(t, has, "bullet_Variant should carry a root-NS color override (the chain's test-bed structure)")
	if !has do return

	// The live sprite the override is applied to.
	target_h: engine.Transform_Handle
	for i in 0 ..< len(tc.world.transforms.slots) {
		slot := &tc.world.transforms.slots[i]
		if !slot.alive || slot.data.scene != loaded do continue
		h := engine.Transform_Handle(engine.Handle{index = u32(i), generation = slot.generation, type_key = .Transform})
		_, sr := engine.transform_get_comp(h, engine.SpriteRenderer)
		if sr != nil && _color_close(sr.color, override_color) {
			target_h = h
			break
		}
	}
	testing.expect(t, target_h != {}, "override should be applied to a live sprite before revert")
	if target_h == {} do return

	engine.nested_scene_revert_override(loaded, root_ns, target, "color")
	_, sr := engine.transform_get_comp(target_h, engine.SpriteRenderer)
	testing.expect(t, sr != nil)
	if sr != nil {
		testing.expect(t, !_color_close(sr.color, override_color),
			fmt.tprintf("after revert color must leave the override %v, got %v", override_color, sr.color))
	}
}
