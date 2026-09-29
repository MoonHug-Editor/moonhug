package inspector

// A plugin's manifest in the package inspector (docs/Plugins.md, "Plugin
// manifest"): its description, the plugins it needs and whether each is
// installed, and the installed plugins that use it. Read from
// packages/<name>/mh_plugin.json when a package is selected.

import "base:runtime"
import "core:encoding/json"
import "core:os"
import "core:slice"
import "core:strings"

@(private = "file")
_PACKAGES_DIR :: "packages"

@(private = "file")
_MANIFEST :: "mh_plugin.json"

Plugin_Dependency :: struct {
	name:      string,
	installed: bool,
	compile:   bool, // what needs it (plugin_dep_kind)
	tests:     bool,
	content:   bool,
}

// One dependency of a plugin and what needs it (plugin_deps_generated.odin,
// from plugin_types_gen, the same scan `mh deps` runs).
Plugin_Dep :: struct {
	plugin:  string,
	needs:   string,
	compile: bool, // an import: the build stops without it
	tests:   bool, // an import from tests/ only: the test build stops without it
	content: bool, // a guid in assets/ or code: what uses it does not load without it
}

// What needs `dep` in `plugin`, by scope. None for a manifest entry nothing on
// disk explains (hand-written).
plugin_dep_kind :: proc(plugin, dep: string) -> (compile, tests, content: bool) {
	for d in plugin_deps do if d.plugin == plugin && d.needs == dep do return d.compile, d.tests, d.content
	return false, false, false
}

Plugin_Manifest_View :: struct {
	found:        bool, // a manifest file exists
	ok:           bool, // and parses
	guid:         string,
	description:  string,
	dependencies: []Plugin_Dependency,
	used_by:      []Plugin_Dependency, // installed plugins whose manifest lists this one, with what in them needs it
}

@(private = "file")
_Manifest :: struct {
	name:         string,
	guid:         string,
	description:  string,
	dependencies: []string,
}

// The manifest of the installed package `name`, owned by the caller
// (plugin_manifest_free). Strings live on the default allocator.
plugin_manifest_load :: proc(name: string) -> (v: Plugin_Manifest_View) {
	context.allocator = runtime.default_allocator()
	m, found, ok := _read(name)
	v.found, v.ok = found, ok
	if !ok do return
	v.guid = strings.clone(m.guid)
	v.description = strings.clone(m.description)
	deps := make([dynamic]Plugin_Dependency)
	for d in m.dependencies {
		compile, tests, content := plugin_dep_kind(name, d)
		append(&deps, Plugin_Dependency{
			name      = strings.clone(d),
			installed = os.exists(strings.join({_PACKAGES_DIR, d}, "/", context.temp_allocator)),
			compile   = compile,
			tests     = tests,
			content   = content,
		})
	}
	v.dependencies = deps[:]

	needed := make([dynamic]Plugin_Dependency)
	if handle, err := os.open(_PACKAGES_DIR); err == nil {
		defer os.close(handle)
		if entries, rerr := os.read_dir(handle, -1, context.temp_allocator); rerr == nil {
			for e in entries {
				if e.name == name || strings.has_prefix(e.name, ".") do continue
				other, _, ook := _read(e.name)
				if ook && slice.contains(other.dependencies, name) {
					compile, tests, content := plugin_dep_kind(e.name, name)
					append(&needed, Plugin_Dependency{name = strings.clone(e.name), installed = true, compile = compile, tests = tests, content = content})
				}
			}
		}
	}
	slice.sort_by(needed[:], proc(a, b: Plugin_Dependency) -> bool { return a.name < b.name })
	v.used_by = needed[:]
	return
}

// A table's sort, by the column imgui reports: 0 name, 1 compile, 2 tests,
// 3 content. A star column sorts stars first, names break ties.
plugin_dependencies_sort :: proc(rows: []Plugin_Dependency, column: int, descending: bool) {
	less :: proc(a, b: Plugin_Dependency, column: int) -> bool {
		switch column {
		case 1: if a.compile != b.compile do return a.compile
		case 2: if a.tests != b.tests do return a.tests
		case 3: if a.content != b.content do return a.content
		}
		return a.name < b.name
	}
	ctx := struct{ column: int, descending: bool }{column, descending}
	context.user_ptr = &ctx
	slice.sort_by(rows, proc(a, b: Plugin_Dependency) -> bool {
		c := (cast(^struct{ column: int, descending: bool })context.user_ptr)^
		return less(b, a, c.column) if c.descending else less(a, b, c.column)
	})
}

plugin_manifest_free :: proc(v: ^Plugin_Manifest_View) {
	context.allocator = runtime.default_allocator()
	delete(v.guid)
	delete(v.description)
	for d in v.dependencies do delete(d.name)
	delete(v.dependencies)
	for d in v.used_by do delete(d.name)
	delete(v.used_by)
	v^ = {}
}

@(private = "file")
_read :: proc(name: string) -> (m: _Manifest, found: bool, ok: bool) {
	path := strings.join({_PACKAGES_DIR, name, _MANIFEST}, "/", context.temp_allocator)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return {}, false, false
	if json.unmarshal(data, &m, allocator = context.temp_allocator) != nil do return {}, true, false
	return m, true, true
}
