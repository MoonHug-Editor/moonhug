package main

// Prebuild code generator.
//
// Architecture: a staged pipeline over an explicit in-memory database (see gen_db).
// Stages run strictly in order — every provider runs before any generator runs:
//   PreProcess  - optional setup (settings/paths). The built-in scan runs last here:
//                 one shared AST walk; every declaration becomes a DeclInfo entity.
//   Provide     - each *_gen module tags the decls it cares about with its components.
//   Generate    - each module queries components and emits GeneratedFile entities.
//   PostProcess - gen_db writes every GeneratedFile to disk.
//
// Modules self-register via gen_db.provider / generator / pre_processor /
// post_processor in an @(init) proc, so adding a generator is "create a *_gen
// package + import it below" — no edits to this file's logic.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import db "gen_db"

// Importing each module pulls in its @(init) system registration. The blank
// reference keeps the import alive without needing a symbol from each package.
import "gen_facts"
import _ "menu_gen"
import _ "phase_gen"
import _ "property_drawer_gen"
import _ "serialization_gen"
import _ "type_guid_gen"
import _ "decorator_gen"
import _ "components_gen"
import _ "context_menu_gen"
import _ "update_gen"
import _ "sim_host_gen"
import _ "plugin_types_gen"
import _ "editor_window_gen"
import _ "attributes_gen"
import _ "project_settings_gen"
import _ "user_settings_gen"
import _ "scene_overlay_gen"
import _ "view_chrome_gen"
import _ "inspector_button_gen"
import _ "packages_gen"
import _ "gizmos_gen"
import _ "mcp_tool_gen"
import _ "union_gen"
// Package-shipped generators (moonhug/packages/<name>/gen) are imported by
// the generated package_gens_generated.odin next to this file.

// Scan roots: every directory beneath these that contains .odin files joins
// the attribute scan (recursively, symlinks followed), so extracting a new
// subpackage never needs an edit here. Directories named "tests" are skipped —
// test packages import the registration bundle, and scanning them would let
// generators import test packages back, a cycle.
SCAN_ROOTS := []string{
	"moonhug/editor",
	"moonhug/engine",
	"moonhug/engine_editor",
}

// Installed packages (docs/core/Plugins.md): presence in moonhug/packages/ is the
// install state. Each package root and its subpackages (editor/, library
// halves) join the attribute scan. RUNNABLE packages (a root
// with `main`, 0..N of them, the app included) each receive their own
// generated dispatcher set (__update, phase_run, register_type_guids,
// register_packages); the shared all-packages copy lands in
// moonhug/engine/registration for the editor and tests.
PACKAGES_DIR :: "moonhug/packages"

// Joins path elements with "/" on every host. NOT filepath.join: that emits
// the OS-native separator, and every path built here becomes a pkg_path on
// DeclInfo. Generators split pkg_path on "/", match it against the literal
// prefix "moonhug/packages/", and splice it into generated Odin import paths
// and output file names — all of which are forward-slash by definition. A
// backslash makes packages_gen see no packages at all. Forward slashes are
// accepted by the os and parser calls these same paths feed, on every platform
// this project targets.
_join :: proc(elems: []string, allocator := context.allocator) -> string {
	return strings.join(elems, "/", allocator)
}

_dir_has_odin :: proc(dir: string) -> bool {
	handle, err := os.open(dir)
	if err != nil do return false
	defer os.close(handle)
	entries, rerr := os.read_dir(handle, -1, context.temp_allocator)
	if rerr != nil do return false
	defer os.file_info_slice_delete(entries, context.temp_allocator)
	for entry in entries {
		if entry.type != .Directory && strings.has_suffix(entry.name, ".odin") do return true
	}
	return false
}

// Installed package folder names, sorted (deterministic regardless of
// readdir order). Names are cloned — the caller owns them.
_package_dir_names :: proc(names: ^[dynamic]string) {
	// Packages resolve through the `moonhug` collection as `moonhug:packages/<name>`;
	// the directory must exist even with zero packages installed.
	os.make_directory(PACKAGES_DIR)
	handle, err := os.open(PACKAGES_DIR)
	if err != nil do return
	defer os.close(handle)
	entries, rerr := os.read_dir(handle, -1, context.temp_allocator)
	if rerr != nil do return
	defer os.file_info_slice_delete(entries, context.temp_allocator)

	for entry in entries {
		if strings.has_prefix(entry.name, ".") do continue
		// A symlinked package (samples installed via symlink) reads as
		// .Symlink — follow it so its code compiles like any package.
		if entry.type != .Directory {
			full := _join({PACKAGES_DIR, entry.name}, context.temp_allocator)
			if entry.type != .Symlink || !os.is_dir(full) do continue
		}
		append(names, strings.clone(entry.name))
	}
	slice.sort(names^[:])
}

_installed_packages :: proc(list: ^[dynamic]string) {
	names: [dynamic]string
	defer { for n in names do delete(n); delete(names) }
	_package_dir_names(&names)

	for name in names {
		root := _join({PACKAGES_DIR, name})
		// Recursive: subpackages (editor/, library halves)
		// join the scan like any engine subpackage. tests/samples/assets/gen
		// are skipped inside _discover.
		_discover(list, root)
	}
}

// Package generators: moonhug/packages/<name>/gen ships prebuild-side code
// that compiles into THIS program (its @(init) registers systems), via the
// generated import file below. The import set must match the installed set
// BEFORE any generator runs — output produced with a generator missing is
// wrong, not just stale — so main refreshes the file first and exits when it
// changed: the next `odin run` compiles the new set in.
_PACKAGE_GENS_FILE :: "moonhug/prebuild/package_gens_generated.odin"

_package_gens_refresh :: proc() -> (changed: bool) {
	names: [dynamic]string
	defer { for n in names do delete(n); delete(names) }
	_package_dir_names(&names)

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "package main\n\n")
	strings.write_string(&b, "// Code generated by prebuild. Do not edit.\n")
	strings.write_string(&b, "// Generators shipped by installed packages (docs/core/Plugins.md): blank\n")
	strings.write_string(&b, "// imports pull in their @(init) system registrations.\n\n")
	for name in names {
		gen_dir := _join({PACKAGES_DIR, name, "gen"}, context.temp_allocator)
		if !_dir_has_odin(gen_dir) do continue
		fmt.sbprintf(&b, "import _ \"moonhug:packages/%s/gen\"\n", name)
	}

	content := strings.to_string(b)
	current, rerr := os.read_entire_file(_PACKAGE_GENS_FILE, context.temp_allocator)
	if rerr == nil && string(current) == content do return false
	_ = os.write_entire_file(_PACKAGE_GENS_FILE, transmute([]byte)content)
	return true
}

// Every installed plugin's code dependencies are installed (the plugins it
// imports, gen_facts.plugin_walk). Otherwise it names each missing plugin and
// the imports that need it, before anything compiles: the Odin build would
// only report a path that does not exist. Warnings, which let the build go on:
// - a dependency the plugin's mh_plugin.json declares and no import needs is
//   not installed (content: its scenes use that plugin's components or assets,
//   which will not load)
// - an import the manifest does not declare, or a plugin without a manifest,
//   with the command that fixes it
_check_plugin_deps :: proc() -> bool {
	names: [dynamic]string
	defer { for n in names do delete(n); delete(names) }
	_package_dir_names(&names)
	dirs := make(map[string]string, context.temp_allocator)
	for n in names do dirs[n] = _join({PACKAGES_DIR, n}, context.temp_allocator)

	missing := make([dynamic]gen_facts.Plugin_Dep_Use, context.temp_allocator)
	errors := make([dynamic]string, context.temp_allocator)
	warnings := make([dynamic]string, context.temp_allocator)
	for name in names {
		manifest_path := _join({dirs[name], gen_facts.PLUGIN_MANIFEST}, context.temp_allocator)
		m, found, ok := gen_facts.plugin_manifest_read(dirs[name])
		if found && !ok {
			append(&errors, fmt.tprintf("%s does not parse as a plugin manifest", manifest_path))
		} else if found && m.name != name {
			append(&errors, fmt.tprintf("%s names the plugin %q, its folder is %q", manifest_path, m.name, name))
		} else if !found {
			append(&warnings, fmt.tprintf("%s has no %s (mh deps %s makes it)", name, gen_facts.PLUGIN_MANIFEST, name))
		}

		uses, _ := gen_facts.plugin_walk(name, dirs)
		undeclared := make(map[string]bool, context.temp_allocator)
		for u in uses {
			if !gen_facts.plugin_installed(u.needs) {
				append(&missing, u)
			} else if found && ok && !slice.contains(gen_facts.plugin_manifest_declared(m), u.needs) && !undeclared[u.needs] {
				undeclared[u.needs] = true
				append(&warnings, fmt.tprintf("%s imports %s, which its %s does not list (%s:%d)", name, u.needs, gen_facts.PLUGIN_MANIFEST, u.file, u.line))
			}
		}
		for d in gen_facts.plugin_manifest_declared(m) {
			if gen_facts.plugin_installed(d) do continue
			needed_by_code := false
			for u in uses do if u.needs == d { needed_by_code = true; break }
			if !needed_by_code {
				append(&warnings, fmt.tprintf("%s needs %s, which is not installed (declared in %s): what it uses from %s will not load", name, d, manifest_path, d))
			}
		}
	}
	for w in warnings do fmt.eprintfln("prebuild: warning: %s", w)
	if len(missing) == 0 && len(errors) == 0 do return true

	for e in errors do fmt.eprintfln("prebuild: %s", e)
	if len(missing) > 0 {
		slice.sort_by(missing[:], proc(a, b: gen_facts.Plugin_Dep_Use) -> bool {
			if a.plugin != b.plugin do return a.plugin < b.plugin
			if a.needs != b.needs do return a.needs < b.needs
			if a.file != b.file do return a.file < b.file
			return a.line < b.line
		})
		fmt.eprintln("prebuild: installed plugins need plugins that are not installed")
		for m, i in missing {
			if i == 0 || m.plugin != missing[i - 1].plugin || m.needs != missing[i - 1].needs {
				fmt.eprintf("  %s needs %s\n", m.plugin, m.needs)
			}
			fmt.eprintf("    %s:%d\n", m.file, m.line)
		}
		fmt.eprintln("Install the missing plugin (mh setup relinks every committed plugin), or uninstall the plugin that needs it (docs/core/Plugins.md).")
	}
	return false
}

main :: proc() {
	total := time.tick_now()
	lap := total
	step :: proc(lap: ^time.Tick, name: string) {
		db.timing_report(name, lap^)
		lap^ = time.tick_now()
	}
	// The manifests' `dependencies` follow the source (docs/core/Plugins.md), so
	// the check below reads current lists and a stale entry never lingers.
	if !gen_facts.plugin_manifests_sync_all("prebuild: ") do os.exit(1)
	step(&lap, "prebuild/manifest sync")
	if !_check_plugin_deps() do os.exit(1)
	step(&lap, "prebuild/dependency check")
	if _package_gens_refresh() {
		fmt.eprintln("prebuild: package generator set changed — run prebuild again")
		os.exit(2)
	}
	step(&lap, "prebuild/package gens")
	all: [dynamic]string
	for root in SCAN_ROOTS do _discover(&all, root)
	_installed_packages(&all)
	step(&lap, "prebuild/discover")
	if !db.run_all(all[:]) do os.exit(1)
	fmt.printf("prebuild: %.0f ms\n", time.duration_milliseconds(time.tick_since(total)))
}

_discover :: proc(list: ^[dynamic]string, dir: string) {
	// An integration subpackage (a plugin subfolder importing another plugin)
	// joins the scan only while that plugin is installed. Its subfolders go
	// with it. The plugin's own editor/ is part of the plugin like its root: a
	// missing import there is a build error (docs/core/Plugins.md).
	if rest := strings.trim_prefix(dir, PACKAGES_DIR + "/"); rest != dir {
		parts := strings.split(rest, "/", context.temp_allocator)
		is_sub := len(parts) > 1
		own_editor := len(parts) == 2 && parts[1] == "editor"
		if is_sub && !own_editor {
			if missing, is_missing := gen_facts.plugin_dir_missing_dep(dir); is_missing {
				fmt.printf("prebuild: %s skipped, needs the %s plugin\n", dir, missing)
				return
			}
		}
	}
	if _dir_has_odin(dir) do append(list, dir)
	handle, err := os.open(dir)
	if err != nil do return
	defer os.close(handle)
	entries, rerr := os.read_dir(handle, -1, context.temp_allocator)
	if rerr != nil do return
	defer os.file_info_slice_delete(entries, context.temp_allocator)

	names: [dynamic]string
	defer delete(names)
	for entry in entries {
		if strings.has_prefix(entry.name, ".") do continue
		// tests: scanning them would let generators import test packages back,
		// a cycle. samples: their contents install as symlinked sibling
		// packages, so scanning the source dir would scan the same files
		// twice. assets: no Odin code. run_configs: one standalone file per
		// configuration, not a package. gen: prebuild-side code compiled into
		// THIS program, not the binaries (docs/core/Plugins.md).
		switch entry.name {
		case "tests", "samples", "assets", "run_configs", "gen":
			continue
		}
		// A symlinked subpackage reads as .Symlink — follow it so its code
		// compiles like any package (docs/core/Plugins.md).
		if entry.type != .Directory {
			full := _join({dir, entry.name}, context.temp_allocator)
			if entry.type != .Symlink || !os.is_dir(full) do continue
		}
		append(&names, strings.clone(entry.name))
	}
	slice.sort(names[:]) // deterministic scan order regardless of readdir order
	for name in names {
		full := _join({dir, name})
		_discover(list, full)
		delete(name)
	}
}

