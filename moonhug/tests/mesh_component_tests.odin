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
	tex_guid, _ := uuid.read("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")

	_, mf := engine.transform_get_or_add_comp(tH, engine.MeshFilter)
	testing.expect(t, mf != nil, "MeshFilter should be added")
	if mf == nil do return
	mf.mesh = engine.Asset_GUID(mesh_guid)
	mf.enabled = true

	_, mr := engine.transform_get_or_add_comp(tH, engine.MeshRenderer)
	testing.expect(t, mr != nil, "MeshRenderer should be added")
	if mr == nil do return
	mr.texture = engine.Asset_GUID(tex_guid)
	mr.color = {0.25, 0.5, 0.75, 1}
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
	testing.expect(t, loaded_mf.mesh == engine.Asset_GUID(mesh_guid), "mesh guid should round-trip")

	_, loaded_mr := engine.transform_get_comp(root_tH, engine.MeshRenderer)
	testing.expect(t, loaded_mr != nil, "MeshRenderer should survive reload")
	if loaded_mr == nil do return
	testing.expect(t, loaded_mr.texture == engine.Asset_GUID(tex_guid), "texture guid should round-trip")
	testing.expect(t, loaded_mr.color == {0.25, 0.5, 0.75, 1}, "color should round-trip")
}
