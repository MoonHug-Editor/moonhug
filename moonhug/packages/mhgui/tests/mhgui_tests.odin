package mhgui_tests

// RectTransform math, the canvas rect walk and the collector's quad placement.

import "core:math/linalg"
import "core:testing"
import "moonhug:engine"
import mhgui "moonhug:packages/mhgui"
import common "moonhug:tests/common"

@(private = "file")
_add :: proc(tH: engine.Transform_Handle, key: engine.TypeKey) -> rawptr {
	_, ptr := engine.transform_add_comp(tH, key)
	if ptr != nil do (cast(^engine.CompData)ptr).enabled = true
	return ptr
}

@(test)
test_rect_resolve_centered_fixed_size :: proc(t: ^testing.T) {
	rt: mhgui.RectTransform
	mhgui.reset_RectTransform(&rt) // anchors and pivot centered, 100x100
	r := mhgui.rect_resolve(mhgui.Rect{{0, 0}, {800, 600}}, &rt)
	testing.expect_value(t, r.pos, [2]f32{350, 250})
	testing.expect_value(t, r.size, [2]f32{100, 100})
}

@(test)
test_rect_resolve_stretch_with_margins :: proc(t: ^testing.T) {
	rt: mhgui.RectTransform
	rt.anchor_min = {0, 0}
	rt.anchor_max = {1, 1}
	rt.pivot = {0.5, 0.5}
	rt.size_delta = {-20, -20} // 10px margin all around
	r := mhgui.rect_resolve(mhgui.Rect{{0, 0}, {800, 600}}, &rt)
	testing.expect_value(t, r.pos, [2]f32{10, 10})
	testing.expect_value(t, r.size, [2]f32{780, 580})
}

@(test)
test_rect_resolve_bottom_left_offset :: proc(t: ^testing.T) {
	rt: mhgui.RectTransform
	rt.anchor_min = {0, 0}
	rt.anchor_max = {0, 0}
	rt.pivot = {0, 0}
	rt.anchored_position = {16, 8}
	rt.size_delta = {200, 50}
	r := mhgui.rect_resolve(mhgui.Rect{{100, 100}, {800, 600}}, &rt)
	testing.expect_value(t, r.pos, [2]f32{116, 108})
	testing.expect_value(t, r.size, [2]f32{200, 50})
}

@(test)
test_canvas_resolve_rects_walks_in_draw_order :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	canvas := engine.transform_new("Canvas")
	_add(canvas, .Canvas)
	group := engine.transform_new("Group", canvas) // no RectTransform: passes the rect through
	child := engine.transform_new("Child", group)
	rt := cast(^mhgui.RectTransform)_add(child, .RectTransform)
	rt.anchor_min = {0, 0}
	rt.anchor_max = {0, 0}
	rt.pivot = {0, 0}
	rt.anchored_position = {10, 20}
	rt.size_delta = {30, 40}
	hidden := engine.transform_new("Hidden", canvas)
	if ht := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(hidden)); ht != nil do ht.is_active = false
	engine.transform_new("Under hidden", hidden)

	root := mhgui.Rect{{0, 0}, {100, 100}}
	nodes := make([dynamic]mhgui.Node_Rect)
	defer delete(nodes)
	mhgui.canvas_resolve_rects(canvas, root, &nodes)

	testing.expect_value(t, len(nodes), 3)
	if len(nodes) != 3 do return
	testing.expect_value(t, nodes[0].tH, canvas)
	testing.expect_value(t, nodes[0].rect, root)
	testing.expect_value(t, nodes[1].tH, group)
	testing.expect_value(t, nodes[1].rect, root)
	testing.expect_value(t, nodes[2].tH, child)
	testing.expect_value(t, nodes[2].rect, mhgui.Rect{{10, 20}, {30, 40}})
}

@(test)
test_canvas_quad_corners_land_on_pixels :: proc(t: ^testing.T) {
	// Identity view and projection: world == NDC, so the corners read directly.
	view := engine.render_view_make(linalg.MATRIX4F32_IDENTITY, linalg.MATRIX4F32_IDENTITY, 200, 100, 0xFFFFFFFF)
	c := mhgui.canvas_quad_corners(view, mhgui.Rect{{50, 25}, {100, 50}})
	testing.expect_value(t, c[0].xy, [2]f32{-0.5, -0.5}) // bl
	testing.expect_value(t, c[1].xy, [2]f32{0.5, -0.5})  // br
	testing.expect_value(t, c[2].xy, [2]f32{0.5, 0.5})   // tr
	testing.expect_value(t, c[3].xy, [2]f32{-0.5, 0.5})  // tl
	testing.expect(t, c[0].z > 0 && c[0].z < 0.01, "canvas plane sits just inside the near plane")
}

@(test)
test_collect_emits_one_quad_per_renderer_in_game_views :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	canvas := engine.transform_new("Canvas")
	cv := cast(^mhgui.Canvas)_add(canvas, .Canvas)
	cv.sort_order = 3
	image := engine.transform_new("Image", canvas)
	_add(image, .RectTransform)
	cr := cast(^mhgui.CanvasRenderer)_add(image, .CanvasRenderer)
	cr.color = {1, 0, 0, 1}

	view := engine.render_view_make(linalg.MATRIX4F32_IDENTITY, linalg.MATRIX4F32_IDENTITY, 200, 100, 0xFFFFFFFF)
	out := make([dynamic]engine.Render_Command)
	defer delete(out)
	mhgui.collect_canvases(view, &out)
	testing.expect_value(t, len(out), 1)
	if len(out) != 1 do return
	q, is_quad := out[0].variant.(engine.Draw_Quad)
	testing.expect(t, is_quad, "a canvas renderer emits a Draw_Quad")
	testing.expect_value(t, q.color, [4]f32{1, 0, 0, 1})
	testing.expect_value(t, q.texture, mhgui.white_texture_guid())
	// Layer 127 packs to 255 in the top byte: after every sprite layer.
	testing.expect_value(t, out[0].key[0] >> 56, u64(255))

	// Scene views show the world, never the HUD.
	scene_view := engine.render_view_make(linalg.MATRIX4F32_IDENTITY, linalg.MATRIX4F32_IDENTITY, 200, 100, 0xFFFFFFFF, .SceneView)
	clear(&out)
	mhgui.collect_canvases(scene_view, &out)
	testing.expect_value(t, len(out), 0)
}
