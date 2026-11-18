package engine_tests

// Scene editing conveniences: the Scale row's link, the pick locks, and an
// object created at the point the Scene window offers.

import "core:encoding/uuid"
import "core:testing"
import "moonhug:editor/viewport"
import "moonhug:packages/engine"
import "moonhug:packages/engine/editor/scene_tools"
import "moonhug:packages/engine/editor/scene_windows"
import undo "moonhug:packages/engine/editor/undo"

@(test)
test_scale_link_keeps_proportions :: proc(t: ^testing.T) {
	near :: proc(a, b: [3]f32) -> bool {
		return abs(a.x - b.x) < 1e-5 && abs(a.y - b.y) < 1e-5 && abs(a.z - b.z) < 1e-5
	}
	testing.expect(t, near(scene_windows.scale_linked({1, 2, 4}, {3, 2, 4}), {3, 6, 12}), "one axis tripled triples the others")
	testing.expect(t, near(scene_windows.scale_linked({1, 2, 4}, {1, 1, 4}), {0.5, 1, 2}), "the changed axis can be any of the three")
	testing.expect(t, near(scene_windows.scale_linked({2, 2, 2}, {-2, 2, 2}), {-2, -2, -2}), "a negative scale carries over")
	testing.expect(t, near(scene_windows.scale_linked({0, 2, 4}, {3, 2, 4}), {3, 3, 3}), "from zero there is no ratio: the others take the value")
	testing.expect(t, near(scene_windows.scale_linked({1, 2, 4}, {1, 2, 4}), {1, 2, 4}), "nothing changed")
	testing.expect(t, near(scene_windows.scale_linked({1, 2, 4}, {5, 6, 4}), {5, 6, 4}), "two axes changed at once is a set value, left as it is")
}

@(test)
test_pick_locks_cover_the_object_and_what_is_under_it :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc, "")
	context.user_ptr = &tc.uc
	defer teardown(tc)
	defer for k in scene_tools.pick_locks.entries do delete_key(&scene_tools.pick_locks.entries, k)

	root := engine.Transform_Handle(tc.scene.root.handle)
	floor := engine.transform_new("Floor", root)
	tile := engine.transform_new("Tile", floor)
	crate := engine.transform_new("Crate", root)

	// A scene never saved has no guid: it holds no lock.
	testing.expect(t, !scene_tools.pick_lock_set(floor, true) && !scene_tools.pick_locked(floor), "no lock without a saved scene")

	id, _ := uuid.read("5d0c2a4e-7b1f-4c3a-9e2d-1f6a8b7c9d01")
	tc.scene.asset_guid = engine.Asset_GUID(id)
	for h in ([]engine.Transform_Handle{floor, tile, crate}) do engine.sm_local_id_get_or_mint(tc.scene, engine.Handle(h))

	testing.expect(t, scene_tools.pick_lock_set(floor, true), "a saved scene's object takes a lock")
	testing.expect(t, scene_tools.pick_lock_own(floor) && scene_tools.pick_locked(floor), "the object is locked")
	testing.expect(t, !scene_tools.pick_lock_own(tile) && scene_tools.pick_locked(tile), "what is under it is passed over too, with no lock of its own")
	testing.expect(t, !scene_tools.pick_locked(crate), "its sibling is not")

	testing.expect(t, scene_tools.pick_lock_set(floor, false), "unlock")
	testing.expect(t, !scene_tools.pick_locked(floor) && !scene_tools.pick_locked(tile), "nothing is locked again")
	testing.expect_value(t, len(scene_tools.pick_locks.entries), 0)
}

@(test)
test_created_object_takes_the_offered_place_once :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc, "")
	context.user_ptr = &tc.uc
	defer teardown(tc)
	root := engine.Transform_Handle(tc.scene.root.handle)

	// Under a moved parent: the offered point is a world point.
	parent := engine.transform_new("Parent", root)
	engine.pool_get(&engine.ctx_world().transforms, engine.Handle(parent)).position = {10, 0, 0}

	viewport.create_place_offer({3, 4, 5})
	first := undo.record_create_child("First", parent)
	second := undo.record_create_child("Second", parent)
	testing.expect_value(t, engine.transform_world(first).position, [3]f32{3, 4, 5})
	testing.expect_value(t, engine.transform_world(second).position, [3]f32{10, 0, 0})

	// An offer nobody takes runs out.
	viewport.create_place_offer({1, 1, 1})
	viewport.create_place_tick()
	viewport.create_place_tick()
	third := undo.record_create_child("Third", root)
	testing.expect_value(t, engine.transform_world(third).position, [3]f32{0, 0, 0})
}
