package gen_facts

// Plugin dependencies (docs/Plugins.md), read from import lines:
//
// - Integration subpackage: a plugin's subfolder that imports another plugin
//   compiles only while that plugin is installed. The prebuild scan skips the
//   folder, and packages_gen skips its tests, when plugin_dir_missing_dep
//   reports a missing plugin.
// - Hard dependency: an import of another plugin from a plugin's root, its
//   editor/, its tests/ or a subpackage those import (plugin_walk). Prebuild
//   checks them, and the dependencies each mh_plugin.json declares, before
//   anything compiles, so a missing plugin is named instead of failing the
//   Odin build on a path.

import "core:encoding/json"
import "core:os"
import "core:slice"
import "core:strings"

PLUGINS_ROOT :: "moonhug/packages"

// Every plugin's manifest, at its root: identity and the plugins it needs.
// `mh deps` gathers the dependencies, a person may edit them.
PLUGIN_MANIFEST :: "mh_plugin.json"

Plugin_Manifest :: struct {
	name:         string,
	guid:         string, // the plugin's identity, minted when the manifest is made
	description:  string,
	dependencies: []string,
}

// One `import "moonhug:packages/..."` line.
Plugin_Import :: struct {
	file: string, // the importing file, "<dir>/<name>.odin"
	line: int, // 1-based
	path: string, // after "moonhug:packages/": "sequencer" or "sequencer/core"
}

// A reason `plugin` needs `needs`: an import at file:line, or content (`why`
// says what it uses).
Plugin_Dep_Use :: struct {
	plugin: string,
	needs:  string,
	file:   string,
	line:   int, // 0 for content and for a declaration in the manifest
	why:    string,
}

// The plugin an import path names: its first segment.
plugin_import_name :: proc(path: string) -> string {
	if i := strings.index_byte(path, '/'); i >= 0 do return path[:i]
	return path
}

plugin_installed :: proc(name: string, root := PLUGINS_ROOT) -> bool {
	return os.is_dir(strings.join({root, name}, "/", context.temp_allocator))
}

// `dir`'s own hand-written .odin files, sorted (temp). Generated files are
// prebuild's own output from the last run, rewritten after the checks that
// read these: they are left out.
plugin_dir_odin_files :: proc(dir: string) -> [dynamic]string {
	files := make([dynamic]string, context.temp_allocator)
	handle, err := os.open(dir)
	if err != nil do return files
	defer os.close(handle)
	entries, rerr := os.read_dir(handle, -1, context.temp_allocator)
	if rerr != nil do return files
	defer os.file_info_slice_delete(entries, context.temp_allocator)
	for entry in entries {
		if entry.type == .Directory || !strings.has_suffix(entry.name, ".odin") do continue
		if strings.has_suffix(entry.name, "_generated.odin") do continue
		append(&files, strings.join({dir, entry.name}, "/", context.temp_allocator))
	}
	slice.sort(files[:])
	return files
}

// Every plugin import in `dir`'s own .odin files, in file order (temp).
plugin_dir_imports :: proc(dir: string) -> [dynamic]Plugin_Import {
	out := make([dynamic]Plugin_Import, context.temp_allocator)
	PREFIX :: "\"moonhug:packages/"
	for path in plugin_dir_odin_files(dir) {
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

// The folder a package import path lives in, from `dirs` (package name -> its
// folder). ok=false when the package is not in `dirs`.
plugin_path_dir :: proc(dirs: map[string]string, path: string) -> (dir: string, ok: bool) {
	name := plugin_import_name(path)
	base, has := dirs[name]
	if !has do return "", false
	if path == name do return base, true
	return strings.join({base, path[len(name) + 1:]}, "/", context.temp_allocator), true
}

// Plugin `name`'s hard dependencies from code, one use per import (temp), and
// the folders the walk read. Walked: the plugin's root, editor/ and tests/,
// then every subpackage those import, transitively. That includes another
// plugin's subpackage (a sample importing animation/sequencer needs the
// sequencer). The plugin's own integration subpackages are not reached:
// nothing of the plugin imports them. Another plugin's root is not walked
// either: that plugin's own dependencies cover it. `dirs` maps package names
// to folders, and a package missing from it is not walked.
plugin_walk :: proc(name: string, dirs: map[string]string) -> (uses: [dynamic]Plugin_Dep_Use, reached: map[string]bool) {
	uses = make([dynamic]Plugin_Dep_Use, context.temp_allocator)
	reached = make(map[string]bool, context.temp_allocator)
	base, has := dirs[name]
	if !has do return
	queue := make([dynamic]string, context.temp_allocator)
	append(&queue, base, strings.join({base, "editor"}, "/", context.temp_allocator), strings.join({base, "tests"}, "/", context.temp_allocator))
	for len(queue) > 0 {
		dir := pop_front(&queue)
		if reached[dir] do continue
		reached[dir] = true
		for imp in plugin_dir_imports(dir) {
			dep := plugin_import_name(imp.path)
			if dep != name do append(&uses, Plugin_Dep_Use{plugin = name, needs = dep, file = imp.file, line = imp.line})
			if imp.path == dep do continue
			if sub, ok := plugin_path_dir(dirs, imp.path); ok do append(&queue, sub)
		}
	}
	return
}

// The manifest in `dir` (strings on `allocator`). found=false when there is
// none, ok=false when it does not parse.
plugin_manifest_read :: proc(dir: string, allocator := context.temp_allocator) -> (m: Plugin_Manifest, found: bool, ok: bool) {
	path := strings.join({dir, PLUGIN_MANIFEST}, "/", context.temp_allocator)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return {}, false, false
	if json.unmarshal(data, &m, allocator = allocator) != nil do return {}, true, false
	return m, true, true
}
