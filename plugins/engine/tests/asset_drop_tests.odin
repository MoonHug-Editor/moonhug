package engine_tests

// Dropping an asset into the scene (scene_tools/asset_drop.odin): what an
// asset becomes is found by its kind, the drop is one undo step, and the
// Scene window's drop lands where the pointer meets an object, or at the
// point it is given over empty space.

import "core:math/linalg"
import "core:testing"
import assets "moonhug:libs/assets"
import "moonhug:packages/engine"
import "moonhug:packages/engine/editor/scene_tools"
import undo "moonhug:packages/engine/editor/undo"

@(private = "file")
_near3 :: proc(a, b: [3]f32) -> bool {
	return linalg.length(a - b) < 0.001
}

@(test)
test_dropped_scene_is_an_instance_at_the_point :: proc(t: ^testing.T) {
	fx: Fixture_Chain
	defer fixture_chain_destroy(&fx)
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)
	fx_ok: bool
	fx, fx_ok = fixture_chain_author(t, tc_mem, "moonhug/tests/_fx_asset_drop")
	if !fx_ok do return
	w := &tc_mem.world
	sc := tc_mem.scene
	root := engine.Transform_Handle(sc.root.handle)

	c_guid, gok := engine.asset_db_get_guid(fx.c_path)
	testing.expect(t, gok, "c.scene is an asset")
	ref := engine.PPtr{guid = engine.Asset_GUID(c_guid)}
	testing.expect_value(t, scene_tools.asset_drop_kind(ref), "scene")
	testing.expect(t, scene_tools.asset_drop_accepts(ref), "a scene can be dropped")
	testing.expect(t, !scene_tools.asset_drop_accepts({}), "an unknown asset cannot")

	before := len(engine.pool_get(&w.transforms, engine.Handle(root)).children)
	inst := scene_tools.asset_drop(ref, root, [3]f32{1, 2, 3})
	testing.expect(t, inst != {}, "the drop made an object")
	if inst == {} do return
	testing.expect(t, engine.scene_find_nested_scene_for_host(sc, inst) != nil, "a nested instance of the scene")
	testing.expect(t, _near3(engine.transform_world(inst).position, {1, 2, 3}), "at the drop point")

	// One undo step takes it away, redo brings it back where it was dropped.
	collisions := engine._composed_lid_collisions
	undo.apply_undo(s)
	testing.expect_value(t, len(engine.pool_get(&w.transforms, engine.Handle(root)).children), before)
	undo.apply_redo(s)
	children := engine.pool_get(&w.transforms, engine.Handle(root)).children
	testing.expect_value(t, len(children), before + 1)
	if len(children) == before + 1 {
		again := engine.Transform_Handle(children[before].handle)
		testing.expect(t, _near3(engine.transform_world(again).position, {1, 2, 3}), "redone at the drop point")
	}
	testing.expect_value(t, engine._composed_lid_collisions, collisions)
}

@(test)
test_dropped_model_part_draws_it :: proc(t: ^testing.T) {
	fx: Fixture_Chain
	defer fixture_chain_destroy(&fx)
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)
	fx_ok: bool
	fx, fx_ok = fixture_chain_author(t, tc_mem, "moonhug/tests/_fx_asset_drop_part")
	if !fx_ok do return
	root := engine.Transform_Handle(tc_mem.scene.root.handle)

	// A sub-asset is found by its kind, whatever file holds it.
	c_guid, _ := engine.asset_db_get_guid(fx.c_path)
	guid := engine.Asset_GUID(c_guid)
	assets.asset_db_sub_assets_set(guid, []assets.Asset_Sub_Info{{id = 7, name = "Wheel", kind = "mesh"}})
	part := engine.PPtr{guid = guid, local_id = 7}
	testing.expect_value(t, scene_tools.asset_drop_kind(part), "mesh")
	testing.expect_value(t, scene_tools.asset_drop_kind({guid = guid, local_id = 8}), "")

	tH := scene_tools.asset_drop(part, root)
	testing.expect(t, tH != {}, "the drop made an object")
	if tH == {} do return
	testing.expect_value(t, engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH)).name, "Wheel")
	_, mf := engine.transform_get_comp(tH, engine.MeshFilter)
	_, mr := engine.transform_get_comp(tH, engine.MeshRenderer)
	testing.expect(t, mf != nil && mf.mesh == part, "a MeshFilter naming the part")
	testing.expect(t, mr != nil, "and a MeshRenderer")
}

// A camera at +Z looking back at the origin, and the view it renders.
@(private = "file")
_drop_view :: proc() -> engine.Render_View {
	camH := engine.transform_new("Camera")
	engine.pool_get(&engine.ctx_world().transforms, engine.Handle(camH)).position = {0, 0, 5}
	_, ptr := engine.transform_add_comp(camH, .Camera)
	cam := cast(^engine.Camera)ptr
	engine.type_reset_Camera(cam)
	return engine.camera_render_view(cam, 100, 100)
}

@(test)
test_drop_in_view_lands_on_the_object_under_the_pointer :: proc(t: ^testing.T) {
	fx: Fixture_Chain
	defer fixture_chain_destroy(&fx)
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)
	fx_ok: bool
	fx, fx_ok = fixture_chain_author(t, tc_mem, "moonhug/tests/_fx_asset_drop_view")
	if !fx_ok do return
	c_guid, _ := engine.asset_db_get_guid(fx.c_path)
	ref := engine.PPtr{guid = engine.Asset_GUID(c_guid)}

	view := _drop_view()
	// A box the ray through the middle of the view meets at z = 1. Skinned
	// renderers are picked by the bounds of their last pose.
	box := engine.transform_new("Box")
	_, ptr := engine.transform_add_comp(box, .SkinnedMeshRenderer)
	smr := cast(^engine.SkinnedMeshRenderer)ptr
	smr.posed_min, smr.posed_max, smr.posed_ok = {-1, -1, -1}, {1, 1, 1}, true

	p, hit := scene_tools.scene_window_surface_point(view, 50, 50)
	testing.expect(t, hit && _near3(p, {0, 0, 1}), "the middle of the view meets the box's face")
	_, hit = scene_tools.scene_window_surface_point(view, 2, 2)
	testing.expect(t, !hit, "a corner of the view meets nothing")

	on_box := scene_tools.asset_drop_in_view(view, 50, 50, ref, {9, 9, 9})
	testing.expect(t, on_box != {} && _near3(engine.transform_world(on_box).position, {0, 0, 1}), "dropped on the box")
	off := scene_tools.asset_drop_in_view(view, 2, 2, ref, {9, 9, 9})
	testing.expect(t, off != {} && _near3(engine.transform_world(off).position, {9, 9, 9}), "over empty space, at the point given")
	parent := engine.pool_get(&tc_mem.world.transforms, engine.Handle(on_box)).parent.handle
	testing.expect(t, parent == tc_mem.scene.root.handle, "under the active scene's root")
}
