package engine_tests

// A prefab spawned at run time (scene_instantiate_guid) keeps the references
// between its own objects: in every spawn, a reference points at that spawn's
// object. The first spawn unpacks the prefab and caches a copy, the next ones
// paste the copy, so both paths are covered.

import "core:os"
import "core:strings"
import "core:testing"
import "moonhug:packages/engine"

@(private = "file")
_child_named :: proc(w: ^engine.World, parent: engine.Transform_Handle, name: string) -> engine.Transform_Handle {
	t := engine.pool_get(&w.transforms, engine.Handle(parent))
	if t == nil do return {}
	for c in t.children {
		ct := engine.pool_get(&w.transforms, c.handle)
		if ct != nil && ct.name == name do return engine.Transform_Handle(c.handle)
	}
	return {}
}

@(test)
test_spawned_prefab_keeps_its_internal_references :: proc(t: ^testing.T) {
	dir := "moonhug/tests/_test_spawn_refs"
	os.make_directory(dir)
	path := strings.concatenate({dir, "/rig.scene"}, context.temp_allocator)
	defer {
		os.remove(path)
		os.remove(strings.concatenate({path, ".meta"}, context.temp_allocator))
		os.remove(dir)
	}

	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)
	w := &tc.world

	// The prefab: Rig, with a Bone under it that Rig's renderer names.
	rig := engine.transform_new("Rig")
	engine.scene_set_root(tc.scene, rig)
	bone := engine.transform_new("Bone", rig)
	_, smr := engine.transform_get_or_add_comp(rig, engine.SkinnedMeshRenderer)
	testing.expect(t, smr != nil, "a renderer on the rig")
	if smr == nil do return
	bt := engine.pool_get(&w.transforms, engine.Handle(bone))
	smr.root_bone = {local_id = bt.local_id, handle = engine.Handle(bone)}
	testing.expect(t, engine.scene_save(tc.scene, path), "the prefab saves")

	engine.asset_db_init(dir)
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()
	guid, gok := engine.asset_db_get_guid(path)
	testing.expect(t, gok, "the prefab is in the asset db")
	if !gok do return

	host := engine.scene_new()
	engine.scene_ensure_root(host)
	defer engine.scene_destroy(host)
	root := engine.Transform_Handle(host.root.handle)

	for i in 0 ..< 3 {
		spawned := engine.scene_instantiate_guid(engine.Asset_GUID(guid), root)
		testing.expectf(t, spawned != {}, "spawn %d", i)
		if spawned == {} do return
		own_bone := _child_named(w, spawned, "Bone")
		_, r := engine.transform_get_comp(spawned, engine.SkinnedMeshRenderer)
		testing.expectf(t, own_bone != {} && r != nil, "spawn %d has its bone and renderer", i)
		if own_bone == {} || r == nil do return
		ob := engine.pool_get(&w.transforms, engine.Handle(own_bone))
		testing.expectf(t, r.root_bone.handle == engine.Handle(own_bone), "spawn %d: root_bone is the spawn's own bone", i)
		testing.expectf(t, r.root_bone.local_id == ob.local_id, "spawn %d: root_bone's id is the bone's (%d), not %d", i, ob.local_id, r.root_bone.local_id)
	}
}
