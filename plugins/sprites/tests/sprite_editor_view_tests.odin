package sprites_tests

// The Sprite Editor canvas's placement math (sprites_editor._se_fit): the zoom
// floor and top, the fit that follows the canvas, the scrollbars and the
// centring, and the scroll value a pan maps to. Pure procs, no imgui.

import "core:testing"
import sprites_editor "moonhug:packages/sprites/editor"

@(private = "file")
_near :: proc(a, b: f32) -> bool {
	return abs(a - b) < 0.001
}

// A texture larger than the canvas opens fitted and centred, with no
// scrollbars, and follows the canvas while it sits at the floor.
@(test)
test_sprite_editor_fit_large_texture :: proc(t: ^testing.T) {
	f := sprites_editor._se_fit({1024, 512}, {400, 300}, 10, 0, 0, {})
	testing.expectf(t, _near(f.floor, 0.390625) && _near(f.zoom, f.floor), "opens at the fit, got zoom %v floor %v", f.zoom, f.floor)
	testing.expect(t, !f.need.x && !f.need.y, "a fitted texture has no scrollbars")
	testing.expectf(t, _near(f.pan.x, 0) && _near(f.pan.y, 128), "centred, got %v", f.pan)

	// The canvas narrows: at the floor the zoom follows it.
	g := sprites_editor._se_fit({1024, 512}, {200, 300}, 10, f.zoom, f.floor, f.pan)
	testing.expectf(t, _near(g.zoom, 200.0 / 1024), "the parked zoom follows the canvas, got %v", g.zoom)

	// Zoomed in, the zoom stays and pan is clamped so the texture covers the view.
	h := sprites_editor._se_fit({1024, 512}, {400, 300}, 10, 2, f.floor, {-1000, 10})
	testing.expectf(t, _near(h.zoom, 2), "a zoom above the floor stays, got %v", h.zoom)
	testing.expect(t, h.need.x && h.need.y, "both axes scroll")
	testing.expectf(t, _near(h.view.x, 390) && _near(h.view.y, 290), "the bars take their strips, got %v", h.view)
	testing.expectf(t, _near(h.pan.x, (390.0 - 2048) / 2) && _near(h.pan.y, 0), "pan clamped to the scroll range, got %v", h.pan)
}

// A texture smaller than the canvas opens at 1x, as the Game view's Scale
// floor is min(1, fit), and can still zoom up to the fit.
@(test)
test_sprite_editor_fit_small_texture :: proc(t: ^testing.T) {
	f := sprites_editor._se_fit({32, 32}, {400, 300}, 10, 0, 0, {})
	testing.expectf(t, _near(f.floor, 1) && _near(f.zoom, 1), "opens at 1x, got zoom %v floor %v", f.zoom, f.floor)
	testing.expectf(t, _near(f.pan.x, 184) && _near(f.pan.y, 134), "centred, got %v", f.pan)
	testing.expectf(t, _near(f.top, 32), "the top is the zoom max, got %v", f.top)

	tiny := sprites_editor._se_fit({4, 4}, {400, 300}, 10, 0, 0, {})
	testing.expectf(t, _near(tiny.top, 75), "a tiny texture can zoom to its fit, got %v", tiny.top)
}

// One scrollbar's strip can make the other axis too small.
@(test)
test_sprite_editor_fit_one_bar_brings_the_other :: proc(t: ^testing.T) {
	f := sprites_editor._se_fit({100, 100}, {105, 99}, 10, 1, 0.99, {})
	testing.expect(t, f.need.y, "y is larger than the canvas")
	testing.expect(t, f.need.x, "the y bar's strip makes x larger too")
	testing.expectf(t, _near(f.view.x, 95) && _near(f.view.y, 89), "got %v", f.view)
}

// A pan that came from a scroll value maps back to the same value, so a
// frame with no input does not move the view.
@(test)
test_sprite_editor_scroll_round_trip :: proc(t: ^testing.T) {
	zoom := f32(3)
	for scroll in i64(0) ..< 200 {
		pan := -f32(scroll) / zoom
		testing.expectf(t, sprites_editor._se_scroll_from_pan(pan, zoom) == scroll, "scroll %v round-trips", scroll)
	}
	testing.expect_value(t, sprites_editor._se_scroll_from_pan(-3.3333, 3), 10)
}
