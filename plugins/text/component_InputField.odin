package text

// InputField: a control the user types text into. It holds the string and
// edits it. A Text on another node shows it (`text_component`), and an
// InputCaret on that node's parent draws the caret and the selection. The
// usual tree, which GameObject, UI, Input Field makes:
//
//   Input Field   the background graphic, InputField
//   └── Text Area     UiMask, InputCaret
//       ├── Placeholder   a Text shown while the field is empty
//       └── Text          the Text that shows the string
//
// - A press on the field starts the editing and puts the caret under the
//   pointer. A drag selects, a double click selects a word. The submit key
//   on a selected field starts the editing with everything selected.
// - While it is edited the field has the keys (mhgui.ui_keys_capture): the
//   arrow keys move the caret, not the selection of controls.
// - Enter ends the editing and sets `submitted`. Escape, a press outside the
//   field and a selection that moves away end it too. The text typed so far
//   stays in every case.
// - A single line longer than the Text Area scrolls so the caret stays in
//   view: the field moves the Text node sideways.
//
// It is a Selectable (mhgui selectable.odin), so it tints its target graphic
// and takes part in keyboard and gamepad navigation as a Button does.
//
// The text plugin holds the controls that are made of text: this one and
// the Dropdown. They build on the mhgui plugin's Selectable.

import "base:runtime"
import "core:math/linalg"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"
import "moonhug:packages/engine"
import "moonhug:libs/input"
import "moonhug:libs/time"
import mhgui "moonhug:packages/mhgui"

Input_Content :: enum u8 {
	Standard,       // any character
	Integer_Number, // digits, and a minus sign at the start
	Decimal_Number, // digits, a minus sign at the start and one point
	Alphanumeric,   // letters and digits
	Password,       // any character, shown as dots
}

Input_Lines :: enum u8 {
	Single_Line, // Enter submits
	Multi_Line,  // Enter starts a new line, the shortcut key with Enter submits
}

// The character a Password field shows for each one typed.
PASSWORD_RUNE :: '•'

@(component={menu="UI/InputField"})
@(typ_guid={guid = "6d0f6b1e-3f0a-4c53-8f5e-2b1d7c9a4e61"})
InputField :: struct {
	using base:       engine.CompData `inspect:"-"`,
	using selectable: mhgui.Selectable `inline:""`,
	text:             string `decor:tooltip(desc="The string the field holds.")`,
	text_component:   engine.Ref_Local `ref:"Transform" decor:tooltip(desc="The node with the Text that shows the string. Its parent's InputCaret draws the caret and the selection.")`,
	placeholder:      engine.Ref_Local `ref:"Transform" decor:tooltip(desc="A node that shows only while the field is empty: the hint.")`,
	content:          Input_Content `decor:tooltip(desc="Which characters the field takes. Password shows a dot for each.")`,
	lines:            Input_Lines `decor:tooltip(desc="Single_Line: Enter submits. Multi_Line: Enter starts a new line.")`,
	character_limit:  i32 `decor:min(0) decor:tooltip(desc="The most characters the field holds. 0 is no limit.")`,
	read_only:        bool `decor:tooltip(desc="The text can be selected and copied, not changed.")`,
	caret_color:      [4]f32 `decor:color()`,
	selection_color:  [4]f32 `decor:color()`,
	caret_width:      f32 `decor:min(0) decor:tooltip(desc="In canvas units.")`,
	caret_blink_rate: f32 `decor:min(0) decor:tooltip(desc="Blinks a second. 0 is a caret that does not blink.")`,
	// Runtime state, never saved.
	editing:   bool `json:"-" inspect:"-"`,
	caret:     int  `json:"-" inspect:"-"`, // counted in characters: 0 is before the first
	anchor:    int  `json:"-" inspect:"-"`, // where the selection began; equal to caret with none
	changed:   bool `json:"-" inspect:"-"`, // the text changed this frame
	submitted: bool `json:"-" inspect:"-"`, // Enter ended the editing this frame
	ended:     bool `json:"-" inspect:"-"`, // the editing ended this frame, by anything
	dragging:  bool `json:"-" inspect:"-"`,
	blink:     f32  `json:"-" inspect:"-"`, // seconds since the caret last moved
	scroll:    f32  `json:"-" inspect:"-"`, // how far the Text node is moved left, canvas units
}

// Draws the caret and the selection of the InputField that edits a Text
// under this node. On the Text's parent, so they draw behind the glyphs and
// follow the Text Area. It draws nothing unless a field is being edited.
@(component={menu="UI/InputCaret"})
@(typ_guid={guid = "b0a5b0c2-93a4-4e0f-a2b6-5d3f1e7c8a92"})
InputCaret :: struct {
	using base:    engine.CompData `inspect:"-"`,
	using graphic: engine.Graphic `inline:"" inspect:"-"`,
	// Runtime state, never saved: the rects to draw, in the node's space.
	rects: [INPUT_CARET_RECTS]engine.Rect `json:"-" inspect:"-"`,
	count: int                            `json:"-" inspect:"-"`,
}

// The most rects an InputCaret draws: one per selected line.
INPUT_CARET_RECTS :: 32

type_reset_InputCaret :: proc(c: ^InputCaret) {
	c.color = {1, 1, 1, 1}
	c.raycast_target = false
	c.count = 0
}

@(canvas_graphic)
canvas_populate_InputCaret :: proc(c: ^InputCaret, rect: engine.Rect, out: ^[dynamic]engine.Graphic_Quad) {
	for r in c.rects[:c.count] {
		append(out, engine.Graphic_Quad{pos = r.pos, size = r.size, uvs = engine.QUAD_UVS_FULL, texture = mhgui.white_texture_guid()})
	}
}

type_reset_InputField :: proc(f: ^InputField) {
	type_cleanup_InputField(f)
	mhgui.selectable_reset(&f.selectable)
	f.caret_color = {1, 1, 1, 1}
	f.selection_color = {0.3, 0.55, 1, 0.5}
	f.caret_width = 2
	f.caret_blink_rate = 1.2
}

type_cleanup_InputField :: proc(f: ^InputField) {
	if f.text != "" do delete(f.text)
	f.text = ""
	if f.editing do mhgui.ui_keys_capture({})
	f.editing = false
}

@(init)
_input_field_register :: proc "contextless" () {
	context = runtime.default_context()
	mhgui.selectable_register(proc(tH: engine.Transform_Handle) -> (^mhgui.Selectable, bool) {
		if _, f := engine.transform_get_comp(tH, InputField); f != nil do return &f.selectable, f.enabled
		return nil, false
	})
}

// --- From code ---------------------------------------------------------------------

// True on the frame the text changed, by typing or by input_field_set_text.
// Read after the field's update (any @(update) at order 0 or later).
input_field_changed :: proc(f: ^InputField) -> bool {
	return f.changed
}

// True on the frame Enter ended the editing.
input_field_submitted :: proc(f: ^InputField) -> bool {
	return f.submitted
}

// True on the frame the editing ended, by Enter, Escape or the selection
// moving away.
input_field_ended :: proc(f: ^InputField) -> bool {
	return f.ended
}

// Replaces the field's string. Characters the field's content does not take
// are left out, and the string is cut at character_limit.
input_field_set_text :: proc(f: ^InputField, s: string) {
	runes := make([dynamic]rune, context.temp_allocator)
	for r in s {
		if !_takes(f, r, len(runes), runes[:]) do continue
		if f.character_limit > 0 && len(runes) >= int(f.character_limit) do break
		append(&runes, r)
	}
	_store(f, runes[:])
	f.caret = min(f.caret, len(runes))
	f.anchor = min(f.anchor, len(runes))
}

// Starts the editing, as a press on the field does: the field becomes the
// selected node and takes the keys. `select_all` selects the whole string.
input_field_begin :: proc(f: ^InputField, select_all := true) {
	mhgui.ui_set_selected(f.owner)
	mhgui.ui_keys_capture(f.owner)
	n := utf8.rune_count_in_string(f.text)
	f.editing = true
	f.caret = n
	f.anchor = 0 if select_all else n
	f.blink = 0
	input.text_input_start()
}

// Ends the editing. The text stays as typed.
input_field_end :: proc(f: ^InputField, submit := false) {
	if !f.editing do return
	f.editing = false
	f.dragging = false
	f.ended = true
	f.submitted = submit
	f.anchor = f.caret
	mhgui.ui_keys_capture({})
	input.text_input_stop()
}

// --- Editing -----------------------------------------------------------------------

// Whether the field takes `r` at index `at` of `runes`, the string so far.
@(private = "file")
_takes :: proc(f: ^InputField, r: rune, at: int, runes: []rune) -> bool {
	if r == '\n' do return f.lines == .Multi_Line && f.content != .Integer_Number && f.content != .Decimal_Number
	if r < 32 || r == 127 do return false
	switch f.content {
	case .Standard, .Password:
		return true
	case .Alphanumeric:
		return unicode.is_letter(r) || unicode.is_digit(r)
	case .Integer_Number, .Decimal_Number:
		if r >= '0' && r <= '9' do return !(at == 0 && len(runes) > 0 && runes[0] == '-')
		if r == '-' do return at == 0 && (len(runes) == 0 || runes[0] != '-')
		if r == '.' && f.content == .Decimal_Number {
			for other in runes do if other == '.' do return false
			return true
		}
		return false
	}
	return false
}

// Makes `runes` the field's string.
@(private = "file")
_store :: proc(f: ^InputField, runes: []rune) {
	s := utf8.runes_to_string(runes, context.temp_allocator)
	if s == f.text do return
	if f.text != "" do delete(f.text)
	f.text = strings.clone(s) if s != "" else ""
	f.changed = true
}

// Replaces the characters [from, to) with `insert`, as far as the field's
// content and its limit let it, and leaves the caret after what went in.
@(private = "file")
_replace :: proc(f: ^InputField, from, to: int, insert: []rune) {
	if f.read_only do return
	old := utf8.string_to_runes(f.text, context.temp_allocator)
	from := clamp(from, 0, len(old))
	to := clamp(to, from, len(old))
	out := make([dynamic]rune, 0, len(old) + len(insert), context.temp_allocator)
	append(&out, ..old[:from])
	rest := old[to:]
	for r in insert {
		if f.character_limit > 0 && len(out) + len(rest) >= int(f.character_limit) do break
		// What the string will be around the new character.
		around := make([dynamic]rune, 0, len(out) + len(rest), context.temp_allocator)
		append(&around, ..out[:])
		append(&around, ..rest)
		if !_takes(f, r, len(out), around[:]) do continue
		append(&out, r)
	}
	at := len(out)
	append(&out, ..rest)
	_store(f, out[:])
	f.caret, f.anchor = at, at
	f.blink = 0
}

@(private = "file")
_selection :: proc(f: ^InputField) -> (lo, hi: int) {
	return min(f.caret, f.anchor), max(f.caret, f.anchor)
}

@(private = "file")
_word_rune :: proc(r: rune) -> bool {
	return unicode.is_letter(r) || unicode.is_digit(r) || r == '_'
}

// The start of the word before `at`, or the end of the word after it.
@(private = "file")
_word_edge :: proc(runes: []rune, at: int, forward: bool) -> int {
	i := at
	if forward {
		for i < len(runes) && !_word_rune(runes[i]) do i += 1
		for i < len(runes) && _word_rune(runes[i]) do i += 1
	} else {
		for i > 0 && !_word_rune(runes[i - 1]) do i -= 1
		for i > 0 && _word_rune(runes[i - 1]) do i -= 1
	}
	return i
}

// The first and the last caret index of the line `at` is on.
@(private = "file")
_line_span :: proc(carets: []Caret, at, n: int) -> (first, last: int) {
	if len(carets) != n + 1 do return 0, n
	first, last = at, at
	for first > 0 && carets[first - 1].line == carets[at].line do first -= 1
	for last < n && carets[last + 1].line == carets[at].line do last += 1
	return
}

// The caret index on the line above or below `at` nearest to its x.
@(private = "file")
_line_step :: proc(carets: []Caret, at, n, step: int) -> int {
	if len(carets) != n + 1 do return 0 if step < 0 else n
	want := carets[at].line + step
	best, best_d := -1, f32(0)
	for c, i in carets {
		if c.line != want do continue
		d := abs(c.pos.x - carets[at].pos.x)
		if best < 0 || d < best_d do best, best_d = i, d
	}
	if best < 0 do return 0 if step < 0 else n
	return best
}

// The keys of a field that is being edited.
@(private = "file")
_keys :: proc(f: ^InputField) {
	runes := utf8.string_to_runes(f.text, context.temp_allocator)
	n := len(runes)
	f.caret = clamp(f.caret, 0, n)
	f.anchor = clamp(f.anchor, 0, n)
	shift, shortcut, word := input.shift_down(), input.shortcut_down(), input.word_down()
	lo, hi := _selection(f)
	carets: []Caret
	if f.lines == .Multi_Line do carets = _carets(f)

	go :: proc(f: ^InputField, to: int, shift: bool) {
		f.caret = to
		if !shift do f.anchor = to
		f.blink = 0
	}
	switch {
	case input.key_repeated(.LEFT):
		first, _ := _line_span(carets, f.caret, n)
		switch {
		case shortcut:               go(f, first, shift)
		case word:                   go(f, _word_edge(runes, f.caret, false), shift)
		case lo != hi && !shift:     go(f, lo, false)
		case:                        go(f, max(f.caret - 1, 0), shift)
		}
	case input.key_repeated(.RIGHT):
		_, last := _line_span(carets, f.caret, n)
		switch {
		case shortcut:               go(f, last, shift)
		case word:                   go(f, _word_edge(runes, f.caret, true), shift)
		case lo != hi && !shift:     go(f, hi, false)
		case:                        go(f, min(f.caret + 1, n), shift)
		}
	case input.key_repeated(.HOME):
		first, _ := _line_span(carets, f.caret, n)
		go(f, first, shift)
	case input.key_repeated(.END):
		_, last := _line_span(carets, f.caret, n)
		go(f, last, shift)
	case input.key_repeated(.UP):
		go(f, _line_step(carets, f.caret, n, -1), shift)
	case input.key_repeated(.DOWN):
		go(f, _line_step(carets, f.caret, n, 1), shift)
	case input.key_repeated(.BACKSPACE):
		first, _ := _line_span(carets, f.caret, n)
		switch {
		case lo != hi: _replace(f, lo, hi, nil)
		case shortcut: _replace(f, first, f.caret, nil)
		case word:     _replace(f, _word_edge(runes, f.caret, false), f.caret, nil)
		case:          _replace(f, f.caret - 1, f.caret, nil)
		}
	case input.key_repeated(.DELETE):
		switch {
		case lo != hi: _replace(f, lo, hi, nil)
		case word:     _replace(f, f.caret, _word_edge(runes, f.caret, true), nil)
		case:          _replace(f, f.caret, f.caret + 1, nil)
		}
	case input.key_repeated(.RETURN), input.key_repeated(.KP_ENTER):
		if f.lines == .Multi_Line && !shortcut {
			_replace(f, lo, hi, {'\n'})
		} else if input.key_pressed(.RETURN) || input.key_pressed(.KP_ENTER) {
			input_field_end(f, submit = true)
		}
		return
	case input.key_pressed(.ESCAPE):
		input_field_end(f)
		return
	case shortcut && input.key_pressed(.A):
		f.anchor, f.caret = 0, n
	case shortcut && (input.key_pressed(.C) || input.key_pressed(.X)):
		// A password does not leave the field.
		if lo != hi && f.content != .Password {
			input.clipboard_set_text(utf8.runes_to_string(runes[lo:hi], context.temp_allocator))
			if input.key_pressed(.X) do _replace(f, lo, hi, nil)
		}
	case shortcut && input.key_repeated(.V):
		pasted := input.clipboard_text(context.temp_allocator)
		insert := make([dynamic]rune, context.temp_allocator)
		for r in pasted {
			// A line break in a single line becomes a space.
			if (r == '\n' || r == '\r' || r == '\t') && f.lines == .Single_Line {
				append(&insert, ' ')
			} else if r != '\r' {
				append(&insert, r)
			}
		}
		_replace(f, lo, hi, insert[:])
	}
	// What was typed, unless a shortcut is held.
	if typed := input.text(); len(typed) > 0 && !shortcut {
		lo, hi = _selection(f)
		_replace(f, lo, hi, typed)
	}
}

// --- Pointer -----------------------------------------------------------------------

@(comp_on_pointer={component=InputField})
comp_on_pointer_InputField :: proc(f: ^InputField, ev: ^mhgui.Pointer_Event) {
	mhgui.selectable_pointer(&f.selectable, ev)
	#partial switch ev.kind {
	case .Down:
		if ev.button != .Left || !mhgui.selectable_usable(&f.selectable, f.owner) do return
		// The field keeps the drag: it selects.
		ev.own_drag = true
		f.dragging = true
		extend := f.editing && input.shift_down()
		if !f.editing do input_field_begin(f, select_all = false)
		if at, ok := _index_at(f, ev); ok {
			f.caret = at
			if !extend do f.anchor = at
		}
		f.blink = 0
	case .Drag_Begin, .Drag:
		if !f.dragging do return
		if at, ok := _index_at(f, ev); ok do f.caret = at
		f.blink = 0
	case .Up, .Cancel:
		f.dragging = false
	case .Click:
		if ev.click_count != 2 || !f.editing do return
		runes := utf8.string_to_runes(f.text, context.temp_allocator)
		at := clamp(f.caret, 0, len(runes))
		f.anchor = _word_edge(runes, min(at + 1, len(runes)), false)
		f.caret = _word_edge(runes, f.anchor, true)
	}
}

// --- Layout ------------------------------------------------------------------------

// The field's Text, the Text's node and the node's parent.
@(private = "file")
_parts :: proc(f: ^InputField) -> (tx: ^Text, text_tH, area_tH: engine.Transform_Handle) {
	text_tH = engine.Transform_Handle(f.text_component.handle)
	_, tx = engine.transform_get_comp(text_tH, Text)
	if tx == nil do return nil, {}, {}
	if t := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(text_tH)); t != nil {
		area_tH = engine.Transform_Handle(t.parent.handle)
	}
	return
}

// The resolved rects of the Text's node and of its parent.
@(private = "file")
_rects :: proc(f: ^InputField, text_tH, area_tH: engine.Transform_Handle) -> (text_node, area_node: engine.Node_Rect, ok: bool) {
	canvas := engine.canvas_of(f.owner)
	if canvas == {} do return
	root, _, _ := engine.canvas_placement(canvas, input.viewport_size())
	nodes := make([dynamic]engine.Node_Rect, context.temp_allocator)
	engine.canvas_resolve_rects(canvas, root, &nodes)
	for n in nodes {
		if n.tH == text_tH do text_node = n
		if n.tH == area_tH do area_node = n
	}
	// The parent may be no canvas node: area_node.tH says whether it is.
	return text_node, area_node, text_tH != {} && text_node.tH == text_tH
}

// The carets of the field's Text, in the Text node's space.
@(private = "file")
_carets :: proc(f: ^InputField) -> []Caret {
	tx, text_tH, area_tH := _parts(f)
	if tx == nil do return nil
	text_node, _, ok := _rects(f, text_tH, area_tH)
	if !ok do return nil
	return text_carets(tx, text_node.rect)
}

// The caret index under the event's pointer: on the nearest line, the
// nearest caret.
@(private = "file")
_index_at :: proc(f: ^InputField, ev: ^mhgui.Pointer_Event) -> (at: int, ok: bool) {
	tx, text_tH, area_tH := _parts(f)
	if tx == nil do return
	text_node, _, found := _rects(f, text_tH, area_tH)
	if !found do return
	carets := text_carets(tx, text_node.rect)
	if len(carets) == 0 do return
	p := mhgui.ui_pointer_canvas_position(ev) or_return
	local := (linalg.inverse(text_node.xform) * [4]f32{p.x, p.y, 0, 1}).xy
	// The line: the one the pointer's y is in, or the nearest.
	line, line_d := 0, max(f32)
	for c in carets {
		d := f32(0)
		if local.y < c.pos.y do d = c.pos.y - local.y
		if local.y > c.pos.y + c.height do d = local.y - (c.pos.y + c.height)
		if d < line_d do line, line_d = c.line, d
	}
	best_d := max(f32)
	for c, i in carets {
		if c.line != line do continue
		if d := abs(c.pos.x - local.x); d < best_d do at, best_d = i, d
	}
	return at, true
}

// What the Text shows: the string, or a dot per character of a password.
@(private = "file")
_show :: proc(f: ^InputField) {
	tx, _, _ := _parts(f)
	if tx != nil {
		shown := f.text
		if f.content == .Password && f.text != "" {
			b := strings.builder_make(context.temp_allocator)
			for _ in f.text do strings.write_rune(&b, PASSWORD_RUNE)
			shown = strings.to_string(b)
		}
		text_set(tx, shown)
	}
	// The hint shows while the field is empty.
	if _, cr := engine.transform_get_comp(engine.Transform_Handle(f.placeholder.handle), engine.CanvasRenderer); cr != nil {
		cr.enabled = f.text == ""
	}
}

// The caret and the selection, given to the InputCaret on the Text's parent,
// and the sideways scroll of a single line that keeps the caret in view.
@(private = "file")
_place :: proc(f: ^InputField) {
	tx, text_tH, area_tH := _parts(f)
	if tx == nil do return
	_, drawn := engine.transform_get_comp(area_tH, InputCaret)
	if drawn != nil do drawn.count = 0
	if !f.editing && f.scroll == 0 do return
	text_node, area_node, ok := _rects(f, text_tH, area_tH)
	if !ok || area_node.tH != area_tH do return
	carets := text_carets(tx, text_node.rect)
	n := len(carets) - 1
	if n < 0 do return
	f.caret = clamp(f.caret, 0, n)
	f.anchor = clamp(f.anchor, 0, n)
	// From the Text node's space to its parent's.
	to_area := linalg.inverse(area_node.xform) * text_node.xform
	area := area_node.rect
	at :: proc(m: matrix[4, 4]f32, p: [2]f32) -> [2]f32 {
		return (m * [4]f32{p.x, p.y, 0, 1}).xy
	}

	// A single line scrolls: the caret stays inside the area, and no room is
	// left empty at the right while text is hidden at the left.
	shift := f32(0)
	if f.lines == .Single_Line {
		x := at(to_area, carets[f.caret].pos).x
		end := at(to_area, carets[n].pos).x
		left, right := area.pos.x, area.pos.x + area.size.x - f.caret_width
		if !f.editing {
			shift = f.scroll // back to the start
		} else if x > right {
			shift = right - x
		} else if x < left {
			shift = left - x
		} else if f.scroll > 0 && end < right {
			shift = min(right - end, f.scroll)
		}
		// The Text node cannot go right of where it was authored.
		shift = min(shift, f.scroll)
		if shift != 0 {
			if _, rt := engine.transform_get_comp(text_tH, engine.RectTransform); rt != nil {
				rt.anchored_position.x += shift
				f.scroll -= shift
			}
		}
	}
	if !f.editing || drawn == nil do return

	add :: proc(drawn: ^InputCaret, area: engine.Rect, lo, hi: [2]f32) {
		if drawn.count >= INPUT_CARET_RECTS do return
		// Cut to the area: the node's own graphic is not clipped by its mask.
		a := linalg.max(lo, area.pos)
		b := linalg.min(hi, area.pos + area.size)
		if b.x <= a.x || b.y <= a.y do return
		drawn.rects[drawn.count] = {pos = a, size = b - a}
		drawn.count += 1
	}
	move := [2]f32{shift, 0}
	lo, hi := _selection(f)
	if lo != hi {
		drawn.color = f.selection_color
		// One rect per line of the selection.
		for i := lo; i <= hi; {
			j := i
			for j < hi && carets[j + 1].line == carets[i].line do j += 1
			a := at(to_area, carets[i].pos) + move
			b := at(to_area, carets[j].pos + {0, carets[j].height}) + move
			// A line with nothing selected on it but its break shows a sliver.
			if b.x - a.x < carets[i].height * 0.25 && j < hi do b.x = a.x + carets[i].height * 0.25
			if i != j || j < hi do add(drawn, area, a, b)
			i = j + 1
		}
	} else if f.caret_blink_rate <= 0 || f.dragging || (f.blink * f.caret_blink_rate - f32(int(f.blink * f.caret_blink_rate))) < 0.5 {
		drawn.color = f.caret_color
		c := carets[f.caret]
		a := at(to_area, c.pos) + move
		b := at(to_area, c.pos + {0, c.height}) + move
		// Kept inside the area at its left edge.
		a.x = max(a.x - f.caret_width * 0.5, area.pos.x)
		add(drawn, area, a, {a.x + f.caret_width, b.y})
	}
}

// After mhgui's ui_tick (order -100), which sends the pointer events.
@(update={order=-99})
input_field_tick :: proc(dt: f32) {
	w := engine.ctx_world()
	selected := mhgui.ui_selected()
	real_dt := time.delta_time(.Unscaled)
	it := engine.pool_iterator(input_fields(w))
	for f, _ in engine.pool_next(&it) {
		f.changed, f.submitted, f.ended = false, false, false
		live := f.enabled && engine.transform_active_in_hierarchy(f.owner)
		chosen := live && selected == f.owner
		usable := live && mhgui.selectable_usable(&f.selectable, f.owner)
		if f.editing && (!chosen || !usable || !engine.application_is_focused()) {
			input_field_end(f)
		}
		began := false
		if !f.editing && chosen && usable && mhgui.ui_navigation() && engine.application_is_focused() && mhgui.ui_submit_pressed() && !input.mouse_down(.Left) {
			input_field_begin(f)
			began = true
		}
		if f.editing {
			// Another field may have given the keys back this frame.
			mhgui.ui_keys_capture(f.owner)
			input.text_input_start()
			f.blink += real_dt
			if !began do _keys(f)
		}
		mhgui.selectable_update(&f.selectable, f.owner, live, chosen, false, real_dt)
		if live {
			_show(f)
			_place(f)
		}
	}
}
