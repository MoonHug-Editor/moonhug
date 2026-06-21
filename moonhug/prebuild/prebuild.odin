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

PACKAGES := []string{
	"moonhug/editor",
	"moonhug/editor/menu",
	"moonhug/editor/inspector",
	"moonhug/app",
	"moonhug/app_editor",
	"moonhug/engine",
	"moonhug/engine_editor",
}

main :: proc() {
	if !db.run_all(PACKAGES) do os.exit(1)
}
