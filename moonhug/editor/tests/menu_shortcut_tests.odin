package editor_tests

// Menu shortcuts (editor/menu): a chord string parses to imgui's key chord.

import "core:testing"
import im "moonhug:external/odin-imgui"
import "moonhug:editor/menu"

@(test)
test_menu_shortcut_parses_space :: proc(t: ^testing.T) {
	chord, ok := menu._parse_shortcut("Shift+Space")
	testing.expect(t, ok, "Shift+Space parses")
	testing.expect_value(t, chord, im.KeyChord(im.Key.ImGuiMod_Shift) | im.KeyChord(im.Key.Space))
	_, bad := menu._parse_shortcut("Shift+Spacebar")
	testing.expect(t, !bad, "an unknown key does not")
}
