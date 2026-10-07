package tests

// Edit Script: every registered type knows the file and line that declare it,
// and the editor command is built from the developer's template.

import "base:runtime"
import "core:os"
import "core:strings"
import "core:testing"
import core "moonhug:host/core"
import "moonhug:editor/script_editor"
import "moonhug:packages/engine"

@(test)
test_registered_types_record_their_declaration :: proc(t: ^testing.T) {
	n := 0
	for T, meta in core.typeid_to_typeMeta {
		if meta.source == "" do continue
		n += 1
		path, line, ok := core.type_source(T)
		if !testing.expectf(t, ok, "%v: unreadable source %q", T, meta.source) do continue
		if !testing.expectf(t, os.exists(path), "%v: %s does not exist", T, path) do continue
		named, is_named := type_info_of(T).variant.(runtime.Type_Info_Named)
		if !is_named do continue
		// From line 0 the search finds the first declaration, which is the recorded one.
		testing.expectf(t, script_editor.declaration_line(path, named.name, 0) == line, "%v: line %d of %s does not declare it", T, line, path)
	}
	testing.expect(t, n > 0, "no registered type has a source")
}

// A plugin's file is recorded under plugins/, where the link in
// moonhug/packages points, so the editor opens the real file.
@(test)
test_component_source_is_the_plugin_file :: proc(t: ^testing.T) {
	path, _, ok := core.type_source(engine.Camera)
	testing.expect(t, ok)
	testing.expectf(t, strings.has_prefix(path, "plugins/engine/"), "Camera's source is %s", path)
}

@(test)
test_script_editor_command_fills_file_and_line :: proc(t: ^testing.T) {
	cmd := script_editor.script_editor_command("code -g {file}:{line}", "/tmp/a b/camera.odin", 12)
	if testing.expect_value(t, len(cmd), 3) {
		testing.expect_value(t, cmd[0], "code")
		testing.expect_value(t, cmd[1], "-g")
		// A path with a space stays one word.
		testing.expect_value(t, cmd[2], "/tmp/a b/camera.odin:12")
	}
	cmd = script_editor.script_editor_command("  zed   {file}:{line} ", "x.odin", 3)
	if testing.expect_value(t, len(cmd), 2) {
		testing.expect_value(t, cmd[0], "zed")
		testing.expect_value(t, cmd[1], "x.odin:3")
	}
}

// The running editor can be older than the file: a stale line is found again
// by the declaration, and a name with the same prefix does not count.
@(test)
test_declaration_line_follows_a_moved_declaration :: proc(t: ^testing.T) {
	path :: "moonhug/tests/fixtures/_script_editor_tmp.txt"
	text :: "package x\n\nCamera_Like_Proc :: proc() {}\nCamera_Like :: struct {\n}\n"
	testing.expect(t, os.write_entire_file(path, transmute([]u8)string(text)) == nil)
	defer os.remove(path)
	testing.expect_value(t, script_editor.declaration_line(path, "Camera_Like", 4), 4)
	testing.expect_value(t, script_editor.declaration_line(path, "Camera_Like", 2), 4)
	testing.expect_value(t, script_editor.declaration_line(path, "Missing", 2), 2)
}
