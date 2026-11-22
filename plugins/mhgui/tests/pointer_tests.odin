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
