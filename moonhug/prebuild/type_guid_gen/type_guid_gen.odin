package type_guid_gen

// type_guid_gen: ECS prebuild generator.
//
//   provide  - query {DeclInfo}, recognise @typ_guid structs/unions (tag with
//              TypeGuid_GenComp) and @cleanup-annotated procs (tag with
//              Cleanup_GenComp).
//   generate - query the tags, sort, emit the TypeKey enum, core's lifecycle
//              table, the registration bundles and the Assets/Create menus.
//
// No package is special except core: the engine's types register like any
// installed package's, so the output compiles with no plugin installed.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "../gen_core"
import db "../gen_db"
import "../gen_facts"

CreateAssetMenuData :: struct {
	file_name: string,
	menu_name: string,
	order:     int,
	origin:    string,
}

// TypeGuid_GenComp marks a DeclInfo entity as a @typ_guid struct/union. The type
// name lives on the entity's DeclInfo; pkg_name is derived from DeclInfo.pkg_path.
TypeGuid_GenComp :: struct {
	pkg_name:         string,
	pkg_path:         string, // scan path; "" for synthetic types
	guid:             string,
	has_reset:        bool,
	has_cleanup:      bool,
	has_on_validate:  bool,
	create_file_name: string,
	create_menu_name: string,
	create_order:     int,
	// Where the nested menu_assets_create was declared, rendered by
	// gen_facts.attr_origin. Emitted into the Assets/Create menu registration
	// and shown in the item's tooltip with debug tooltips on.
	create_origin:    string,
}

// Cleanup_GenComp marks a DeclInfo entity as an @cleanup-annotated proc.
Cleanup_GenComp :: struct {
	target_type: string,
	priority:    int,
}

// TypeGuid_GenComp and Cleanup_GenComp are provided into the central registry (see
// provide); any generator can query them by type via get_comps.

// Synthetic types provided by sibling modules (e.g. TweenUnion from tween_gen):
// types the generator emits that have no source declaration. Kept as a plain
// module-local list rather than entities, so they never appear in the {decls}
// views that providers iterate.
@(private) _synthetic: [dynamic]_TypeGuidRow

@(init)
_register :: proc "contextless" () {
	db.provider("type_guid/provide", provide)
	db.generator("type_guid/generate", generate)
	context = runtime.default_context()
	gen_facts.register_naming({
		key     = "type_lifecycle",
		title   = "Type lifecycle procs",
		subject = "a type with @(typ_guid)",
		layer   = "host",
		owner   = "type_guid_gen",
		scope   = .Subject_File,
		procs   = {
			{prefix = "reset_", signature = "proc(v: ^T)", summary = "Sets a fresh instance to its defaults: Reset in the inspector, Add Component, a new asset."},
			{prefix = "cleanup_", signature = "proc(v: ^T)", summary = "Frees what the instance owns. Runs before undo, reset and document release overwrite it, and must be safe to call twice."},
			{prefix = "on_validate_", signature = "proc(v: ^T)", summary = "Runs after a value is written into the instance: an inspector edit, undo, a load."},
		},
		doc     = "The type registry calls these for every registered type, so a component, an asset type or a plain data type gets defaults, cleanup and validation by declaring them next to itself. A cleanup can also come from `@(cleanup)` on a proc of any name.",
	})
}

// provide_synthetic lets a sibling module register a type it emits as a
// typ_guid type. Called from that module's provider (Provide stage).
provide_synthetic :: proc(w: ^db.World, name, pkg_name, guid: string) -> bool {
	append(&_synthetic, _TypeGuidRow{pkg_name = pkg_name, type_name = name, guid = guid})
	return true
}

// `decl` supplies the file and line the origin string names — the create-asset
// menu item is hoverable UI, so it carries where it was declared.
_has_typ_guid_attr :: proc(attr_set: ^gen_facts.Attrs_GenComp, decl: ^db.DeclInfo) -> (guid: string, makeProcName: string, create: CreateAssetMenuData, has_create_menu: bool, found: bool) {
	args, ok := gen_facts.attr_find(attr_set, "typ_guid")
	if !ok do return "", "", {}, false, false

	guid = args.fields["guid"]
	makeProcName = args.fields["makeProcName"]

	create = {}
	if menu, menu_ok := gen_facts.attr_nested(args, "menu_assets_create"); menu_ok {
		has_create_menu = true
		create.file_name = menu.fields["file_name"]
		create.menu_name = menu.fields["menu_name"]
		create.order = gen_facts.attr_int(menu, "order")
		create.origin = gen_facts.attr_origin(menu, gen_facts.decl_rel_path(decl), decl.decl.pos.line, decl.name)
	}
	return guid, makeProcName, create, has_create_menu, guid != ""
}

_parse_cleanup_attr :: proc(attr_set: ^gen_facts.Attrs_GenComp) -> (target_type: string, priority: int, found: bool) {
	args, ok := gen_facts.attr_find(attr_set, "cleanup")
	if !ok do return "", 0, false
	tt := gen_facts.attr_keyname(args, "type")
	if tt == "" do return "", 0, false
	return tt, gen_facts.attr_int(args, "priority"), true
}

provide :: proc(w: ^db.World) -> bool {
	guids    := db.get_or_create_comps(w, TypeGuid_GenComp)
	cleanups := db.get_or_create_comps(w, Cleanup_GenComp)

	decls   := db.get_comps_DeclInfo()
	structs := db.get_comps(w, gen_facts.Struct_GenComp) // struct OR union
	procs   := db.get_comps(w, gen_facts.Proc_GenComp)
	attrs   := db.get_comps(w, gen_facts.Attrs_GenComp)

	m := db.all_of(db.r(decls), db.r(attrs)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		decl := db.get(decls, entity)
		// The DECLARED package name: generated references are
		// <pkg_name>.<type>, and subpackages declare tween_editor-style names
		// that differ from their folder ("editor").
		pkg_name := decl.pkg.name
		attr_set := db.get(attrs, entity)

		// @typ_guid structs/unions. Editor subpackages are excluded: their
		// types can't be referenced from the app-side registration file.
		type_name := decl.name
		if type_name != "" && db.has(structs, entity) && !strings.has_suffix(decl.pkg_path, "/editor") {
			guid, make_proc, create, has_create_menu, found := _has_typ_guid_attr(attr_set, decl)
			if found {
				if make_proc != "" {
					fmt.eprintf("type_guid_gen: %s.%s: makeProcName is gone, write reset_%s next to the type for its defaults (plugins/engine/docs/Components.md)\n", pkg_name, type_name, type_name)
					return false
				}
				// The lifecycle procs, by name in the type's own file
				// (plugins/engine/docs/Components.md, "Lifecycle procs").
				reset_name       := strings.concatenate({"reset_",       type_name})
				cleanup_name     := strings.concatenate({"cleanup_",     type_name})
				on_validate_name := strings.concatenate({"on_validate_", type_name})
				gen_facts.naming_subject("type_lifecycle", type_name, decl.file_path, fmt.tprintf("%s:%d", gen_facts.decl_rel_path(decl), decl.decl.pos.line))
				tag := TypeGuid_GenComp{
					pkg_name        = pkg_name,
					pkg_path        = decl.pkg_path,
					guid            = guid,
					has_reset       = gen_core.FileHasProc(decl.file, reset_name),
					has_cleanup     = gen_core.FileHasProc(decl.file, cleanup_name),
					has_on_validate = gen_core.FileHasProc(decl.file, on_validate_name),
				}
				delete(reset_name)
				delete(cleanup_name)
				delete(on_validate_name)
				if has_create_menu {
					tag.create_file_name = create.file_name
					if tag.create_file_name == "" do tag.create_file_name = strings.concatenate({type_name, ".asset"})
					tag.create_menu_name = create.menu_name
					if tag.create_menu_name == "" do tag.create_menu_name = type_name
					tag.create_order = create.order
					tag.create_origin = create.origin
				}
				db.set(guids, entity, tag)
			}
		}

		// @cleanup procs, in any package. generate checks that each one is
		// declared in the package of the type it frees.
		if db.has(procs, entity) {
			if tt, pr, ok := _parse_cleanup_attr(attr_set); ok {
				db.set(cleanups, entity, Cleanup_GenComp{target_type = tt, priority = pr})
			}
		}
	}
	return true
}

// _TypeGuidRow mirrors the old TypeGuidEntry the generate body consumed.
_TypeGuidRow :: struct {
	pkg_name:         string,
	pkg_path:         string,
	type_name:        string,
	guid:             string,
	has_reset:        bool,
	has_cleanup:      bool,
	has_on_validate:  bool,
	create_file_name: string,
	create_menu_name: string,
	create_order:     int,
	create_origin:    string,
	tid_expr:         string,
	source:           string, // gen_facts.decl_source, for Edit Script
}

_CleanupRow :: struct {
	target_type: string,
	pkg_name:    string, // package the proc is declared in
	proc_name:   string,
	priority:    int,
}

_ensure_string_type_key :: proc(entries: ^[dynamic]_TypeGuidRow) {
	for e in entries {
		if e.type_name == "string" do return
	}
	append(
		entries,
		_TypeGuidRow{
			pkg_name  = "core",
			type_name = "string",
			guid      = "c4f0a1b2-3d5e-6f7a-8b9c-0d1e2f3a4b5c",
			tid_expr  = "string",
		},
	)
}

generate :: proc(w: ^db.World) -> bool {
	entries: [dynamic]_TypeGuidRow
	defer delete(entries)
	cleanup_bindings: [dynamic]_CleanupRow
	defer delete(cleanup_bindings)

	decls := db.get_comps_DeclInfo()

	// Real declarations: type name comes from the DeclInfo entity.
	{
		guids := db.get_comps(w, TypeGuid_GenComp)
		m := db.all_of(db.r(decls), db.r(guids)); defer db.matcher_destroy(&m)
		for entity in db.matched(w, &m) {
			decl := db.get(decls, entity)
			guid := db.get(guids, entity)
			append(&entries, _TypeGuidRow{
				pkg_name         = guid.pkg_name,
				pkg_path         = guid.pkg_path,
				type_name        = decl.name,
				guid             = guid.guid,
				has_reset        = guid.has_reset,
				has_cleanup      = guid.has_cleanup,
				has_on_validate  = guid.has_on_validate,
				create_file_name = guid.create_file_name,
				create_menu_name = guid.create_menu_name,
				create_order     = guid.create_order,
				create_origin    = guid.create_origin,
				source           = gen_facts.decl_source(decl),
			})
		}
	}

	// Synthetic types provided by sibling modules (e.g. TweenUnion from tween_gen).
	for r in _synthetic {
		append(&entries, r)
	}

	{
		cleanups := db.get_comps(w, Cleanup_GenComp)
		m := db.all_of(db.r(decls), db.r(cleanups)); defer db.matcher_destroy(&m)
		for entity in db.matched(w, &m) {
			decl := db.get(decls, entity)
			cleanup := db.get(cleanups, entity)
			append(&cleanup_bindings, _CleanupRow{
				target_type = cleanup.target_type,
				pkg_name    = decl.pkg.name,
				proc_name   = decl.name,
				priority    = cleanup.priority,
			})
		}
	}

	// Old collect_finalize: ensure string key, then sort.
	_ensure_string_type_key(&entries)
	slice.sort_by(entries[:], proc(a, b: _TypeGuidRow) -> bool {
		return a.type_name < b.type_name
	})

	// A synthetic type (e.g. TweenUnion, emitted by tween_gen) can be present
	// BOTH as a TypeGuid_GenComp a sibling module attached AND as a real decl parsed
	// from the previously-generated file on disk. Drop adjacent duplicates by
	// type_name (sorted above) so the in-memory provider path is authoritative
	// and works on a clean tree without a second generator pass.
	dedup: [dynamic]_TypeGuidRow
	defer delete(dedup)
	for e in entries {
		if len(dedup) > 0 && dedup[len(dedup) - 1].type_name == e.type_name do continue
		append(&dedup, e)
	}
	clear(&entries)
	append(&entries, ..dedup[:])
	slice.sort_by(cleanup_bindings[:], proc(a, b: _CleanupRow) -> bool {
		if a.target_type != b.target_type do return a.target_type < b.target_type
		if a.priority != b.priority do return a.priority < b.priority
		return a.proc_name < b.proc_name
	})

	if !_generate_type_key(entries[:], w) do return false
	if !_generate_type_procs(entries[:], cleanup_bindings[:], w) do return false
	if !_generate_type_registration(entries[:], cleanup_bindings[:], w) do return false
	if !_generate_create_asset_menus(entries[:], w) do return false
	return true
}

_generate_type_key :: proc(entries: []_TypeGuidRow, w: ^db.World) -> bool {
	// TypeKey is core vocabulary (moonhug:host/core): packages index by it
	// without importing the engine. The guids are not globals: each
	// registration bundle writes them as literals next to its register_type
	// calls.
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "package core\n\n")
	strings.write_string(&b, "// Code generated by type_guid_gen. Do not edit.\n\n")
	strings.write_string(&b, "TypeKey :: enum u16 {\n")
	for e in entries {
		fmt.sbprintf(&b, "\t%s,\n", e.type_name)
	}
	strings.write_string(&b, "}\n\n")
	strings.write_string(&b, "INVALID_TYPE_KEY :: TypeKey(max(u16))\n")
	db.emit(w, "moonhug/host/core/type_key_generated.odin", strings.to_string(b))

	// The engine plugin held the guid globals and the engine and core
	// lifecycle tables. Plain os.remove, not gen_core.RemoveStaleFile: that
	// also removes the parent folder, and moonhug/packages/engine is a symlink.
	for stale in _ENGINE_STALE_FILES do if os.exists(stale) do _ = os.remove(stale)
	return true
}

_ENGINE_STALE_FILES := [?]string{
	"moonhug/packages/engine/type_key_generated.odin",
	"moonhug/packages/engine/type_procs_generated.odin",
}

_CORE_PKG_PATH   :: "moonhug/host/core"

// register_type_guids copies (docs/core/Plugins.md): one in the shared
// `registration` package (ALL types — imported by the editor and the tests
// bootstrap, which must work with zero runnable packages), plus one INSIDE
// each runnable package (its own types + library packages, the engine among
// them when installed; other runnable packages are separate programs and
// excluded). Hosts get their own copy because a shared package importing the
// host would cycle.
_generate_type_registration :: proc(entries: []_TypeGuidRow, cleanup_bindings: []_CleanupRow, w: ^db.World) -> bool {
	runnables := gen_facts.runnable_packages(w)
	defer delete(runnables)

	_write_registration(entries, cleanup_bindings, w, "registration", "moonhug/registration", "", runnables[:])
	for host in runnables {
		_write_registration(entries, cleanup_bindings, w, host.name, host.path, host.name, runnables[:])
	}
	return true
}

// host_name == "" writes the shared all-types package.
_write_registration :: proc(entries: []_TypeGuidRow, cleanup_bindings: []_CleanupRow, w: ^db.World, pkg_name, out_dir, host_name: string, runnables: []gen_facts.Runnable_Pkg) {
	included :: proc(e: _TypeGuidRow, host_name: string, runnables: []gen_facts.Runnable_Pkg) -> bool {
		if host_name == "" do return true
		if e.pkg_name == host_name do return true
		return !gen_facts.is_runnable(runnables, e.pkg_name)
	}

	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	fmt.sbprintf(&b, "package %s\n\n", pkg_name)
	if host_name != "" {
		// Self-import: the host's own types reference as <host>.T like every
		// other package's, via the packages: collection.
		fmt.sbprintf(&b, "import \"moonhug:packages/%s\"\n", host_name)
	}
	strings.write_string(&b, "import \"core:encoding/uuid\"\n")
	strings.write_string(&b, "import \"core:sync\"\n")
	strings.write_string(&b, "import core \"moonhug:host/core\"\n")
	// Every other package with a registered type is imported by its scan
	// path, with the declared package name as the alias: subpackages
	// (foo/util) live below their folder name. The engine is one of them
	// when it is installed.
	_Pkg_Import :: struct {
		name: string,
		path: string,
	}
	pkg_imports: [dynamic]_Pkg_Import
	defer delete(pkg_imports)
	for e in entries {
		if !included(e, host_name, runnables) do continue
		if e.pkg_name == "core" || e.pkg_name == host_name do continue
		if !strings.has_prefix(e.pkg_path, "moonhug/") do continue
		found := false
		for p in pkg_imports do if p.name == e.pkg_name { found = true; break }
		if !found do append(&pkg_imports, _Pkg_Import{name = e.pkg_name, path = e.pkg_path})
	}
	slice.sort_by(pkg_imports[:], proc(a, b: _Pkg_Import) -> bool {
		return a.name < b.name
	})
	for p in pkg_imports {
		fmt.sbprintf(&b, "import %s \"moonhug:%s\"\n", p.name, p.path[len("moonhug/"):])
	}
	strings.write_string(&b, "\n")
	strings.write_string(&b, "// Code generated by type_guid_gen. Do not edit.\n\n")
	strings.write_string(&b, "@(private)\n")
	strings.write_string(&b, "_register_type_guids_once: sync.Once\n\n")
	strings.write_string(&b, "register_type_guids :: proc() {\n")
	strings.write_string(&b, "\tsync.once_do(&_register_type_guids_once, proc() {\n")
	for e in entries {
		if !included(e, host_name, runnables) do continue
		// Source locations go to the editor's registration only: a game
		// binary has no use for repo paths.
		if host_name == "" && e.source != "" {
			fmt.sbprintf(&b, "\t\tcore.register_type(%s, uuid.read(%q) or_else uuid.Identifier{{}}, %q)\n", _qualified_type(e), e.guid, e.source)
		} else {
			fmt.sbprintf(&b, "\t\tcore.register_type(%s, uuid.read(%q) or_else uuid.Identifier{{}})\n", _qualified_type(e), e.guid)
		}
	}
	for e in entries {
		if !included(e, host_name, runnables) do continue
		fmt.sbprintf(&b, "\t\tcore.register_type_key(%s, core.TypeKey.%s)\n", _qualified_type(e), e.type_name)
	}
	// The lifecycle tables: core's types from core's generated table, every
	// other package's types here. Here, not in w_init: a type's procs exist
	// as soon as its key does.
	strings.write_string(&b, "\t\tcore.__type_procs_init()\n")
	scratch: [dynamic]_CleanupRow
	defer delete(scratch)
	for e in entries {
		if !included(e, host_name, runnables) || e.pkg_name == "core" do continue
		_write_type_procs(&b, e, cleanup_bindings, &scratch, "\t\t", "core.", fmt.tprintf("%s.", e.pkg_name))
	}
	strings.write_string(&b, "\t})\n")
	strings.write_string(&b, "}\n")

	db.emit(w, fmt.tprintf("%s/type_registration_generated.odin", out_dir), strings.to_string(b))
}

_generate_create_asset_menus :: proc(entries: []_TypeGuidRow, w: ^db.World) -> bool {
	any_menu := false
	for e in entries do if e.create_menu_name != "" { any_menu = true; break }

	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	strings.write_string(&b, "package editor\n\n")
	if any_menu {
		strings.write_string(&b, "import \"core:path/filepath\"\n")
		strings.write_string(&b, "import core \"moonhug:host/core\"\n")
		strings.write_string(&b, "import \"moonhug:host/serialization\"\n")
		strings.write_string(&b, "import \"menu\"\n\n")
	}
	strings.write_string(&b, "// Code generated by type_guid_gen. Do not edit.\n\n")

	for e in entries {
		if e.create_menu_name == "" do continue
		fmt.sbprintf(&b, "__create_asset__%s :: proc() ", e.type_name)
		strings.write_string(&b, "{\n")
		strings.write_string(&b, "\tfull_path, _ := filepath.join({projectViewData.currentPath, ")
		fmt.sbprintf(&b, "%q", e.create_file_name)
		strings.write_string(&b, "}, context.temp_allocator)\n")
		fmt.sbprintf(&b, "\tinstance := core.create_instance_by_type_key(core.TypeKey.%s)\n", e.type_name)
		fmt.sbprintf(&b, "\tserialization.write_asset_to_path(full_path, core.get_guid_by_type_key(core.TypeKey.%s), instance)\n", e.type_name)
		strings.write_string(&b, "}\n\n")
	}

	strings.write_string(&b, "register_create_asset_menus :: proc() {\n")
	for e in entries {
		if e.create_menu_name == "" do continue
		menu_path := strings.concatenate({"Assets/Create/", e.create_menu_name})
		fmt.sbprintf(&b, "\tmenu.add_menu_item(%q, \"\", __create_asset__%s, %d, origin = %q)\n",
			menu_path, e.type_name, e.create_order, e.create_origin)
		delete(menu_path)
	}
	strings.write_string(&b, "}\n")

	db.emit(w, "moonhug/editor/create_asset_menus_generated.odin", strings.to_string(b))
	return true
}

// The type as the registration bundle names it: <pkg>.<T>, or the builtin
// (string) as is.
_qualified_type :: proc(e: _TypeGuidRow) -> string {
	if e.tid_expr != "" do return e.tid_expr
	return fmt.tprintf("%s.%s", e.pkg_name, e.type_name)
}

_bindings_for_type_entry :: proc(cleanup_bindings: []_CleanupRow, e: _TypeGuidRow, out: ^[dynamic]_CleanupRow) {
	clear(out)
	for b in cleanup_bindings {
		if b.target_type == e.type_name do append(out, b)
	}
}

// One type's lifecycle procs as type_register_* calls. `core_q` qualifies the
// core procs ("" inside package core), `q` the type's own package ("" inside
// it). @(cleanup) bindings replace cleanup_T, and several run in priority order.
_write_type_procs :: proc(b: ^strings.Builder, e: _TypeGuidRow, cleanup_bindings: []_CleanupRow, scratch: ^[dynamic]_CleanupRow, indent, core_q, q: string) {
	ct := e.tid_expr != "" ? e.tid_expr : fmt.tprintf("%s%s", q, e.type_name)
	if e.has_reset {
		fmt.sbprintf(b, "%s%stype_register_reset(.%s, proc(ptr: rawptr) {{ %sreset_%s(cast(^%s)ptr) }})\n", indent, core_q, e.type_name, q, e.type_name, ct)
	}
	_bindings_for_type_entry(cleanup_bindings, e, scratch)
	if len(scratch) == 1 {
		fmt.sbprintf(b, "%s%stype_register_cleanup(.%s, proc(ptr: rawptr) {{ %s%s(cast(^%s)ptr) }})\n", indent, core_q, e.type_name, q, scratch[0].proc_name, ct)
	} else if len(scratch) > 1 {
		fmt.sbprintf(b, "%s%stype_register_cleanup(.%s, proc(ptr: rawptr) {{\n", indent, core_q, e.type_name)
		for b0 in scratch {
			fmt.sbprintf(b, "%s\t%s%s(cast(^%s)ptr)\n", indent, q, b0.proc_name, ct)
		}
		fmt.sbprintf(b, "%s})\n", indent)
	} else if e.has_cleanup {
		fmt.sbprintf(b, "%s%stype_register_cleanup(.%s, proc(ptr: rawptr) {{ %scleanup_%s(cast(^%s)ptr) }})\n", indent, core_q, e.type_name, q, e.type_name, ct)
	}
	if e.has_on_validate {
		fmt.sbprintf(b, "%s%stype_register_on_validate(.%s, proc(ptr: rawptr) {{ %son_validate_%s(cast(^%s)ptr) }})\n", indent, core_q, e.type_name, q, e.type_name, ct)
	}
}

// Checks every @(cleanup) binding, then writes core's lifecycle table:
// moonhug/host/core/type_procs_generated.odin, called first by every
// registration bundle. The other packages' types register theirs in the
// bundles (_write_registration).
_generate_type_procs :: proc(entries: []_TypeGuidRow, cleanup_bindings: []_CleanupRow, w: ^db.World) -> bool {
	for cb in cleanup_bindings {
		target: ^_TypeGuidRow
		for &e in entries do if e.type_name == cb.target_type { target = &e; break }
		if target == nil {
			fmt.eprintf("type_guid_gen: @(cleanup) references unknown type %q (proc %s.%s)\n", cb.target_type, cb.pkg_name, cb.proc_name)
			return false
		}
		// The binding is called from the type's registration, which reaches
		// the type's package and core only.
		if target.pkg_name != cb.pkg_name {
			fmt.eprintf("type_guid_gen: @(cleanup) proc %s.%s frees %s.%s: declare it in package %s\n", cb.pkg_name, cb.proc_name, target.pkg_name, target.type_name, target.pkg_name)
			return false
		}
	}

	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	strings.write_string(&b, "package core\n\n")
	strings.write_string(&b, "// Code generated by type_guid_gen. Do not edit.\n")
	strings.write_string(&b, "// The core types' lifecycle procs (type_lifecycle.odin). Every registration\n")
	strings.write_string(&b, "// bundle calls __type_procs_init, then registers its packages' types.\n\n")
	strings.write_string(&b, "__type_procs_init :: proc() {\n")
	scratch: [dynamic]_CleanupRow
	defer delete(scratch)
	for e in entries {
		if e.pkg_name != "core" do continue
		_write_type_procs(&b, e, cleanup_bindings, &scratch, "\t", "", "")
	}
	strings.write_string(&b, "}\n")

	db.emit(w, fmt.tprintf("%s/type_procs_generated.odin", _CORE_PKG_PATH), strings.to_string(b))
	return true
}
