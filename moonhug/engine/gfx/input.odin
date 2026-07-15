// Per-frame input snapshot built from SDL events in poll_events. Call sites
// keep raylib's polling style (input_key_down(.W)) — the event-driven model
// is contained here.
package gfx

import sdl "vendor:sdl3"

// SDL scancodes are physical key positions (WASD stays WASD on AZERTY
// hardware layouts too, like raylib's KeyboardKey).
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
	wheel:          f32,
	text:           [dynamic]rune, // text typed this frame
	focused:        bool,
	focus_gained:   bool, // edge, this frame — drives the editor asset refresh

	// Lifetime diagnostics (never reset): raw SDL event counts, for the
	// editor's Input Debug window — discriminates "SDL stopped delivering
	// key events" from "imgui state stuck" when keyboard input dies.
	dbg_key_down:     u64,
	dbg_key_up:       u64,
	dbg_focus_gained: u64,
	dbg_focus_lost:   u64,
}

_input_frame_reset :: proc() {
	_input.key_pressed = {}
	_input.key_released = {}
	_input.mouse_pressed = {}
	_input.mouse_released = {}
	_input.mouse_delta = {}
	_input.wheel = 0
	_input.focus_gained = false
	clear(&_input.text)
}

_input_apply_event :: proc(e: ^sdl.Event) {
	#partial switch e.type {
	case .KEY_DOWN:
		_input.dbg_key_down += 1
		sc := int(e.key.scancode)
		if sc >= 0 && sc < _MAX_KEYS {
			if !e.key.repeat do _input.key_pressed[sc] = true
			_input.key_down[sc] = true
		}
	case .KEY_UP:
		_input.dbg_key_up += 1
		sc := int(e.key.scancode)
		if sc >= 0 && sc < _MAX_KEYS {
			_input.key_released[sc] = true
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
		} else {
			_input.mouse_down[btn] = false
			_input.mouse_released[btn] = true
		}
	case .MOUSE_WHEEL:
		_input.wheel += e.wheel.y
	case .TEXT_INPUT:
		for r in string(e.text.text) {
			append(&_input.text, r)
		}
	case .WINDOW_FOCUS_GAINED:
		_input.dbg_focus_gained += 1
		_input.focus_gained = !_input.focused
		_input.focused = true
	case .WINDOW_FOCUS_LOST:
		_input.dbg_focus_lost += 1
		_input.focused = false
	}
}

// Raw SDL event counters for the editor's Input Debug window.
input_debug_counters :: proc() -> (key_down, key_up, focus_gained, focus_lost: u64) {
	return _input.dbg_key_down, _input.dbg_key_up, _input.dbg_focus_gained, _input.dbg_focus_lost
}

input_key_down :: proc(k: Key) -> bool {
	return _input.key_down[int(k)]
}

input_key_pressed :: proc(k: Key) -> bool {
	return _input.key_pressed[int(k)]
}

input_key_released :: proc(k: Key) -> bool {
	return _input.key_released[int(k)]
}

input_mouse_down :: proc(b: Mouse_Button) -> bool {
	return _input.mouse_down[b]
}

input_mouse_pressed :: proc(b: Mouse_Button) -> bool {
	return _input.mouse_pressed[b]
}

input_mouse_released :: proc(b: Mouse_Button) -> bool {
	return _input.mouse_released[b]
}

input_mouse_position :: proc() -> [2]f32 {
	return _input.mouse_pos
}

input_mouse_delta :: proc() -> [2]f32 {
	return _input.mouse_delta
}

input_wheel :: proc() -> f32 {
	return _input.wheel
}

input_text :: proc() -> []rune {
	return _input.text[:]
}

input_focused :: proc() -> bool {
	return _input.focused
}

input_focus_gained :: proc() -> bool {
	return _input.focus_gained
}
