package mhgui_tests

// UiMask (plugins/engine/ui_canvas.odin): the quads of the nodes under masks
// carry every mask above them, each as the map from a target pixel into the
// mask's own space with its shape, and the pointer does not hit what a mask
// clips away.

import "core:math"
import "core:math/linalg"
import gfx "moonhug:libs/gfx"
import "core:testing"
import "moonhug:packages/engine"
import mhgui "moonhug:packages/mhgui"
import common "moonhug:tests/common"

@(private = "file")
_madd :: proc(tH: engine.Transform_Handle, key: engine.TypeKey) -> rawptr {
	_, ptr := engine.transform_add_comp(tH, key)
	if ptr != nil do (cast(^engine.CompData)ptr).enabled = true
	return ptr
}

@(private = "file")
_mnode :: proc(name: string, parent: engine.Transform_Handle, pos: [2]f32, size: [2]f32, drawn := true) -> (engine.Transform_Handle, ^engine.RectTransform) {
	node := engine.transform_new(name, parent)
	rt := cast(^engine.RectTransform)_madd(node, .RectTransform)
	engine.type_reset_RectTransform(rt)
	rt.anchored_position = {pos.x, pos.y, 0}
	rt.size_delta = size
	if drawn {
		_madd(node, .CanvasRenderer)
		img := cast(^mhgui.Image)_madd(node, .Image)
		mhgui.type_reset_Image(img)
	}
	return node, rt
}

// The Draw_Quad the collector emits for `node` in a 800 x 600 game view.
@(private = "file")
_quad_of :: proc(node: engine.Transform_Handle) -> (engine.Draw_Quad, bool) {
	view := engine.render_view_make(linalg.MATRIX4F32_IDENTITY, linalg.MATRIX4F32_IDENTITY, 800, 600, 0xFFFFFFFF)
	out := make([dynamic]engine.Render_Command, context.temp_allocator)
	engine.canvas_collect_graphics(view, &out)
	for cmd in out do if cmd.owner == node {
		q, ok := cmd.variant.(engine.Draw_Quad)
		return q, ok
	}
	return {}, false
}

@(private = "file")
_near2 :: proc(a, b: [2]f32) -> bool {
	return abs(a.x - b.x) < 1e-3 && abs(a.y - b.y) < 1e-3
}

// Where a mask's map takes a target pixel: the place in the mask's own
// space, from its rect's centre.
@(private = "file")
_mask_at :: proc(m: gfx.Clip_Mask, pixel: [2]f32) -> [2]f32 {
	p := [3]f32{pixel.x, pixel.y, 1}
	h := [3]f32{linalg.dot(m.to[0].xyz, p), linalg.dot(m.to[1].xyz, p), linalg.dot(m.to[2].xyz, p)}
	return h.xy / h.z
}

@(test)
test_mask_gives_its_children_a_clip :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	engine.canvas_set_game_viewport({800, 600})

	canvas := engine.transform_new("Canvas")
	_madd(canvas, .Canvas)
	_madd(canvas, .GraphicRaycaster)
	// A 200 x 100 viewport at the canvas centre, with its own graphic.
	viewport, _ := _mnode("Viewport", canvas, {0, 0}, {200, 100})
	child, _ := _mnode("Child", viewport, {50, 0}, {200, 300})
	other, _ := _mnode("Other", viewport, {0, 0}, {10, 10})
	outside, _ := _mnode("Outside", canvas, {300, 0}, {50, 50})

	q, found := _quad_of(child)
	testing.expect(t, found && len(q.clip) == 0, "with no mask nothing is clipped")

	mask := cast(^engine.UiMask)_madd(viewport, .UiMask)
	mask.corner_radius = {40, 30, 20, 10}
	mask.softness = 6
	q, found = _quad_of(child)
	if !testing.expect(t, found && len(q.clip) == 1, "a node under a mask is clipped to it") do return
	m := q.clip[0]
	testing.expect_value(t, m.shape, [4]f32{100, 50, 6, 0})
	testing.expect_value(t, m.radii, [4]f32{40, 30, 20, 10})
	// The view is 800 x 600 pixels, one canvas unit a pixel, y down: the
	// mask's centre is drawn at (400, 300).
	testing.expectf(t, _near2(_mask_at(m, {400, 300}), {0, 0}), "centre %v", _mask_at(m, {400, 300}))
	testing.expectf(t, _near2(_mask_at(m, {500, 300}), {100, 0}), "right edge %v", _mask_at(m, {500, 300}))
	testing.expectf(t, _near2(_mask_at(m, {400, 250}), {0, 50}), "top edge %v", _mask_at(m, {400, 250}))
	testing.expectf(t, _near2(_mask_at(m, {300, 350}), {-100, -50}), "bottom left %v", _mask_at(m, {300, 350}))

	// Every node under the same masks shares the slice, so their quads merge.
	q2, _ := _quad_of(other)
	testing.expect(t, len(q2.clip) == 1, "the other child is clipped too")
	q, _ = _quad_of(viewport)
	testing.expect(t, len(q.clip) == 0, "the mask's own graphic is not clipped")
	q, _ = _quad_of(outside)
	testing.expect(t, len(q.clip) == 0, "nor a node that is not under it")

	// Turned a quarter turn (counterclockwise): the mask's x axis points up
	// the screen. A pixel above the centre is along the mask's +x.
	engine.pool_get(&tc.world.transforms, engine.Handle(viewport)).rotation = engine.quat_from_euler_xyz(0, 0, 90)
	q, _ = _quad_of(child)
	testing.expectf(t, _near2(_mask_at(q.clip[0], {400, 200}), {100, 0}), "a turned mask clips in its own axes: %v", _mask_at(q.clip[0], {400, 200}))

	// A disabled mask clips nothing.
	engine.pool_get(&tc.world.transforms, engine.Handle(viewport)).rotation = {0, 0, 0, 1}
	mask.enabled = false
	q, _ = _quad_of(child)
	testing.expect(t, len(q.clip) == 0, "a disabled mask clips nothing")
}

// One collect: the quads of two nodes under one mask carry the very same
// slice, which is what lets gfx merge them into one draw.
@(test)
test_mask_children_share_one_clip :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	engine.canvas_set_game_viewport({800, 600})

	canvas := engine.transform_new("Canvas")
	_madd(canvas, .Canvas)
	viewport, _ := _mnode("Viewport", canvas, {0, 0}, {200, 100}, drawn = false)
	_madd(viewport, .UiMask)
	a, _ := _mnode("A", viewport, {0, 0}, {50, 50})
	b, _ := _mnode("B", viewport, {60, 0}, {50, 50})
	view := engine.render_view_make(linalg.MATRIX4F32_IDENTITY, linalg.MATRIX4F32_IDENTITY, 800, 600, 0xFFFFFFFF)
	out := make([dynamic]engine.Render_Command, context.temp_allocator)
	engine.canvas_collect_graphics(view, &out)
	qa, qb: engine.Draw_Quad
	for cmd in out {
		if cmd.owner == a do qa = cmd.variant.(engine.Draw_Quad)
		if cmd.owner == b do qb = cmd.variant.(engine.Draw_Quad)
	}
	testing.expect(t, len(qa.clip) == 1 && raw_data(qa.clip) == raw_data(qb.clip), "two nodes under one mask share the slice")
}

@(test)
test_mask_hides_its_children_from_the_pointer :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	screen := [2]f32{800, 600}
	engine.canvas_set_game_viewport(screen)

	canvas := engine.transform_new("Canvas")
	_madd(canvas, .Canvas)
	_madd(canvas, .GraphicRaycaster)
	viewport, _ := _mnode("Viewport", canvas, {0, 0}, {200, 100}, drawn = false)
	child, _ := _mnode("Child", viewport, {0, 0}, {200, 300})
	// Screen points: the canvas centre is (400, 300), y down.
	inside := [2]f32{400, 300}
	below := [2]f32{400, 300 + 120} // on the child, under the viewport's bottom edge

	testing.expect_value(t, engine.canvas_raycast(inside, screen), child)
	testing.expect_value(t, engine.canvas_raycast(below, screen), child)
	_madd(viewport, .UiMask)
	testing.expect_value(t, engine.canvas_raycast(inside, screen), child)
	testing.expect_value(t, engine.canvas_raycast(below, screen), engine.Transform_Handle{})

	// A mask in a mask: a node is hidden where either cuts it.
	inner, _ := _mnode("Inner", viewport, {0, 0}, {60, 300}, drawn = false)
	_madd(inner, .UiMask)
	leaf, _ := _mnode("Leaf", inner, {0, 0}, {300, 300})
	engine.pool_get(&tc.world.transforms, engine.Handle(child)).is_active = false
	testing.expect_value(t, engine.canvas_raycast(inside, screen), leaf)
	testing.expect_value(t, engine.canvas_raycast({400 + 60, 300}, screen), engine.Transform_Handle{}) // past the inner mask's side
	testing.expect_value(t, engine.canvas_raycast({400, 300 + 80}, screen), engine.Transform_Handle{}) // in the inner, under the outer's edge
}

// A node under several masks is clipped to every one, each with its own shape.
@(test)
test_mask_in_a_mask_clips_to_both :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	engine.canvas_set_game_viewport({800, 600})

	canvas := engine.transform_new("Canvas")
	_madd(canvas, .Canvas)
	// Page 400 x 200, a panel 300 x 300 in it moved 100 right and turned, a
	// list 200 x 100 in the panel. Every one a mask with its own radius.
	page, _ := _mnode("Page", canvas, {0, 0}, {400, 200}, drawn = false)
	(cast(^engine.UiMask)_madd(page, .UiMask)).corner_radius = {30, 30, 30, 30}
	panel, _ := _mnode("Panel", page, {100, 0}, {300, 300}, drawn = false)
	(cast(^engine.UiMask)_madd(panel, .UiMask)).corner_radius = {20, 0, 0, 0}
	engine.pool_get(&tc.world.transforms, engine.Handle(panel)).rotation = engine.quat_from_euler_xyz(0, 0, 30)
	list, _ := _mnode("List", panel, {0, 0}, {200, 100}, drawn = false)
	(cast(^engine.UiMask)_madd(list, .UiMask)).softness = 8
	item, _ := _mnode("Item", list, {0, 0}, {100, 100})

	q, found := _quad_of(item)
	if !testing.expect(t, found && len(q.clip) == 3, "clipped by the list, the panel and the page") do return
	// The nearest first, each with its own shape.
	testing.expect_value(t, q.clip[0].shape, [4]f32{100, 50, 8, 0})
	testing.expect_value(t, q.clip[1].shape, [4]f32{150, 150, 0, 0})
	testing.expect_value(t, q.clip[1].radii, [4]f32{20, 0, 0, 0})
	testing.expect_value(t, q.clip[2].shape, [4]f32{200, 100, 0, 0})
	testing.expect_value(t, q.clip[2].radii, [4]f32{30, 30, 30, 30})
	// The page's centre is the screen's, the panel's is 100 pixels right of it.
	testing.expectf(t, _near2(_mask_at(q.clip[2], {400, 300}), {0, 0}), "page %v", _mask_at(q.clip[2], {400, 300}))
	testing.expectf(t, _near2(_mask_at(q.clip[1], {500, 300}), {0, 0}), "panel %v", _mask_at(q.clip[1], {500, 300}))
	// The panel is turned 30 degrees: a pixel 100 along its turned x axis.
	along := [2]f32{500 + 100 * math.cos_f32(math.to_radians_f32(30)), 300 - 100 * math.sin_f32(math.to_radians_f32(30))}
	testing.expectf(t, _near2(_mask_at(q.clip[1], along), {100, 0}), "along the turned panel %v", _mask_at(q.clip[1], along))
}

// The pointer follows the mask's round corners.
@(test)
test_mask_round_corner_takes_no_pointer :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	screen := [2]f32{800, 600}
	engine.canvas_set_game_viewport(screen)

	canvas := engine.transform_new("Canvas")
	_madd(canvas, .Canvas)
	_madd(canvas, .GraphicRaycaster)
	viewport, _ := _mnode("Viewport", canvas, {0, 0}, {200, 200}, drawn = false)
	mask := cast(^engine.UiMask)_madd(viewport, .UiMask)
	child, _ := _mnode("Child", viewport, {0, 0}, {400, 400})
	// Just inside the viewport's top right corner: screen (400 + 95, 300 - 95).
	corner := [2]f32{495, 205}
	testing.expect_value(t, engine.canvas_raycast(corner, screen), child)
	// A circle: the corner is outside it.
	mask.corner_radius = {100, 100, 100, 100}
	testing.expect_value(t, engine.canvas_raycast(corner, screen), engine.Transform_Handle{})
	testing.expect_value(t, engine.canvas_raycast({400 + 60, 300 - 60}, screen), child) // inside the circle
	// The top right corner left square.
	mask.corner_radius[1] = 0
	testing.expect_value(t, engine.canvas_raycast(corner, screen), child)
	testing.expect_value(t, engine.canvas_raycast({400 - 95, 300 - 95}, screen), engine.Transform_Handle{}) // top left is still round
}

