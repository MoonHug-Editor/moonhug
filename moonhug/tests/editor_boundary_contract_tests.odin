package tests

// The editor is a generic shell (dock, views, menus, inspector reflection,
// undo stack, settings, console, MCP) standing on the host packages, and the
// engine is a plugin like any other (plugins/engine, its editor half in
// plugins/engine/editor). The rule: no hand-written file under moonhug/editor,
// moonhug/host or moonhug/registration imports the engine. Generated files
// are skipped, they are the composition point and import every installed
// package. main.odin may import moonhug:registration, the bundle that
// registers every installed package: that is where the shell is composed with
// the plugins.
//
// Any import form counts: `moonhug:packages/engine`,
// `moonhug:packages/engine/...`, `moonhug:registration` outside main.odin,
// and relative paths that reach the engine.

import "core:os"
import "core:strings"
import "core:testing"

_SHELL_ROOTS := []string{"moonhug/editor", "moonhug/host", "moonhug/registration"}

// The composition point, the one file allowed to import moonhug:registration.
_SHELL_COMPOSITION_FILE :: "moonhug/editor/main.odin"

@(test)
test_shell_imports_no_engine :: proc(t: ^testing.T) {
	seen := 0
	for root in _SHELL_ROOTS {
		files := make([dynamic]string, context.temp_allocator)
		_collect_odin_files(root, &files)
		for path in files {
			if strings.has_suffix(path, "_generated.odin") do continue
			data, rerr := os.read_entire_file(path, context.temp_allocator)
			if rerr != nil do continue
			seen += 1
			allow_registration := path == _SHELL_COMPOSITION_FILE
			if line, bad := _imports_engine(string(data), allow_registration); bad {
				testing.expectf(t, false, "%s imports the engine: %s. The shell must not depend on the engine plugin, move the code into plugins/engine/editor", path, line)
			}
		}
	}
	testing.expect(t, seen > 100, "the walk should see the shell's sources")
}

_imports_engine :: proc(src: string, allow_registration: bool) -> (line: string, bad: bool) {
	text := src
	for raw in strings.split_lines_iterator(&text) {
		l := strings.trim_space(raw)
		if !strings.has_prefix(l, "import ") do continue
		q := strings.index_byte(l, '"')
		if q < 0 do continue
		path := l[q + 1:]
		if strings.has_prefix(path, "moonhug:packages/engine\"") || strings.has_prefix(path, "moonhug:packages/engine/") do return l, true
		// The registration bundle imports the engine and every installed package.
		if strings.has_prefix(path, "moonhug:registration\"") && !allow_registration do return l, true
		if strings.has_prefix(path, "../") && (strings.contains(path, "packages/engine") || strings.contains(path, "plugins/engine")) do return l, true
	}
	return "", false
}

// The core host and the packages beside it are what a plugin-free editor
// stands on, so none of them may import the engine itself.
@(test)
test_host_packages_import_no_engine :: proc(t: ^testing.T) {
	HOST := []string{"moonhug/host/core", "moonhug/host/log", "moonhug/host/serialization", "moonhug/host/gizmos", "moonhug/host/gfx", "moonhug/host/input", "moonhug/host/assets", "moonhug/host/catalog", "moonhug/host/crash_journal"}
	for root in HOST {
		files := make([dynamic]string, context.temp_allocator)
		_collect_odin_files(root, &files)
		testing.expectf(t, len(files) > 0, "%s should have sources", root)
		for path in files {
			data, rerr := os.read_entire_file(path, context.temp_allocator)
			if rerr != nil do continue
			text := string(data)
			for line in strings.split_lines_iterator(&text) {
				l := strings.trim_space(line)
				if !strings.has_prefix(l, "import ") do continue
				bad := strings.contains(l, "\"moonhug:packages/engine") || strings.contains(l, "\"..\"") || strings.contains(l, "/engine\"")
				testing.expectf(t, !bad, "%s imports the engine: %s", path, l)
			}
		}
	}
}
