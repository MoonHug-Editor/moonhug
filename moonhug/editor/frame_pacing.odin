package editor

// How often the editor draws. It draws at most `max_fps` frames a second,
// and while idle (no input for a moment and nothing animating) only
// `idle_fps`, waiting in the kernel between frames. Input ends an idle wait
// at once, so throttling never delays a click. Something that changes on
// screen without input keeps the full rate with gfx.keep_awake.

import "core:sync"
import sdl "vendor:sdl3"
import gfx "moonhug:host/gfx"
import "moonhug:editor/frame_pacing"
import "moonhug:editor/simulate"

// Input keeps the editor at its full rate this long after the last event.
@(private = "file")
_ACTIVE_AFTER_INPUT :: 0.5

@(private = "file")
_pacing: struct {
	frame_start: u64, // performance counter at the start of the last frame
}

// Waits until the next frame is due, draining events, and reports whether the
// frame may draw. Call once per loop in place of gfx.poll_events.
frame_pacing_wait :: proc(event_cb: proc(e: ^sdl.Event)) {
	idle := frame_pacing.settings.throttle_idle && !_frame_pacing_busy()
	fps := max(frame_pacing.settings.idle_fps if idle else frame_pacing.settings.max_fps, 1)
	remaining := 1.0 / f64(fps)
	if _pacing.frame_start != 0 do remaining -= gfx.seconds_since(_pacing.frame_start)
	wait_ms := u32(remaining * 1000) if remaining > 0.001 else 0
	if gfx.poll_events(event_cb, wait_ms = wait_ms, wake_on_event = idle) {
		gfx.keep_awake(_ACTIVE_AFTER_INPUT)
	}
	_pacing.frame_start = gfx.perf_counter()
}

// Something on screen changes without input.
@(private = "file")
_frame_pacing_busy :: proc() -> bool {
	if gfx.awake() do return true
	if simulate.is_ticking() do return true
	if sync.atomic_load(&_play_phase) != .Idle do return true
	if len(_pending_scene_loads) > 0 do return true
	return false
}
