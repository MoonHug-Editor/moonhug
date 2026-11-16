package editor_tests

// Whether a saved window place can still be reached (editor.window_rect_reachable):
// a monitor left of or above the main one has negative coordinates, and a
// place on a monitor that is gone must not be restored.

import "core:testing"
import editor "moonhug:editor"

@(test)
test_saved_window_place_is_reachable :: proc(t: ^testing.T) {
	main := [4]i32{0, 25, 1920, 1055}
	left := [4]i32{-1920, 0, 1920, 1080}
	both := [][4]i32{main, left}

	testing.expect(t, editor.window_rect_reachable({100, 100, 1200, 800}, both), "on the main display")
	testing.expect(t, editor.window_rect_reachable({-1800, 40, 1200, 800}, both), "on the display to the left: negative x")
	testing.expect(t, !editor.window_rect_reachable({-1800, 40, 1200, 800}, {main}), "that display is gone")
	testing.expect(t, !editor.window_rect_reachable({100, 2000, 1200, 800}, both), "below every display")
	// The title strip a few pixels onto the display is not enough to grab.
	testing.expect(t, !editor.window_rect_reachable({1900, 100, 1200, 800}, {main}), "only its edge shows")
	testing.expect(t, editor.window_rect_reachable({1700, 100, 1200, 800}, {main}), "enough of the title strip shows")
	testing.expect(t, !editor.window_rect_reachable({100, 100, 1200, 800}, nil), "no display at all")
}
