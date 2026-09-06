package tests

// Game view size math (editor/view_game.odin): the rect the game renders into
// for each kind of entry in the size list, plus the flip and scale modifiers.

import "../editor"
import im "moonhug:external/odin-imgui"
import "core:testing"

@(private = "file")
_rect :: proc(index: int, flipped: bool, scale: f32, area: im.Vec2) -> im.Vec2 {
	old_index, old_flip, old_scale := editor.game_size_index, editor.game_size_flipped, editor.game_scale
	defer {
		editor.game_size_index = old_index
		editor.game_size_flipped = old_flip
		editor.game_scale = old_scale
	}
	editor.game_size_index = index
	editor.game_size_flipped = flipped
	editor.game_scale = scale
	return editor.game_target_rect(area)
}

// Index of the first entry matching `label`, so the tests survive list edits.
@(private = "file")
_index_of :: proc(label: cstring) -> int {
	for e, i in editor.GAME_SIZES {
		if e.label == label do return i
	}
	return -1
}

@(test)
game_size_free_aspect_fills_area :: proc(t: ^testing.T) {
	idx := _index_of("Free Aspect")
	testing.expect(t, idx >= 0, "Free Aspect entry exists")
	got := _rect(idx, false, 1, {800, 600})
	testing.expect_value(t, got, im.Vec2{800, 600})
}

@(test)
game_size_aspect_letterboxes :: proc(t: ^testing.T) {
	idx := _index_of("16:9")
	testing.expect(t, idx >= 0, "16:9 entry exists")
	// A 4:3 area fits 16:9 by width, leaving bars above and below.
	got := _rect(idx, false, 1, {800, 600})
	testing.expect_value(t, got, im.Vec2{800, 450})
}

@(test)
game_size_fixed_resolution_is_exact_when_it_fits :: proc(t: ^testing.T) {
	idx := _index_of("1280x720 HD")
	testing.expect(t, idx >= 0, "1280x720 entry exists")
	got := _rect(idx, false, 1, {1600, 1000})
	testing.expect_value(t, got, im.Vec2{1280, 720})
}

@(test)
game_size_zoom_one_is_actual_pixels_even_when_larger_than_the_view :: proc(t: ^testing.T) {
	idx := _index_of("1280x720 HD")
	// Zoom 1 means actual pixels; a rect larger than the view overflows it,
	// and the zoom FLOOR is what brings it back into view.
	got := _rect(idx, false, 1, {640, 1000})
	testing.expect_value(t, got, im.Vec2{1280, 720})
}

@(test)
game_min_scale_fits_a_resolution_larger_than_the_view :: proc(t: ^testing.T) {
	old := editor.game_size_index
	defer editor.game_size_index = old
	editor.game_size_index = _index_of("1280x720 HD")
	// Half the width it needs: the floor is the zoom that fits.
	testing.expect_value(t, editor.game_min_scale({640, 1000}), f32(0.5))
}

@(test)
game_min_scale_is_one_when_the_resolution_fits :: proc(t: ^testing.T) {
	old := editor.game_size_index
	defer editor.game_size_index = old
	editor.game_size_index = _index_of("1280x720 HD")
	// Never above 1: a small size stays at its own pixels, not blown up.
	testing.expect_value(t, editor.game_min_scale({1920, 1200}), f32(1))
}

@(test)
game_min_scale_is_one_for_an_aspect :: proc(t: ^testing.T) {
	old := editor.game_size_index
	defer editor.game_size_index = old
	editor.game_size_index = _index_of("16:9")
	// An aspect already fits by construction, so its floor is 1.
	testing.expect_value(t, editor.game_min_scale({640, 1000}), f32(1))
}

@(test)
game_size_zoom_is_capped_at_the_max :: proc(t: ^testing.T) {
	idx := _index_of("1280x720 HD")
	// Above GAME_SCALE_MAX the rect stops growing.
	got := _rect(idx, false, 99, {1600, 1000})
	testing.expect_value(t, got, im.Vec2{1280 * editor.GAME_SCALE_MAX, 720 * editor.GAME_SCALE_MAX})
}

@(test)
game_size_flip_swaps_width_and_height :: proc(t: ^testing.T) {
	idx := _index_of("1280x720 HD")
	got := _rect(idx, true, 1, {1600, 1400})
	testing.expect_value(t, got, im.Vec2{720, 1280})
}

@(test)
game_size_flip_does_nothing_for_free_aspect :: proc(t: ^testing.T) {
	idx := _index_of("Free Aspect")
	got := _rect(idx, true, 1, {800, 600})
	testing.expect_value(t, got, im.Vec2{800, 600})
}

@(test)
game_size_free_aspect_ignores_zoom :: proc(t: ^testing.T) {
	idx := _index_of("Free Aspect")
	got := _rect(idx, false, 3, {800, 600})
	testing.expect_value(t, got, im.Vec2{800, 600})
}

@(test)
game_size_scale_multiplies_the_rect :: proc(t: ^testing.T) {
	idx := _index_of("1280x720 HD")
	got := _rect(idx, false, 2, {1600, 1000})
	testing.expect_value(t, got, im.Vec2{2560, 1440})
}

@(test)
game_size_index_out_of_range_clamps :: proc(t: ^testing.T) {
	// A settings file naming an entry the list no longer has must not crash.
	got := _rect(9999, false, 1, {800, 600})
	testing.expect(t, got.x > 0 && got.y > 0, "clamped index yields a usable rect")
}
