// Input abstraction: the ONLY package that touches the input side of the
// underlying libraries. Call sites (app, editor, packages) import this and
// never read SDL — the platform layer (gfx.poll_events) feeds events in via
// frame_reset/apply_event and everything else reads the per-frame snapshot.
// Polling style is preserved (input.key_down(.W)), the event-driven model is
// contained here.
package input

import sdl "vendor:sdl3"

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
				_input.fixed_key_pressed_accum[sc] = true
			}
			_input.key_down[sc] = true
		}
	case .KEY_UP:
		_input.dbg_key_up += 1
		sc := int(e.key.scancode)
		if sc >= 0 && sc < _MAX_KEYS {
			_input.key_released[sc] = true
			_input.fixed_key_released_accum[sc] = true
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
			_input.fixed_mouse_pressed_accum[btn] = true
		} else {
			_input.mouse_down[btn] = false
			_input.mouse_released[btn] = true
			_input.fixed_mouse_released_accum[btn] = true
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
	case .WINDOW_FOCUS_LOST:
		_input.dbg_focus_lost += 1
		_input.is_focused = false
	}
}

// --- Per-frame reads -----------------------------------------------------------

key_down :: proc(k: Key) -> bool {
	return _input.key_down[int(k)]
}

key_pressed :: proc(k: Key) -> bool {
	return _input.key_pressed[int(k)]
}

key_released :: proc(k: Key) -> bool {
	return _input.key_released[int(k)]
}

mouse_down :: proc(b: Mouse_Button) -> bool {
	return _input.mouse_down[b]
}

mouse_pressed :: proc(b: Mouse_Button) -> bool {
	return _input.mouse_pressed[b]
}

mouse_released :: proc(b: Mouse_Button) -> bool {
	return _input.mouse_released[b]
}

mouse_position :: proc() -> [2]f32 {
	return _input.mouse_pos
}

// This frame's accumulated raw mouse motion (SDL xrel/yrel). Unlike imgui's
// MouseDelta (derived from cursor position), it keeps flowing in relative
// mouse mode, where the cursor is pinned.
mouse_delta :: proc() -> [2]f32 {
	return _input.mouse_delta
}

wheel :: proc() -> f32 {
	return _input.wheel_y
}

text :: proc() -> []rune {
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
	return _input.fixed_key_down[int(k)]
}

key_pressed_fixed :: proc(k: Key) -> bool {
	return _input.fixed_key_pressed[int(k)]
}

key_released_fixed :: proc(k: Key) -> bool {
	return _input.fixed_key_released[int(k)]
}

mouse_down_fixed :: proc(b: Mouse_Button) -> bool {
	return _input.fixed_mouse_down[b]
}

mouse_pressed_fixed :: proc(b: Mouse_Button) -> bool {
	return _input.fixed_mouse_pressed[b]
}

mouse_released_fixed :: proc(b: Mouse_Button) -> bool {
	return _input.fixed_mouse_released[b]
}
