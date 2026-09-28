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
import "../editor/handles"
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

// --- Pick providers ------------------------------------------------------------------------

// A package shape at the origin, live only while a test turns it on: the
// registry is process-global and has no unregister.
@(private = "file")
_fake_on: bool
@(private = "file")
_fake_tH: engine.Transform_Handle
@(private = "file")
_fake_registered: bool

@(private = "file")
_fake_click :: proc(view: engine.Render_View, ray: engine.Ray) -> (engine.Transform_Handle, f32, bool) {
	if !_fake_on do return {}, 0, false
	return _fake_tH, 1, true
}

@(private = "file")
_fake_band :: proc(view: engine.Render_View, rmin, rmax: [2]f32, out: ^[dynamic]engine.Transform_Handle) {
	if _fake_on do append(out, _fake_tH)
}

// A provider is asked by click picking and by box select alike.
@(test)
test_pick_provider_takes_click_and_box :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)
	if !_fake_registered {
		handles.pick_register(handles.Pick_Provider{click = _fake_click, band = _fake_band})
		_fake_registered = true
	}
	_fake_tH = engine.transform_new("Shape")
	_fake_on = true
	defer _fake_on = false

	v := handles_test_view()
	picked, ok := editor.scene_view_pick(v, 400, 300)
	testing.expect(t, ok && picked == _fake_tH, "the click asks the provider")
	band := editor.scene_view_band_query(v, {0, 0}, {800, 600})
	testing.expect(t, len(band) == 1 && band[0] == _fake_tH, "so does box select")
}

// The pick menu lists every object under the pointer, nearest first, each
// once: a mesh behind another is reachable through it, and the two triangles
// of one quad make one entry.
@(test)
test_pick_all_lists_every_hit_nearest_first :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	view := _pick_view()
	far := _posed_skinned("Far", {-1, -1, -3}, {1, 1, -2})
	near := _posed_skinned("Near", {-1, -1, 0}, {1, 1, 1})
	_ = _posed_skinned("Aside", {5, 5, 0}, {6, 6, 1})

	hits := editor.scene_view_pick_all(view, 50, 50)
	testing.expect_value(t, len(hits), 2)
	if len(hits) != 2 do return
	testing.expect_value(t, hits[0].tH, near)
	testing.expect_value(t, hits[1].tH, far)
	testing.expect(t, hits[0].t < hits[1].t, "nearest first")
}
