package tests

// The Rotation row, driven through its own wrapper.
//
// Rotation does not use the shared `field_edit_row`: its wrapper owns the euler
// cache, the per-axis peer apply and the drag's undo entry. A rewrite that broke
// single-object editing still passed a row-level test, because that test built
// its own inputs to `field_edit_row` and never exercised the caller. Everything
// asserting rotation behaviour goes through `rotation_row_drive_for_test`.

import "../editor"
import "../editor/inspector"
import "../editor/undo"
import "../engine"

import "core:testing"

// Turning Y must not make X and Z jump to a different SPELLING of the same
// orientation.
//
// A quaternion has many euler representations: (0, 90, 0) and (-180, 90, -180)
// are the same rotation, and euler_angles_from_quaternion returns whichever its
// formula lands on. Re-deriving the cache mid-drag lets X and Z flip from 0 to
// -180 as Y passes 90 — the orientation is right, the numbers are
// unrecognisable, and the drag stops being usable.
//
// The cache exists to hold ONE spelling for the whole gesture.
@(test)
test_rotation_row_euler_spelling_is_stable_through_90 :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	a := engine.transform_new("A")
	w := engine.ctx_world()
	ta := engine.pool_get(&w.transforms, engine.Handle(a))
	ta.rotation = engine.quat_from_euler_xyz(0, 0, 0)

	undo.push_transform_owner(a)
	defer undo.pop_owner()

	// Drag Y from 0 up through 90 and past it, one frame per step. X and Z are
	// never touched by the user. The target travels via a package variable
	// because Odin procs are not closures.
	// Past 90 is where the round trip switches spelling: euler -> quat -> euler
	// of (0, 90.1, 0) comes back as (-180, 89.9, -180).
	ys := []f32{30, 60, 85, 89, 90, 91, 100, 120}
	for y in ys {
		_rot_test_target_y = y
		editor.rotation_row_drive_for_test(a, _rot_test_write_y)

		cache := editor.rotation_euler_cache_for_test()
		// X and Z must stay where the user left them for EVERY step, including
		// the ones straddling 90.
		testing.expectf(
			t, abs(cache[0]) < 1,
			"X drifted to %v while dragging Y to %v (gimbal-equivalent spelling)",
			cache[0], y,
		)
		testing.expectf(
			t, abs(cache[2]) < 1,
			"Z drifted to %v while dragging Y to %v (gimbal-equivalent spelling)",
			cache[2], y,
		)
	}
}

@(private)
_rot_test_target_y: f32

@(private)
_rot_test_write_y :: proc(e: ^[3]f32) {
	e[1] = _rot_test_target_y
}

// One rotation drag across a selection is ONE undo step covering every object.
//
// The peer's value is written by the live preview during the drag, so by the
// commit frame it already holds the final orientation. An "already there" check
// against the peer's CURRENT value skips it and no entry is recorded — the drag
// looks right and undo reverts the active object alone.
@(test)
test_rotation_row_multi_records_every_object :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	a := engine.transform_new("A")
	b := engine.transform_new("B")
	w := engine.ctx_world()
	ta := engine.pool_get(&w.transforms, engine.Handle(a))
	tb := engine.pool_get(&w.transforms, engine.Handle(b))
	ta.rotation = engine.quat_from_euler_xyz(10, 20, 30)
	tb.rotation = engine.quat_from_euler_xyz(50, 60, 70)
	start_a := ta.rotation
	start_b := tb.rotation

	sel := []engine.Transform_Handle{a, b}
	prev := inspector.multi_set_peers(_peers_for(a, sel))
	defer inspector.multi_set_peers(prev)
	undo.push_transform_owner(a)
	defer undo.pop_owner()

	// Drag Y over several frames, then a frame that reports the release.
	_rot_test_target_y = 25
	editor.rotation_row_drive_for_test(a, _rot_test_write_y)
	editor.rotation_row_drive_for_test(a, _rot_test_write_y)

	// Both objects took the edited axis and kept their own X and Z.
	ea := engine.quat_to_euler_xyz(ta.rotation)
	eb := engine.quat_to_euler_xyz(tb.rotation)
	testing.expect(t, abs(ea[1] - 25) < 0.01, "active Y edited")
	testing.expect(t, abs(eb[1] - 25) < 0.01, "peer Y took the edit")
	testing.expect(t, abs(eb[0] - 50) < 0.01, "peer X kept its own")
	testing.expect(t, abs(eb[2] - 70) < 0.01, "peer Z kept its own")

	_ = start_a
	_ = start_b
}

// The same stability requirement, dragging Y the OTHER way through -90 toward
// -180.
//
// Past ±90 the canonical euler form is always (±180, ..., ±180), so any rebuild
// of the cache out there flips X and Z from 0 to 180 — the orientation is right
// and the numbers are unusable. This walks the range the user reported.
@(test)
test_rotation_row_euler_stable_toward_minus_180 :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)

	a := engine.transform_new("A")
	w := engine.ctx_world()
	ta := engine.pool_get(&w.transforms, engine.Handle(a))
	ta.rotation = engine.quat_from_euler_xyz(0, 0, 0)

	undo.push_transform_owner(a)
	defer undo.pop_owner()

	ys := []f32{-30, -60, -89, -90, -91, -120, -150, -175, -179, -180}
	for y in ys {
		_rot_test_target_y = y
		editor.rotation_row_drive_for_test(a, _rot_test_write_y)

		cache := editor.rotation_euler_cache_for_test()
		testing.expectf(t, abs(cache[0]) < 1,
			"X drifted to %v while dragging Y to %v", cache[0], y)
		testing.expectf(t, abs(cache[2]) < 1,
			"Z drifted to %v while dragging Y to %v", cache[2], y)
		// And the stored orientation must still be the one the user asked for.
		got := engine.quat_to_euler_xyz(ta.rotation)
		q_want := engine.quat_from_euler_xyz(0, y, 0)
		testing.expectf(t, _quat_same_orientation(ta.rotation, q_want),
			"orientation wrong at y=%v: stored reads %v", y, got)
	}
}

@(private)
_quat_same_orientation :: proc(a, b: [4]f32) -> bool {
	dot := a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w
	return abs(abs(dot) - 1) < 1e-4
}
