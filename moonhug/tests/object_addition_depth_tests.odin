package tests

// Object additions must survive save+reload at EVERY nesting depth, including
// a parent that lives inside a prefab nested within the instance. Unity records
// such a modification in the file that CONTAINS the instance (never the source
// prefab), addressing the parent by a composed fileID — so depth is a property
// of the address, not a reason to refuse the edit.
//
// Runs against the real prefabs_example chain rather than a synthetic fixture:
// host.scene -> blobs.scene -> {c.scene, c_Variant.scene} is the shape that
// exposed every bug here, and look-alike names across levels (three different
// "Transform" rows) are exactly what mis-targeted the capture.

import engine "../engine"
import "core:strings"
import "core:testing"

@(test)
test_object_addition_survives_at_every_depth :: proc(t: ^testing.T) {
	cases := []struct{ scene, parent: string }{
		{"host.scene", "Root/blobs_Variant"},
		{"host.scene", "Root/blobs_Variant/Transform"},
		{"host.scene", "Root/blobs_Variant/c"},
		{"host.scene", "Root/blobs_Variant/c/Transform"}, // parent inside a nested prefab
		{"host.scene", "Root/blobs_Variant/c_Variant"},
		{"blobs.scene", "Root/Transform"},
		{"blobs.scene", "Root/c"},
		{"blobs.scene", "Root/c_Variant"},
	}

	for c in cases {
		engine.asset_db_init("moonhug/packages/prefabs_example/assets")

		tc_mem := new(TestCtx)
		setup(tc_mem, "moonhug/tests/fixtures/_test_depth_added.scene")
		context.user_ptr = &tc_mem.uc

		src := strings.concatenate(
			{"moonhug/packages/prefabs_example/assets/", c.scene},
			context.temp_allocator,
		)
		loaded := engine.scene_load_single_path(src)
		testing.expectf(t, loaded != nil, "%v should load", c.scene)
		if loaded != nil {
			tc_mem.scene = loaded

			parent := _find_by_path(&tc_mem.world, loaded, c.parent)
			testing.expectf(t, parent != {}, "%v: %v should resolve", c.scene, c.parent)
			if parent != {} {
				added := engine.transform_new("DepthAddedChild", parent)
				testing.expectf(t, added != {}, "%v: %v child should be created", c.scene, c.parent)

				testing.expectf(t, engine.scene_save(loaded, tc_mem.path), "%v: save", c.scene)

				engine.sm_scene_destroy_or_unload(loaded)
				engine.sm_scene_set_active(nil)
				reloaded := engine.scene_load_single_path(tc_mem.path)
				tc_mem.scene = reloaded
				testing.expectf(t, reloaded != nil, "%v: reload", c.scene)

				if reloaded != nil {
					back := find_transform_named(&tc_mem.world, reloaded, "DepthAddedChild", false)
					testing.expectf(t, back != {},
						"%v: child added under %v must come back after reload", c.scene, c.parent)
				}
			}
		}

		teardown(tc_mem)
		free(tc_mem)
		engine.asset_db_shutdown()
		engine.scene_lib_shutdown()
	}
}

// Resolves a slash-separated hierarchy path. Bare-name lookup is ambiguous
// here: "Transform" names three different rows at three nesting levels.
@(private = "file")
_find_by_path :: proc(w: ^engine.World, s: ^engine.Scene, path: string) -> engine.Transform_Handle {
	it := engine.pool_iterator(&w.transforms)
	for tr, h in engine.pool_next(&it) {
		if tr.scene != s do continue

		chain := tr.name
		pt := engine.pool_get(&w.transforms, tr.parent.handle)
		for pt != nil {
			chain = strings.concatenate({pt.name, "/", chain}, context.temp_allocator)
			pt = engine.pool_get(&w.transforms, pt.parent.handle)
		}
		if strings.compare(chain, path) == 0 {
			th := h
			th.type_key = .Transform
			return engine.Transform_Handle(th)
		}
	}
	return {}
}
