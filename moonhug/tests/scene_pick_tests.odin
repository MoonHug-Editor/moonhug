package tests

// Scene-view click picking (editor/scene_pick.odin).
//
// Every renderer has to be tested the way it is DRAWN. A SkinnedMeshRenderer
// draws posed world vertices under an identity model, so it needs a world-space
// test — it had none at all, and clicking a character in the scene view
// selected nothing. These pin that it is pickable, and that a renderer which
// has never been skinned stays unpickable rather than answering from bounds
// that describe the bind pose in the rig's own space.

import "core:testing"
import "../editor"
import "../engine"
import "../engine/gfx"

// A camera at +Z looking back at the origin, and the view it renders.
@(private = "file")
_pick_view :: proc() -> engine.Render_View {
	camH := engine.transform_new("Camera")
	w := engine.ctx_world()
	ct := engine.pool_get(&w.transforms, engine.Handle(camH))
	ct.position = {0, 0, 5}
	_, ptr := engine.transform_add_comp(camH, .Camera)
	cam := cast(^engine.Camera)ptr
	return engine.camera_render_view(cam, 100, 100)
}

// A skinned renderer whose last pose filled the given world box. `posed` holds
// what the skinning produced — its LENGTH is what says the mesh has been
// skinned, so one vertex is enough to stand for a pose here.
@(private = "file")
_posed_skinned :: proc(name: string, lo, hi: [3]f32) -> engine.Transform_Handle {
	tH := engine.transform_new(name)
	_, ptr := engine.transform_add_comp(tH, .SkinnedMeshRenderer)
	smr := cast(^engine.SkinnedMeshRenderer)ptr
	append(&smr.posed, gfx.Vertex{position = lo})
	smr.posed_min, smr.posed_max = lo, hi
	return tH
}

@(test)
test_pick_hits_a_posed_skinned_mesh :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	view := _pick_view()
	tH := _posed_skinned("Character", {-1, -1, -1}, {1, 1, 1})

	// Centre of the viewport: the ray runs down -Z through the box.
	got, ok := editor.scene_view_pick(view, 50, 50)
	testing.expect(t, ok, "the skinned mesh is picked")
	testing.expect_value(t, got, tH)
}

// The bounds are world-space, so an object off to one side is NOT hit by a
// ray through the middle — the test that would still pass if picking simply
// returned the first skinned renderer it found.
@(test)
test_pick_misses_a_skinned_mesh_beside_the_ray :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	view := _pick_view()
	_ = _posed_skinned("Character", {20, -1, -1}, {22, 1, 1})

	_, ok := editor.scene_view_pick(view, 50, 50)
	testing.expect(t, !ok, "a mesh beside the ray is not picked")
}

// Never skinned: no pose, so no bounds that mean anything. Answering from the
// bind pose here would put the character wherever its rig was authored.
@(test)
test_pick_skips_an_unskinned_mesh :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	view := _pick_view()
	tH := engine.transform_new("Character")
	engine.transform_add_comp(tH, .SkinnedMeshRenderer)

	_, ok := editor.scene_view_pick(view, 50, 50)
	testing.expect(t, !ok, "an unposed skinned mesh is not picked")
}

// The rubber band asks the same question over a rect, and had the same gap.
@(test)
test_band_query_finds_a_posed_skinned_mesh :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	view := _pick_view()
	tH := _posed_skinned("Character", {-1, -1, -1}, {1, 1, 1})

	hits := editor.scene_view_band_query(view, {0, 0}, {100, 100})
	found := false
	for h in hits do if h == tH do found = true
	testing.expect(t, found, "the skinned mesh is inside the band")
}
