package mhgui_tests

// Pointer events (plugins/engine/ui_pointer.odin), driven by real mouse
// events through the pointer pass. A recorder proc on RectTransform, which
// every UI node has, writes down what each node got, and a table says which
// node uses which event, so a test builds a scroll list or a slider out of
// plain nodes. The Button on a node takes the same events through its own
// proc.

import "core:testing"
import "moonhug:packages/engine"
import "moonhug:libs/input"
import sdl "vendor:sdl3"
import mhgui "moonhug:packages/mhgui"
import common "moonhug:tests/common"

@(private = "file")
_Got :: struct {
	kind: engine.UI_Pointer_Kind,
	node: engine.Transform_Handle,
	ev:   engine.UI_Pointer_Event,
}

@(private = "file")
_Use :: struct {
	node:     engine.Transform_Handle,
	kind:     engine.UI_Pointer_Kind,
	own_drag: bool,
}

@(private = "file") _got: [512]_Got
@(private = "file") _got_n: int
@(private = "file") _uses: [16]_Use
@(private = "file") _uses_n: int
@(private = "file") _mouse: [2]f32

@(private = "file")
_record :: proc(comp: rawptr, ev: ^engine.UI_Pointer_Event) {
	if _got_n < len(_got) {
		_got[_got_n] = {ev.kind, ev.node, ev^}
		_got_n += 1
	}
	for u in _uses[:_uses_n] do if u.node == ev.node && u.kind == ev.kind {
		ev.used = true
		if u.own_drag do ev.own_drag = true
	}
}

@(private = "file")
_use :: proc(node: engine.Transform_Handle, kind: engine.UI_Pointer_Kind, own_drag := false) {
	_uses[_uses_n] = {node, kind, own_drag}
	_uses_n += 1
}

// How many events of `kind` the node got since the last _forget.
@(private = "file")
_count :: proc(node: engine.Transform_Handle, kind: engine.UI_Pointer_Kind) -> (n: int) {
	for g in _got[:_got_n] do if g.node == node && g.kind == kind do n += 1
	return
}

@(private = "file")
_last :: proc(node: engine.Transform_Handle, kind: engine.UI_Pointer_Kind) -> engine.UI_Pointer_Event {
	#reverse for g in _got[:_got_n] do if g.node == node && g.kind == kind do return g.ev
	return {}
}

// The place of the first `kind` the node got, -1 for none.
@(private = "file")
_index :: proc(node: engine.Transform_Handle, kind: engine.UI_Pointer_Kind) -> int {
	for g, i in _got[:_got_n] do if g.node == node && g.kind == kind do return i
	return -1
}

@(private = "file")
_forget :: proc() {
	_got_n = 0
}

@(private = "file")
_Pointer_Fixture :: struct {
	tc:   ^common.TestCtx,
	prev: engine.UI_Pointer_Proc,
}

@(private = "file")
_begin :: proc(f: ^_Pointer_Fixture) {
	f.tc = new(common.TestCtx)
	common.setup(f.tc)
	input.set_app_focused(true)
	input.set_viewport({0, 0}, {800, 600})
	engine.ui_pointer_reset()
	f.prev = engine.ui_pointer_procs[.RectTransform]
	engine.ui_pointer_register(.RectTransform, _record)
	_got_n, _uses_n = 0, 0
	_mouse = {-10, -10}
	input.frame_reset()
}

@(private = "file")
_end :: proc(f: ^_Pointer_Fixture) {
	// Let go of every button, so no press leaks into another test.
	for b in ([]u8{1, 2, 3}) do _button(b, false)
	input.frame_reset()
	engine.ui_pointer_reset()
	engine.ui_pointer_register(.RectTransform, f.prev)
	input.set_app_focused(false)
	common.teardown(f.tc)
	free(f.tc)
}

@(private = "file")
_button :: proc(button: u8, down: bool) {
	e: sdl.Event
	e.type = .MOUSE_BUTTON_DOWN if down else .MOUSE_BUTTON_UP
	e.button.button = button
	e.button.down = down
	e.button.x, e.button.y = _mouse.x, _mouse.y
	input.apply_event(&e)
}

// One frame with the mouse at `pos` (viewport pixels, y down), a button
// going down or up, and the wheel turned.
@(private = "file")
_frame :: proc(pos: [2]f32, down: u8 = 0, up: u8 = 0, wheel: f32 = 0) {
	input.frame_reset()
	e: sdl.Event
	e.type = .MOUSE_MOTION
	e.motion.x, e.motion.y = pos.x, pos.y
	e.motion.xrel, e.motion.yrel = pos.x - _mouse.x, pos.y - _mouse.y
	input.apply_event(&e)
	_mouse = pos
	if down != 0 do _button(down, true)
	if up != 0 do _button(up, false)
	if wheel != 0 {
		w: sdl.Event
		w.type = .MOUSE_WHEEL
		w.wheel.y = wheel
		input.apply_event(&w)
	}
	mhgui.ui_tick(0)
}

@(private = "file")
_padd :: proc(tH: engine.Transform_Handle, key: engine.TypeKey) -> rawptr {
	_, ptr := engine.transform_add_comp(tH, key)
	if ptr != nil do (cast(^engine.CompData)ptr).enabled = true
	return ptr
}

// A canvas the pointer reaches, the size of the 800 x 600 viewport.
@(private = "file")
_canvas :: proc() -> engine.Transform_Handle {
	canvas := engine.transform_new("Canvas")
	_padd(canvas, .Canvas)
	_padd(canvas, .GraphicRaycaster)
	return canvas
}

// A node with a rect of `size` at `pos` from its parent's centre. With
// `drawn` it has an Image the pointer hits.
@(private = "file")
_node :: proc(name: string, parent: engine.Transform_Handle, pos: [2]f32, size: [2]f32, drawn := true) -> engine.Transform_Handle {
	node := engine.transform_new(name, parent)
	rt := cast(^engine.RectTransform)_padd(node, .RectTransform)
	engine.type_reset_RectTransform(rt)
	rt.anchored_position = {pos.x, pos.y, 0}
	rt.size_delta = size
	if drawn {
		_padd(node, .CanvasRenderer)
		img := cast(^mhgui.Image)_padd(node, .Image)
		mhgui.type_reset_Image(img)
	}
	return node
}

@(private = "file")
_as_button :: proc(node: engine.Transform_Handle) -> ^mhgui.Button {
	b := cast(^mhgui.Button)_padd(node, .Button)
	mhgui.type_reset_Button(b)
	return b
}

// The screen point of a canvas point given from the canvas centre, y up.
@(private = "file")
_at :: proc(x, y: f32) -> [2]f32 {
	return {400 + x, 300 - y}
}

@(test)
test_pointer_click_goes_to_the_button :: proc(t: ^testing.T) {
	f: _Pointer_Fixture
	_begin(&f)
	context.user_ptr = &f.tc.uc
	defer _end(&f)

	canvas := _canvas()
	root := _node("Root", canvas, {0, 0}, {800, 600}, drawn = false)
	node := _node("Button", root, {0, 0}, {100, 40})
	b := _as_button(node)
	// A label over the button: a child graphic, the node the pointer hits.
	label := _node("Label", node, {0, 0}, {60, 20})

	_frame(_at(0, 0))
	testing.expect(t, b.hovered, "the pointer over its label is over the button")
	testing.expect(t, _index(node, .Enter) < _index(label, .Enter) && _index(node, .Enter) >= 0, "Enter goes to the parent first")
	testing.expect(t, engine.ui_pointer_over_ui(), "the pointer is over UI")

	_frame(_at(0, 0), down = 1)
	testing.expect(t, b.pressed, "Down presses it")
	testing.expect_value(t, b.state, mhgui.Selectable_State.Pressed)
	testing.expect_value(t, _count(label, .Down), 1)
	testing.expect_value(t, _count(root, .Down), 0) // the Button used it
	testing.expect_value(t, engine.ui_selected(), node)

	// Released over another part of the button: still its click.
	_frame(_at(40, 0), up = 1)
	testing.expect(t, b.clicked && !b.pressed, "the release clicks it")
	testing.expect_value(t, _last(node, .Click).click_count, 1)
	_frame(_at(40, 0))
	testing.expect(t, !b.clicked, "clicked lasts one frame")

	// A second click soon after is a double click.
	_frame(_at(40, 0), down = 1)
	_frame(_at(40, 0), up = 1)
	testing.expect_value(t, _last(node, .Click).click_count, 2)

	// Pressed on it and released off it: no click.
	_forget()
	_frame(_at(0, 0), down = 1)
	testing.expect_value(t, b.state, mhgui.Selectable_State.Pressed)
	// Dragged off it with the button still down: it looks let go.
	_frame(_at(300, 200))
	testing.expect(t, b.pressed, "the press is still its own")
	testing.expect_value(t, b.state, mhgui.Selectable_State.Selected)
	// Back over it: pressed again.
	_frame(_at(10, 0))
	testing.expect_value(t, b.state, mhgui.Selectable_State.Pressed)
	_frame(_at(300, 200))
	_frame(_at(300, 200), up = 1)
	testing.expect(t, !b.clicked && !b.pressed, "a release off the button does not click")
	testing.expect_value(t, _count(node, .Up), 1)
	testing.expect(t, !_last(node, .Up).inside, "Up says the pointer is outside")
	testing.expect(t, !b.hovered && !engine.ui_pointer_over_ui(), "and the pointer left the UI")

	// The right button is not the Button's.
	_frame(_at(0, 0), down = 3)
	testing.expect(t, !b.pressed, "the right button does not press it")
	_frame(_at(0, 0), up = 3)
	testing.expect(t, !b.clicked, "nor click it")
}

@(test)
test_pointer_parent_takes_the_drag_from_a_button :: proc(t: ^testing.T) {
	f: _Pointer_Fixture
	_begin(&f)
	context.user_ptr = &f.tc.uc
	defer _end(&f)

	canvas := _canvas()
	// A list that scrolls: a plain node that uses Drag_Begin. It draws nothing.
	list := _node("List", canvas, {0, 0}, {400, 400}, drawn = false)
	_use(list, .Drag_Begin)
	item := _node("Item", list, {0, 0}, {300, 60})
	b := _as_button(item)

	_frame(_at(0, 0))
	_frame(_at(0, 0), down = 1)
	testing.expect(t, b.pressed, "the item is pressed")
	testing.expect_value(t, _count(item, .Hold), 1)
	// Under the threshold: still the button's press.
	_frame(_at(0, 5))
	testing.expect(t, b.pressed && _count(list, .Drag_Begin) == 0, "a small move is no drag")

	_frame(_at(0, 40))
	testing.expect_value(t, _count(item, .Drag_Begin), 1) // asked first, did not use it
	testing.expect_value(t, _count(list, .Drag_Begin), 1)
	testing.expect_value(t, _count(item, .Cancel), 1)
	testing.expect(t, !b.pressed, "the list took the drag: the button's press is cancelled")
	testing.expect_value(t, _last(list, .Drag_Begin).delta, [2]f32{0, -40})

	_frame(_at(0, 70))
	testing.expect_value(t, _count(list, .Drag), 1)
	testing.expect_value(t, _last(list, .Drag).delta, [2]f32{0, -30})
	testing.expect_value(t, _count(item, .Drag), 0)

	_frame(_at(0, 70), up = 1)
	testing.expect_value(t, _count(list, .Drag_End), 1)
	testing.expect_value(t, _count(list, .Up), 1)
	testing.expect(t, !b.clicked, "a drag is no click")
	testing.expect_value(t, _count(item, .Click) + _count(list, .Click), 0)
}

@(test)
test_pointer_press_stays_a_click_when_nothing_drags :: proc(t: ^testing.T) {
	f: _Pointer_Fixture
	_begin(&f)
	context.user_ptr = &f.tc.uc
	defer _end(&f)

	canvas := _canvas()
	node := _node("Button", canvas, {0, 0}, {300, 100})
	b := _as_button(node)
	_frame(_at(-100, 0), down = 1)
	_frame(_at(100, 0))
	_frame(_at(120, 0))
	testing.expect_value(t, _count(node, .Drag_Begin), 1) // offered once, no node took it
	testing.expect(t, b.pressed, "the press goes on")
	_frame(_at(120, 0), up = 1)
	testing.expect(t, b.clicked, "moved far inside the button with nothing to drag: a click")
}

@(test)
test_pointer_own_drag_keeps_the_drag :: proc(t: ^testing.T) {
	f: _Pointer_Fixture
	_begin(&f)
	context.user_ptr = &f.tc.uc
	defer _end(&f)

	canvas := _canvas()
	list := _node("List", canvas, {0, 0}, {400, 400}, drawn = false)
	_use(list, .Drag_Begin)
	// A slider: it uses Down and keeps the drag.
	slider := _node("Slider", list, {0, 0}, {200, 20})
	_use(slider, .Down, own_drag = true)

	_frame(_at(0, 0), down = 1)
	testing.expect_value(t, _count(slider, .Drag_Begin), 1) // at once, no threshold
	_frame(_at(2, 0))
	testing.expect_value(t, _count(slider, .Drag), 1)
	_frame(_at(90, 60))
	testing.expect_value(t, _count(slider, .Drag), 2)
	testing.expect_value(t, _count(list, .Drag_Begin), 0)
	testing.expect_value(t, _count(slider, .Cancel), 0)
	_frame(_at(90, 60), up = 1)
	testing.expect_value(t, _count(slider, .Drag_End), 1)
	testing.expect_value(t, _count(slider, .Click), 0)
}

@(test)
test_pointer_hover_chain_and_common_click :: proc(t: ^testing.T) {
	f: _Pointer_Fixture
	_begin(&f)
	context.user_ptr = &f.tc.uc
	defer _end(&f)

	canvas := _canvas()
	root := _node("Root", canvas, {0, 0}, {800, 600}, drawn = false)
	panel := _node("Panel", root, {0, 0}, {300, 100}, drawn = false)
	left := _node("Left", panel, {-100, 0}, {100, 100})
	right := _node("Right", panel, {100, 0}, {100, 100})

	_frame(_at(-100, 0))
	testing.expect_value(t, _count(panel, .Enter), 1)
	testing.expect_value(t, _count(left, .Enter), 1)
	// From one child to the other: the panel stays entered.
	_frame(_at(100, 0))
	testing.expect_value(t, _count(left, .Exit), 1)
	testing.expect_value(t, _count(right, .Enter), 1)
	testing.expect_value(t, _count(panel, .Exit), 0)
	testing.expect_value(t, _count(panel, .Enter), 1)
	// Between the children the pointer hits nothing: the panel draws nothing.
	_frame(_at(0, 0))
	testing.expect_value(t, _count(panel, .Exit), 1)

	// Pressed on one child and released on the other, with no node using
	// Down: the click is the panel's, the nearest node that holds both.
	_forget()
	_frame(_at(-100, 0), down = 1)
	_frame(_at(100, 0), up = 1)
	testing.expect_value(t, _count(left, .Click) + _count(right, .Click), 0)
	testing.expect_value(t, _count(panel, .Click), 1)
	testing.expect_value(t, _count(root, .Click), 1) // not used: it goes on up
	// While the button was down the hover chain held still.
	testing.expect_value(t, _count(left, .Enter), 1)
	testing.expect_value(t, _count(left, .Exit), 1) // on the release
	testing.expect(t, _index(right, .Enter) > _index(left, .Up), "the hover moves after the release")
}

@(test)
test_pointer_scroll_goes_up_until_used :: proc(t: ^testing.T) {
	f: _Pointer_Fixture
	_begin(&f)
	context.user_ptr = &f.tc.uc
	defer _end(&f)

	canvas := _canvas()
	root := _node("Root", canvas, {0, 0}, {800, 600}, drawn = false)
	outer := _node("Outer", root, {0, 0}, {400, 400}, drawn = false)
	inner := _node("Inner", outer, {0, 0}, {200, 200}, drawn = false)
	item := _node("Item", inner, {0, 0}, {100, 40})
	_use(outer, .Scroll)

	_frame(_at(0, 0), wheel = 1)
	testing.expect_value(t, _count(item, .Scroll), 1)
	testing.expect_value(t, _count(inner, .Scroll), 1) // at its limit: it did not use it
	testing.expect_value(t, _count(outer, .Scroll), 1)
	testing.expect_value(t, _count(root, .Scroll), 0)
	testing.expect_value(t, _last(outer, .Scroll).scroll, [2]f32{0, 1})
	testing.expect_value(t, _last(outer, .Scroll).target, item)

	// The inner one moves: the outer one hears nothing.
	_forget()
	_use(inner, .Scroll)
	_frame(_at(0, 0), wheel = -1)
	testing.expect_value(t, _count(inner, .Scroll), 1)
	testing.expect_value(t, _count(outer, .Scroll), 0)

	// Off every node: no Scroll.
	_forget()
	_frame(_at(390, 290), wheel = 1)
	testing.expect_value(t, _count(item, .Scroll) + _count(inner, .Scroll) + _count(outer, .Scroll) + _count(root, .Scroll), 0)
}

@(test)
test_pointer_hit_area_and_cancel :: proc(t: ^testing.T) {
	f: _Pointer_Fixture
	_begin(&f)
	context.user_ptr = &f.tc.uc
	defer _end(&f)

	canvas := _canvas()
	// A node that draws nothing and takes the pointer through a HitArea.
	area := _node("Area", canvas, {0, 0}, {100, 100}, drawn = false)
	testing.expect_value(t, engine.canvas_raycast(_at(0, 0), {800, 600}), engine.Transform_Handle{})
	_padd(area, .HitArea)
	testing.expect_value(t, engine.canvas_raycast(_at(0, 0), {800, 600}), area)
	b := _as_button(area)

	_frame(_at(0, 0), down = 1)
	testing.expect(t, b.pressed, "a HitArea makes the node pressable")
	// Code takes the pointer away: Cancel, and no Up or Click after.
	engine.ui_pointer_cancel()
	testing.expect_value(t, _count(area, .Cancel), 1)
	testing.expect(t, !b.pressed, "Cancel lets go of the press")
	_frame(_at(0, 0), up = 1)
	testing.expect_value(t, _count(area, .Up) + _count(area, .Click), 0)
	testing.expect(t, !b.clicked, "a cancelled press does not click")

	// The application loses focus during a press.
	_frame(_at(0, 0), down = 1)
	testing.expect(t, b.pressed)
	input.set_app_focused(false)
	_frame(_at(0, 0))
	testing.expect_value(t, _count(area, .Cancel), 2)
	testing.expect(t, !b.pressed && !b.hovered, "losing focus cancels the press and the hover")
	input.set_app_focused(true)
}

// --- ScrollRect and Scrollbar ---------------------------------------------------------

@(private = "file")
_Scroll_Case :: struct {
	root, view, content, item: engine.Transform_Handle,
	scroll:                    ^mhgui.ScrollRect,
	button:                    ^mhgui.Button,
	content_rt:                ^engine.RectTransform,
}

// A 200 x 100 viewport at the canvas centre with a ScrollRect, a 200 x 300
// content under it whose top is the viewport's top, and a button at the
// content's top.
@(private = "file")
_scroll_case :: proc(canvas: engine.Transform_Handle, pos: [2]f32 = {}) -> (c: _Scroll_Case) {
	c.root = _node("Root", canvas, {0, 0}, {800, 600}, drawn = false)
	c.view = _node("View", c.root, pos, {200, 100}, drawn = false)
	c.scroll = cast(^mhgui.ScrollRect)_padd(c.view, .ScrollRect)
	mhgui.type_reset_ScrollRect(c.scroll)
	c.scroll.movement = .Clamped
	c.scroll.inertia = false
	c.content = _node("Content", c.view, {0, -100}, {200, 300})
	_, c.content_rt = engine.transform_get_comp(c.content, engine.RectTransform)
	c.scroll.content.handle = engine.Handle(c.content)
	c.item = _node("Item", c.content, {0, 120}, {150, 40})
	c.button = _as_button(c.item)
	return
}

@(test)
test_scroll_rect_drag_scrolls_and_cancels_the_button :: proc(t: ^testing.T) {
	f: _Pointer_Fixture
	_begin(&f)
	context.user_ptr = &f.tc.uc
	defer _end(&f)
	c := _scroll_case(_canvas())

	testing.expect_value(t, mhgui.scroll_rect_normalized(c.scroll), [2]f32{0, 1}) // at the top
	// The item is at the content's top: canvas (0, 20). Press it and drag up.
	_frame(_at(0, 20))
	_frame(_at(0, 20), down = 1)
	testing.expect(t, c.button.pressed, "the button under the pointer is pressed")
	_frame(_at(0, 50))
	testing.expect(t, c.scroll.dragging && !c.button.pressed, "the drag is the ScrollRect's, the button's press is cancelled")
	_frame(_at(0, 80))
	// The first move past the threshold starts the drag, the next one moves
	// the content by what the pointer moved: 30 up.
	testing.expectf(t, abs(c.content_rt.anchored_position.y - (-70)) < 0.5, "the content follows the pointer up: %v", c.content_rt.anchored_position)
	_frame(_at(0, 80), up = 1)
	testing.expect(t, !c.button.clicked && !c.scroll.dragging, "a drag is no click")
	n := mhgui.scroll_rect_normalized(c.scroll)
	testing.expectf(t, abs(n.y - 0.85) < 0.01, "30 of 200 down from the top: %v", n)

	// Clamped: a drag down past the top stops at the top.
	_frame(_at(0, 0), down = 1)
	_frame(_at(0, -20))
	_frame(_at(0, -200))
	_frame(_at(0, -200), up = 1)
	testing.expectf(t, abs(c.content_rt.anchored_position.y - (-100)) < 0.5, "stopped at the top: %v", c.content_rt.anchored_position)

	// A drag across is not its own: it scrolls up and down only.
	_forget()
	_frame(_at(0, 0), down = 1)
	_frame(_at(60, 0))
	testing.expect(t, !c.scroll.dragging, "a drag across is left to what is above")
	testing.expect_value(t, _count(c.root, .Drag_Begin), 1)
	_frame(_at(60, 0), up = 1)
}

@(test)
test_scroll_rect_wheel_and_nested_axes :: proc(t: ^testing.T) {
	f: _Pointer_Fixture
	_begin(&f)
	context.user_ptr = &f.tc.uc
	defer _end(&f)
	canvas := _canvas()
	c := _scroll_case(canvas)
	// A list that scrolls across, inside the one that scrolls up and down.
	row := _node("Row", c.content, {0, 0}, {150, 60}, drawn = false)
	row_scroll := cast(^mhgui.ScrollRect)_padd(row, .ScrollRect)
	mhgui.type_reset_ScrollRect(row_scroll)
	row_scroll.horizontal, row_scroll.vertical = true, false
	row_scroll.movement, row_scroll.inertia = .Clamped, false
	strip := _node("Strip", row, {75, 0}, {300, 60})
	_, strip_rt := engine.transform_get_comp(strip, engine.RectTransform)
	row_scroll.content.handle = engine.Handle(strip)
	// The row is at the content's centre: canvas (0, -100), out of the
	// viewport. Scroll down to it with the wheel first.
	_frame(_at(0, 0), wheel = -2)
	testing.expectf(t, abs(c.content_rt.anchored_position.y - (-20)) < 0.5, "two notches down is 80 units: %v", c.content_rt.anchored_position)
	_frame(_at(0, 0), wheel = -1)
	_frame(_at(0, 0), wheel = -1)
	_frame(_at(0, 0), wheel = -1)
	testing.expectf(t, abs(c.content_rt.anchored_position.y - 100) < 0.5, "it stops at the bottom: %v", c.content_rt.anchored_position)
	testing.expect_value(t, mhgui.scroll_rect_normalized(c.scroll).y, f32(0))
	// At the bottom the wheel is not used: it goes on up.
	_forget()
	_frame(_at(0, 0), wheel = -1)
	testing.expect_value(t, _count(c.root, .Scroll), 1)
	_frame(_at(0, 0), wheel = 1)
	testing.expect_value(t, _count(c.root, .Scroll), 1) // back in range: used again

	// The row now sits in the viewport. A drag across it scrolls the row, a
	// drag up and down from the same place scrolls the outer list.
	mhgui.scroll_rect_set_normalized(c.scroll, {0, 0.5})
	mid := c.content_rt.anchored_position.y
	_frame(_at(0, 0), down = 1)
	_frame(_at(-30, 0))
	_frame(_at(-60, 0))
	_frame(_at(-60, 0), up = 1)
	testing.expect(t, strip_rt.anchored_position.x < 75 - 20, "a drag across scrolls the inner list")
	testing.expectf(t, abs(c.content_rt.anchored_position.y - mid) < 0.5, "and leaves the outer one: %v", c.content_rt.anchored_position)
	at_x := strip_rt.anchored_position.x
	_frame(_at(0, 0), down = 1)
	_frame(_at(0, 30))
	_frame(_at(0, 60))
	_frame(_at(0, 60), up = 1)
	testing.expect(t, c.content_rt.anchored_position.y > mid + 20, "a drag up and down from the inner list scrolls the outer one")
	testing.expect_value(t, strip_rt.anchored_position.x, at_x)
}

@(test)
test_scroll_rect_coasts_and_comes_back :: proc(t: ^testing.T) {
	f: _Pointer_Fixture
	_begin(&f)
	context.user_ptr = &f.tc.uc
	defer _end(&f)
	c := _scroll_case(_canvas())

	// Inertia: let go with a speed, and the content goes on, slower each step.
	c.scroll.inertia = true
	c.scroll.velocity = {0, 600}
	mhgui.scroll_rect_step(c.scroll, 0.1)
	first := c.content_rt.anchored_position.y + 100
	testing.expect(t, first > 20, "it moved on with its speed")
	mhgui.scroll_rect_step(c.scroll, 0.1)
	second := c.content_rt.anchored_position.y + 100 - first
	testing.expect(t, second > 0 && second < first, "and slower in the next step")
	// A press stops it.
	_frame(_at(0, 0), down = 1)
	testing.expect_value(t, c.scroll.velocity, [2]f32{})
	_frame(_at(0, 0), up = 1)

	// Elastic: pulled past the top it comes back when let go.
	c.scroll.movement = .Elastic
	c.scroll.inertia = false
	mhgui.scroll_rect_set_normalized(c.scroll, {0, 1})
	c.content_rt.anchored_position.y = -140 // 40 past the top
	mhgui.scroll_rect_step(c.scroll, 0.05)
	part := c.content_rt.anchored_position.y
	testing.expect(t, part > -140 && part < -100, "it comes back part of the way in a short step")
	for _ in 0 ..< 60 do mhgui.scroll_rect_step(c.scroll, 0.05)
	testing.expectf(t, abs(c.content_rt.anchored_position.y - (-100)) < 0.1, "and all the way in the end: %v", c.content_rt.anchored_position)

	// Shown: the least scroll that brings a node into the viewport.
	low := _node("Low", c.content, {0, -130}, {100, 20})
	mhgui.scroll_rect_show(c.scroll, low)
	// Its bottom, 140 under the content's centre, sits on the viewport's bottom.
	testing.expectf(t, abs(c.content_rt.anchored_position.y - 90) < 0.5, "the low node is brought to the viewport's bottom edge: %v", c.content_rt.anchored_position)
	mhgui.scroll_rect_show(c.scroll, low)
	testing.expectf(t, abs(c.content_rt.anchored_position.y - 90) < 0.5, "a node already in view moves nothing: %v", c.content_rt.anchored_position)
}

@(test)
test_scrollbar_follows_and_leads :: proc(t: ^testing.T) {
	f: _Pointer_Fixture
	_begin(&f)
	context.user_ptr = &f.tc.uc
	defer _end(&f)
	canvas := _canvas()
	c := _scroll_case(canvas, pos = {-100, 0})
	// A bar 10 wide and 100 tall to the right of the viewport, its handle under it.
	bar_node := _node("Bar", c.root, {50, 0}, {10, 100})
	bar := cast(^mhgui.Scrollbar)_padd(bar_node, .Scrollbar)
	mhgui.type_reset_Scrollbar(bar)
	bar.min_handle = 0
	handle := _node("Handle", bar_node, {0, 0}, {10, 10})
	_, handle_rt := engine.transform_get_comp(handle, engine.RectTransform)
	bar.handle.handle = engine.Handle(handle)
	c.scroll.vertical_scrollbar.handle = engine.Handle(bar_node)

	// It follows: a third of the content shows, at the top.
	mhgui.scroll_rect_step(c.scroll, 0.016)
	testing.expectf(t, abs(bar.size - 1.0 / 3) < 0.01 && bar.value == 1, "size %v value %v", bar.size, bar.value)
	testing.expectf(t, abs(handle_rt.anchor_min.y - 2.0 / 3) < 0.01 && abs(handle_rt.anchor_max.y - 1) < 0.01, "the handle is the top third: %v %v", handle_rt.anchor_min, handle_rt.anchor_max)
	mhgui.scroll_rect_set_normalized(c.scroll, {0, 0})
	mhgui.scroll_rect_step(c.scroll, 0.016)
	testing.expectf(t, bar.value == 0 && abs(handle_rt.anchor_min.y) < 0.01, "at the bottom the handle is the bottom third: %v", handle_rt.anchor_min)

	// It leads: the handle dragged up by half the free track is value 0.5.
	// The bar's centre is canvas (50, 0), the handle's middle at the bottom is y -33.
	_frame(_at(50, -33))
	_frame(_at(50, -33), down = 1)
	testing.expect(t, bar.dragging, "the press on the handle is the bar's")
	_frame(_at(50, 0))
	testing.expectf(t, abs(bar.value - 0.5) < 0.02, "the handle follows the pointer: %v", bar.value)
	mhgui.scroll_rect_step(c.scroll, 0.016)
	testing.expectf(t, abs(mhgui.scroll_rect_normalized(c.scroll).y - 0.5) < 0.02, "and the content follows the bar: %v", mhgui.scroll_rect_normalized(c.scroll))
	_frame(_at(50, 0), up = 1)
	testing.expect(t, !bar.dragging)

	// A press on the track, off the handle, brings the handle's middle there.
	_frame(_at(50, 45), down = 1)
	testing.expectf(t, bar.value > 0.95, "a press near the top of the track goes to the top: %v", bar.value)
	_frame(_at(50, 45), up = 1)
}

// --- Toggle and Slider ----------------------------------------------------------------

@(private = "file")
_toggle :: proc(name: string, parent: engine.Transform_Handle, pos: [2]f32) -> (engine.Transform_Handle, ^mhgui.Toggle, ^engine.CanvasRenderer) {
	node := _node(name, parent, pos, {40, 40})
	t := cast(^mhgui.Toggle)_padd(node, .Toggle)
	mhgui.type_reset_Toggle(t)
	mark := _node("Mark", node, {0, 0}, {20, 20})
	t.graphic.handle = engine.Handle(mark)
	_, cr := engine.transform_get_comp(mark, engine.CanvasRenderer)
	return node, t, cr
}

@(test)
test_toggle_flips_and_groups :: proc(t: ^testing.T) {
	f: _Pointer_Fixture
	_begin(&f)
	context.user_ptr = &f.tc.uc
	defer _end(&f)
	canvas := _canvas()
	root := _node("Root", canvas, {0, 0}, {800, 600}, drawn = false)
	_, alone, alone_mark := _toggle("Alone", root, {0, 200})

	// A click flips it, and the mark shows with it. The mark is a child
	// graphic: the click lands on it and is still the toggle's.
	_frame(_at(0, 200))
	testing.expect(t, !alone_mark.enabled, "off: the mark is hidden")
	_frame(_at(0, 200), down = 1)
	_frame(_at(0, 200), up = 1)
	testing.expect(t, alone.is_on && mhgui.toggle_changed(alone), "a click turns it on")
	testing.expect(t, alone_mark.enabled, "on: the mark shows")
	_frame(_at(0, 200))
	testing.expect(t, !mhgui.toggle_changed(alone), "changed lasts one frame")
	_frame(_at(0, 200), down = 1)
	_frame(_at(0, 200), up = 1)
	testing.expect(t, !alone.is_on && !alone_mark.enabled, "another click turns it off")

	// A group: one on at a time.
	group_node := _node("Group", root, {0, 0}, {300, 60}, drawn = false)
	group := cast(^mhgui.ToggleGroup)_padd(group_node, .ToggleGroup)
	a_node, a, _ := _toggle("A", group_node, {-100, 0})
	_, b, b_mark := _toggle("B", group_node, {0, 0})
	_, c, _ := _toggle("C", group_node, {100, 0})
	for tg in ([]^mhgui.Toggle{a, b, c}) do tg.group.handle = engine.Handle(group_node)
	click :: proc(x: f32) {
		_frame(_at(x, 0), down = 1)
		_frame(_at(x, 0), up = 1)
	}
	click(-100)
	testing.expect(t, a.is_on && !b.is_on && !c.is_on, "A is on")
	click(0)
	testing.expect(t, !a.is_on && b.is_on && !c.is_on, "B on turns A off")
	testing.expect(t, mhgui.toggle_changed(a) && mhgui.toggle_changed(b), "both changed this frame")
	testing.expect(t, b_mark.enabled, "B's mark shows")
	// The on one cannot be clicked off: one stays on.
	click(0)
	testing.expect(t, b.is_on, "a click on the on toggle of a group keeps it on")
	group.allow_switch_off = true
	click(0)
	testing.expect(t, !a.is_on && !b.is_on && !c.is_on, "with allow_switch_off none is on")

	// The submit key flips the selected one.
	engine.ui_set_selected(a_node)
	defer engine.ui_set_selected({})
	input.frame_reset()
	e: sdl.Event
	e.type = .KEY_DOWN
	e.key.scancode = .RETURN
	input.apply_event(&e)
	mhgui.ui_tick(0)
	e.type = .KEY_UP
	input.apply_event(&e)
	testing.expect(t, a.is_on, "Enter turns the selected toggle on")

	// Not interactable: clicks do nothing.
	c.interactable = false
	click(100)
	testing.expect(t, !c.is_on && a.is_on, "a toggle that is not interactable does not flip")
}

@(test)
test_slider_drag_keys_and_parts :: proc(t: ^testing.T) {
	f: _Pointer_Fixture
	_begin(&f)
	context.user_ptr = &f.tc.uc
	defer _end(&f)
	canvas := _canvas()
	root := _node("Root", canvas, {0, 0}, {800, 600}, drawn = false)
	// A list around it that would take a drag across: the slider keeps its own.
	list := _node("List", root, {0, 0}, {400, 200}, drawn = false)
	_use(list, .Drag_Begin)
	// A track 200 wide at the canvas centre, values 0 to 10.
	track := _node("Slider", list, {0, 0}, {200, 20})
	s := cast(^mhgui.Slider)_padd(track, .Slider)
	mhgui.type_reset_Slider(s)
	s.max_value = 10
	fill := _node("Fill", track, {0, 0}, {0, 0}, drawn = false)
	_, fill_rt := engine.transform_get_comp(fill, engine.RectTransform)
	fill_rt.anchor_min, fill_rt.anchor_max = {0, 0}, {1, 1}
	handle := _node("Handle", track, {0, 0}, {16, 30})
	_, handle_rt := engine.transform_get_comp(handle, engine.RectTransform)
	s.fill.handle = engine.Handle(fill)
	s.handle.handle = engine.Handle(handle)

	// A press on the track goes there: a quarter along is 2.5.
	_frame(_at(-50, 0))
	_frame(_at(-50, 0), down = 1)
	testing.expectf(t, abs(s.value - 2.5) < 0.05 && mhgui.slider_changed(s), "the press sets the value: %v", s.value)
	testing.expectf(t, abs(fill_rt.anchor_max.x - 0.25) < 0.01 && fill_rt.anchor_min.x == 0, "the fill covers a quarter: %v", fill_rt.anchor_max)
	testing.expectf(t, abs(handle_rt.anchor_min.x - 0.25) < 0.01 && handle_rt.anchor_min.x == handle_rt.anchor_max.x, "the handle sits at it: %v", handle_rt.anchor_min)
	testing.expect_value(t, handle_rt.size_delta, [2]f32{16, 30}) // its own size stays
	// The drag follows the pointer, and the list around it gets none of it.
	_frame(_at(50, 5))
	testing.expectf(t, abs(s.value - 7.5) < 0.05, "the drag moves it: %v", s.value)
	_frame(_at(500, 5))
	testing.expect_value(t, s.value, f32(10)) // past the end: the end
	testing.expect_value(t, _count(list, .Drag_Begin), 0)
	_frame(_at(500, 5), up = 1)
	testing.expect(t, !s.dragging)
	_frame(_at(500, 5))
	testing.expect(t, !mhgui.slider_changed(s), "changed lasts one frame")

	// Whole numbers.
	s.whole_numbers = true
	_frame(_at(-47, 0), down = 1)
	_frame(_at(-47, 0), up = 1)
	testing.expect_value(t, s.value, f32(3)) // 2.65 is 3

	// Selected, the keys along it change it, and the keys across it move on.
	engine.ui_set_selected(track)
	defer engine.ui_set_selected({})
	key :: proc(k: input.Key) {
		input.frame_reset()
		e: sdl.Event
		e.type = .KEY_DOWN
		e.key.scancode = k
		input.apply_event(&e)
		mhgui.ui_tick(0)
		e.type = .KEY_UP
		input.apply_event(&e)
		input.frame_reset()
	}
	key(.RIGHT)
	testing.expect_value(t, s.value, f32(4))
	key(.LEFT)
	key(.LEFT)
	testing.expect_value(t, s.value, f32(2))
	testing.expect_value(t, engine.ui_selected(), track)
	other := _node("Other", root, {0, 150}, {100, 40})
	_as_button(other)
	key(.UP)
	testing.expect_value(t, engine.ui_selected(), other) // across the slider: the selection moves
	testing.expect_value(t, s.value, f32(2))

	// Right to left: the least value is at the right.
	s.direction = .Right_To_Left
	s.whole_numbers = false
	mhgui.slider_set(s, 2.5)
	testing.expectf(t, abs(fill_rt.anchor_min.x - 0.75) < 0.01 && fill_rt.anchor_max.x == 1, "reversed, the fill grows from the right: %v %v", fill_rt.anchor_min, fill_rt.anchor_max)
}

// The Sprite_Swap transition: the target Image shows the state's sprite, its
// own again for Normal and for a state that has none.
@(test)
test_selectable_sprite_swap :: proc(t: ^testing.T) {
	f: _Pointer_Fixture
	_begin(&f)
	context.user_ptr = &f.tc.uc
	defer _end(&f)
	canvas := _canvas()
	node := _node("Button", canvas, {0, 0}, {100, 40})
	b := _as_button(node)
	b.transition = .Sprite_Swap
	_, img := engine.transform_get_comp(node, mhgui.Image)
	sprite :: proc(n: u8, slice: engine.Local_ID = 0) -> engine.PPtr {
		p: engine.PPtr
		p.guid[0] = n
		p.local_id = slice
		return p
	}
	img.sprite = sprite(1)
	b.sprites.highlighted = sprite(2, 7)
	b.sprites.pressed = sprite(3)

	_frame(_at(300, 200))
	testing.expect_value(t, img.sprite, sprite(1)) // Normal: its own
	_frame(_at(0, 0))
	testing.expect_value(t, img.sprite, sprite(2, 7)) // hovered: the texture and its slice
	_frame(_at(0, 0), down = 1)
	testing.expect_value(t, img.sprite, sprite(3))
	_frame(_at(0, 0), up = 1)
	testing.expect_value(t, img.sprite, sprite(2, 7))
	// Selected has no sprite: the Image's own.
	_frame(_at(300, 200))
	testing.expect_value(t, b.state, mhgui.Selectable_State.Selected)
	testing.expect_value(t, img.sprite, sprite(1))
	// Disabled has none either.
	b.interactable = false
	_frame(_at(0, 0))
	testing.expect_value(t, img.sprite, sprite(1))
	b.sprites.disabled = sprite(4)
	b.interactable = true
	_frame(_at(0, 0))
	b.interactable = false
	_frame(_at(0, 0))
	testing.expect_value(t, img.sprite, sprite(4))
	engine.ui_set_selected({})
}
