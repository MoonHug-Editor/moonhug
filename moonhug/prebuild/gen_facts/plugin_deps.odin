package gen_facts

// Plugin dependencies (docs/Plugins.md), read from import lines:
//
// - Integration subpackage: a plugin's subfolder that imports another plugin
//   compiles only while that plugin is installed. The prebuild scan skips the
//   folder, and packages_gen skips its tests, when plugin_dir_missing_dep
//   reports a missing plugin.
// - Hard dependency: an import of another plugin from a plugin's root, its
//   editor/, its tests/ or a library subpackage those import. Prebuild checks
//   them before anything compiles (plugin_missing_deps), so a missing plugin
//   is named instead of failing the Odin build on a path.

import "core:os"
import "core:slice"
import "core:strings"

PLUGINS_ROOT :: "moonhug/packages"

// One `import "moonhug:packages/..."` line.
Plugin_Import :: struct {
	file: string, // the importing file, "<dir>/<name>.odin"
	line: int, // 1-based
	path: string, // after "moonhug:packages/": "sequencer" or "sequencer/core"
}

// The plugin an import path names: its first segment.
plugin_import_name :: proc(path: string) -> string {
	if i := strings.index_byte(path, '/'); i >= 0 do return path[:i]
	return path
}

plugin_installed :: proc(name: string, root := PLUGINS_ROOT) -> bool {
	return os.is_dir(strings.join({root, name}, "/", context.temp_allocator))
}

// Every plugin import in `dir`'s own .odin files, in file order (temp).
// Generated files are prebuild's own output from the last run, rewritten after
// this check: they are not read.
plugin_dir_imports :: proc(dir: string) -> [dynamic]Plugin_Import {
	out := make([dynamic]Plugin_Import, context.temp_allocator)
	handle, err := os.open(dir)
	if err != nil do return out
	defer os.close(handle)
	entries, rerr := os.read_dir(handle, -1, context.temp_allocator)
	if rerr != nil do return out
	defer os.file_info_slice_delete(entries, context.temp_allocator)

	files := make([dynamic]string, context.temp_allocator)
	for entry in entries {
		if entry.type == .Directory || !strings.has_suffix(entry.name, ".odin") do continue
		if strings.has_suffix(entry.name, "_generated.odin") do continue
		append(&files, strings.join({dir, entry.name}, "/", context.temp_allocator))
	}
	slice.sort(files[:])

	PREFIX :: "\"moonhug:packages/"
	for path in files {
		data, ferr := os.read_entire_file(path, context.temp_allocator)
		if ferr != nil do continue
		for line, i in strings.split_lines(string(data), context.temp_allocator) {
			l := strings.trim_space(line)
			if !strings.has_prefix(l, "import") do continue
			at := strings.index(l, PREFIX)
			if at < 0 do continue
			rest := l[at + len(PREFIX):]
			end := strings.index_byte(rest, '"')
			if end <= 0 do continue
			append(&out, Plugin_Import{file = path, line = i + 1, path = rest[:end]})
		}
	}
	return out
}

// The first plugin an import in `dir`'s own .odin files names that is not
// installed.
plugin_dir_missing_dep :: proc(dir: string) -> (missing: string, is_missing: bool) {
	for imp in plugin_dir_imports(dir) {
		name := plugin_import_name(imp.path)
		if !plugin_installed(name) do return name, true
	}
	return "", false
}

Plugin_Missing_Dep :: struct {
	plugin: string, // the installed plugin that needs it
	needs:  string, // the plugin that is not installed
	file:   string,
	line:   int,
}

// The hard dependencies of installed plugin `name` that are not installed,
// appended to `out` (strings temp). Walked: the plugin's root, editor/ and
// tests/, then every subpackage those import, transitively. That includes
// another plugin's subpackage (a sample importing animation/sequencer needs
// the sequencer). The plugin's own integration subpackages are not walked:
// nothing of the plugin imports them. Another plugin's root is not walked
// either: its own check covers it.
plugin_missing_deps :: proc(name: string, out: ^[dynamic]Plugin_Missing_Dep, root := PLUGINS_ROOT) {
	base := strings.join({root, name}, "/", context.temp_allocator)
	queue := make([dynamic]string, context.temp_allocator)
	append(&queue, base, strings.join({base, "editor"}, "/", context.temp_allocator), strings.join({base, "tests"}, "/", context.temp_allocator))
	seen := make(map[string]bool, context.temp_allocator)
	for len(queue) > 0 {
		dir := pop_front(&queue)
		if seen[dir] do continue
		seen[dir] = true
		for imp in plugin_dir_imports(dir) {
			dep := plugin_import_name(imp.path)
			if dep != name && !plugin_installed(dep, root) {
				append(out, Plugin_Missing_Dep{plugin = name, needs = dep, file = imp.file, line = imp.line})
				continue
			}
			if imp.path != dep do append(&queue, strings.join({root, imp.path}, "/", context.temp_allocator))
		}
	}
}
