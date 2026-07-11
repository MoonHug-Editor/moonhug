// Window, event pump, and frame timing on SDL3. This package is the only
// place vendor:sdl3 is imported (plus editor/main.odin for the imgui backend
// hookup) — engine and app code go through the procs here and in input.odin.
//
// gfx never imports engine: it knows nothing about assets, scenes, or
// components. See docs/SDL3Renderer.md.
package gfx

import sdl "vendor:sdl3"

_platform: struct {
	window:         ^sdl.Window,
	quit_requested: bool,
	perf_freq:      f64,
	last_counter:   u64,
	delta:          f32,
}

// Creates the SDL window (hidden when show=false so the caller can apply
// saved geometry first, then show_window). GPU device setup lives in
// init() in gfx.odin, which calls this.
_platform_init :: proc(title: cstring, width, height: i32, show := true) -> bool {
	if !sdl.Init({.VIDEO}) {
		return false
	}
	flags := sdl.WindowFlags{.RESIZABLE, .HIGH_PIXEL_DENSITY}
	if !show do flags += {.HIDDEN}
	_platform.window = sdl.CreateWindow(title, width, height, flags)
	if _platform.window == nil {
		sdl.Quit()
		return false
	}
	_platform.perf_freq = f64(sdl.GetPerformanceFrequency())
	_platform.last_counter = sdl.GetPerformanceCounter()
	return true
}

_platform_shutdown :: proc() {
	if _platform.window != nil {
		sdl.DestroyWindow(_platform.window)
		_platform.window = nil
	}
	sdl.Quit()
}

// Escape hatch for the editor's imgui platform backend init.
window :: proc() -> ^sdl.Window {
	return _platform.window
}

show_window :: proc() {
	sdl.ShowWindow(_platform.window)
	// ShowWindow maps the window but doesn't activate the app (macOS): a
	// window created HIDDEN (editor: saved geometry applies before first
	// present) would start behind everything. RaiseWindow activates + focuses.
	_ = sdl.RaiseWindow(_platform.window)
}

// Drains the SDL event queue once per frame: updates the input snapshot and
// forwards every event to event_cb (the editor passes imgui's ProcessEvent).
poll_events :: proc(event_cb: proc(e: ^sdl.Event) = nil) {
	_input_frame_reset()
	e: sdl.Event
	for sdl.PollEvent(&e) {
		if event_cb != nil do event_cb(&e)
		#partial switch e.type {
		case .QUIT, .WINDOW_CLOSE_REQUESTED:
			_platform.quit_requested = true
		case:
			_input_apply_event(&e)
		}
	}
}

quit_requested :: proc() -> bool {
	return _platform.quit_requested
}

request_quit :: proc() {
	_platform.quit_requested = true
}

// Computes the frame's dt (called from frame_begin in gfx.odin). Frame pacing
// itself comes from swapchain vsync — there is no SetTargetFPS equivalent;
// dt-based logic handles 120Hz fine.
_platform_frame_tick :: proc() {
	now := sdl.GetPerformanceCounter()
	_platform.delta = f32(f64(now - _platform.last_counter) / _platform.perf_freq)
	_platform.last_counter = now
	// Clamp huge gaps (debugger pause, window drag) so dt-driven logic
	// doesn't explode.
	if _platform.delta > 0.25 do _platform.delta = 0.25
}

delta_time :: proc() -> f32 {
	return _platform.delta
}

window_size :: proc() -> [2]i32 {
	w, h: i32
	sdl.GetWindowSize(_platform.window, &w, &h)
	return {w, h}
}

// Framebuffer pixels (differs from window_size on HiDPI).
pixel_size :: proc() -> [2]i32 {
	w, h: i32
	sdl.GetWindowSizeInPixels(_platform.window, &w, &h)
	return {w, h}
}

window_position :: proc() -> [2]i32 {
	x, y: i32
	sdl.GetWindowPosition(_platform.window, &x, &y)
	return {x, y}
}

set_window_geometry :: proc(x, y, w, h: i32) {
	sdl.SetWindowSize(_platform.window, w, h)
	sdl.SetWindowPosition(_platform.window, x, y)
}

// Usable bounds (excluding menu bar/dock) of the display the window is on.
display_usable_bounds :: proc() -> (x, y, w, h: i32) {
	display := sdl.GetDisplayForWindow(_platform.window)
	rect: sdl.Rect
	if sdl.GetDisplayUsableBounds(display, &rect) {
		return rect.x, rect.y, rect.w, rect.h
	}
	return 0, 0, 1280, 800
}
