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

import "core:os"
import "core:path/filepath"
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
import _ "tween_gen"
import _ "scene_toolbar_gen"
import _ "packages_gen"
import _ "gizmos_gen"

PACKAGES := []string{
	"moonhug/editor",
	"moonhug/editor/menu",
	"moonhug/editor/inspector",
	"moonhug/app",
	"moonhug/app_editor",
	"moonhug/engine",
	"moonhug/engine_editor",
}

// Installed packages (docs/Plugins.md): presence in moonhug/packages/ is the
// install state. Each package root — and its editor/ subpackage when present —
// joins the attribute scan exactly like moonhug/app.
PACKAGES_DIR :: "moonhug/packages"

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

_installed_packages :: proc(list: ^[dynamic]string) {
	// The collection flag (-collection:packages=moonhug/packages) needs the
	// directory to exist even with zero packages installed.
	os.make_directory(PACKAGES_DIR)
	handle, err := os.open(PACKAGES_DIR)
	if err != nil do return
	defer os.close(handle)
	entries, rerr := os.read_dir(handle, -1, context.temp_allocator)
	if rerr != nil do return
	defer os.file_info_slice_delete(entries, context.temp_allocator)

	names: [dynamic]string
	defer delete(names)
	for entry in entries {
		if entry.type != .Directory do continue
		if strings.has_prefix(entry.name, ".") do continue
		append(&names, entry.name)
	}
	slice.sort(names[:]) // deterministic scan order regardless of readdir order

	for name in names {
		root, _ := filepath.join({PACKAGES_DIR, name})
		if _dir_has_odin(root) {
			append(list, root)
		}
		editor_dir, _ := filepath.join({root, "editor"})
		if _dir_has_odin(editor_dir) {
			append(list, editor_dir)
		}
	}
}

main :: proc() {
	all: [dynamic]string
	append(&all, ..PACKAGES)
	_installed_packages(&all)
	if !db.run_all(all[:]) do os.exit(1)
}
