// Input abstraction: the ONLY package that touches the input side of the
// underlying libraries. Call sites (app, editor, packages) import this and
// never read SDL — the platform layer (gfx.poll_events) feeds events in via
// frame_reset/apply_event and everything else reads the per-frame snapshot.
// Polling style is preserved (input.key_down(.W)), the event-driven model is
// contained here.
package input

import sdl "vendor:sdl3"
import core "moonhug:engine/core"

// SDL scancodes are physical key positions (WASD stays WASD on AZERTY
// hardware layouts too). The TYPE is re-exported so call sites only import
// this package; the values being SDL's is an implementation detail.
Key :: sdl.Scancode

Mouse_Button :: enum u8 {
	Left,
	Right,
	Middle,
}

_MAX_KEYS :: 512

_input: struct {
	key_down:       [_MAX_KEYS]bool,
	key_pressed:    [_MAX_KEYS]bool,
	key_released:   [_MAX_KEYS]bool,
	mouse_down:     [Mouse_Button]bool,
	mouse_pressed:  [Mouse_Button]bool,
	mouse_released: [Mouse_Button]bool,
	mouse_pos:      [2]f32,
	mouse_delta:    [2]f32,
	wheel_y:        f32,
	text_runes:     [dynamic]rune, // text typed this frame
	is_focused:     bool,
	focus_edge:     bool, // gained focus this frame — drives the editor asset refresh

	// The game's screen: mouse_position is relative to it and viewport_size
	// is what games measure the screen with. The whole window by default
	// (platform sets it every frame); the editor sets it to the Game view's
	// image instead, in which case the platform leaves it alone.
	viewport_pos:    [2]f32,
	viewport_size:   [2]f32,
	viewport_custom: bool,
	// Application focus (core.application_is_focused, docs/Simulate.md):
	// the window's focus standalone, the Game view's in the editor, which
	// sets it itself (focus_custom). Game reads report nothing while the
	// application is unfocused and inside the game scope; the editor's own
	// reads sit outside the scope. The raw state keeps tracking, so a key
	// held across the gap reads as down once focus returns.
	focus_custom:    bool,
	game_scope:      bool,
	unfocused_mouse: [2]f32, // the mouse where focus left; mouse_position holds it
	relative:        bool,   // relative mouse mode: the global cursor is meaningless

	// Fixed-tick input latching (docs/FixedTick.md): edges ACCUMULATE across
	// frames and are consumed once per fixed tick (fixed_latch), so a press
	// shorter than a tick still registers on the next tick. The non-accum
	// fields are the latched view fixed-update code reads.
	fixed_key_pressed_accum:    [_MAX_KEYS]bool,
	fixed_key_released_accum:   [_MAX_KEYS]bool,
	fixed_mouse_pressed_accum:  [Mouse_Button]bool,
	fixed_mouse_released_accum: [Mouse_Button]bool,
	fixed_key_pressed:          [_MAX_KEYS]bool,
	fixed_key_released:         [_MAX_KEYS]bool,
	fixed_key_down:             [_MAX_KEYS]bool,
	fixed_mouse_pressed:        [Mouse_Button]bool,
	fixed_mouse_released:       [Mouse_Button]bool,
	fixed_mouse_down:           [Mouse_Button]bool,

	// Lifetime diagnostics (never reset): raw SDL event counts, for the
	// editor's Input Debug window — discriminates "SDL stopped delivering
	// key events" from "imgui state stuck" when keyboard input dies.
	dbg_key_down:     u64,
	dbg_key_up:       u64,
	dbg_focus_gained: u64,
	dbg_focus_lost:   u64,
}

// The window relative mouse mode acts on; set once by the platform layer.
_window: ^sdl.Window

// --- Platform feed (gfx only) -------------------------------------------------

// attach_window registers the window relative mouse mode acts on. Called by
// gfx.init right after window creation.
attach_window :: proc(window: ^sdl.Window) {
	_window = window
}

// default_viewport is the platform's per-frame default (the window), taken
// only while no host has set its own.
default_viewport :: proc(size: [2]f32) {
	if _input.viewport_custom do return
	_input.viewport_pos = {}
	_input.viewport_size = size
}

// set_viewport declares the game's screen in window coordinates: an editor
// hosting the game in a panel calls it every frame with the panel's image.
set_viewport :: proc(pos, size: [2]f32) {
	_input.viewport_pos = pos
	_input.viewport_size = size
	_input.viewport_custom = true
}

// The game's screen size, the pair to mouse_position for unprojecting.
viewport_size :: proc() -> [2]f32 {
	return _input.viewport_size
}

mouse_in_viewport :: proc() -> bool {
	p := _mouse_pos() - _input.viewport_pos
	return p.x >= 0 && p.y >= 0 && p.x < _input.viewport_size.x && p.y < _input.viewport_size.y
}

// set_app_focused is the host's statement of application focus (the editor:
// the Game view during a run). Set every frame or on change, only a change
// does anything: losing focus freezes the mouse where it was and drops the
// fixed-tick edges nothing consumed; gaining it seeds them from this frame's
// edges, so the click that gives focus reaches the game like in Unity while
// clicks from before it do not (apply_event skips the accumulators while
// unfocused).
set_app_focused :: proc(on: bool) {
	_input.focus_custom = true
	_apply_app_focus(on)
}

// The window's focus, applied unless a host owns the application focus.
@(private = "file")
_platform_app_focus :: proc(on: bool) {
	if _input.focus_custom do return
	_apply_app_focus(on)
}

@(private = "file")
_apply_app_focus :: proc(on: bool) {
	if on == core.application_is_focused() do return
	core.application_set_focused(on)
	if !on {
		_input.unfocused_mouse = _input.mouse_pos
		_input.fixed_key_pressed_accum = {}
		_input.fixed_key_released_accum = {}
		_input.fixed_mouse_pressed_accum = {}
		_input.fixed_mouse_released_accum = {}
		return
	}
	for i in 0 ..< _MAX_KEYS {
		if _input.key_pressed[i] do _input.fixed_key_pressed_accum[i] = true
		if _input.key_released[i] do _input.fixed_key_released_accum[i] = true
	}
	for b in Mouse_Button {
		if _input.mouse_pressed[b] do _input.fixed_mouse_pressed_accum[b] = true
		if _input.mouse_released[b] do _input.fixed_mouse_released_accum[b] = true
	}
}

// set_game_scope marks the stretch of the frame where the focus gate applies
// to reads. A standalone app sets it once; the editor opens it around the
// simulation tick and closes it after, so its own views read freely.
set_game_scope :: proc(on: bool) {
	_input.game_scope = on
}

@(private = "file")
_hidden :: proc() -> bool {
	return !core.application_is_focused() && _input.game_scope
}

// Drops every pending press and release, per-frame and fixed-tick
// accumulated. A host calls it when a run starts, so clicks from before the
// run (the Play button itself) never reach the first tick.
reset_edges :: proc() {
	_input.key_pressed = {}
	_input.key_released = {}
	_input.mouse_pressed = {}
	_input.mouse_released = {}
	_input.wheel_y = 0
	clear(&_input.text_runes)
	_input.fixed_key_pressed_accum = {}
	_input.fixed_key_released_accum = {}
	_input.fixed_mouse_pressed_accum = {}
	_input.fixed_mouse_released_accum = {}
}

@(private = "file")
_mouse_pos :: proc() -> [2]f32 {
	return _input.unfocused_mouse if _hidden() else _input.mouse_pos
}

// sync_global_mouse keeps mouse_pos following the cursor outside the window
// while the window has focus (SDL stops sending motion at the edge), as a
// windowed game expects when aiming. Called by the platform after the
// frame's events. Skipped in relative mode, where the cursor is pinned.
sync_global_mouse :: proc() {
	if _window == nil || !_input.is_focused || _input.relative do return
	gx, gy: f32
	_ = sdl.GetGlobalMouseState(&gx, &gy)
	wx, wy: i32
	if !sdl.GetWindowPosition(_window, &wx, &wy) do return
	_input.mouse_pos = {gx - f32(wx), gy - f32(wy)}
}

// frame_reset clears the per-frame edges. Called by gfx.poll_events at the
// start of every frame, before events apply.
frame_reset :: proc() {
	_input.key_pressed = {}
	_input.key_released = {}
	_input.mouse_pressed = {}
	_input.mouse_released = {}
	_input.mouse_delta = {}
	_input.wheel_y = 0
	_input.focus_edge = false
	clear(&_input.text_runes)
}

// apply_event folds one SDL event into the snapshot. Called by
// gfx.poll_events for every polled event.
apply_event :: proc(e: ^sdl.Event) {
	#partial switch e.type {
	case .KEY_DOWN:
		_input.dbg_key_down += 1
		sc := int(e.key.scancode)
		if sc >= 0 && sc < _MAX_KEYS {
			if !e.key.repeat {
				_input.key_pressed[sc] = true
				if core.application_is_focused() do _input.fixed_key_pressed_accum[sc] = true
			}
			_input.key_down[sc] = true
		}
	case .KEY_UP:
		_input.dbg_key_up += 1
		sc := int(e.key.scancode)
		if sc >= 0 && sc < _MAX_KEYS {
			_input.key_released[sc] = true
			if core.application_is_focused() do _input.fixed_key_released_accum[sc] = true
			_input.key_down[sc] = false
		}
	case .MOUSE_MOTION:
		_input.mouse_pos = {e.motion.x, e.motion.y}
		_input.mouse_delta += {e.motion.xrel, e.motion.yrel}
	case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
		btn: Mouse_Button
		switch e.button.button {
		case 1: btn = .Left
		case 2: btn = .Middle
		case 3: btn = .Right
		case:   return
		}
		_input.mouse_pos = {e.button.x, e.button.y}
		if e.button.down {
			_input.mouse_down[btn] = true
			_input.mouse_pressed[btn] = true
			if core.application_is_focused() do _input.fixed_mouse_pressed_accum[btn] = true
		} else {
			_input.mouse_down[btn] = false
			_input.mouse_released[btn] = true
			if core.application_is_focused() do _input.fixed_mouse_released_accum[btn] = true
		}
	case .MOUSE_WHEEL:
		_input.wheel_y += e.wheel.y
	case .TEXT_INPUT:
		for r in string(e.text.text) {
			append(&_input.text_runes, r)
		}
	case .WINDOW_FOCUS_GAINED:
		_input.dbg_focus_gained += 1
		_input.focus_edge = !_input.is_focused
		_input.is_focused = true
		_platform_app_focus(true)
	case .WINDOW_FOCUS_LOST:
		_input.dbg_focus_lost += 1
		_input.is_focused = false
		_platform_app_focus(false)
	}
}

// --- Per-frame reads -----------------------------------------------------------

key_down :: proc(k: Key) -> bool {
	return !_hidden() && _input.key_down[int(k)]
}

key_pressed :: proc(k: Key) -> bool {
	return !_hidden() && _input.key_pressed[int(k)]
}

key_released :: proc(k: Key) -> bool {
	return !_hidden() && _input.key_released[int(k)]
}

mouse_down :: proc(b: Mouse_Button) -> bool {
	return !_hidden() && _input.mouse_down[b]
}

mouse_pressed :: proc(b: Mouse_Button) -> bool {
	return !_hidden() && _input.mouse_pressed[b]
}

mouse_released :: proc(b: Mouse_Button) -> bool {
	return !_hidden() && _input.mouse_released[b]
}

// The mouse in viewport coordinates (see set_viewport), y down. Frozen while
// blocked, so nothing in the game follows the cursor.
mouse_position :: proc() -> [2]f32 {
	return _mouse_pos() - _input.viewport_pos
}

// This frame's accumulated raw mouse motion (SDL xrel/yrel). Unlike imgui's
// MouseDelta (derived from cursor position), it keeps flowing in relative
// mouse mode, where the cursor is pinned.
mouse_delta :: proc() -> [2]f32 {
	if _hidden() do return {}
	return _input.mouse_delta
}

wheel :: proc() -> f32 {
	if _hidden() do return 0
	return _input.wheel_y
}

text :: proc() -> []rune {
	if _hidden() do return nil
	return _input.text_runes[:]
}

focused :: proc() -> bool {
	return _input.is_focused
}

focus_gained :: proc() -> bool {
	return _input.focus_edge
}

// Relative mouse mode (camera capture): hides the cursor and pins it in place
// while SDL streams raw deltas — the cursor can never hit a screen edge or
// leave the window mid-drag, so the delta stream never stalls.
set_mouse_relative :: proc(on: bool) {
	_input.relative = on
	if _window != nil do _ = sdl.SetWindowRelativeMouseMode(_window, on)
}

// Raw SDL event counters for the editor's Input Debug window.
debug_counters :: proc() -> (key_down_events, key_up_events, focus_gained_events, focus_lost_events: u64) {
	return _input.dbg_key_down, _input.dbg_key_up, _input.dbg_focus_gained, _input.dbg_focus_lost
}

// --- Fixed-tick input (docs/FixedTick.md) -----------------------------------
// Call once at the START of every fixed tick: moves the accumulated edges
// into the latched view and clears the accumulators. With several ticks in
// one frame the first tick consumes the edges (a press fires once); with
// zero ticks the edges carry over to the next frame's first tick.

fixed_latch :: proc() {
	_input.fixed_key_pressed = _input.fixed_key_pressed_accum
	_input.fixed_key_released = _input.fixed_key_released_accum
	_input.fixed_mouse_pressed = _input.fixed_mouse_pressed_accum
	_input.fixed_mouse_released = _input.fixed_mouse_released_accum
	// Down = held now OR pressed since the last tick — a tap that started and
	// ended between ticks still reads as down for one tick.
	for i in 0 ..< _MAX_KEYS {
		_input.fixed_key_down[i] = _input.key_down[i] || _input.fixed_key_pressed_accum[i]
	}
	for b in Mouse_Button {
		_input.fixed_mouse_down[b] = _input.mouse_down[b] || _input.fixed_mouse_pressed_accum[b]
	}
	_input.fixed_key_pressed_accum = {}
	_input.fixed_key_released_accum = {}
	_input.fixed_mouse_pressed_accum = {}
	_input.fixed_mouse_released_accum = {}
}

key_down_fixed :: proc(k: Key) -> bool {
	return !_hidden() && _input.fixed_key_down[int(k)]
}

key_pressed_fixed :: proc(k: Key) -> bool {
	return !_hidden() && _input.fixed_key_pressed[int(k)]
}

key_released_fixed :: proc(k: Key) -> bool {
	return !_hidden() && _input.fixed_key_released[int(k)]
}

mouse_down_fixed :: proc(b: Mouse_Button) -> bool {
	return !_hidden() && _input.fixed_mouse_down[b]
}

mouse_pressed_fixed :: proc(b: Mouse_Button) -> bool {
	return !_hidden() && _input.fixed_mouse_pressed[b]
}

mouse_released_fixed :: proc(b: Mouse_Button) -> bool {
	return !_hidden() && _input.fixed_mouse_released[b]
}
