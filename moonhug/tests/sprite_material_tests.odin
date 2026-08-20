package tests

// SpriteRenderer.material serialization round-trip (docs/Materials.md).
// Rendering (shader/tint/properties applied per sprite) needs a GPU and is
// verified in-editor.

import "core:encoding/uuid"
import "core:testing"
import "../engine"

@(test)
test_save_load_scene_with_sprite_material :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_sprite_material.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	tH := engine.transform_new("Sprite")
	engine.scene_set_root(tc_mem.scene, tH)

	tex_guid, _ := uuid.read("11111111-2222-3333-4444-555555555555")
	mat_guid, _ := uuid.read("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")

	_, sr := engine.transform_get_or_add_comp(tH, engine.SpriteRenderer)
	testing.expect(t, sr != nil, "SpriteRenderer should be added")
	if sr == nil do return
	sr.texture = engine.Asset_GUID(tex_guid)
	sr.material = engine.Asset_GUID(mat_guid)
	sr.enabled = true

	ok := engine.scene_save(tc_mem.scene, tc_mem.path)
	testing.expect(t, ok, "scene_save should succeed")

	loaded := engine.scene_load_single_path(tc_mem.path)
	testing.expect(t, loaded != nil, "scene_load should return non-nil")
	if loaded == nil do return
	tc_mem.scene = loaded

	root_tH := engine.Transform_Handle(loaded.root.handle)
	_, loaded_sr := engine.transform_get_comp(root_tH, engine.SpriteRenderer)
	testing.expect(t, loaded_sr != nil, "SpriteRenderer should survive reload")
	if loaded_sr == nil do return
	testing.expect(t, loaded_sr.texture == engine.Asset_GUID(tex_guid), "texture guid should round-trip")
	testing.expect(t, loaded_sr.material == engine.Asset_GUID(mat_guid), "material guid should round-trip")
}
