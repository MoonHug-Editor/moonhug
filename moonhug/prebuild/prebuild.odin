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
import db "gen_db"

// Importing each module pulls in its @(init) system registration. The blank
// reference keeps the import alive without needing a symbol from each package.
import _ "gen_facts"
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
import _ "editor_window_gen"
import _ "project_settings_gen"
import _ "scene_overlay_gen"
import _ "inspector_button_gen"
import _ "packages_gen"
import _ "gizmos_gen"
import _ "mcp_tool_gen"
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

// Installed packages (docs/Plugins.md): presence in moonhug/packages/ is the
// install state. Each package root and its subpackages (editor/, library
// halves) join the attribute scan. RUNNABLE packages (a root
// with `main`, 0..N of them, the app included) each receive their own
// generated dispatcher set (__update, phase_run, register_type_guids,
// register_packages); the shared all-packages copy lands in
// moonhug/engine/registration for the editor and tests.
PACKAGES_DIR :: "moonhug/packages"

// Joins path elements with "/" regardless of host OS. Every path built here
// becomes (or feeds) a pkg_path stored on DeclInfo, which generators splice
// directly into generated Odin `import "..."` strings — those are always
// forward-slash, so this must NOT be filepath.join: that emits the OS-native
// separator (backslash on Windows) and corrupts every generated relative
// import. Forward slashes work fine for the os/parser calls these paths also
// feed on every platform this project targets.
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
		// Recursive: subpackages (editor/, tween/core-style library halves)
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
	strings.write_string(&b, "// Generators shipped by installed packages (docs/Plugins.md): blank\n")
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

main :: proc() {
	if _package_gens_refresh() {
		fmt.eprintln("prebuild: package generator set changed — run prebuild again")
		os.exit(2)
	}
	all: [dynamic]string
	for root in SCAN_ROOTS do _discover(&all, root)
	_installed_packages(&all)
	if !db.run_all(all[:]) do os.exit(1)
}

_discover :: proc(list: ^[dynamic]string, dir: string) {
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
		// THIS program, not the binaries (docs/Plugins.md).
		switch entry.name {
		case "tests", "samples", "assets", "run_configs", "gen":
			continue
		}
		// A symlinked subpackage reads as .Symlink — follow it so its code
		// compiles like any package (docs/Plugins.md).
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

