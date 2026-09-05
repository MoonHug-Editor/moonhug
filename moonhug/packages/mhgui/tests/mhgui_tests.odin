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
	rt: engine.RectTransform
	engine.reset_RectTransform(&rt) // anchors and pivot centered, 100x100
	r := engine.rect_resolve(engine.Rect{{0, 0}, {800, 600}}, &rt)
	testing.expect_value(t, r.pos, [2]f32{350, 250})
	testing.expect_value(t, r.size, [2]f32{100, 100})
}

@(test)
test_rect_resolve_stretch_with_margins :: proc(t: ^testing.T) {
	rt: engine.RectTransform
	rt.anchor_min = {0, 0}
	rt.anchor_max = {1, 1}
	rt.pivot = {0.5, 0.5}
	rt.size_delta = {-20, -20} // 10px margin all around
	r := engine.rect_resolve(engine.Rect{{0, 0}, {800, 600}}, &rt)
	testing.expect_value(t, r.pos, [2]f32{10, 10})
	testing.expect_value(t, r.size, [2]f32{780, 580})
}

@(test)
test_rect_resolve_bottom_left_offset :: proc(t: ^testing.T) {
	rt: engine.RectTransform
	rt.anchor_min = {0, 0}
	rt.anchor_max = {0, 0}
	rt.pivot = {0, 0}
	rt.anchored_position = {16, 8}
	rt.size_delta = {200, 50}
	r := engine.rect_resolve(engine.Rect{{100, 100}, {800, 600}}, &rt)
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
	rt := cast(^engine.RectTransform)_add(child, .RectTransform)
	rt.anchor_min = {0, 0}
	rt.anchor_max = {0, 0}
	rt.pivot = {0, 0}
	rt.anchored_position = {10, 20}
	rt.size_delta = {30, 40}
	hidden := engine.transform_new("Hidden", canvas)
	if ht := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(hidden)); ht != nil do ht.is_active = false
	engine.transform_new("Under hidden", hidden)

	root := engine.Rect{{0, 0}, {100, 100}}
	nodes := make([dynamic]engine.Node_Rect)
	defer delete(nodes)
	engine.canvas_resolve_rects(canvas, root, &nodes)

	testing.expect_value(t, len(nodes), 3)
	if len(nodes) != 3 do return
	testing.expect_value(t, nodes[0].tH, canvas)
	testing.expect_value(t, nodes[0].rect, root)
	testing.expect_value(t, nodes[1].tH, group)
	testing.expect_value(t, nodes[1].rect, root)
	testing.expect_value(t, nodes[2].tH, child)
	testing.expect_value(t, nodes[2].rect, engine.Rect{{10, 20}, {30, 40}})
}

@(test)
test_canvas_quad_corners_land_on_pixels :: proc(t: ^testing.T) {
	// Identity view and projection: world == NDC, so the corners read directly.
	view := engine.render_view_make(linalg.MATRIX4F32_IDENTITY, linalg.MATRIX4F32_IDENTITY, 200, 100, 0xFFFFFFFF)
	flat := engine.rect_corners(engine.Rect{{50, 25}, {100, 50}}, linalg.MATRIX4F32_IDENTITY)
	flat2: [4][2]f32
	for f, i in flat do flat2[i] = f.xy
	c := mhgui.canvas_quad_corners(view, flat2)
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
	cv := cast(^engine.Canvas)_add(canvas, .Canvas)
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
	// per canvas unit, sized like the game viewport (200x100 here): the
	// centered 100x100 image starts at (50, 0).
	engine.canvas_set_game_viewport({200, 100})
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
	parent := engine.Rect{{0, 0}, {800, 600}}
	rt: engine.RectTransform
	engine.reset_RectTransform(&rt) // centered 100x100: x 350..450, y 250..350
	before := engine.rect_resolve(parent, &rt)

	// Drag the right edge 20px right: left edge stays, width grows.
	mhgui.rect_drag_edges(&rt, {1, 0}, {20, 0})
	after := engine.rect_resolve(parent, &rt)
	testing.expect_value(t, after.pos.x, before.pos.x)
	testing.expect_value(t, after.size.x, before.size.x + 20)
	testing.expect_value(t, after.size.y, before.size.y)

	// Drag the bottom-left corner down-left: top and right edges stay.
	mhgui.rect_drag_edges(&rt, {-1, -1}, {-10, -30})
	moved := engine.rect_resolve(parent, &rt)
	testing.expect_value(t, moved.pos.x + moved.size.x, after.pos.x + after.size.x)
	testing.expect_value(t, moved.pos.y + moved.size.y, after.pos.y + after.size.y)
	testing.expect_value(t, moved.size, [2]f32{130, 130})

	// Body drag moves the whole rect.
	mhgui.rect_drag_move(&rt, {5, 7})
	shifted := engine.rect_resolve(parent, &rt)
	testing.expect_value(t, shifted.pos, moved.pos + {5, 7})
	testing.expect_value(t, shifted.size, moved.size)
}

@(test)
test_rect_drag_edges_with_corner_pivot :: proc(t: ^testing.T) {
	// Pivot at the bottom-left: dragging the right edge changes only the size.
	parent := engine.Rect{{0, 0}, {800, 600}}
	rt: engine.RectTransform
	rt.pivot = {0, 0}
	rt.size_delta = {100, 100}
	rt.anchored_position = {40, 40}
	mhgui.rect_drag_edges(&rt, {1, 1}, {25, 15})
	testing.expect_value(t, rt.anchored_position, [2]f32{40, 40})
	testing.expect_value(t, rt.size_delta, [2]f32{125, 115})
	r := engine.rect_resolve(parent, &rt)
	testing.expect_value(t, r.pos, [2]f32{40, 40})
}

@(test)
test_image_fit_preserves_aspect_centered :: proc(t: ^testing.T) {
	rect := engine.Rect{{100, 100}, {400, 200}}
	// Stretch: the rect itself.
	testing.expect_value(t, mhgui.image_fit(rect, {64, 64}, false), rect)
	// Square sprite in a wide rect: 200x200 centered horizontally.
	fit := mhgui.image_fit(rect, {64, 64}, true)
	testing.expect_value(t, fit, engine.Rect{{200, 100}, {200, 200}})
	// Wide sprite in a tall rect: full width, centered vertically.
	tall := mhgui.image_fit(engine.Rect{{0, 0}, {100, 400}}, {200, 100}, true)
	testing.expect_value(t, tall, engine.Rect{{0, 175}, {100, 50}})
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

@(test)
test_scaler_factor_modes :: proc(t: ^testing.T) {
	cs: engine.CanvasScaler
	engine.reset_CanvasScaler(&cs) // scale with screen size, 1920x1080, match 0.5
	testing.expect_value(t, engine.scaler_factor(&cs, {1920, 1080}), 1)
	// Twice the reference in both axes: 2 whatever the match.
	testing.expect_value(t, engine.scaler_factor(&cs, {3840, 2160}), 2)
	// Only the width doubled: match 0 follows width (2), match 1 follows
	// height (1), 0.5 is the geometric mean.
	cs.match = 0
	testing.expect_value(t, engine.scaler_factor(&cs, {3840, 1080}), 2)
	cs.match = 1
	testing.expect_value(t, engine.scaler_factor(&cs, {3840, 1080}), 1)
	cs.match = 0.5
	mid := engine.scaler_factor(&cs, {3840, 1080})
	testing.expect(t, abs(mid - 1.4142135) < 1e-4, "match 0.5 is the geometric mean of width and height scale")

	cs.mode = .Constant_Pixel_Size
	cs.scale_factor = 3
	testing.expect_value(t, engine.scaler_factor(&cs, {640, 480}), 3)
}

@(test)
test_layout_horizontal_and_vertical :: proc(t: ^testing.T) {
	g: mhgui.LayoutGroup
	mhgui.reset_LayoutGroup(&g) // spacing 8
	g.padding = {left = 10, right = 10, top = 5, bottom = 5}
	area := engine.Rect{{0, 0}, {300, 100}}
	sizes := [][2]f32{{40, 20}, {60, 30}}
	out := make([]engine.Rect, 2)
	defer delete(out)

	// Row, upper-left: starts at the padded left, tops at the padded top.
	g.direction = .Horizontal
	g.child_alignment = .Upper_Left
	mhgui.layout_arrange(&g, area, sizes, out)
	testing.expect_value(t, out[0], engine.Rect{{10, 75}, {40, 20}})
	testing.expect_value(t, out[1], engine.Rect{{58, 65}, {60, 30}})

	// Row, middle-center: the 108-wide run centered in the 280-wide area,
	// each child centered vertically.
	g.child_alignment = .Middle_Center
	mhgui.layout_arrange(&g, area, sizes, out)
	testing.expect_value(t, out[0], engine.Rect{{96, 40}, {40, 20}})
	testing.expect_value(t, out[1], engine.Rect{{144, 35}, {60, 30}})

	// Column, upper-left: hangs from the padded top, left-aligned.
	g.direction = .Vertical
	g.child_alignment = .Upper_Left
	mhgui.layout_arrange(&g, area, sizes, out)
	testing.expect_value(t, out[0], engine.Rect{{10, 75}, {40, 20}})
	testing.expect_value(t, out[1], engine.Rect{{10, 37}, {60, 30}})

	// Column, lower-right: sits on the padded bottom, right-aligned.
	g.child_alignment = .Lower_Right
	mhgui.layout_arrange(&g, area, sizes, out)
	testing.expect_value(t, out[1], engine.Rect{{230, 5}, {60, 30}})
	testing.expect_value(t, out[0], engine.Rect{{250, 43}, {40, 20}})
}

@(test)
test_layout_grid_fills_rows_from_the_top :: proc(t: ^testing.T) {
	g: mhgui.LayoutGroup
	mhgui.reset_LayoutGroup(&g)
	g.direction = .Grid
	g.cell_size = {50, 50}
	g.spacing = {10, 10}
	g.child_alignment = .Upper_Left
	sizes := [][2]f32{{0, 0}, {0, 0}, {0, 0}, {0, 0}, {0, 0}} // grid ignores child sizes
	out := make([]engine.Rect, 5)
	defer delete(out)

	// Flexible: 170 wide fits 3 columns (3*50 + 2*10 = 170), so 2 rows.
	area := engine.Rect{{0, 0}, {170, 200}}
	mhgui.layout_arrange(&g, area, sizes, out)
	testing.expect_value(t, out[0], engine.Rect{{0, 150}, {50, 50}})
	testing.expect_value(t, out[2], engine.Rect{{120, 150}, {50, 50}})
	testing.expect_value(t, out[3], engine.Rect{{0, 90}, {50, 50}})

	// Fixed 2 columns: 3 rows.
	g.constraint = .Fixed_Column_Count
	g.constraint_count = 2
	mhgui.layout_arrange(&g, area, sizes, out)
	testing.expect_value(t, out[1], engine.Rect{{60, 150}, {50, 50}})
	testing.expect_value(t, out[4], engine.Rect{{0, 30}, {50, 50}})
}

@(test)
test_canvas_resolve_rects_applies_layout_and_scaler :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	mhgui.mhgui_package_init() // the LayoutGroup provider joins the engine's rect walk
	canvas := engine.transform_new("Canvas")
	_add(canvas, .Canvas)
	cs := cast(^engine.CanvasScaler)_add(canvas, .CanvasScaler)
	cs.mode = .Constant_Pixel_Size
	cs.scale_factor = 2

	// A row of two 50x20 items under the canvas.
	row := engine.transform_new("Row", canvas)
	rrt := cast(^engine.RectTransform)_add(row, .RectTransform)
	rrt.anchor_min = {0, 0}
	rrt.anchor_max = {0, 0}
	rrt.pivot = {0, 0}
	rrt.anchored_position = {100, 100}
	rrt.size_delta = {300, 40}
	g := cast(^mhgui.LayoutGroup)_add(row, .LayoutGroup)
	g.direction = .Horizontal
	g.spacing = {10, 0}
	g.child_alignment = .Lower_Left
	for i in 0 ..< 2 {
		item := engine.transform_new("Item", row)
		rt := cast(^engine.RectTransform)_add(item, .RectTransform)
		rt.size_delta = {50, 20}
		rt.anchored_position = {999, 999} // ignored under a layout
		_ = i
	}

	// Game view 400x300 at scale 2: the canvas is 200x150 units.
	view := engine.render_view_make(linalg.MATRIX4F32_IDENTITY, linalg.MATRIX4F32_IDENTITY, 400, 300, 0xFFFFFFFF)
	root := engine.canvas_rect(view, canvas)
	testing.expect_value(t, root.size, [2]f32{200, 150})

	nodes := make([dynamic]engine.Node_Rect)
	defer delete(nodes)
	engine.canvas_resolve_rects(canvas, root, &nodes)
	testing.expect_value(t, len(nodes), 4)
	if len(nodes) != 4 do return
	testing.expect_value(t, nodes[1].rect, engine.Rect{{100, 100}, {300, 40}})
	testing.expect_value(t, nodes[2].rect, engine.Rect{{100, 100}, {50, 20}})
	testing.expect_value(t, nodes[3].rect, engine.Rect{{160, 100}, {50, 20}})
}

@(test)
test_position_api_converts_through_anchored_position :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	engine.canvas_set_game_viewport({200, 100})
	canvas := engine.transform_new("Canvas")
	_add(canvas, .Canvas)
	image := engine.transform_new("Image", canvas)
	rt := cast(^engine.RectTransform)_add(image, .RectTransform)
	engine.reset_RectTransform(rt) // anchors and pivot centered, 100x100

	// Centered image: local position is relative to the canvas center, which
	// is also its anchor reference point, so local == anchored.
	testing.expect_value(t, engine.transform_local_position(image), [3]f32{0, 0, 0})
	engine.transform_set_local_position(image, {10, 20, 0})
	testing.expect_value(t, rt.anchored_position, [2]f32{10, 20})
	testing.expect_value(t, engine.transform_local_position(image), [3]f32{10, 20, 0})
	// World position is the pivot on the canvas plane.
	testing.expect_value(t, engine.transform_world_position(image), [3]f32{110, 70, 0})
	engine.transform_set_world_position(image, {30, 40, 0})
	testing.expect_value(t, rt.anchored_position, [2]f32{-70, -10})

	// Bottom-left anchored: the anchor reference is the canvas corner, so
	// anchored and local differ by the parent pivot (the canvas center).
	rt.anchor_min = {0, 0}
	rt.anchor_max = {0, 0}
	rt.anchored_position = {0, 0}
	testing.expect_value(t, engine.transform_local_position(image), [3]f32{-100, -50, 0})
	engine.transform_set_local_position(image, {0, 0, 0})
	testing.expect_value(t, rt.anchored_position, [2]f32{100, 50})

	// The Transform's own position never took part.
	tr := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(image))
	testing.expect_value(t, tr.position, [3]f32{0, 0, 0})
}

@(test)
test_rotation_and_scale_apply_around_pivot :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	engine.canvas_set_game_viewport({200, 100})
	canvas := engine.transform_new("Canvas")
	_add(canvas, .Canvas)
	panel := engine.transform_new("Panel", canvas)
	prt := cast(^engine.RectTransform)_add(panel, .RectTransform)
	engine.reset_RectTransform(prt) // 100x100 centered: 50..150 x 0..100, pivot (100, 50)
	pt := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(panel))
	pt.rotation = engine.quat_from_euler_xyz(0, 0, 90)

	nodes := make([dynamic]engine.Node_Rect)
	defer delete(nodes)
	engine.canvas_resolve_rects(canvas, engine.canvas_world_rect(canvas), &nodes)
	testing.expect_value(t, len(nodes), 2)
	if len(nodes) != 2 do return
	// The rect itself stays axis-aligned in the parent's space...
	testing.expect_value(t, nodes[1].rect, engine.Rect{{50, 0}, {100, 100}})
	// ...the corners rotate 90 degrees counter-clockwise around the pivot:
	// bottom-left (50, 0) lands at (150, 0).
	c := engine.rect_corners(nodes[1].rect, nodes[1].xform)
	testing.expect(t, linalg.length(c[0] - [3]f32{150, 0, 0}) < 1e-3, "rotated bl corner")
	testing.expect(t, linalg.length(c[2] - [3]f32{50, 100, 0}) < 1e-3, "rotated tr corner")

	// Scale 2 around the pivot: bl at (0, -50). Rotation off first.
	pt.rotation = engine.QUAT_IDENTITY
	pt.scale = {2, 2, 1}
	clear(&nodes)
	engine.canvas_resolve_rects(canvas, engine.canvas_world_rect(canvas), &nodes)
	c = engine.rect_corners(nodes[1].rect, nodes[1].xform)
	testing.expect(t, linalg.length(c[0] - [3]f32{0, -50, 0}) < 1e-3, "scaled bl corner")

	// A tilt around Y by 90 degrees folds the rect edge-on: every corner
	// lands on the pivot's x, its depth carrying the width.
	pt.scale = {1, 1, 1}
	pt.rotation = engine.quat_from_euler_xyz(0, 90, 0)
	clear(&nodes)
	engine.canvas_resolve_rects(canvas, engine.canvas_world_rect(canvas), &nodes)
	c = engine.rect_corners(nodes[1].rect, nodes[1].xform)
	for k in 0 ..< 4 do testing.expect(t, abs(c[k].x - 100) < 1e-3, "Y tilt keeps every corner on the pivot's x")
	testing.expect(t, abs(abs(c[0].z) - 50) < 1e-3, "Y tilt turns width into depth")
	pt.rotation = engine.QUAT_IDENTITY
	pt.scale = {2, 2, 1}

	// A child inherits the chain: a 10x10 child at the panel's bottom-left
	// anchor, pivot (0, 0), sits at the panel's scaled bottom-left corner.
	child := engine.transform_new("Child", panel)
	crt := cast(^engine.RectTransform)_add(child, .RectTransform)
	crt.anchor_min = {0, 0}
	crt.anchor_max = {0, 0}
	crt.pivot = {0, 0}
	crt.size_delta = {10, 10}
	clear(&nodes)
	engine.canvas_resolve_rects(canvas, engine.canvas_world_rect(canvas), &nodes)
	testing.expect_value(t, len(nodes), 3)
	if len(nodes) != 3 do return
	cc := engine.rect_corners(nodes[2].rect, nodes[2].xform)
	testing.expect(t, linalg.length(cc[0] - [3]f32{0, -50, 0}) < 1e-3, "child bl follows the scaled parent")
	testing.expect(t, linalg.length(cc[2] - [3]f32{20, -30, 0}) < 1e-3, "child size scales with the parent")
	// And its world position through the Transform API is that corner.
	testing.expect(t, linalg.length(engine.transform_world_position(child) - [3]f32{0, -50, 0}) < 1e-3, "world position through the chain")
}
