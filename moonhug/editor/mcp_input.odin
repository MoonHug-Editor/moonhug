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
import "core:strings"
import im "moonhug:external/odin-imgui"
import mcp "moonhug:editor/mcp"
import gfx "moonhug:libs/gfx"
import "moonhug:editor/inspector"

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
}

@(private = "file")
_INPUT_KIND_NAMES := [_Input_Kind]string{.Move = "move", .Down = "down", .Up = "up", .Key = "key", .Text = "text", .Wait = "wait"}

@(private = "file")
_Input_Step :: struct {
	kind:   _Input_Kind,
	pos:    [2]f32, // Move: points from the editor's top-left
	button: i32,    // Down, Up: 0 left, 1 right, 2 middle
	key:    im.Key, // Key: the key as imgui names it
	mod:    im.Key, // Key: the modifier flag a modifier key sets as well, None otherwise
	down:   bool,   // Key
	text:   string, // Text, owned
	frames: int,    // Wait
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
		case "wait":
			n := int(mcp.json_int(obj, "frames", 1))
			if n < 1 || n > _INPUT_MAX_WAIT do err = {"bad_request", fmt.tprintf("step %d: wait needs frames 1 to %d", i, _INPUT_MAX_WAIT)}
			step = {kind = .Wait, frames = n}
			frames += n - 1
		case:
			err = {"bad_request", fmt.tprintf("step %d: type must be move, down, up, key, text or wait (got %q)", i, kind)}
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
	description="Drive the editor's widgets with real mouse and keyboard input: a script of steps played one per frame into imgui, the way the OS feeds it. Steps are objects with a type: move {x, y} (points from the editor's top-left, item_rect and window_list use the same frame), down {button} and up {button} (left, right, middle, default left), key {name, down} (an imgui key name, or ctrl, shift, alt, cmd for the physical modifier keys, down defaults to true, a press needs a down and an up), text {text} (characters typed into the focused field), wait {frames}. A drag is move, down, a few moves, up. Answers when the script is done, with what each step's frame saw: the mouse position, the window under it, whether an item was hovered or active. The script's position holds until the real cursor moves. One script at a time, and not in a batch.",
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
		_input.mouse = step.pos
		_input.has_mouse = true
		im.IO_AddMousePosEvent(io, vp.Pos.x + step.pos.x, vp.Pos.y + step.pos.y)
	case .Down:
		im.IO_AddMouseButtonEvent(io, step.button, true)
	case .Up:
		im.IO_AddMouseButtonEvent(io, step.button, false)
	case .Key:
		// The backend sends the modifier flag before the key itself.
		if step.mod != .None do im.IO_AddKeyEvent(io, step.mod, step.down)
		im.IO_AddKeyEvent(io, step.key, step.down)
	case .Text:
		im.IO_AddInputCharactersUTF8(io, strings.clone_to_cstring(step.text, context.temp_allocator))
	case .Wait:
		// This frame is the first of them.
		_input.wait = step.frames - 1
	}
	if _input.wait == 0 do _input.pending = true
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
	param_window="string!:Title or id of the window (window_list)",
	param_label="string!:The row's field name as get_property addresses it (duration), or the text to find, case ignored, a part of a longer text matches",
})
mcp_tool_item_rect :: proc(id: i64, params: json.Object) -> (string, Mcp_Error) {
	query, _ := params["window"].(json.String)
	w, err := _find_window(query)
	if err.code != "" do return "", err
	label, _ := params["label"].(json.String)
	label = strings.trim_space(label)
	if label == "" do return mcp.tool_fail("bad_request", "need label: a row's field name or text in the window")
	if _item_probes == nil do _item_probes = make([dynamic]_Item_Probe, runtime.default_allocator())
	append(&_item_probes, _Item_Probe{
		id     = id,
		window = strings.clone(string(w.Name), runtime.default_allocator()),
		label  = strings.clone(label, runtime.default_allocator()),
	})
	inspector.row_probe_arm()
	return MCP_DEFERRED, {}
}

// Whether imgui window `name` is `window` or a child of it ("<parent>/<child>_<id>").
@(private = "file")
_owned_by :: proc(name, window: string) -> bool {
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
			if !_owned_by(run.owner, probe.window) do continue
			if !strings.contains(strings.to_lower(run.text, context.temp_allocator), q) do continue
			append(&matches, _Item_Match{"text", run.text, run.min.x - vp.Pos.x, run.min.y - vp.Pos.y, run.max.x - run.min.x, run.max.y - run.min.y})
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
}

// Every visible glyph of every font, at the size each font was last drawn
// at, keyed by its rectangle in the atlas texture. Temp allocated.
@(private = "file")
_glyph_table :: proc(atlas: ^im.FontAtlas) -> []_Glyph_Ref {
	out := make([dynamic]_Glyph_Ref, context.temp_allocator)
	for font in ([^]^im.Font)(atlas.Fonts.Data)[:atlas.Fonts.Size] {
		if font == nil || font.LastBaked == nil do continue
		baked := font.LastBaked
		space := baked.Size * 0.25
		if g := im.FontBaked_FindGlyphNoFallback(baked, ' '); g != nil do space = g.AdvanceX
		for g in ([^]im.FontGlyph)(baked.Glyphs.Data)[:baked.Glyphs.Size] {
			if g.Visible == 0 do continue
			append(&out, _Glyph_Ref{
				uv0 = {g.U0, g.V0}, uv1 = {g.U1, g.V1}, codepoint = rune(g.Codepoint),
				x0 = g.X0, y0 = g.Y0, advance = g.AdvanceX, size = baked.Size, space = space,
			})
		}
	}
	return out[:]
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

// Every run of text the last frame drew, decoded from its draw lists: a
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
	flush := proc(out: ^[dynamic]_Text_Run, run: ^_Text_Run, b: ^strings.Builder, open: ^bool) {
		if !open^ do return
		run.text = strings.clone(strings.to_string(b^), context.temp_allocator)
		append(out, run^)
		strings.builder_reset(b)
		open^ = false
	}

	for list in ([^]^im.DrawList)(dd.CmdLists.Data)[:dd.CmdLists.Size] {
		if list == nil || list._OwnerName == nil do continue
		owner := string(list._OwnerName)
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
					flush(&out, &run, &b, &open)
					run = {owner = owner, min = v0.pos, max = v2.pos}
					open = true
				} else if gap := pen - pen_end; gap > g.space * 0.5 {
					for _ in 0 ..< max(int(math.round(gap / g.space)), 1) do strings.write_byte(&b, ' ')
				}
				strings.write_rune(&b, g.codepoint)
				run.min = {min(run.min.x, v0.pos.x), min(run.min.y, v0.pos.y)}
				run.max = {max(run.max.x, v2.pos.x), max(run.max.y, v2.pos.y)}
				pen_end = pen + g.advance
				line_top = top
			}
		}
		flush(&out, &run, &b, &open)
	}
	return out[:]
}
