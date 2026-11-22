package editor

// The bridge's input tools (docs/core/McpBridge.md "Input"). `input` plays a
// script of mouse and keyboard steps into imgui, one step per frame, so an
// agent drives the real widgets (a drag on an inspector row, a click on a
// button, typing into a field) through the event queue the SDL backend
// feeds. `item_rect` finds where to aim: the widget rectangle of an
// inspector row by the field it edits (inspector/row_probe.odin), or the
// rectangle of a piece of text in a window, decoded from the last frame's
// draw data.
//
// The script's events go into the queue right after the SDL backend's
// NewFrame and before im.NewFrame reads it (mcp_bridge_input_feed,
// main.odin), so the script's mouse position is the last one queued: when
// the editor window has focus and the real cursor is off it, the backend
// queues the cursor's position every frame, which would otherwise win. The
// wanted position is re-sent every frame of the script for the same reason.
// imgui's event trickling is off while a script runs: with it on, a button
// event queued after a position that differs from the current one waits a
// frame, and "one step per frame" would drift.
//
// Positions are points from the editor window's top-left, the frame
// window_list and item_rect report. With OS-level viewports on, imgui's
// mouse position is absolute, so the main viewport's position is added on
// the way in and taken off on the way out.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import im "moonhug:external/odin-imgui"
import mcp "moonhug:editor/mcp"
import gfx "moonhug:libs/gfx"
import "moonhug:editor/inspector"
import "moonhug:libs/input"
import sdl "vendor:sdl3"

_INPUT_MAX_STEPS :: 500
_INPUT_MAX_WAIT :: 600
_INPUT_MAX_FRAMES :: 3000
_INPUT_MAX_TEXT :: 1024

@(private = "file")
_Input_Kind :: enum u8 {
	Move,
	Down,
	Up,
	Key,
	Text,
	Wait,
	Wheel,
	Touch,
}

@(private = "file")
_INPUT_KIND_NAMES := [_Input_Kind]string{.Move = "move", .Down = "down", .Up = "up", .Key = "key", .Text = "text", .Wait = "wait", .Wheel = "wheel", .Touch = "touch"}

@(private = "file")
_Input_Step :: struct {
	kind:   _Input_Kind,
	pos:    [2]f32, // Move: points from the editor's top-left. Wheel: the scroll, x across and y up
	button: i32,    // Down, Up: 0 left, 1 right, 2 middle
	key:    im.Key, // Key: the key as imgui names it
	mod:    im.Key, // Key: the modifier flag a modifier key sets as well, None otherwise
	down:   bool,   // Key
	text:   string, // Text, owned
	frames: int,    // Wait
	finger: u64,    // Touch: the finger's id
	phase:  sdl.EventType, // Touch: FINGER_DOWN, FINGER_MOTION or FINGER_UP
}

// What the frame a step played in saw, for diagnosis.
@(private = "file")
_Input_Result :: struct {
	step:    int,
	type:    string,
	mouse:   [2]f32, // imgui's mouse position that frame, editor points
	window:  string, // the frontmost editor window under it, "" outside every window (owned)
	hovered: bool,   // an item was hovered
	active:  bool,   // an item was active: held, or being edited
}

@(private = "file")
_input: struct {
	running:   bool,
	started:   bool, // the first frame has run: the trickle flag is saved
	id:        i64,
	steps:     [dynamic]_Input_Step,
	results:   [dynamic]_Input_Result,
	next:      int,  // the next step to play
	wait:      int,  // frames left of the running Wait step
	pending:   bool, // a step played last frame and its result is not recorded yet
	mouse:     [2]f32,
	has_mouse: bool,
	trickle:   bool, // io.ConfigInputTrickleEventQueue before the script
}

// The imgui key `name` names, case ignored: imgui's own key names (A, 5,
// Enter, Space, Tab, Backspace, LeftCtrl, F3, Keypad1, UpArrow, ...), the
// physical modifier keys ctrl, shift, alt and cmd (also super), which also
// give the modifier flag the SDL backend sends with them, and esc, return,
// del, up, down, left, right, pgup, pgdn as shorthand. On macOS imgui swaps
// Ctrl and Cmd as the backend hands them in, and the same swap applies here,
// so ctrl is the physical Ctrl key there too and cmd the Cmd key (Cmd+Z is
// undo). The mouse keys are not keys to send: the mouse steps are.
mcp_input_key :: proc(name: string) -> (key, mod: im.Key, ok: bool) {
	n := strings.to_lower(strings.trim_space(name), context.temp_allocator)
	switch n {
	case "": return .None, .None, false
	case "ctrl", "control": return .LeftCtrl, .ImGuiMod_Ctrl, true
	case "shift": return .LeftShift, .ImGuiMod_Shift, true
	case "alt", "option": return .LeftAlt, .ImGuiMod_Alt, true
	case "cmd", "command", "super", "meta", "win": return .LeftSuper, .ImGuiMod_Super, true
	case "esc": return .Escape, .None, true
	case "return": return .Enter, .None, true
	case "del": return .Delete, .None, true
	case "up": return .UpArrow, .None, true
	case "down": return .DownArrow, .None, true
	case "left": return .LeftArrow, .None, true
	case "right": return .RightArrow, .None, true
	case "pgup": return .PageUp, .None, true
	case "pgdn": return .PageDown, .None, true
	}
	for k := int(im.Key.NamedKey_BEGIN); k < int(im.Key.NamedKey_END); k += 1 {
		key = im.Key(k)
		if key >= .MouseLeft && key <= .ReservedForModSuper do continue
		if strings.equal_fold(string(im.GetKeyName(key)), n) do return key, .None, true
	}
	return .None, .None, false
}

@(private = "file")
_input_button :: proc(v: json.Value) -> (i32, bool) {
	if v == nil do return 0, true
	#partial switch b in v {
	case json.String:
		switch strings.to_lower(b, context.temp_allocator) {
		case "left": return 0, true
		case "right": return 1, true
		case "middle": return 2, true
		}
	case json.Integer:
		if b >= 0 && b < 5 do return i32(b), true
	case json.Float:
		if b >= 0 && b < 5 do return i32(b), true
	}
	return 0, false
}

@(private = "file")
_input_steps_free :: proc(steps: ^[dynamic]_Input_Step) {
	for s in steps do delete(s.text, runtime.default_allocator())
	delete(steps^)
	steps^ = nil
}

// The steps `raw` holds, on the default allocator, or the first error.
@(private = "file")
_input_parse :: proc(raw: json.Array) -> (steps: [dynamic]_Input_Step, err: Mcp_Error) {
	steps = make([dynamic]_Input_Step, 0, len(raw), runtime.default_allocator())
	frames := 0
	for entry, i in raw {
		obj, is_obj := entry.(json.Object)
		if !is_obj {
			err = {"bad_request", fmt.tprintf("step %d is not an object", i)}
			break
		}
		kind, _ := obj["type"].(json.String)
		step: _Input_Step
		switch kind {
		case "move":
			x, has_x := mcp.json_f32(obj, "x")
			y, has_y := mcp.json_f32(obj, "y")
			if !has_x || !has_y do err = {"bad_request", fmt.tprintf("step %d: move needs x and y", i)}
			step = {kind = .Move, pos = {x, y}}
		case "down", "up":
			button, ok := _input_button(obj["button"])
			if !ok do err = {"bad_request", fmt.tprintf("step %d: button must be left, right, middle or 0 to 4", i)}
			step = {kind = kind == "down" ? _Input_Kind.Down : _Input_Kind.Up, button = button}
		case "key":
			name, _ := obj["name"].(json.String)
			key, mod, ok := mcp_input_key(name)
			if !ok do err = {"bad_request", fmt.tprintf("step %d: unknown key %q (an imgui key name, or ctrl, shift, alt, cmd)", i, name)}
			down := true
			if v, has := obj["down"].(json.Boolean); has do down = bool(v)
			step = {kind = .Key, key = key, mod = mod, down = down}
		case "text":
			text, has := obj["text"].(json.String)
			if !has || len(text) == 0 || len(text) > _INPUT_MAX_TEXT do err = {"bad_request", fmt.tprintf("step %d: text needs text, 1 to %d bytes", i, _INPUT_MAX_TEXT)}
			step = {kind = .Text, text = strings.clone(text, runtime.default_allocator())}
		case "wheel":
			x, _ := mcp.json_f32(obj, "x")
			y, _ := mcp.json_f32(obj, "y")
			if x == 0 && y == 0 do err = {"bad_request", fmt.tprintf("step %d: wheel needs x or y", i)}
			step = {kind = .Wheel, pos = {x, y}}
		case "wait":
			n := int(mcp.json_int(obj, "frames", 1))
			if n < 1 || n > _INPUT_MAX_WAIT do err = {"bad_request", fmt.tprintf("step %d: wait needs frames 1 to %d", i, _INPUT_MAX_WAIT)}
			step = {kind = .Wait, frames = n}
			frames += n - 1
		case "touch":
			x, has_x := mcp.json_f32(obj, "x")
			y, has_y := mcp.json_f32(obj, "y")
			phase, _ := obj["phase"].(json.String)
			step = {kind = .Touch, pos = {x, y}, finger = u64(mcp.json_int(obj, "id", 1))}
			switch phase {
			case "down": step.phase = .FINGER_DOWN
			case "move": step.phase = .FINGER_MOTION
			case "up":   step.phase = .FINGER_UP
			case:        err = {"bad_request", fmt.tprintf("step %d: touch needs phase down, move or up", i)}
			}
			if !has_x || !has_y do err = {"bad_request", fmt.tprintf("step %d: touch needs x and y", i)}
		case:
			err = {"bad_request", fmt.tprintf("step %d: type must be move, down, up, key, text, wheel, touch or wait (got %q)", i, kind)}
		}
		if err.code != "" {
			delete(step.text, runtime.default_allocator())
			break
		}
		frames += 1
		append(&steps, step)
	}
	if err.code == "" && frames > _INPUT_MAX_FRAMES do err = {"bad_request", fmt.tprintf("the script takes %d frames, max %d", frames, _INPUT_MAX_FRAMES)}
	if err.code != "" do _input_steps_free(&steps)
	return
}

@(mcp_tool={
	description="Drive the editor's widgets with real mouse and keyboard input: a script of steps played one per frame into imgui, the way the OS feeds it. Steps are objects with a type: move {x, y} (points from the editor's top-left, item_rect and window_list use the same frame), down {button} and up {button} (left, right, middle, default left), key {name, down} (an imgui key name, or ctrl, shift, alt, cmd for the physical modifier keys, down defaults to true, a press needs a down and an up), text {text} (characters typed into the focused field), wheel {x, y} (a scroll at the mouse, in wheel notches, y up and x across), touch {id, x, y, phase} (a finger on a touch screen going down, move or up, for a game in Play only), wait {frames}. A drag is move, down, a few moves, up. Answers when the script is done, with what each step's frame saw: the mouse position, the window under it, whether an item was hovered or active. The mouse, key and text steps also reach a game in Play (the Game window focused, as with real input). The script's position holds until the real cursor moves. One script at a time, and not in a batch.",
	param_steps="object[]!:The steps, in order, at most 500 and 3000 frames",
})
mcp_tool_input :: proc(id: i64, params: json.Object) -> (string, Mcp_Error) {
	raw, has := params["steps"].(json.Array)
	if !has || len(raw) == 0 do return mcp.tool_fail("bad_request", "need steps: an array of step objects")
	if len(raw) > _INPUT_MAX_STEPS do return mcp.tool_fail("bad_request", "%d steps, max %d", len(raw), _INPUT_MAX_STEPS)
	if _input.running do return mcp.tool_fail("busy", "a script is running (%d of %d steps played)", _input.next, len(_input.steps))
	steps, err := _input_parse(raw)
	if err.code != "" do return "", err
	_input = {
		running = true,
		id      = id,
		steps   = steps,
		results = make([dynamic]_Input_Result, 0, len(steps), runtime.default_allocator()),
	}
	return MCP_DEFERRED, {}
}

// The title of the frontmost editor window under `p` (screen coordinates), or "".
@(private = "file")
_input_window_under :: proc(p: [2]f32) -> string {
	// ctx.Windows is back to front, and _imgui_windows keeps that order.
	found := ""
	for w in _imgui_windows() {
		if !((w.Active || w.WasActive) && !w.Hidden) do continue
		if p.x < w.Pos.x || p.y < w.Pos.y || p.x >= w.Pos.x + w.Size.x || p.y >= w.Pos.y + w.Size.y do continue
		found, _ = mcp_window_title_id(string(w.Name))
	}
	return found
}

// Plays the running script: one step per frame, right after the SDL
// backend's NewFrame and before im.NewFrame (main.odin).
mcp_bridge_input_feed :: proc() {
	if !_input.running do return
	io := im.GetIO()
	vp := im.GetMainViewport()
	if !_input.started {
		_input.started = true
		_input.trickle = io.ConfigInputTrickleEventQueue
		io.ConfigInputTrickleEventQueue = false
	}
	// The step played last frame: what that frame saw. imgui clears the
	// hovered item at NewFrame, so this reads before it.
	if _input.pending {
		_input.pending = false
		step := _input.next - 1
		append(&_input.results, _Input_Result{
			step    = step,
			type    = _INPUT_KIND_NAMES[_input.steps[step].kind],
			mouse   = {io.MousePos.x - vp.Pos.x, io.MousePos.y - vp.Pos.y},
			window  = strings.clone(_input_window_under({io.MousePos.x, io.MousePos.y}), runtime.default_allocator()),
			hovered = im.IsAnyItemHovered(),
			active  = im.IsAnyItemActive(),
		})
	}
	if _input.wait == 0 && _input.next >= len(_input.steps) {
		_input_finish()
		return
	}
	// The editor idles without input, and injected events are not input to
	// the frame pacing.
	gfx.keep_awake(1)
	if _input.has_mouse do im.IO_AddMousePosEvent(io, vp.Pos.x + _input.mouse.x, vp.Pos.y + _input.mouse.y)
	if _input.wait > 0 {
		_input.wait -= 1
		if _input.wait == 0 do _input.pending = true
		return
	}
	step := _input.steps[_input.next]
	_input.next += 1
	switch step.kind {
	case .Move:
		_game_mouse_move(step.pos)
		_input.mouse = step.pos
		_input.has_mouse = true
		im.IO_AddMousePosEvent(io, vp.Pos.x + step.pos.x, vp.Pos.y + step.pos.y)
	case .Down:
		_game_mouse_button(step.button, true)
		im.IO_AddMouseButtonEvent(io, step.button, true)
	case .Up:
		_game_mouse_button(step.button, false)
		im.IO_AddMouseButtonEvent(io, step.button, false)
	case .Key:
		// The backend sends the modifier flag before the key itself.
		if step.mod != .None do im.IO_AddKeyEvent(io, step.mod, step.down)
		im.IO_AddKeyEvent(io, step.key, step.down)
		_game_key(step.key, step.down)
	case .Text:
		text := strings.clone_to_cstring(step.text, context.temp_allocator)
		im.IO_AddInputCharactersUTF8(io, text)
		e: sdl.Event
		e.type = .TEXT_INPUT
		e.text.text = text
		input.apply_event(&e)
	case .Wheel:
		e: sdl.Event
		e.type = .MOUSE_WHEEL
		e.wheel.y = step.pos.y
		input.apply_event(&e)
		im.IO_AddMouseWheelEvent(io, step.pos.x, step.pos.y)
	case .Touch:
		// A finger on a touch screen, for the game alone: imgui reads no
		// touches. It comes as a fraction of the window, as SDL sends it.
		e: sdl.Event
		e.type = step.phase
		e.tfinger.fingerID = sdl.FingerID(step.finger)
		e.tfinger.x, e.tfinger.y = step.pos.x / max(vp.Size.x, 1), step.pos.y / max(vp.Size.y, 1)
		input.apply_event(&e)
	case .Wait:
		// This frame is the first of them.
		_input.wait = step.frames - 1
	}
	if _input.wait == 0 do _input.pending = true
}

// The mouse, key and text steps reach the game's own input too (libs/input,
// what a game in Play reads), as the SDL events of a real mouse and keyboard
// would: imgui alone gets the editor's widgets, not the game. The game reads
// them while its Game window has the focus, as with real input. Keys the
// game gets: letters, digits, the arrows, Enter, Escape, Backspace, Delete,
// Tab, Space, Home, End, the page keys and the modifiers. Positions are in the main window's points,
// which is what the steps carry.
//
// The last position sent outlives the script, as the real mouse's does: a
// script that begins with a button step presses where the one before it left
// the mouse.
@(private = "file")
_game_mouse: [2]f32
@(private = "file")
_game_mouse_known: bool

@(private = "file")
_game_mouse_move :: proc(pos: [2]f32) {
	from := _game_mouse if _game_mouse_known else pos
	e: sdl.Event
	e.type = .MOUSE_MOTION
	e.motion.x, e.motion.y = pos.x, pos.y
	e.motion.xrel, e.motion.yrel = pos.x - from.x, pos.y - from.y
	input.apply_event(&e)
	_game_mouse, _game_mouse_known = pos, true
}

// imgui's buttons are 0 left, 1 right, 2 middle. SDL's are 1 left, 2 middle, 3 right.
@(private = "file")
_game_mouse_button :: proc(button: i32, down: bool) {
	e: sdl.Event
	e.type = .MOUSE_BUTTON_DOWN if down else .MOUSE_BUTTON_UP
	switch button {
	case 0: e.button.button = 1
	case 1: e.button.button = 3
	case 2: e.button.button = 2
	case: return
	}
	e.button.down = down
	if !_game_mouse_known do return
	e.button.x, e.button.y = _game_mouse.x, _game_mouse.y
	input.apply_event(&e)
}

// The key as the scancode the game reads, false for a key with none here.
@(private = "file")
_game_scancode :: proc(key: im.Key) -> (sdl.Scancode, bool) {
	if key >= .A && key <= .Z do return sdl.Scancode(int(sdl.Scancode.A) + int(key) - int(im.Key.A)), true
	if key == ._0 do return ._0, true
	if key >= ._1 && key <= ._9 do return sdl.Scancode(int(sdl.Scancode._1) + int(key) - int(im.Key._1)), true
	#partial switch key {
	case .Enter:       return .RETURN, true
	case .KeypadEnter: return .KP_ENTER, true
	case .Escape:      return .ESCAPE, true
	case .Backspace:   return .BACKSPACE, true
	case .Delete:      return .DELETE, true
	case .Tab:         return .TAB, true
	case .Space:       return .SPACE, true
	case .Home:        return .HOME, true
	case .End:         return .END, true
	case .PageUp:      return .PAGEUP, true
	case .PageDown:    return .PAGEDOWN, true
	case .LeftArrow:   return .LEFT, true
	case .RightArrow:  return .RIGHT, true
	case .UpArrow:     return .UP, true
	case .DownArrow:   return .DOWN, true
	case .LeftCtrl:    return .LCTRL, true
	case .RightCtrl:   return .RCTRL, true
	case .LeftShift:   return .LSHIFT, true
	case .RightShift:  return .RSHIFT, true
	case .LeftAlt:     return .LALT, true
	case .RightAlt:    return .RALT, true
	case .LeftSuper:   return .LGUI, true
	case .RightSuper:  return .RGUI, true
	}
	return .UNKNOWN, false
}

@(private = "file")
_game_key :: proc(key: im.Key, down: bool) {
	sc, ok := _game_scancode(key)
	if !ok do return
	e: sdl.Event
	e.type = .KEY_DOWN if down else .KEY_UP
	e.key.scancode = sc
	e.key.down = down
	input.apply_event(&e)
}

@(private = "file")
_input_finish :: proc() {
	io := im.GetIO()
	io.ConfigInputTrickleEventQueue = _input.trickle
	vp := im.GetMainViewport()
	result, err := mcp.tool_ok(struct {
		steps: []_Input_Result,
		mouse: [2]f32,
	}{_input.results[:], {io.MousePos.x - vp.Pos.x, io.MousePos.y - vp.Pos.y}})
	if err.code != "" do _mcp_respond_error(_input.id, err.code, err.message)
	else do _mcp_respond(_input.id, result)
	for r in _input.results do delete(r.window, runtime.default_allocator())
	delete(_input.results)
	_input_steps_free(&_input.steps)
	_input = {}
}

// --- item_rect ----------------------------------------------------------------

@(private = "file")
_Item_Probe :: struct {
	id:     i64,
	window: string, // the imgui window name, owned
	label:  string, // owned
	popups: bool,   // asked for "popup": text in any open popup matches
	tooltips: bool, // asked for "tooltip": text in the tooltip shown matches (a drag's)
}

// Probes waiting for the frame they armed to draw, on the default allocator.
@(private = "file")
_item_probes: [dynamic]_Item_Probe

@(private = "file")
_Item_Match :: struct {
	kind:   string, // "row": an inspector row's widget. "text": text drawn in the window
	label:  string, // the row's field, or the text as drawn
	x:      f32,    // points from the editor's top-left
	y:      f32,
	width:  f32,
	height: f32,
}

@(mcp_tool={
	description="Where an item is, for input: the rectangle of an inspector row's widget by the field it edits, or of a piece of text drawn in a window (a button, a component header, a tab, an object in the hierarchy), in points from the editor's top-left, the frame input moves in. Answers after the next frame draws. Rows come from the inspector's own row drawing and text from the frame's draw data, so a row folded away or scrolled out of view, or text clipped away, is not found: window_place and window_resize make room first. A row's rectangle is its last widget (the z of a vector).",
	param_window="string!:Title or id of the window (window_list), popup for the open popups (a context menu and its open submenu), or tooltip for the tooltip shown (a drag's, saying what a drop would do)",
	param_label="string!:The row's field name as get_property addresses it (duration), or the text to find, case ignored, a part of a longer text matches",
})
mcp_tool_item_rect :: proc(id: i64, params: json.Object) -> (string, Mcp_Error) {
	query, _ := params["window"].(json.String)
	// A tooltip is a window of no title, made fresh each time it shows.
	tooltips := strings.equal_fold(string(query), "tooltip")
	window := "tooltip"
	if !tooltips {
		w, err := _find_window(query)
		if err.code != "" do return "", err
		window = string(w.Name)
	}
	label, _ := params["label"].(json.String)
	label = strings.trim_space(label)
	if label == "" do return mcp.tool_fail("bad_request", "need label: a row's field name or text in the window")
	if _item_probes == nil do _item_probes = make([dynamic]_Item_Probe, runtime.default_allocator())
	append(&_item_probes, _Item_Probe{
		id     = id,
		window   = strings.clone(window, runtime.default_allocator()),
		label    = strings.clone(label, runtime.default_allocator()),
		popups   = strings.equal_fold(string(query), "popup"),
		tooltips = tooltips,
	})
	inspector.row_probe_arm()
	return MCP_DEFERRED, {}
}

// Whether imgui window `name` is one of the open popups: a context menu and
// the submenu open from it are two.
@(private = "file")
_owned_by_open_popup :: proc(name: string) -> bool {
	ctx := im.GetCurrentContext()
	if ctx == nil do return false
	for p in ([^]im.PopupData)(ctx.OpenPopupStack.Data)[:ctx.OpenPopupStack.Size] {
		if p.Window_ != nil && _owned_by(name, string(p.Window_.Name)) do return true
	}
	return false
}

// Whether imgui window `name` is `window` or a child of it ("<parent>/<child>_<id>").
// Compared by the part from "###" on, the window's id: a title that changes
// (" *" on an edited document) leaves its child windows with the old title in
// their names.
@(private = "file")
_owned_by :: proc(name, window: string) -> bool {
	name, window := name, window
	if at := strings.index(window, "###"); at >= 0 do window = window[at:]
	if at := strings.index(name, "###"); at >= 0 do name = name[at:]
	if name == window do return true
	return len(name) > len(window) && strings.has_prefix(name, window) && name[len(window)] == '/'
}

// Answers the probes armed last tick from the rows that frame recorded and
// the text its draw data holds. Runs in the bridge tick, before NewFrame.
_mcp_item_rects_poll :: proc() {
	if len(_item_probes) == 0 do return
	rows := inspector.row_probe_take()
	runs := _text_runs()
	vp := im.GetMainViewport()
	for probe in _item_probes {
		title, _ := mcp_window_title_id(probe.window)
		matches := make([dynamic]_Item_Match, context.temp_allocator)
		for r in rows {
			if !_owned_by(r.window, probe.window) || !strings.equal_fold(r.label, probe.label) do continue
			append(&matches, _Item_Match{"row", r.label, r.min.x - vp.Pos.x, r.min.y - vp.Pos.y, r.max.x - r.min.x, r.max.y - r.min.y})
		}
		q := strings.to_lower(probe.label, context.temp_allocator)
		for run in runs {
			owned: bool
			switch {
			case probe.tooltips: owned = strings.has_prefix(run.owner, "##Tooltip_")
			case probe.popups:   owned = _owned_by_open_popup(run.owner)
			case:                owned = _owned_by(run.owner, probe.window)
			}
			if !owned do continue
			lower := strings.to_lower(run.text, context.temp_allocator)
			at := strings.index(lower, q)
			if at < 0 do continue
			// The matched text's own span, when the lowercase text lines up
			// byte for byte with the run's.
			x0, x1 := run.min.x, run.max.x
			if len(lower) == len(run.lefts) && len(q) > 0 {
				x0, x1 = run.lefts[at], run.rights[at + len(q) - 1]
			}
			append(&matches, _Item_Match{"text", run.text, x0 - vp.Pos.x, run.min.y - vp.Pos.y, x1 - x0, run.max.y - run.min.y})
		}
		if len(matches) == 0 {
			_mcp_respond_error(probe.id, "not_found", fmt.tprintf("no row or text %q drawn in %q this frame", probe.label, title))
		} else {
			result, _ := mcp.tool_ok(struct {
				window:  string,
				matches: []_Item_Match,
			}{title, matches[:]})
			_mcp_respond(probe.id, result)
		}
		delete(probe.window, runtime.default_allocator())
		delete(probe.label, runtime.default_allocator())
	}
	clear(&_item_probes)
}

// --- Text in the draw data ----------------------------------------------------

@(private = "file")
_Glyph_Ref :: struct {
	uv0, uv1:  [2]f32,
	codepoint: rune,
	x0, y0:    f32, // the quad's offset from the pen
	advance:   f32,
	size:      f32, // the font size it was baked at
	space:     f32, // the space's advance in that font
}

@(private = "file")
_Text_Run :: struct {
	owner:    string, // the imgui window whose draw list drew it
	text:     string,
	min, max: [2]f32, // screen coordinates
	// The left and right edge of each byte of `text`: a match inside the
	// run gets its own rectangle, so "Remove" in "Add Group  Remove" is the
	// button on the right.
	lefts:    []f32,
	rights:   []f32,
}

// Every visible glyph of every font at the sizes its text is drawn at, keyed
// by its rectangle in the atlas texture. Temp allocated.
//
// A font is baked once per size it is drawn at. A font's LastBaked is the
// size it was drawn at last, which is not always the size most of its text
// has: the Project window's grid draws labels at a size of their own. So the
// bake ordinary text is drawn with, noted as the frame began, is read too.
// Nothing is asked of the atlas here: a bake made or a glyph loaded now
// could repack it, and the frame being decoded would no longer match.
@(private = "file")
_glyph_table :: proc(atlas: ^im.FontAtlas) -> []_Glyph_Ref {
	out := make([dynamic]_Glyph_Ref, context.temp_allocator)
	base_read := false
	for font in ([^]^im.Font)(atlas.Fonts.Data)[:atlas.Fonts.Size] {
		if font == nil || font.LastBaked == nil do continue
		_glyph_table_add(&out, font.LastBaked)
		if font.LastBaked == _base_bake do base_read = true
	}
	if _base_bake != nil && !base_read do _glyph_table_add(&out, _base_bake)
	return out[:]
}

// The bake of ordinary text: the default font at the base size, as the frame
// began (mcp_bridge_frame_began).
@(private = "file")
_base_bake: ^im.FontBaked

// How far into an ImGuiWindow its draw list is, measured once on imgui's
// fallback window: what ties a drawn list to its window (_text_runs).
@(private = "file")
_draw_list_offset: uintptr

// Right after im.NewFrame, when imgui's current window is its fallback
// window: notes the bake ordinary text is drawn with, which a font's
// LastBaked may no longer be when the frame is decoded, and measures where a
// window keeps its draw list.
mcp_bridge_frame_began :: proc() {
	_base_bake = im.GetFontBaked()
	if _draw_list_offset == 0 {
		if w := im.GetCurrentWindow(); w != nil {
			if dl := im.GetWindowDrawList(); uintptr(dl) > uintptr(w) do _draw_list_offset = uintptr(dl) - uintptr(w)
		}
	}
}

@(private = "file")
_glyph_table_add :: proc(out: ^[dynamic]_Glyph_Ref, baked: ^im.FontBaked) {
	// The space's advance from the advance table, which loads nothing.
	space := baked.Size * 0.25
	if int(baked.IndexAdvanceX.Size) > int(' ') {
		if adv := ([^]f32)(baked.IndexAdvanceX.Data)[' ']; adv > 0 do space = adv
	}
	for g in ([^]im.FontGlyph)(baked.Glyphs.Data)[:baked.Glyphs.Size] {
		if g.Visible == 0 do continue
		append(out, _Glyph_Ref{
			uv0 = {g.U0, g.V0}, uv1 = {g.U1, g.V1}, codepoint = rune(g.Codepoint),
			x0 = g.X0, y0 = g.Y0, advance = g.AdvanceX, size = baked.Size, space = space,
		})
	}
}

// The glyph a quad with texture rectangle uv0..uv1 was drawn from. A glyph
// clipped at a window edge keeps a part of its rectangle, so containment is
// the test.
@(private = "file")
_glyph_for :: proc(table: []_Glyph_Ref, uv0, uv1: [2]f32) -> (^_Glyph_Ref, bool) {
	EPS :: 1e-5
	for &g in table {
		if uv0.x >= g.uv0.x - EPS && uv0.y >= g.uv0.y - EPS && uv1.x <= g.uv1.x + EPS && uv1.y <= g.uv1.y + EPS do return &g, true
	}
	return nil, false
}

// Every run of text the last frame drew, in every viewport, decoded from its draw lists: a
// glyph quad's texture rectangle names the glyph. Space has no quad, so a
// gap of a space width or more between two glyphs puts spaces back. Glyphs
// drawn in a row on one line make one run. Temp allocated.
@(private = "file")
_text_runs :: proc() -> []_Text_Run {
	out := make([dynamic]_Text_Run, context.temp_allocator)
	dd := im.GetDrawData()
	io := im.GetIO()
	if dd == nil || !dd.Valid || io.Fonts == nil do return out[:]
	atlas := io.Fonts
	table := _glyph_table(atlas)
	if len(table) == 0 do return out[:]

	b := strings.builder_make(context.temp_allocator)
	run: _Text_Run
	open := false
	pen_end, line_top: f32
	lefts := make([dynamic]f32, context.temp_allocator)
	rights := make([dynamic]f32, context.temp_allocator)
	flush := proc(out: ^[dynamic]_Text_Run, run: ^_Text_Run, b: ^strings.Builder, open: ^bool, lefts, rights: ^[dynamic]f32) {
		if !open^ do return
		run.text = strings.clone(strings.to_string(b^), context.temp_allocator)
		run.lefts = slice.clone(lefts[:], context.temp_allocator)
		run.rights = slice.clone(rights[:], context.temp_allocator)
		append(out, run^)
		strings.builder_reset(b)
		clear(lefts)
		clear(rights)
		open^ = false
	}

	// Each draw list's window, by the window's name now. A draw list's own
	// _OwnerName points at the name the window had when it was made: after
	// a title change (" *" on an edited document) it is freed memory. A
	// window's draw list is a field of the window, at the same offset in
	// every window (measured by mcp_bridge_frame_began), so a drawn list at
	// that offset from a window is that window's. Only window addresses and
	// names are read: the binding's ImGuiWindow does not match imgui's
	// layout as far as its draw list fields.
	owners := make(map[^im.DrawList]string, context.temp_allocator)
	if ctx := im.GetCurrentContext(); ctx != nil && _draw_list_offset > 0 {
		by_list := make(map[uintptr]^im.Window, int(ctx.Windows.Size), context.temp_allocator)
		for w in ([^]^im.Window)(ctx.Windows.Data)[:ctx.Windows.Size] do if w != nil {
			by_list[uintptr(w) + _draw_list_offset] = w
		}
		pio := im.GetPlatformIO()
		for vp in ([^]^im.Viewport)(pio.Viewports.Data)[:pio.Viewports.Size] {
			if vp == nil || vp.DrawData_ == nil || !vp.DrawData_.Valid do continue
			for list in ([^]^im.DrawList)(vp.DrawData_.CmdLists.Data)[:vp.DrawData_.CmdLists.Size] {
				if w, ok := by_list[uintptr(list)]; ok do owners[list] = string(w.Name)
			}
		}
	}

	// Every viewport's draw data: a popup that reaches past the editor's
	// edge is drawn in a viewport of its own.
	pio := im.GetPlatformIO()
	for vp in ([^]^im.Viewport)(pio.Viewports.Data)[:pio.Viewports.Size] {
		if vp == nil || vp.DrawData_ == nil || !vp.DrawData_.Valid do continue
		dd = vp.DrawData_
		for list in ([^]^im.DrawList)(dd.CmdLists.Data)[:dd.CmdLists.Size] {
			if list == nil do continue
			owner, known := owners[list]
			if !known {
				if list._OwnerName == nil do continue
				owner = string(list._OwnerName)
			}
			verts := ([^]im.DrawVert)(list.VtxBuffer.Data)
			idx := ([^]im.DrawIdx)(list.IdxBuffer.Data)
			for &cmd in ([^]im.DrawCmd)(list.CmdBuffer.Data)[:list.CmdBuffer.Size] {
				if cmd.UserCallback != nil do continue
				if cmd.TexRef._TexData != atlas.TexRef._TexData || cmd.TexRef._TexID != atlas.TexRef._TexID do continue
				end := cmd.IdxOffset + cmd.ElemCount
				// A glyph is a quad of two triangles: i, i+1, i+2, i, i+2, i+3.
				// Other shapes share the command, so every triangle is a candidate.
				for k := cmd.IdxOffset; k + 6 <= end; k += 3 {
					i0 := idx[k]
					if idx[k + 1] != i0 + 1 || idx[k + 2] != i0 + 2 || idx[k + 3] != i0 || idx[k + 4] != i0 + 2 || idx[k + 5] != i0 + 3 do continue
					v0 := verts[cmd.VtxOffset + u32(i0)]
					v2 := verts[cmd.VtxOffset + u32(i0) + 2]
					if v2.uv.x - v0.uv.x <= 0 || v2.uv.y - v0.uv.y <= 0 do continue // a filled shape: the white pixel
					g, found := _glyph_for(table, v0.uv, v2.uv)
					if !found do continue
					k += 3
					pen := v0.pos.x - g.x0
					top := v0.pos.y - g.y0
					same := open && run.owner == owner && math.abs(top - line_top) < 0.75 && pen >= pen_end - 0.75 && pen - pen_end < g.size * 1.5
					if !same {
						flush(&out, &run, &b, &open, &lefts, &rights)
						run = {owner = owner, min = v0.pos, max = v2.pos}
						open = true
					} else if gap := pen - pen_end; gap > g.space * 0.5 {
						for _ in 0 ..< max(int(math.round(gap / g.space)), 1) {
							strings.write_byte(&b, ' ')
							append(&lefts, pen_end)
							append(&rights, pen)
						}
					}
					n, _ := strings.write_rune(&b, g.codepoint)
					for _ in 0 ..< n {
						append(&lefts, v0.pos.x)
						append(&rights, v2.pos.x)
					}
					run.min = {min(run.min.x, v0.pos.x), min(run.min.y, v0.pos.y)}
					run.max = {max(run.max.x, v2.pos.x), max(run.max.y, v2.pos.y)}
					pen_end = pen + g.advance
					line_top = top
				}
			}
			flush(&out, &run, &b, &open, &lefts, &rights)
		}
	}
	return out[:]
}
