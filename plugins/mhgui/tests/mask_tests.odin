package mhgui_tests

// UiMask (plugins/engine/ui_canvas.odin): the quads of the nodes under a mask
// carry their place in the mask's rect, and the pointer does not hit what
// the mask clips away.

import "core:math/linalg"
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
	// A child as wide as the viewport, 300 tall, moved 50 right.
	child, _ := _mnode("Child", viewport, {50, 0}, {200, 300})
	outside, _ := _mnode("Outside", canvas, {300, 0}, {50, 50})

	q, found := _quad_of(child)
	testing.expect(t, found && !q.clipped, "with no mask nothing is clipped")

	_madd(viewport, .UiMask)
	q, found = _quad_of(child)
	if !testing.expect(t, found && q.clipped, "a node under a mask is clipped") do return
	// Corners bl, br, tr, tl, from the mask's centre in its own units. The
	// child spans x -50..150 and y -150..150, the mask's half size is 100 x 50.
	testing.expect_value(t, q.clip.half, [2]f32{100, 50})
	testing.expectf(t, _near2(q.clip.pos[0], {-50, -150}), "bl %v", q.clip.pos[0])
	testing.expectf(t, _near2(q.clip.pos[1], {150, -150}), "br %v", q.clip.pos[1])
	testing.expectf(t, _near2(q.clip.pos[2], {150, 150}), "tr %v", q.clip.pos[2])
	testing.expectf(t, _near2(q.clip.pos[3], {-50, 150}), "tl %v", q.clip.pos[3])
	testing.expect(t, !q.clip.has_outer, "one mask: no outer rect")
	// The mask's shape goes along.
	_, shaped := engine.transform_get_comp(viewport, engine.UiMask)
	shaped.corner_radius, shaped.softness = 20, 6
	shaped.corners = {.Top_Left, .Bottom_Right}
	q, _ = _quad_of(child)
	testing.expect_value(t, q.clip.radius, f32(20))
	testing.expect_value(t, q.clip.softness, f32(6))
	testing.expect_value(t, q.clip.corners, u8(1 | 4))

	q, _ = _quad_of(viewport)
	testing.expect(t, !q.clipped, "the mask's own graphic is not clipped")
	q, _ = _quad_of(outside)
	testing.expect(t, !q.clipped, "nor a node that is not under it")

	// Turned a quarter turn, the mask's axes swap: what was the child's x
	// extent is measured against the mask's short side.
	engine.pool_get(&tc.world.transforms, engine.Handle(viewport)).rotation = engine.quat_from_euler_xyz(0, 0, 90)
	q, _ = _quad_of(child)
	lo, hi := q.clip.pos[0], q.clip.pos[0]
	for c in q.clip.pos[1:] {
		lo = {min(lo.x, c.x), min(lo.y, c.y)}
		hi = {max(hi.x, c.x), max(hi.y, c.y)}
	}
	// The child turns with its parent, so its place in the mask is the same.
	testing.expectf(t, _near2(lo, {-50, -150}) && _near2(hi, {150, 150}), "a turned mask clips in its own axes: %v %v", lo, hi)

	// A disabled mask clips nothing.
	engine.pool_get(&tc.world.transforms, engine.Handle(viewport)).rotation = {0, 0, 0, 1}
	_, mask := engine.transform_get_comp(viewport, engine.UiMask)
	mask.enabled = false
	q, _ = _quad_of(child)
	testing.expect(t, !q.clipped, "a disabled mask clips nothing")
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

// A node under two or more masks: the nearest one clips with its shape, the
// ones above it are one rect.
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
	// Page 400 x 200, a panel 300 x 300 in it moved 100 right, a list 200 x 100
	// in the panel. Every one a mask.
	page, _ := _mnode("Page", canvas, {0, 0}, {400, 200}, drawn = false)
	_madd(page, .UiMask)
	panel, _ := _mnode("Panel", page, {100, 0}, {300, 300}, drawn = false)
	_madd(panel, .UiMask)
	list, _ := _mnode("List", panel, {0, 0}, {200, 100}, drawn = false)
	_madd(list, .UiMask)
	item, _ := _mnode("Item", list, {0, 0}, {100, 100})

	q, found := _quad_of(item)
	if !testing.expect(t, found && q.clipped && q.clip.has_outer, "clipped by the list, with an outer rect") do return
	testing.expect_value(t, q.clip.half, [2]f32{100, 50}) // the list
	// The outer rect is the panel cut by the page, in the panel's space:
	// the panel spans x -150..150, y -150..150 around its centre, and the
	// page, whose centre is 100 to its left, x -300..100, y -100..100. Together
	// x -150..100, y -100..100: centre (-25, 0), half (125, 100). The item
	// spans -50..50 both ways around the panel's centre.
	testing.expectf(t, _near2(q.clip.outer[0], {(-50 + 25) / 125.0, -0.5}), "bl %v", q.clip.outer[0])
	testing.expectf(t, _near2(q.clip.outer[2], {(50 + 25) / 125.0, 0.5}), "tr %v", q.clip.outer[2])

	// A panel turned against the page is left out of the outer rect: the
	// item is then inside the panel's own rect alone.
	engine.pool_get(&tc.world.transforms, engine.Handle(page)).rotation = engine.quat_from_euler_xyz(0, 0, 30)
	engine.pool_get(&tc.world.transforms, engine.Handle(panel)).rotation = engine.quat_from_euler_xyz(0, 0, -30)
	q, _ = _quad_of(item)
	testing.expectf(t, _near2(q.clip.outer[0], {-50.0 / 150, -50.0 / 150}), "bl %v", q.clip.outer[0])
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
	engine.type_reset_UiMask(mask)
	child, _ := _mnode("Child", viewport, {0, 0}, {400, 400})
	// Just inside the viewport's top right corner: screen (400 + 95, 300 - 95).
	corner := [2]f32{495, 205}
	testing.expect_value(t, engine.canvas_raycast(corner, screen), child)
	// A circle: the corner is outside it.
	mask.corner_radius = 100
	testing.expect_value(t, engine.canvas_raycast(corner, screen), engine.Transform_Handle{})
	testing.expect_value(t, engine.canvas_raycast({400 + 60, 300 - 60}, screen), child) // inside the circle
	// The top right corner left square.
	mask.corners -= {.Top_Right}
	testing.expect_value(t, engine.canvas_raycast(corner, screen), child)
	testing.expect_value(t, engine.canvas_raycast({400 - 95, 300 - 95}, screen), engine.Transform_Handle{}) // top left is still round
}

