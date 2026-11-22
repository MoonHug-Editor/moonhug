package mhgui_tests

// A canvas keeps what it drew (engine/ui_canvas_cache.odin): a collect with
// nothing changed makes nothing again, and any change under the canvas is
// seen with no call.

import "core:math/linalg"
import "core:testing"
import "moonhug:packages/engine"
import mhgui "moonhug:packages/mhgui"
import common "moonhug:tests/common"

@(private = "file")
_kadd :: proc(tH: engine.Transform_Handle, key: engine.TypeKey) -> rawptr {
	_, ptr := engine.transform_add_comp(tH, key)
	if ptr != nil do (cast(^engine.CompData)ptr).enabled = true
	return ptr
}

@(private = "file")
_knode :: proc(name: string, parent: engine.Transform_Handle, pos, size: [2]f32) -> (engine.Transform_Handle, ^engine.RectTransform) {
	node := engine.transform_new(name, parent)
	rt := cast(^engine.RectTransform)_kadd(node, .RectTransform)
	engine.type_reset_RectTransform(rt)
	rt.anchored_position = {pos.x, pos.y, 0}
	rt.size_delta = size
	return node, rt
}

// One collect of every canvas. How many quads came out, and how many
// canvases were collected afresh for it.
@(private = "file")
_kcollect :: proc() -> (quads, rebuilt: int, out: [dynamic]engine.Render_Command) {
	view := engine.render_view_make(linalg.MATRIX4F32_IDENTITY, linalg.MATRIX4F32_IDENTITY, 800, 600, 0xFFFFFFFF)
	out = make([dynamic]engine.Render_Command, context.temp_allocator)
	before := engine.canvas_rebuilds
	engine.canvas_collect_graphics(view, &out)
	return len(out), engine.canvas_rebuilds - before, out
}

@(test)
test_canvas_keeps_what_it_drew :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	engine.canvas_kept_clear()
	defer engine.canvas_kept_clear()

	canvas := engine.transform_new("Canvas")
	_kadd(canvas, .Canvas)
	card, card_rt := _knode("Card", canvas, {0, 0}, {200, 100})
	_kadd(card, .CanvasRenderer)
	img := cast(^mhgui.Image)_kadd(card, .Image)
	mhgui.type_reset_Image(img)
	arrow, _ := _knode("Arrow", card, {0, 0}, {50, 50})
	_kadd(arrow, .CanvasRenderer)
	poly := cast(^mhgui.UiPolygon)_kadd(arrow, .UiPolygon)
	mhgui.type_reset_UiPolygon(poly)
	defer mhgui.type_cleanup_UiPolygon(poly)
	poly.antialias = false
	append(&poly.points, [2]f32{0, 0}, [2]f32{1, 0}, [2]f32{0.5, 1})

	quads, rebuilt, _ := _kcollect()
	testing.expect_value(t, quads, 2)
	testing.expect_value(t, rebuilt, 1)
	// Nothing changed: the same quads, nothing made again.
	for _ in 0 ..< 3 {
		quads, rebuilt, _ = _kcollect()
		testing.expect_value(t, quads, 2)
		testing.expect_value(t, rebuilt, 0)
	}

	corner :: proc(out: [dynamic]engine.Render_Command, node: engine.Transform_Handle) -> [3]f32 {
		for cmd in out do if cmd.owner == node do return cmd.variant.(engine.Draw_Quad).corners[0]
		return {}
	}
	color :: proc(out: [dynamic]engine.Render_Command, node: engine.Transform_Handle) -> [4]f32 {
		for cmd in out do if cmd.owner == node do return cmd.variant.(engine.Draw_Quad).color
		return {}
	}

	// A field of a graphic.
	img.color = {1, 0, 0, 1}
	out: [dynamic]engine.Render_Command
	_, rebuilt, out = _kcollect()
	testing.expect_value(t, rebuilt, 1)
	testing.expect_value(t, color(out, card), [4]f32{1, 0, 0, 1})
	// A rect: the child under it moves with it.
	was := corner(out, arrow)
	card_rt.anchored_position.x = 40
	_, rebuilt, out = _kcollect()
	testing.expect_value(t, rebuilt, 1)
	testing.expect(t, corner(out, arrow).x > was.x, "the child followed its parent's rect")
	// A node's own transform.
	engine.pool_get(&engine.ctx_world().transforms, engine.Handle(arrow)).scale = {2, 2, 1}
	_, rebuilt, _ = _kcollect()
	testing.expect_value(t, rebuilt, 1)
	// A list changed in place: the same memory, the same length, another point.
	poly.points[2] = {0.2, 1}
	_, rebuilt, _ = _kcollect()
	testing.expect_value(t, rebuilt, 1)
	// The renderer's tint, which a Button sets.
	_, cr := engine.transform_get_comp(card, engine.CanvasRenderer)
	engine.canvas_renderer_set_tint(cr, {0.5, 0.5, 0.5, 1})
	_, rebuilt, out = _kcollect()
	testing.expect_value(t, rebuilt, 1)
	testing.expect_value(t, color(out, card), [4]f32{0.5, 0, 0, 1})
	// A node switched off, and on again.
	engine.transform_set_active(arrow, false)
	quads, rebuilt, _ = _kcollect()
	testing.expect_value(t, quads, 1)
	testing.expect_value(t, rebuilt, 1)
	engine.transform_set_active(arrow, true)
	quads, rebuilt, _ = _kcollect()
	testing.expect_value(t, quads, 2)
	// A component added: a shadow doubles the card's quads.
	shadow := cast(^mhgui.UiShadow)_kadd(card, .UiShadow)
	mhgui.type_reset_UiShadow(shadow)
	quads, rebuilt, _ = _kcollect()
	testing.expect_value(t, quads, 3)
	testing.expect_value(t, rebuilt, 1)
	// A node added and one taken away.
	extra, _ := _knode("Extra", canvas, {0, 0}, {10, 10})
	_kadd(extra, .CanvasRenderer)
	mhgui.type_reset_Image(cast(^mhgui.Image)_kadd(extra, .Image))
	quads, rebuilt, _ = _kcollect()
	testing.expect_value(t, quads, 4)
	engine.transform_destroy(extra)
	quads, rebuilt, _ = _kcollect()
	testing.expect_value(t, quads, 3)
	testing.expect_value(t, rebuilt, 1)

	// What no component holds, a texture that loaded: said by a call.
	_, rebuilt, _ = _kcollect()
	testing.expect_value(t, rebuilt, 0)
	engine.canvas_content_changed()
	_, rebuilt, _ = _kcollect()
	testing.expect_value(t, rebuilt, 1)
	_, rebuilt, _ = _kcollect()
	testing.expect_value(t, rebuilt, 0)
}

// Controls at rest change nothing from frame to frame, so a canvas of them
// keeps what it drew while the game runs.
@(test)
test_canvas_fingerprint_holds_while_controls_rest :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	mhgui.ui_pointer_reset()
	defer mhgui.ui_pointer_reset()

	canvas := engine.transform_new("Canvas")
	_kadd(canvas, .Canvas)
	_kadd(canvas, .GraphicRaycaster)
	control :: proc(name: string, canvas: engine.Transform_Handle, y: f32, key: engine.TypeKey) -> rawptr {
		node, _ := _knode(name, canvas, {0, y}, {120, 30})
		_kadd(node, .CanvasRenderer)
		mhgui.type_reset_Image(cast(^mhgui.Image)_kadd(node, .Image))
		return _kadd(node, key)
	}
	mhgui.type_reset_Button(cast(^mhgui.Button)control("Button", canvas, 100, .Button))
	mhgui.type_reset_Toggle(cast(^mhgui.Toggle)control("Toggle", canvas, 50, .Toggle))
	mhgui.type_reset_Slider(cast(^mhgui.Slider)control("Slider", canvas, 0, .Slider))
	mhgui.type_reset_ScrollRect(cast(^mhgui.ScrollRect)control("Scroll", canvas, -50, .ScrollRect))

	// The first frames settle the tints.
	for _ in 0 ..< 3 do mhgui.ui_tick(0.016)
	rest := engine.canvas_fingerprint(canvas)
	for frame in 0 ..< 5 {
		mhgui.ui_tick(0.016)
		testing.expectf(t, engine.canvas_fingerprint(canvas) == rest, "frame %d at rest changed something under the canvas", frame)
	}
}
