package main

// Drops import lines in package_gens_generated.odin whose gen/ folder no
// longer exists — they would fail the prebuild compile before prebuild's own
// refresh can run. Prune only: prebuild generates the full set itself.
//
// A separate program because it must run BEFORE prebuild compiles (mh
// invokes it first) — it never imports prebuild code.

import "core:os"
import "core:strings"

GENS_FILE :: "moonhug/prebuild/package_gens_generated.odin"
IMPORT_PREFIX :: "import _ \"moonhug:"

main :: proc() {
	data, rerr := os.read_entire_file(GENS_FILE, context.allocator)
	if rerr != nil do return // no file, nothing to prune

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	changed := false
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		if strings.has_prefix(line, IMPORT_PREFIX) {
			rel := strings.trim_suffix(line[len(IMPORT_PREFIX):], "\"")
			path := strings.concatenate({"moonhug/", rel}, context.temp_allocator)
			if !os.is_dir(path) {
				changed = true
				continue
			}
		}
		strings.write_string(&b, line)
		strings.write_string(&b, "\n")
	}
	if changed {
		_ = os.write_entire_file(GENS_FILE, transmute([]byte)strings.to_string(b))
	}
}
