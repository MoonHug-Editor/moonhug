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
	_add(image, .CanvasRenderer)
	img := cast(^mhgui.Image)_add(image, .Image)
	img.color = {1, 0, 0, 1}

	view := engine.render_view_make(linalg.MATRIX4F32_IDENTITY, linalg.MATRIX4F32_IDENTITY, 200, 100, 0xFFFFFFFF)
	out := make([dynamic]engine.Render_Command)
	defer delete(out)
	mhgui.collect_canvases(view, &out)
	testing.expect_value(t, len(out), 1)
	if len(out) != 1 do return
	q, is_quad := out[0].variant.(engine.Draw_Quad)
	testing.expect(t, is_quad, "a drawn Image emits a Draw_Quad")
	testing.expect_value(t, q.color, [4]f32{1, 0, 0, 1})
	testing.expect_value(t, q.texture, mhgui.white_texture_guid())
	// Layer 127 packs to 255 in the top byte: after every sprite layer.
	testing.expect_value(t, out[0].key[0] >> 56, u64(255))

	// The scene view draws the canvas as a world rect at the origin, one unit
	// per pixel, sized like the last Game view (200x100 above): the centered
	// 100x100 image starts at (50, 0).
	scene_view := engine.render_view_make(linalg.MATRIX4F32_IDENTITY, linalg.MATRIX4F32_IDENTITY, 640, 480, 0xFFFFFFFF, .SceneView)
	clear(&out)
	mhgui.collect_canvases(scene_view, &out)
	testing.expect_value(t, len(out), 1)
	if len(out) != 1 do return
	sq := out[0].variant.(engine.Draw_Quad)
	testing.expect_value(t, sq.corners[0], [3]f32{50, 0, 0})
	testing.expect_value(t, sq.corners[2], [3]f32{150, 100, 0})

	// Previews show neither.
	preview := engine.render_view_make(linalg.MATRIX4F32_IDENTITY, linalg.MATRIX4F32_IDENTITY, 64, 64, 0xFFFFFFFF, .Preview)
	clear(&out)
	mhgui.collect_canvases(preview, &out)
	testing.expect_value(t, len(out), 0)
}

@(test)
test_rect_drag_edges_keeps_opposite_edge :: proc(t: ^testing.T) {
	parent := mhgui.Rect{{0, 0}, {800, 600}}
	rt: mhgui.RectTransform
	mhgui.reset_RectTransform(&rt) // centered 100x100: x 350..450, y 250..350
	before := mhgui.rect_resolve(parent, &rt)

	// Drag the right edge 20px right: left edge stays, width grows.
	mhgui.rect_drag_edges(&rt, {1, 0}, {20, 0})
	after := mhgui.rect_resolve(parent, &rt)
	testing.expect_value(t, after.pos.x, before.pos.x)
	testing.expect_value(t, after.size.x, before.size.x + 20)
	testing.expect_value(t, after.size.y, before.size.y)

	// Drag the bottom-left corner down-left: top and right edges stay.
	mhgui.rect_drag_edges(&rt, {-1, -1}, {-10, -30})
	moved := mhgui.rect_resolve(parent, &rt)
	testing.expect_value(t, moved.pos.x + moved.size.x, after.pos.x + after.size.x)
	testing.expect_value(t, moved.pos.y + moved.size.y, after.pos.y + after.size.y)
	testing.expect_value(t, moved.size, [2]f32{130, 130})

	// Body drag moves the whole rect.
	mhgui.rect_drag_move(&rt, {5, 7})
	shifted := mhgui.rect_resolve(parent, &rt)
	testing.expect_value(t, shifted.pos, moved.pos + {5, 7})
	testing.expect_value(t, shifted.size, moved.size)
}

@(test)
test_rect_drag_edges_with_corner_pivot :: proc(t: ^testing.T) {
	// Pivot at the bottom-left: dragging the right edge changes only the size.
	parent := mhgui.Rect{{0, 0}, {800, 600}}
	rt: mhgui.RectTransform
	rt.pivot = {0, 0}
	rt.size_delta = {100, 100}
	rt.anchored_position = {40, 40}
	mhgui.rect_drag_edges(&rt, {1, 1}, {25, 15})
	testing.expect_value(t, rt.anchored_position, [2]f32{40, 40})
	testing.expect_value(t, rt.size_delta, [2]f32{125, 115})
	r := mhgui.rect_resolve(parent, &rt)
	testing.expect_value(t, r.pos, [2]f32{40, 40})
}

@(test)
test_image_fit_preserves_aspect_centered :: proc(t: ^testing.T) {
	rect := mhgui.Rect{{100, 100}, {400, 200}}
	// Stretch: the rect itself.
	testing.expect_value(t, mhgui.image_fit(rect, {64, 64}, false), rect)
	// Square sprite in a wide rect: 200x200 centered horizontally.
	fit := mhgui.image_fit(rect, {64, 64}, true)
	testing.expect_value(t, fit, mhgui.Rect{{200, 100}, {200, 200}})
	// Wide sprite in a tall rect: full width, centered vertically.
	tall := mhgui.image_fit(mhgui.Rect{{0, 0}, {100, 400}}, {200, 100}, true)
	testing.expect_value(t, tall, mhgui.Rect{{0, 175}, {100, 50}})
}

@(test)
test_image_uvs_flip_v_for_top_left_rects :: proc(t: ^testing.T) {
	// A 64x32 slice at pixel (64, 0) of a 128x64 texture: right half, top half.
	uvs := mhgui.image_uvs({128, 64}, {64, 0, 64, 32})
	testing.expect_value(t, uvs[0], [2]f32{0.5, 0.5}) // bl
	testing.expect_value(t, uvs[1], [2]f32{1, 0.5})   // br
	testing.expect_value(t, uvs[2], [2]f32{1, 0})     // tr
	testing.expect_value(t, uvs[3], [2]f32{0.5, 0})   // tl
	// The whole texture is imgui's full-quad uvs.
	testing.expect_value(t, mhgui.image_uvs({128, 64}, {0, 0, 128, 64}), engine.QUAD_UVS_FULL)
}
