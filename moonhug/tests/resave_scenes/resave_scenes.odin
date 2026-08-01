package resave_scenes

// Re-saves every scene in the repo through the current serializer, so checked-in
// files match the serializer's shape after an additive format change (a new
// field on SceneFile / NestedScene / a component). Load->save is the byte-stable
// fixed point the package tests assert, so this is exactly what they expect.
//
//   odin run moonhug/tests/resave_scenes -collection:moonhug=moonhug -ignore-unknown-attributes
//
// Run from the REPO ROOT. Scenes are re-saved in place — commit the result as
// its own reviewed change, and check the diff: only the new keys should appear.
// A changed value or a new override in a scene that is NOT in SKIP is a real
// bug, not migration.

import "core:fmt"
import "core:os"
import "core:strings"
import "moonhug:engine"
import common "moonhug:tests/common"

// Every directory the asset db can mount. Each is inited separately so guid
// lookups resolve within the same root the editor would use.
ROOTS :: []string{
	"moonhug/packages/app/assets",
	"moonhug/packages/essentials/assets",
	"moonhug/packages/plugin_example/assets",
	"moonhug/packages/prefabs_example/assets",
	"moonhug/packages/physics2d/samples/physics2d_sample/assets",
	"moonhug/packages/physics3d/samples/physics3d_sample/assets",
	"moonhug/tests/fixtures/nested_scenes",
}

// Scenes whose committed bytes are load-bearing, so a re-save would break the
// test that reads them. These are hand-authored baselines, deliberately NOT at
// the serializer's fixed point: test_apply_override_clears_shadowing_intermediate
// writes a TestD override into TestC.scene during the run and then asserts a
// shallower Apply clears it. Re-saving bakes that override into the committed
// file, so the test starts from the state it means to produce and its assertion
// no longer proves anything.
//
// A migration that must reach these has to be applied by hand, keeping whatever
// property the test depends on intact.
SKIP :: []string{
	"moonhug/tests/fixtures/nested_scenes/TestC.scene",
	"moonhug/tests/fixtures/nested_scenes/TestD.scene",
}

_scenes :: proc(dir: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	handle, err := os.open(dir)
	if err != nil do return out[:]
	defer os.close(handle)
	entries, rerr := os.read_dir(handle, -1, context.temp_allocator)
	if rerr != nil do return out[:]
	for e in entries {
		path := strings.concatenate({dir, "/", e.name}, context.temp_allocator)
		if e.type == .Directory {
			for sub in _scenes(path) do append(&out, sub)
			continue
		}
		if strings.has_suffix(e.name, ".scene") do append(&out, path)
	}
	return out[:]
}

main :: proc() {
	total, changed := 0, 0
	for root in ROOTS {
		paths := _scenes(root)
		if len(paths) == 0 do continue

		engine.asset_db_init(root)
		tc := new(common.TestCtx)
		common.setup(tc)
		context.user_ptr = &tc.uc

		for path in paths {
			skipped := false
			for s in SKIP {
				if path == s {
					skipped = true
					break
				}
			}
			if skipped {
				fmt.printfln("SKIP (hand-authored baseline) %s", path)
				continue
			}

			total += 1
			before, _ := os.read_entire_file(path, context.temp_allocator)
			s := engine.scene_load_single_path(path)
			if s == nil {
				fmt.printfln("SKIP (load failed) %s", path)
				continue
			}
			tc.scene = s
			engine.sm_scene_set_active(s)
			if !engine.scene_save(s, path) {
				fmt.printfln("FAIL %s", path)
				continue
			}
			after, _ := os.read_entire_file(path, context.temp_allocator)
			if string(before) != string(after) {
				changed += 1
				fmt.printfln("updated %s", path)
			}
		}

		common.teardown(tc)
		free(tc)
		engine.asset_db_shutdown()
		engine.scene_lib_shutdown()
	}
	fmt.printfln("\n%d scenes scanned, %d updated", total, changed)
}
