package tests

// Light component serialization round-trip (docs/Materials.md). The light's
// effect on shading needs a GPU and is verified in-editor.

import "core:testing"
import "../engine"
import gfx "../engine/gfx"

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
	testing.expect(t, l.type == .Directional && l.range == 10 && l.spot_angle == 30,
		"reset_Light type/range/spot defaults should apply")
	l.type = .Spot
	l.color = {1, 0.9, 0.7, 1}
	l.intensity = 1.5
	l.range = 25
	l.spot_angle = 45
	l.inner_spot_angle = 30
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
	testing.expect(t, loaded_l.type == .Spot, "type should round-trip")
	testing.expect(t, loaded_l.range == 25, "range should round-trip")
	testing.expect(t, loaded_l.spot_angle == 45 && loaded_l.inner_spot_angle == 30,
		"spot angles should round-trip")
}

// scene_collect_lights gathers every enabled light up to gfx.MAX_LIGHTS, in
// pool order, with the first enabled light's ambient as the scene floor.
@(test)
test_collect_scene_lights :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_lights_collect.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	root := engine.Transform_Handle(tc_mem.scene.root.handle)

	sun_tH := engine.transform_new("Sun", root)
	_, sun := engine.transform_get_or_add_comp(sun_tH, engine.Light)
	sun.enabled = true
	sun.ambient = 0.25

	lamp_tH := engine.transform_new("Lamp", root)
	if tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(lamp_tH)); tr != nil {
		tr.position = {3, 2, 1}
	}
	_, lamp := engine.transform_get_or_add_comp(lamp_tH, engine.Light)
	lamp.enabled = true
	lamp.type = .Point
	lamp.range = 7
	lamp.ambient = 0.9 // must NOT win: the first enabled light's ambient does

	off_tH := engine.transform_new("Off", root)
	_, off := engine.transform_get_or_add_comp(off_tH, engine.Light)
	off.enabled = false

	// Pool slots allocate from the freelist top down, so slot order is the
	// REVERSE of creation order: Lamp sits before Sun. "First enabled light"
	// follows slot order, as it always has.
	buf: [gfx.MAX_LIGHTS]gfx.Light
	n, ambient := engine.scene_collect_lights(buf[:])
	testing.expectf(t, n == 2, "two enabled lights collected, got %d", n)
	testing.expect(t, ambient == 0.9, "first enabled light in slot order sets ambient")
	if n < 2 do return
	testing.expect(t, buf[0].kind == .Point)
	testing.expect(t, buf[1].kind == .Directional)
	testing.expect(t, buf[0].position == {3, 2, 1}, "point light carries world position")
	testing.expect(t, buf[0].range == 7)

	// Spot angles arrive as half-angle cosines.
	lamp.type = .Spot
	lamp.spot_angle = 60
	lamp.inner_spot_angle = 30
	n2, _ := engine.scene_collect_lights(buf[:])
	testing.expect(t, n2 == 2)
	testing.expect(t, buf[0].kind == .Spot)
	testing.expectf(t, abs(buf[0].outer_cos - 0.8660254) < 1e-4,
		"outer_cos = cos(30 deg), got %v", buf[0].outer_cos)
	testing.expectf(t, abs(buf[0].inner_cos - 0.9659258) < 1e-4,
		"inner_cos = cos(15 deg), got %v", buf[0].inner_cos)
}
