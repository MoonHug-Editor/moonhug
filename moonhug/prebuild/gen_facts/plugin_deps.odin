package gen_facts

// Integration subpackages (docs/Plugins.md): a plugin's subfolder that imports
// another plugin compiles only while that plugin is installed. The prebuild
// scan skips the folder, and packages_gen skips its tests, when this reports a
// missing plugin. A package root and its own editor/ are never skipped: a
// missing import there is a build error, a hard dependency.

import "core:os"
import "core:strings"

// The first plugin that an import in `dir`'s own .odin files names and that is
// not installed (no moonhug/packages/<name>). Imports are read as text: every
// `import` line naming "moonhug:packages/<name>...".
plugin_dir_missing_dep :: proc(dir: string) -> (missing: string, is_missing: bool) {
	handle, err := os.open(dir)
	if err != nil do return "", false
	defer os.close(handle)
	entries, rerr := os.read_dir(handle, -1, context.temp_allocator)
	if rerr != nil do return "", false
	defer os.file_info_slice_delete(entries, context.temp_allocator)

	PREFIX :: "\"moonhug:packages/"
	for entry in entries {
		if entry.type == .Directory || !strings.has_suffix(entry.name, ".odin") do continue
		path := strings.join({dir, entry.name}, "/", context.temp_allocator)
		data, ferr := os.read_entire_file(path, context.temp_allocator)
		if ferr != nil do continue
		for line in strings.split_lines(string(data), context.temp_allocator) {
			l := strings.trim_space(line)
			if !strings.has_prefix(l, "import") do continue
			at := strings.index(l, PREFIX)
			if at < 0 do continue
			rest := l[at + len(PREFIX):]
			end := strings.index_any(rest, "/\"")
			if end <= 0 do continue
			name := rest[:end]
			if !os.is_dir(strings.join({"moonhug/packages", name}, "/", context.temp_allocator)) do return name, true
		}
	}
	return "", false
}
