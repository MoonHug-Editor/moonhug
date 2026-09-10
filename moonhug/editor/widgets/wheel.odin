package widgets

// Mouse wheel with one axis at a time, for views where the wheel means two
// different things (zoom on one axis, pan on the other).
//
// A trackpad reports both axes during a single swipe, so a gesture that is
// mostly vertical still carries some horizontal motion. Acting on both would
// zoom and pan at once. The axis is decided by whichever dominates when a
// gesture starts and held until the wheel goes quiet, so drift partway
// through a swipe cannot switch actions. imgui locks its own wheeling the
// same way.

import im "moonhug:external/odin-imgui"

Wheel_Axis :: enum u8 {
	None,
	Vertical,
	Horizontal,
}

// Per-view state. Zero value is "no gesture in progress".
Wheel_Lock :: struct {
	axis: Wheel_Axis,
	idle: f32, // seconds the wheel has been quiet
}

// A gesture is over once the wheel is this quiet, so the next swipe picks its
// own axis. Long enough to survive the gaps between a trackpad's events.
WHEEL_GESTURE_IDLE :: f32(0.25)

// This frame's wheel with only the locked axis non-zero. Call once per frame
// per view, whether or not the view is hovered, so the gesture times out even
// while the pointer is elsewhere; ignore the result when not hovered.
wheel_dominant :: proc(lock: ^Wheel_Lock) -> (vertical, horizontal: f32) {
	io := im.GetIO()
	wv, wh := io.MouseWheel, io.MouseWheelH

	if wv == 0 && wh == 0 {
		lock.idle += io.DeltaTime
		if lock.idle >= WHEEL_GESTURE_IDLE do lock.axis = .None
		return 0, 0
	}

	lock.idle = 0
	if lock.axis == .None {
		lock.axis = abs(wv) >= abs(wh) ? .Vertical : .Horizontal
	}
	if lock.axis == .Vertical do return wv, 0
	return 0, wh
}
