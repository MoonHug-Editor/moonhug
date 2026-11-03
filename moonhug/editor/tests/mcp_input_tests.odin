package editor_tests

// The bridge's input tools (editor/mcp_input.odin): the key names a script
// may use, and what a script is refused for before it touches imgui. The
// playback itself needs a drawn frame, so it is verified in a running editor.

import "core:encoding/json"
import "core:testing"
import "moonhug:editor"

@(test)
test_mcp_input_key_names :: proc(t: ^testing.T) {
	key, mod, ok := editor.mcp_input_key("ctrl")
	testing.expect(t, ok && key == .LeftCtrl && mod == .ImGuiMod_Ctrl, "ctrl is the physical Ctrl key with its modifier flag")
	key, mod, ok = editor.mcp_input_key("CMD")
	testing.expect(t, ok && key == .LeftSuper && mod == .ImGuiMod_Super, "cmd is the physical Cmd key, case ignored")
	key, mod, ok = editor.mcp_input_key("enter")
	testing.expect(t, ok && key == .Enter && mod == .None, "an imgui key name resolves without a modifier flag")
	key, _, ok = editor.mcp_input_key("a")
	testing.expect(t, ok && key == .A, "a letter")
	key, _, ok = editor.mcp_input_key("UpArrow")
	testing.expect(t, ok && key == .UpArrow, "imgui's own name")
	key, _, ok = editor.mcp_input_key("up")
	testing.expect(t, ok && key == .UpArrow, "the shorthand")
	_, _, ok = editor.mcp_input_key("MouseLeft")
	testing.expect(t, !ok, "mouse keys are not keys to send")
	_, _, ok = editor.mcp_input_key("ModCtrl")
	testing.expect(t, !ok, "the reserved modifier slots are not keys to send")
	_, _, ok = editor.mcp_input_key("nosuchkey")
	testing.expect(t, !ok)
	_, _, ok = editor.mcp_input_key("")
	testing.expect(t, !ok)
}

@(private = "file")
_params_json :: proc(text: string) -> json.Object {
	v, err := json.parse(transmute([]byte)text, allocator = context.temp_allocator)
	if err != nil do return nil
	obj, _ := v.(json.Object)
	return obj
}

// A script with a step the tool cannot play is refused whole, before any
// step runs.
@(test)
test_mcp_input_refuses_bad_scripts :: proc(t: ^testing.T) {
	cases := []string{
		`{}`,
		`{"steps":[]}`,
		`{"steps":[{"type":"jump"}]}`,
		`{"steps":[{"type":"move","x":1}]}`,
		`{"steps":[{"type":"key","name":"nosuch"}]}`,
		`{"steps":[{"type":"wait","frames":0}]}`,
		`{"steps":[{"type":"down","button":"back"}]}`,
		`{"steps":[{"type":"text","text":""}]}`,
		`{"steps":[{"type":"move","x":1,"y":2},"up"]}`,
		`{"steps":[{"type":"wait","frames":600},{"type":"wait","frames":600},{"type":"wait","frames":600},{"type":"wait","frames":600},{"type":"wait","frames":600},{"type":"wait","frames":600}]}`,
	}
	for c in cases {
		_, err := editor.run_mcp_tool_for_test("input", _params_json(c))
		testing.expectf(t, err.code == "bad_request", "%s: got %q %s", c, err.code, err.message)
	}
}

@(test)
test_mcp_item_rect_needs_a_window :: proc(t: ^testing.T) {
	_, err := editor.run_mcp_tool_for_test("item_rect", _params_json(`{"window":"","label":"duration"}`))
	testing.expect_value(t, err.code, "bad_request")
	_, err = editor.run_mcp_tool_for_test("item_rect", _params_json(`{"window":"no such window","label":"duration"}`))
	testing.expect_value(t, err.code, "not_found")
}
