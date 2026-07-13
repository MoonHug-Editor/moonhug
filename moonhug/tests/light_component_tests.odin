package tests

// Light component serialization round-trip (docs/Materials.md). The light's
// effect on shading needs a GPU and is verified in-editor.

import "core:testing"
import "../engine"

@(test)
test_save_load_scene_with_light :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_light_component.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	tH := engine.transform_new("Sun")
	engine.scene_set_root(tc_mem.scene, tH)

	_, l := engine.transform_get_or_add_comp(tH, engine.Light)
	testing.expect(t, l != nil, "Light should be added")
	if l == nil do return
	testing.expect(t, l.intensity == 1 && l.ambient == 0.35, "reset_Light defaults should apply")
	l.color = {1, 0.9, 0.7, 1}
	l.intensity = 1.5
	l.ambient = 0.2
	l.enabled = true

	ok := engine.scene_save(tc_mem.scene, tc_mem.path)
	testing.expect(t, ok, "scene_save should succeed")

	loaded := engine.scene_load_single_path(tc_mem.path)
	testing.expect(t, loaded != nil, "scene_load should return non-nil")
	if loaded == nil do return
	tc_mem.scene = loaded

	root_tH := engine.Transform_Handle(loaded.root.handle)
	_, loaded_l := engine.transform_get_comp(root_tH, engine.Light)
	testing.expect(t, loaded_l != nil, "Light should survive reload")
	if loaded_l == nil do return
	testing.expect(t, loaded_l.color == {1, 0.9, 0.7, 1}, "color should round-trip")
	testing.expect(t, loaded_l.intensity == 1.5, "intensity should round-trip")
	testing.expect(t, loaded_l.ambient == 0.2, "ambient should round-trip")
}
