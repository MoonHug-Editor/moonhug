package text_tests

// InputField and Dropdown through a fake monospace text
// backend: at size 12 every glyph advances 10, so the caret before character
// i of a left-aligned Text is 10 * i from its rect's left edge.

import "core:testing"
import "moonhug:packages/engine"
import "moonhug:libs/input"
import mhgui "moonhug:packages/mhgui"
import text "moonhug:packages/text"
import common "moonhug:tests/common"
import sdl "vendor:sdl3"

@(private = "file")
_fake_metrics :: proc(font: engine.Asset_GUID, size_px: f32) -> (text.Line_Metrics, bool) {
	s := size_px / 12
	return {ascent = 10 * s, descent = 2 * s, line_gap = 0}, true
}

@(private = "file")
_fake_glyph :: proc(font: engine.Asset_GUID, size_px: f32, r: rune) -> (text.Glyph, bool) {
	s := size_px / 12
	g := text.Glyph{advance = 10 * s, texture = font}
	if r != ' ' {
		g.size = {10 * s, 12 * s}
		g.offset = {0, -2 * s}
		g.uvs = engine.QUAD_UVS_FULL
	}
	return g, true
}

@(private = "file")
_add :: proc(tH: engine.Transform_Handle, key: engine.TypeKey) -> rawptr {
	_, ptr := engine.transform_add_comp(tH, key)
	if ptr != nil do (cast(^engine.CompData)ptr).enabled = true
	return ptr
}

@(private = "file")
_node :: proc(name: string, parent: engine.Transform_Handle, pos, size: [2]f32) -> engine.Transform_Handle {
	node := engine.transform_new(name, parent)
	rt := cast(^engine.RectTransform)_add(node, .RectTransform)
	engine.type_reset_RectTransform(rt)
	rt.anchored_position = {pos.x, pos.y, 0}
	rt.size_delta = size
	return node
}

// A reference to a node as a scene saves one, so it holds in a copy too.
@(private = "file")
_ref :: proc(tH: engine.Transform_Handle) -> engine.Ref_Local {
	t := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(tH))
	lid := t.local_id
	if lid == 0 && t.scene != nil do lid = engine.sm_local_id_get_or_mint(t.scene, engine.Handle(tH))
	return {local_id = lid, handle = engine.Handle(tH)}
}

@(private = "file")
_image :: proc(node: engine.Transform_Handle) {
	_add(node, .CanvasRenderer)
	mhgui.type_reset_Image(cast(^mhgui.Image)_add(node, .Image))
}

@(private = "file")
_text :: proc(name: string, parent: engine.Transform_Handle, size: [2]f32) -> (engine.Transform_Handle, ^text.Text) {
	node := _node(name, parent, {0, 0}, size)
	_add(node, .CanvasRenderer)
	tx := cast(^text.Text)_add(node, .Text)
	text.type_reset_Text(tx)
	tx.font.guid[0] = 1
	tx.font_size = 12
	tx.wrap = false
	tx.raycast_target = false
	return node, tx
}

@(private = "file")
_Field :: struct {
	node, area, text_node: engine.Transform_Handle,
	field: ^text.InputField,
	tx:    ^text.Text,
	drawn: ^text.InputCaret,
}

// A 200 x 40 field at the canvas's centre: its text starts at canvas x -100.
@(private = "file")
_field :: proc(canvas: engine.Transform_Handle) -> (f: _Field) {
	f.node = _node("Input Field", canvas, {0, 0}, {200, 40})
	_image(f.node)
	f.area = _node("Text Area", f.node, {0, 0}, {200, 40})
	_add(f.area, .CanvasRenderer)
	f.drawn = cast(^text.InputCaret)_add(f.area, .InputCaret)
	text.type_reset_InputCaret(f.drawn)
	f.text_node, f.tx = _text("Text", f.area, {200, 40})
	f.field = cast(^text.InputField)_add(f.node, .InputField)
	text.type_reset_InputField(f.field)
	f.field.text_component = {handle = engine.Handle(f.text_node)}
	return
}

@(private = "file")
_tick :: proc() {
	mhgui.ui_tick(0)
	text.input_field_tick(0)
	text.dropdown_tick(0)
}

// One frame with `k` going down, then the key let go.
@(private = "file")
_tap :: proc(k: input.Key) {
	input.frame_reset()
	e: sdl.Event
	e.type = .KEY_DOWN
	e.key.scancode = k
	input.apply_event(&e)
	_tick()
	e.type = .KEY_UP
	input.apply_event(&e)
	input.frame_reset()
}

@(private = "file")
_hold :: proc(k: input.Key, down: bool) {
	e: sdl.Event
	e.type = .KEY_DOWN if down else .KEY_UP
	e.key.scancode = k
	input.apply_event(&e)
}

// One frame in which `s` is typed.
@(private = "file")
_type :: proc(s: cstring) {
	input.frame_reset()
	e: sdl.Event
	e.type = .TEXT_INPUT
	e.text.text = s
	input.apply_event(&e)
	_tick()
	input.frame_reset()
}

@(private = "file")
_mouse_was: [2]f32

// One frame with the mouse at a canvas point, a button going down or up.
@(private = "file")
_mouse :: proc(x, y: f32, down := false, up := false) {
	input.frame_reset()
	e: sdl.Event
	e.type = .MOUSE_MOTION
	e.motion.x, e.motion.y = 400 + x, 300 - y
	e.motion.xrel, e.motion.yrel = 400 + x - _mouse_was.x, 300 - y - _mouse_was.y
	_mouse_was = {400 + x, 300 - y}
	input.apply_event(&e)
	if down || up {
		b: sdl.Event
		b.type = .MOUSE_BUTTON_DOWN if down else .MOUSE_BUTTON_UP
		b.button.button = 1
		b.button.down = down
		b.button.x, b.button.y = 400 + x, 300 - y
		input.apply_event(&b)
	}
	_tick()
}

@(private = "file")
_Fixture :: struct {
	tc:   ^common.TestCtx,
	prev: text.Backend,
}

@(private = "file")
_begin :: proc(fx: ^_Fixture) -> engine.Transform_Handle {
	fx.tc = new(common.TestCtx)
	common.setup(fx.tc)
	context.user_ptr = &fx.tc.uc
	fx.prev = text.backend()^
	text.backend_set(text.Backend{name = "fake", metrics = _fake_metrics, glyph = _fake_glyph})
	input.set_app_focused(true)
	input.set_viewport({0, 0}, {800, 600})
	mhgui.ui_pointer_reset()
	mhgui.ui_set_selected({})
	canvas := engine.transform_new("Canvas")
	_add(canvas, .Canvas)
	_add(canvas, .GraphicRaycaster)
	return canvas
}

@(private = "file")
_end :: proc(fx: ^_Fixture) {
	context.user_ptr = &fx.tc.uc
	mhgui.ui_keys_capture({})
	mhgui.ui_set_selected({})
	mhgui.ui_pointer_reset()
	input.set_app_focused(false)
	input.frame_reset()
	text.backend_set(fx.prev)
	common.teardown(fx.tc)
	free(fx.tc)
}

@(test)
test_input_field_types_and_edits :: proc(t: ^testing.T) {
	fx: _Fixture
	canvas := _begin(&fx)
	context.user_ptr = &fx.tc.uc
	defer _end(&fx)
	f := _field(canvas)
	field := f.field

	text.input_field_begin(field, select_all = false)
	testing.expect(t, field.editing && mhgui.ui_selected() == f.node, "begin selects the field")
	_type("hello")
	testing.expect_value(t, field.text, "hello")
	testing.expect_value(t, field.caret, 5)
	testing.expect(t, text.input_field_changed(field), "typing sets changed")
	testing.expect_value(t, f.tx.text, "hello")

	// The arrow keys move the caret, not the selection of controls.
	_tap(.LEFT)
	_tap(.LEFT)
	testing.expect_value(t, field.caret, 3)
	testing.expect(t, !text.input_field_changed(field), "a move changes nothing")
	testing.expect_value(t, mhgui.ui_selected(), f.node)
	_type("X")
	testing.expect_value(t, field.text, "helXlo")
	_tap(.BACKSPACE)
	testing.expect_value(t, field.text, "hello")
	_tap(.DELETE)
	testing.expect_value(t, field.text, "helo")

	// Shift selects, and what is typed replaces the selection.
	_hold(.LSHIFT, true)
	_tap(.LEFT)
	_tap(.LEFT)
	_hold(.LSHIFT, false)
	testing.expect_value(t, field.anchor, 3)
	testing.expect_value(t, field.caret, 1)
	testing.expect_value(t, f.drawn.count, 1)
	// The selection's rect: characters 1 to 3 of a text that starts at 300.
	testing.expect(t, abs(f.drawn.rects[0].pos.x - 310) < 0.01 && abs(f.drawn.rects[0].size.x - 20) < 0.01, "the selection covers two characters")
	_type("i")
	testing.expect_value(t, field.text, "hio")

	// Home and End, and a caret drawn when nothing is selected.
	_tap(.HOME)
	testing.expect_value(t, field.caret, 0)
	_tap(.END)
	testing.expect_value(t, field.caret, 3)
	testing.expect_value(t, f.drawn.count, 1)
	testing.expect(t, abs(f.drawn.rects[0].size.x - field.caret_width) < 0.01, "the caret is caret_width wide")

	// Enter submits and ends the editing. The text stays.
	_tap(.RETURN)
	testing.expect(t, !field.editing, "Enter ends the editing")
	testing.expect(t, text.input_field_submitted(field) && text.input_field_ended(field), "Enter submits")
	testing.expect_value(t, field.text, "hio")
	testing.expect(t, !mhgui.ui_keys_captured(), "the keys are given back")
	input.frame_reset()
	_tick()
	testing.expect(t, !text.input_field_submitted(field), "submitted lasts a frame")
	testing.expect_value(t, f.drawn.count, 0)

	// The submit key on the selected field starts the editing again, with
	// everything selected. Escape ends it and keeps the text.
	_tap(.RETURN)
	testing.expect(t, field.editing, "the submit key edits the selected field")
	testing.expect_value(t, field.anchor, 0)
	testing.expect_value(t, field.caret, 3)
	_type("new")
	testing.expect_value(t, field.text, "new")
	_tap(.ESCAPE)
	testing.expect(t, !field.editing && !text.input_field_submitted(field), "Escape ends without a submit")
	testing.expect_value(t, field.text, "new")
}

@(test)
test_input_field_content_limit_and_password :: proc(t: ^testing.T) {
	fx: _Fixture
	canvas := _begin(&fx)
	context.user_ptr = &fx.tc.uc
	defer _end(&fx)
	f := _field(canvas)
	field := f.field

	field.content = .Integer_Number
	text.input_field_set_text(field, "-12a3-")
	testing.expect_value(t, field.text, "-123")
	text.input_field_begin(field, select_all = false)
	_type("4.5x")
	testing.expect_value(t, field.text, "-12345")

	field.content = .Decimal_Number
	text.input_field_set_text(field, "1.5.2")
	testing.expect_value(t, field.text, "1.52")

	field.content = .Standard
	field.character_limit = 4
	text.input_field_set_text(field, "")
	_type("abcdef")
	testing.expect_value(t, field.text, "abcd")

	// A read-only field takes no typing.
	field.read_only = true
	_tap(.BACKSPACE)
	testing.expect_value(t, field.text, "abcd")
	field.read_only = false

	// A password shows a dot per character.
	field.content = .Password
	input.frame_reset()
	_tick()
	testing.expect_value(t, f.tx.text, "••••")
	testing.expect_value(t, field.text, "abcd")

	// A single line takes no line break, a multi-line field does.
	field.content = .Standard
	field.character_limit = 0
	_tap(.RETURN)
	testing.expect(t, !field.editing, "Enter ends a single line")
	field.lines = .Multi_Line
	text.input_field_begin(field, select_all = false)
	_tap(.RETURN)
	testing.expect(t, field.editing, "Enter does not end a multi-line field")
	testing.expect_value(t, field.text, "abcd\n")
	_type("ef")
	_tap(.UP)
	testing.expect_value(t, field.caret, 2) // above "ef|", on the first line
	_tap(.DOWN)
	testing.expect_value(t, field.caret, 7)
}

@(test)
test_input_field_pointer_places_the_caret :: proc(t: ^testing.T) {
	fx: _Fixture
	canvas := _begin(&fx)
	context.user_ptr = &fx.tc.uc
	defer _end(&fx)
	f := _field(canvas)
	field := f.field
	text.input_field_set_text(field, "abcdefgh")
	input.frame_reset()
	_tick()

	// The text starts at canvas x -100: a press at -78 is nearest to the
	// caret before the third character.
	_mouse(-78, 0, down = true)
	testing.expect(t, field.editing, "a press starts the editing")
	testing.expect_value(t, mhgui.ui_selected(), f.node)
	testing.expect_value(t, field.caret, 2)
	testing.expect_value(t, field.anchor, 2)
	// A drag selects.
	_mouse(-59, 0)
	testing.expect_value(t, field.caret, 4)
	testing.expect_value(t, field.anchor, 2)
	_mouse(-59, 0, up = true)
	testing.expect(t, field.editing, "the release keeps the editing")

	// A press on nothing ends it.
	_mouse(300, 200, down = true)
	_mouse(300, 200, up = true)
	testing.expect(t, !field.editing, "a press outside ends the editing")
	testing.expect_value(t, field.text, "abcdefgh")
}

// A line longer than its area scrolls so the caret stays in view.
@(test)
test_input_field_scrolls_a_long_line :: proc(t: ^testing.T) {
	fx: _Fixture
	canvas := _begin(&fx)
	context.user_ptr = &fx.tc.uc
	defer _end(&fx)
	f := _field(canvas)
	field := f.field
	_, rt := engine.transform_get_comp(f.text_node, engine.RectTransform)

	text.input_field_begin(field, select_all = false)
	_type("0123456789012345678901234") // 250 wide in a 200 wide area
	input.frame_reset()
	_tick()
	testing.expect(t, field.scroll > 49 && field.scroll < 53, "the text moved left by what did not fit")
	testing.expect(t, abs(rt.anchored_position.x + field.scroll) < 0.01, "the Text node carries the scroll")
	// Back at the start, the text is back too.
	_tap(.HOME)
	input.frame_reset()
	_tick()
	testing.expect(t, abs(field.scroll) < 0.01, "the caret at the start scrolls back")
	// The editing over, the node is where it was authored.
	_tap(.END)
	input.frame_reset()
	_tick()
	_tap(.ESCAPE)
	input.frame_reset()
	_tick()
	testing.expect(t, abs(rt.anchored_position.x) < 0.01 && field.scroll == 0, "the end of the editing puts the Text back")
}

@(test)
test_dropdown_opens_picks_and_closes :: proc(t: ^testing.T) {
	fx: _Fixture
	canvas := _begin(&fx)
	context.user_ptr = &fx.tc.uc
	defer _end(&fx)

	node := _node("Dropdown", canvas, {0, 100}, {160, 30})
	_image(node)
	caption_node, caption := _text("Label", node, {160, 30})
	template := _node("Template", node, {0, -60}, {160, 90})
	_image(template)
	row := _node("Item", template, {0, 30}, {160, 30})
	_image(row)
	label_node, _ := _text("Item Label", row, {160, 30})
	item := cast(^text.DropdownItem)_add(row, .DropdownItem)
	text.type_reset_DropdownItem(item)
	item.label = _ref(label_node)
	engine.transform_set_active(template, false)

	d := cast(^text.Dropdown)_add(node, .Dropdown)
	text.type_reset_Dropdown(d)
	d.caption = _ref(caption_node)
	d.template = _ref(template)
	text.dropdown_set_options(d, {"Low", "Medium", "High"})

	input.frame_reset()
	_tick()
	testing.expect_value(t, caption.text, "Low")
	testing.expect(t, !text.dropdown_is_open(d), "closed at first")

	// A click opens the list: a copy of the template with a row per option.
	_mouse(0, 100, down = true)
	_mouse(0, 100, up = true)
	testing.expect(t, text.dropdown_is_open(d), "a click opens the list")
	testing.expect(t, engine.transform_active_in_hierarchy(d.list) && !engine.transform_active_in_hierarchy(template), "the copy shows, the template stays hidden")
	rows: [3]^text.DropdownItem
	count := 0
	{
		it := engine.pool_iterator(text.dropdown_items(engine.ctx_world()))
		for found, _ in engine.pool_next(&it) {
			if found.dropdown != node || found.index < 0 do continue
			count += 1
			if found.index < 3 do rows[found.index] = found
		}
	}
	testing.expect_value(t, count, 3)
	if rows[2] == nil do return
	_, high := engine.transform_get_comp(engine.Transform_Handle(rows[2].label.handle), text.Text)
	testing.expect(t, high != nil && high.text == "High", "a row shows its option")
	testing.expect_value(t, mhgui.ui_selected(), rows[0].owner)

	// The submit key on a row picks it and closes the list.
	mhgui.ui_set_selected(rows[2].owner)
	_tap(.RETURN)
	testing.expect_value(t, d.value, i32(2))
	testing.expect(t, text.dropdown_changed(d), "a pick sets changed")
	testing.expect(t, !text.dropdown_is_open(d), "a pick closes the list")
	testing.expect_value(t, mhgui.ui_selected(), node)
	testing.expect_value(t, caption.text, "High")
	engine.transform_destroy_pending()

	// Open by the submit key, closed by Escape with nothing picked.
	_tap(.RETURN)
	testing.expect(t, text.dropdown_is_open(d), "the submit key opens the list")
	_tap(.ESCAPE)
	testing.expect(t, !text.dropdown_is_open(d), "Escape closes the list")
	testing.expect_value(t, d.value, i32(2))
	testing.expect(t, !text.dropdown_changed(d), "nothing picked, nothing changed")
	engine.transform_destroy_pending()

	// A press outside the list lands on the node that covers the canvas.
	_tap(.RETURN)
	testing.expect(t, text.dropdown_is_open(d), "open again")
	_mouse(-300, -200, down = true)
	_mouse(-300, -200, up = true)
	testing.expect(t, !text.dropdown_is_open(d), "a press outside closes the list")
	testing.expect_value(t, d.value, i32(2))
	engine.transform_destroy_pending()
}

// A canvas keeps what it drew until something under it changes. Text typed
// into the same memory, at the same length, is a change too: the canvas's
// fingerprint reads strings by what they hold.
@(test)
test_canvas_fingerprint_reads_strings :: proc(t: ^testing.T) {
	fx: _Fixture
	canvas := _begin(&fx)
	context.user_ptr = &fx.tc.uc
	defer _end(&fx)
	_, tx := _text("Score", canvas, {200, 40})
	buffer := make([]u8, 9)
	defer delete(buffer)
	copy(buffer, "Score: 10")
	tx.text = string(buffer)
	// The Text does not own the buffer: taken back before its cleanup.
	defer tx.text = ""

	before := engine.canvas_fingerprint(canvas)
	testing.expect_value(t, engine.canvas_fingerprint(canvas), before)
	buffer[8] = '1'
	after := engine.canvas_fingerprint(canvas)
	testing.expect(t, after != before, "the same memory with another character is another fingerprint")
	buffer[8] = '0'
	testing.expect_value(t, engine.canvas_fingerprint(canvas), before)
}
