package mhgui_tests

// The layout additions: what a row or column gives each child from its
// LayoutElement and the group's expand settings, a node sized to its content
// (ContentSizeFitter), a node kept at a ratio (AspectRatioFitter), and
// CanvasGroup, which fades a subtree and turns it off for the pointer.

import "core:math/linalg"
import "core:testing"
import "moonhug:packages/engine"
import pointer "moonhug:packages/engine/pointer"
import "moonhug:libs/input"
import sdl "vendor:sdl3"
import mhgui "moonhug:packages/mhgui"
import common "moonhug:tests/common"

@(private = "file")
_ladd :: proc(tH: engine.Transform_Handle, key: engine.TypeKey) -> rawptr {
	_, ptr := engine.transform_add_comp(tH, key)
	if ptr != nil do (cast(^engine.CompData)ptr).enabled = true
	return ptr
}

@(private = "file")
_lnode :: proc(name: string, parent: engine.Transform_Handle, size: [2]f32, pos: [2]f32 = {}) -> (engine.Transform_Handle, ^engine.RectTransform) {
	node := engine.transform_new(name, parent)
	rt := cast(^engine.RectTransform)_ladd(node, .RectTransform)
	engine.type_reset_RectTransform(rt)
	rt.size_delta = size
	rt.anchored_position = {pos.x, pos.y, 0}
	return node, rt
}

// The node's resolved rect on a 800 x 600 canvas.
@(private = "file")
_rect_of :: proc(canvas, node: engine.Transform_Handle) -> engine.Rect {
	nodes := make([dynamic]engine.Node_Rect, context.temp_allocator)
	engine.canvas_resolve_rects(canvas, engine.Rect{{0, 0}, {800, 600}}, &nodes)
	for n in nodes do if n.tH == node do return n.rect
	return {}
}

@(private = "file")
_rnear :: proc(t: ^testing.T, got: engine.Rect, pos, size: [2]f32, what: string, loc := #caller_location) {
	ok := abs(got.pos.x - pos.x) < 0.01 && abs(got.pos.y - pos.y) < 0.01 && abs(got.size.x - size.x) < 0.01 && abs(got.size.y - size.y) < 0.01
	testing.expectf(t, ok, "%s: got pos %v size %v, want pos %v size %v", what, got.pos, got.size, pos, size, loc = loc)
}

@(test)
test_layout_distribute_shares_room :: proc(t: ^testing.T) {
	asks := []mhgui.Layout_Sizes{
		{min = {20, 0}, preferred = {100, 0}},
		{min = {50, 0}, preferred = {100, 0}, flexible = {1, 0}},
		{min = {0, 0}, preferred = {100, 0}, flexible = {3, 0}},
	}
	out: [3]f32
	// Exactly what they want.
	mhgui.layout_distribute(asks, 0, 300, false, out[:])
	testing.expect_value(t, out, [3]f32{100, 100, 100})
	// Room left over goes to the flexible ones by their shares.
	mhgui.layout_distribute(asks, 0, 380, false, out[:])
	testing.expect_value(t, out, [3]f32{100, 120, 160})
	// Too little: each gives the same share of what it can give, down to its least.
	mhgui.layout_distribute(asks, 0, 185, false, out[:])
	testing.expect_value(t, out, [3]f32{60, 75, 50}) // half of each one's give of 80, 50, 100
	mhgui.layout_distribute(asks, 0, 10, false, out[:])
	testing.expect_value(t, out, [3]f32{20, 50, 0}) // never under the least
	// With none flexible, expand shares the room alike, and without it they keep their size.
	plain := []mhgui.Layout_Sizes{{preferred = {50, 0}}, {preferred = {100, 0}}}
	two: [2]f32
	mhgui.layout_distribute(plain, 0, 250, true, two[:])
	testing.expect_value(t, two, [2]f32{100, 150})
	mhgui.layout_distribute(plain, 0, 250, false, two[:])
	testing.expect_value(t, two, [2]f32{50, 100})
}

@(test)
test_layout_group_expand_and_elements :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	canvas := engine.transform_new("Canvas")
	_ladd(canvas, .Canvas)
	// A row 400 x 100 at the canvas's bottom left corner region: anchors centre.
	row, _ := _lnode("Row", canvas, {400, 100})
	g := cast(^mhgui.LayoutGroup)_ladd(row, .LayoutGroup)
	mhgui.type_reset_LayoutGroup(g)
	g.direction = .Horizontal
	g.spacing = {10, 0}
	g.child_alignment = .Middle_Left
	a, _ := _lnode("A", row, {50, 40})
	b, _ := _lnode("B", row, {50, 40})
	c, _ := _lnode("C", row, {50, 40})
	// The row spans x 200..600, y 250..350.
	_rnear(t, _rect_of(canvas, a), {200, 280}, {50, 40}, "as before: each its own size")
	_rnear(t, _rect_of(canvas, c), {320, 280}, {50, 40}, "C after two children and two gaps")

	// Expand across: every child as tall as the row.
	g.expand_height = true
	_rnear(t, _rect_of(canvas, b), {260, 250}, {50, 100}, "expand_height fills the row's height")
	// Expand along: the 230 left over (400 less 150 and two gaps) shared alike.
	g.expand_width = true
	_rnear(t, _rect_of(canvas, a), {200, 250}, {126.6667, 100}, "expand_width shares the room")
	_rnear(t, _rect_of(canvas, c), {473.3333, 250}, {126.6667, 100}, "the last one ends at the row's end")

	// A flexible child takes the room left over, the others keep their size.
	el := cast(^mhgui.LayoutElement)_ladd(b, .LayoutElement)
	mhgui.type_reset_LayoutElement(el)
	el.flexible = {1, 0}
	_rnear(t, _rect_of(canvas, a), {200, 250}, {50, 100}, "not flexible: its own width")
	_rnear(t, _rect_of(canvas, b), {260, 250}, {280, 100}, "the flexible one takes the rest")
	// A preferred size replaces the node's own.
	el.flexible = {}
	el.preferred_size = {120, -1}
	g.expand_width = false
	_rnear(t, _rect_of(canvas, b), {260, 250}, {120, 100}, "the LayoutElement's preferred width")
	_rnear(t, _rect_of(canvas, c), {390, 250}, {50, 100}, "C follows it")

	// ignore_layout: the node is left out and keeps its own anchors.
	skip := cast(^mhgui.LayoutElement)_ladd(a, .LayoutElement)
	mhgui.type_reset_LayoutElement(skip)
	skip.ignore_layout = true
	_rnear(t, _rect_of(canvas, a), {375, 280}, {50, 40}, "left out: centred in the row by its own anchors")
	_rnear(t, _rect_of(canvas, b), {200, 250}, {120, 100}, "B is the first of the layout now")
}

@(test)
test_content_size_fitter_sizes_to_children_and_content :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	canvas := engine.transform_new("Canvas")
	_ladd(canvas, .Canvas)

	// A column with a pivot at its top centre: it grows downward.
	list, list_rt := _lnode("List", canvas, {200, 10})
	list_rt.pivot = {0.5, 1}
	g := cast(^mhgui.LayoutGroup)_ladd(list, .LayoutGroup)
	mhgui.type_reset_LayoutGroup(g)
	g.direction = .Vertical
	g.spacing = {0, 5}
	g.padding = {left = 10, right = 10, top = 8, bottom = 12}
	_lnode("One", list, {120, 30})
	_lnode("Two", list, {150, 40})
	_rnear(t, _rect_of(canvas, list), {300, 290}, {200, 10}, "without a fitter: its own size")
	fit := cast(^mhgui.ContentSizeFitter)_ladd(list, .ContentSizeFitter)
	fit.vertical_fit = .Preferred_Size
	// 30 + 5 + 40 and the padding of 20: 95 tall, hanging from the same top.
	_rnear(t, _rect_of(canvas, list), {300, 205}, {200, 95}, "as tall as its children, the top where it was")
	fit.horizontal_fit = .Preferred_Size
	_rnear(t, _rect_of(canvas, list), {315, 205}, {170, 95}, "as wide as its widest child and the padding")
	_lnode("Three", list, {100, 20})
	_rnear(t, _rect_of(canvas, list), {315, 180}, {170, 120}, "a new child makes it taller")

	// A node whose graphic measures itself, here an Image given a measure.
	prev := engine.canvas_measure_procs[.Image]
	engine.canvas_measure_register(.Image, proc(comp: rawptr, width: f32) -> [2]f32 {
		// As a text that wraps: 30 tall with no limit, 60 in 100 or less.
		return {240, 30} if width <= 0 || width > 100 else {width, 60}
	})
	defer engine.canvas_measure_register(.Image, prev)
	label, _ := _lnode("Label", canvas, {100, 10})
	_ladd(label, .CanvasRenderer)
	img := cast(^mhgui.Image)_ladd(label, .Image)
	mhgui.type_reset_Image(img)
	label_fit := cast(^mhgui.ContentSizeFitter)_ladd(label, .ContentSizeFitter)
	label_fit.horizontal_fit, label_fit.vertical_fit = .Preferred_Size, .Preferred_Size
	_rnear(t, _rect_of(canvas, label), {280, 285}, {240, 30}, "both axes: the content's own size")
	label_fit.horizontal_fit = .Unconstrained
	_rnear(t, _rect_of(canvas, label), {350, 270}, {100, 60}, "the height alone: what its width makes it")

	// A LayoutElement's min size.
	el := cast(^mhgui.LayoutElement)_ladd(label, .LayoutElement)
	mhgui.type_reset_LayoutElement(el)
	el.min_size = {0, 44}
	label_fit.vertical_fit = .Min_Size
	_rnear(t, _rect_of(canvas, label), {350, 278}, {100, 44}, "Min_Size takes the LayoutElement's least")

	// In a row, a child with a fitter asks the row for its content's size.
	label_fit.horizontal_fit, label_fit.vertical_fit = .Preferred_Size, .Unconstrained
	el.enabled = false
	row, _ := _lnode("Row", canvas, {400, 50})
	rg := cast(^mhgui.LayoutGroup)_ladd(row, .LayoutGroup)
	mhgui.type_reset_LayoutGroup(rg)
	rg.direction = .Horizontal
	rg.child_alignment = .Middle_Left
	engine.transform_set_parent(label, row)
	_rnear(t, _rect_of(canvas, label), {200, 295}, {240, 10}, "the row gives it its content's width")
}

@(test)
test_aspect_ratio_fitter_modes :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	canvas := engine.transform_new("Canvas")
	_ladd(canvas, .Canvas)
	frame, _ := _lnode("Frame", canvas, {400, 200}) // x 200..600, y 200..400
	pic, pic_rt := _lnode("Pic", frame, {160, 40})
	a := cast(^mhgui.AspectRatioFitter)_ladd(pic, .AspectRatioFitter)
	mhgui.type_reset_AspectRatioFitter(a)
	a.aspect_ratio = 2
	_rnear(t, _rect_of(canvas, pic), {320, 280}, {160, 40}, "None: its own size")
	a.aspect_mode = .Width_Controls_Height
	_rnear(t, _rect_of(canvas, pic), {320, 260}, {160, 80}, "the height follows the width, around the pivot")
	a.aspect_mode = .Height_Controls_Width
	_rnear(t, _rect_of(canvas, pic), {360, 280}, {80, 40}, "the width follows the height")
	// A pivot at the bottom left corner: the corner sits at the frame's
	// centre, where the anchors put the pivot, and the rect grows from it.
	pic_rt.pivot = {0, 0}
	_rnear(t, _rect_of(canvas, pic), {400, 300}, {80, 40}, "a pivot at the corner keeps the corner")
	// The frame is 2 to 1 itself: a 1 to 1 picture fits its height and covers its width.
	a.aspect_ratio = 1
	a.aspect_mode = .Fit_In_Parent
	_rnear(t, _rect_of(canvas, pic), {300, 200}, {200, 200}, "the largest square inside the frame, centred")
	a.aspect_mode = .Envelope_Parent
	_rnear(t, _rect_of(canvas, pic), {200, 100}, {400, 400}, "the smallest square that covers the frame, centred")
}

@(test)
test_canvas_group_fades_and_turns_off :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	input.set_app_focused(true)
	defer input.set_app_focused(false)
	input.set_viewport({0, 0}, {800, 600})
	pointer.reset()
	defer pointer.reset()
	screen := [2]f32{800, 600}
	engine.canvas_set_game_viewport(screen)

	canvas := engine.transform_new("Canvas")
	_ladd(canvas, .Canvas)
	_ladd(canvas, .GraphicRaycaster)
	back, _ := _lnode("Back", canvas, {300, 300})
	_ladd(back, .CanvasRenderer)
	mhgui.type_reset_Image(cast(^mhgui.Image)_ladd(back, .Image))
	panel, _ := _lnode("Panel", canvas, {200, 200})
	inner, _ := _lnode("Inner", panel, {150, 150})
	node, _ := _lnode("Button", inner, {100, 40})
	_ladd(node, .CanvasRenderer)
	img := cast(^mhgui.Image)_ladd(node, .Image)
	mhgui.type_reset_Image(img)
	img.color = {1, 1, 1, 0.8}
	b := cast(^mhgui.Button)_ladd(node, .Button)
	mhgui.type_reset_Button(b)
	b.transition = .None

	alpha :: proc(node: engine.Transform_Handle) -> f32 {
		view := engine.render_view_make(linalg.MATRIX4F32_IDENTITY, linalg.MATRIX4F32_IDENTITY, 800, 600, 0xFFFFFFFF)
		out := make([dynamic]engine.Render_Command, context.temp_allocator)
		engine.canvas_collect_graphics(view, &out)
		for cmd in out do if cmd.owner == node do return cmd.variant.(engine.Draw_Quad).color.a
		return -1
	}
	centre := [2]f32{400, 300}
	testing.expect(t, abs(alpha(node) - 0.8) < 1e-4, "no group: its own alpha")
	testing.expect_value(t, mhgui.canvas_raycast(centre, screen), node)

	// Two groups above it: their alphas multiply.
	outer := cast(^engine.CanvasGroup)_ladd(panel, .CanvasGroup)
	engine.type_reset_CanvasGroup(outer)
	near := cast(^engine.CanvasGroup)_ladd(inner, .CanvasGroup)
	engine.type_reset_CanvasGroup(near)
	outer.alpha, near.alpha = 0.5, 0.5
	testing.expectf(t, abs(alpha(node) - 0.2) < 1e-4, "0.8 times 0.5 times 0.5: %v", alpha(node))
	near.ignore_parent_groups = true
	testing.expectf(t, abs(alpha(node) - 0.4) < 1e-4, "ignore_parent_groups starts over: %v", alpha(node))
	near.ignore_parent_groups = false
	outer.alpha = 0
	testing.expect_value(t, alpha(node), f32(-1)) // fully faded: not drawn

	// blocks_raycasts off: the pointer goes through to what is behind.
	outer.alpha = 1
	outer.blocks_raycasts = false
	testing.expect_value(t, mhgui.canvas_raycast(centre, screen), back)
	outer.blocks_raycasts = true

	// interactable off: the button shows disabled and does not click.
	press :: proc(down: bool) {
		input.frame_reset()
		e: sdl.Event
		e.type = .MOUSE_MOTION
		e.motion.x, e.motion.y = 400, 300
		input.apply_event(&e)
		b: sdl.Event
		b.type = .MOUSE_BUTTON_DOWN if down else .MOUSE_BUTTON_UP
		b.button.button, b.button.down = 1, down
		b.button.x, b.button.y = 400, 300
		input.apply_event(&b)
		mhgui.ui_frame_begin(0)
		pointer.pointer_update(0)
		mhgui.ui_tick(0)
	}
	press(true)
	press(false)
	testing.expect(t, b.clicked, "with the group interactable the button clicks")
	outer.interactable = false
	press(true)
	testing.expect(t, !b.pressed, "a group that is not interactable: no press")
	testing.expect_value(t, b.state, mhgui.Selectable_State.Disabled)
	press(false)
	testing.expect(t, !b.clicked, "and no click")
	input.frame_reset()
}
