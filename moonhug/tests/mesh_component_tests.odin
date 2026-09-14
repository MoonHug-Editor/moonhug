package tests

// MeshFilter/MeshRenderer serialization round-trip (docs/SDL3Renderer.md #6).
// Rendering itself needs a GPU device and is verified in-editor.

import "core:encoding/uuid"
import "core:testing"
import "../engine"

@(test)
test_save_load_scene_with_mesh_components :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_mesh_components.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	tH := engine.transform_new("Cube")
	engine.scene_set_root(tc_mem.scene, tH)

	mesh_guid, _ := uuid.read("11111111-2222-3333-4444-555555555555")
	mat_guid, _ := uuid.read("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")

	_, mf := engine.transform_get_or_add_comp(tH, engine.MeshFilter)
	testing.expect(t, mf != nil, "MeshFilter should be added")
	if mf == nil do return
	mf.mesh = engine.PPtr{guid = engine.Asset_GUID(mesh_guid)}
	mf.enabled = true

	_, mr := engine.transform_get_or_add_comp(tH, engine.MeshRenderer)
	testing.expect(t, mr != nil, "MeshRenderer should be added")
	if mr == nil do return
	append(&mr.materials, engine.Asset_GUID(mat_guid))
	mr.enabled = true

	ok := engine.scene_save(tc_mem.scene, tc_mem.path)
	testing.expect(t, ok, "scene_save should succeed")

	loaded := engine.scene_load_single_path(tc_mem.path)
	testing.expect(t, loaded != nil, "scene_load should return non-nil")
	if loaded == nil do return
	tc_mem.scene = loaded

	root_tH := engine.Transform_Handle(loaded.root.handle)
	_, loaded_mf := engine.transform_get_comp(root_tH, engine.MeshFilter)
	testing.expect(t, loaded_mf != nil, "MeshFilter should survive reload")
	if loaded_mf == nil do return
	testing.expect(t, loaded_mf.mesh.guid == engine.Asset_GUID(mesh_guid), "mesh guid should round-trip")

	_, loaded_mr := engine.transform_get_comp(root_tH, engine.MeshRenderer)
	testing.expect(t, loaded_mr != nil, "MeshRenderer should survive reload")
	if loaded_mr == nil do return
	testing.expect(t, len(loaded_mr.materials) == 1 && loaded_mr.materials[0] == engine.Asset_GUID(mat_guid), "materials array should round-trip")
}

// A SkinnedMeshRenderer resolves its joints by NAME once and caches the
// handles. If the skeleton is rebuilt under it — delete and recreate, an undo,
// a prefab reload — those handles die, and posing through them would hold that
// joint at its bind pose forever with nothing reporting it. The collector asks
// skin_joints_alive before every pose and throws the binding away when it says no.
//
// Skinning itself needs a GPU device, so this covers the decision, not the pose.
@(test)
test_skin_binding_notices_a_dead_joint :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc, "")
	context.user_ptr = &tc.uc
	defer teardown(tc)

	root := engine.transform_new("Rig")
	engine.scene_set_root(tc.scene, root)
	hip := engine.transform_new("Hip", root)
	knee := engine.transform_new("Knee", hip)

	_, smr := engine.transform_get_or_add_comp(root, engine.SkinnedMeshRenderer)
	testing.expect(t, smr != nil)
	if smr == nil do return
	smr.joints = make([dynamic]engine.Transform_Handle)
	append(&smr.joints, hip, knee)

	testing.expect(t, engine.skin_joints_alive(smr), "a live skeleton keeps its binding")

	// A joint that never resolved is zero, and that is not a rebind reason —
	// the missing name was already reported when the binding was built.
	append(&smr.joints, engine.Transform_Handle{})
	testing.expect(t, engine.skin_joints_alive(smr), "an unresolved joint does not force a rebind")

	engine.transform_destroy(knee)
	testing.expect(t, !engine.skin_joints_alive(smr), "a joint that died invalidates the binding")
}
