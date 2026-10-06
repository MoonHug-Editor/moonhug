package app_tests

import "core:testing"
import "moonhug:packages/engine"
import common "moonhug:tests/common"

// Asset-namespace PPtrs must survive nested-instance lid composition. A PPtr
// with a guid addresses ANOTHER asset's namespace (MeshFilter.mesh's local_id
// is a mesh PART id) — the instance remap walker used to push it through the
// scene lid map, so a part id that collided with a source object lid got
// retargeted at a nonexistent part and the filter drew nothing. BoxAnimated
// is the live case: part id 2 == the prefab root's lid 2, so nesting it in
// demo_prefabs broke exactly the outer box.
@(test)
test_nested_instance_keeps_asset_pptr_part_ids :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc, "")
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	engine.asset_db_init("moonhug/packages/app/assets")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	s := engine.scene_load_additive_path("moonhug/packages/app/assets/demo_prefabs/demo_prefabs.scene")
	testing.expect(t, s != nil, "demo_prefabs loads")
	if s == nil do return

	checked := 0
	it := engine.pool_iterator(&tc.world.transforms)
	for tr, ih in engine.pool_next(&it) {
		if tr.scene != s do continue
		if tr.name != "node_2" && tr.name != "node_3" do continue
		th := ih
		th.type_key = .Transform
		_, mf := engine.transform_get_comp(engine.Transform_Handle(th), engine.MeshFilter)
		if mf == nil do continue
		checked += 1
		expected := engine.Local_ID(tr.name == "node_2" ? 1 : 2)
		testing.expectf(t, mf.mesh.local_id == expected,
			"%s: part id must stay %d (authored), got %d — the remap walker corrupted an asset PPtr",
			tr.name, expected, mf.mesh.local_id)
		_, ok := engine.mesh_filter_part(mf)
		testing.expectf(t, ok, "%s: part must resolve in the model's table", tr.name)
	}
	testing.expect_value(t, checked, 2)
}
