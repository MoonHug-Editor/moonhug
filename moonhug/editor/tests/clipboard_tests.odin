package editor_tests

// The editor's clipboard holds what the last copy took, of one kind: a copy
// of a value, of hierarchy objects or of project files clears the others.

import "core:testing"
import clip "moonhug:editor/clipboard"

@(test)
test_clipboard_copy_clears_other_kinds :: proc(t: ^testing.T) {
	clip.init()
	defer clip.shutdown()

	clip.copy_files({"Assets/a.png", "Assets/b.png"}, cut = true)
	testing.expect_value(t, len(clip.files()), 2)
	testing.expect(t, clip.files_cut(), "a cut is kept")

	hierarchy := make([]byte, 3)
	clip.copy_hierarchy(hierarchy)
	testing.expect(t, clip.has_hierarchy(), "hierarchy copied")
	testing.expect_value(t, len(clip.files()), 0)
	testing.expect(t, !clip.files_cut(), "the cut is gone with the files")

	value := [3]f32{1, 2, 3}
	testing.expect(t, clip.copy(value), "value copied")
	testing.expect(t, clip.can_paste([3]f32), "the value pastes")
	testing.expect(t, !clip.has_hierarchy(), "a value copy clears the hierarchy")

	clip.copy_files({"Assets/c.png"}, cut = false)
	testing.expect(t, !clip.has(), "a file copy clears the value")
	testing.expect(t, !clip.can_paste([3]f32), "nothing of the value pastes")
	testing.expect_value(t, len(clip.files()), 1)

	clip.clear_files()
	testing.expect_value(t, len(clip.files()), 0)
}
