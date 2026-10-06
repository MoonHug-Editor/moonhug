package tests_common

// Drives editor/handles across frames without a UI. The gizmo pass hands
// handles an Input each frame and runs the handle code once, and so does
// this, with the pointer over a world point. The hot handle comes from the
// shapes the handles recorded the frame before, and a drag spans frames (it
// starts, moves, releases), so a test replays whole drags.

import "core:math/linalg"
import "moonhug:packages/engine"
import "moonhug:host/gizmos"
import "../../editor/handles"

// A perspective camera at `eye` looking at the origin, 800x600 pixels.
handles_test_view :: proc(eye := [3]f32{0, 0, 10}) -> engine.Render_View {
	view := linalg.matrix4_look_at_f32(eye, {0, 0, 0}, {0, 1, 0})
	proj := linalg.matrix4_perspective_f32(1.0, 800.0 / 600.0, 0.1, 100)
	return engine.render_view_make(view, proj, 800, 600, ~u32(0))
}

// Keys held and the snap step for every frame of a drag.
Handles_Keys :: struct {
	alt:        bool,
	shift:      bool,
	snap:       f32,
	snap_angle: f32,
}

// Starts one handles frame with the pointer over world point `at`.
handles_frame :: proc(v: engine.Render_View, at: [3]f32, down := false, clicked := false, keys := Handles_Keys{}) {
	px, _ := gizmos.helper_project_in(v, at)
	gizmos.set_view(v)
	handles.frame_begin(v, handles.Input{
		mouse      = px,
		hovered    = true,
		down       = down,
		clicked    = clicked,
		alt        = keys.alt,
		shift      = keys.shift,
		snap       = keys.snap,
		snap_angle = keys.snap_angle,
	})
}

// One frame as the gizmo pass runs it: the frame starts, then `body` (the
// handle code) runs.
handles_step :: proc(v: engine.Render_View, at: [3]f32, body: proc(user: rawptr), user: rawptr, down := false, clicked := false, keys := Handles_Keys{}) {
	handles_frame(v, at, down, clicked, keys)
	body(user)
}

// One drag from `from` to `to`: hover, press, move, release, one frame each.
// A last frame without the body clears the hot handle, so nothing leaks into
// the next test.
handles_drag :: proc(v: engine.Render_View, from, to: [3]f32, body: proc(user: rawptr), user: rawptr, keys := Handles_Keys{}) {
	handles_step(v, from, body, user, keys = keys)
	handles_step(v, from, body, user, down = true, clicked = true, keys = keys)
	handles_step(v, to, body, user, down = true, keys = keys)
	handles_step(v, to, body, user, keys = keys)
	handles_frame(v, to)
}
