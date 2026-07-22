package type_guid_gen

// type_guid_gen: ECS prebuild generator.
//
//   provide  - query {DeclInfo}, recognise @typ_guid structs/unions (tag with
//              TypeGuid_GenComp) and @cleanup-annotated procs in package engine
//              (tag with Cleanup_GenComp).
//   generate - query the tags, sort, build the four generated files, emit them.
//
// String-building output is identical to the previous collect/generate version.

import "core:fmt"
import "core:slice"
import "core:strings"
import "../gen_core"
import db "../gen_db"
import "../gen_facts"

CreateAssetMenuData :: struct {
	file_name: string,
	menu_name: string,
	order:     int,
}

// TypeGuid_GenComp marks a DeclInfo entity as a @typ_guid struct/union. The type
// name lives on the entity's DeclInfo; pkg_name is derived from DeclInfo.pkg_path.
TypeGuid_GenComp :: struct {
	pkg_name:         string,
	pkg_path:         string, // scan path; "" for synthetic types
	guid:             string,
	make_proc:        string,
	has_reset:        bool,
	has_cleanup:      bool,
	create_file_name: string,
	create_menu_name: string,
	create_order:     int,
}

// Cleanup_GenComp marks a DeclInfo entity as an @cleanup-annotated proc (engine pkg).
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
}

// provide_synthetic lets a sibling module register a type it emits as a
// typ_guid type. Called from that module's provider (Provide stage).
provide_synthetic :: proc(w: ^db.World, name, pkg_name, guid: string) -> bool {
	append(&_synthetic, _TypeGuidRow{pkg_name = pkg_name, type_name = name, guid = guid})
	return true
}

_has_typ_guid_attr :: proc(attr_set: ^gen_facts.Attrs_GenComp) -> (guid: string, makeProcName: string, create: CreateAssetMenuData, has_create_menu: bool, found: bool) {
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

_pkg_name_from_path :: proc(pkg_path: string) -> string {
	if i := strings.last_index(pkg_path, "/"); i >= 0 && i + 1 < len(pkg_path) {
		return pkg_path[i + 1:]
	}
	return pkg_path
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
		pkg_name := _pkg_name_from_path(decl.pkg_path)
		attr_set := db.get(attrs, entity)

		// @typ_guid structs/unions. Editor subpackages are excluded: their
		// types can't be referenced from the app-side registration file.
		type_name := decl.name
		if type_name != "" && db.has(structs, entity) && !strings.has_suffix(decl.pkg_path, "/editor") {
			guid, make_proc, create, has_create_menu, found := _has_typ_guid_attr(attr_set)
			if found {
				reset_name   := strings.concatenate({"reset_",   type_name})
				cleanup_name := strings.concatenate({"cleanup_", type_name})
				tag := TypeGuid_GenComp{
					pkg_name    = pkg_name,
					pkg_path    = decl.pkg_path,
					guid        = guid,
					make_proc   = make_proc,
					has_reset   = gen_core.FileHasProc(decl.file, reset_name),
					has_cleanup = gen_core.FileHasProc(decl.file, cleanup_name),
				}
				delete(reset_name)
				delete(cleanup_name)
				if has_create_menu {
					tag.create_file_name = create.file_name
					if tag.create_file_name == "" do tag.create_file_name = strings.concatenate({type_name, ".asset"})
					tag.create_menu_name = create.menu_name
					if tag.create_menu_name == "" do tag.create_menu_name = type_name
					tag.create_order = create.order
				}
				db.set(guids, entity, tag)
			}
		}

		// @cleanup procs, only in package engine.
		if pkg_name == "engine" && db.has(procs, entity) {
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
	make_proc:        string,
	has_reset:        bool,
	has_cleanup:      bool,
	create_file_name: string,
	create_menu_name: string,
	create_order:     int,
	tid_expr:         string,
}

_CleanupRow :: struct {
	target_type: string,
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
			pkg_name  = "engine",
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
				make_proc        = guid.make_proc,
				has_reset        = guid.has_reset,
				has_cleanup      = guid.has_cleanup,
				create_file_name = guid.create_file_name,
				create_menu_name = guid.create_menu_name,
				create_order     = guid.create_order,
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
	if !_generate_type_registration(entries[:], w) do return false
	if !_generate_create_asset_menus(entries[:], w) do return false
	return true
}

_generate_type_key :: proc(entries: []_TypeGuidRow, w: ^db.World) -> bool {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	strings.write_string(&b, "package engine\n\n")
	strings.write_string(&b, "import \"core:encoding/uuid\"\n\n")
	strings.write_string(&b, "// Code generated by type_guid_gen. Do not edit.\n\n")
	strings.write_string(&b, "TypeKey :: enum u16 {\n")
	for e in entries {
		fmt.sbprintf(&b, "\t%s,\n", e.type_name)
	}
	strings.write_string(&b, "}\n\n")
	strings.write_string(&b, "INVALID_TYPE_KEY :: TypeKey(max(u16))\n\n")
	strings.write_string(&b, "UUID_NIL :: uuid.Identifier{};\n")
	for e in entries {
		fmt.sbprintf(&b, "%s__Guid := uuid.read(%q) or_else UUID_NIL\n", e.type_name, e.guid)
	}

	db.emit(w, "moonhug/engine/type_key_generated.odin", strings.to_string(b))
	return true
}

_PACKAGES_PREFIX :: "moonhug/packages/"

// register_type_guids copies (docs/Plugins.md): one in the shared
// `registration` package (ALL types — imported by the editor and the tests
// bootstrap, which must work with zero runnable packages), plus one INSIDE
// each runnable package (its own types + engine + library packages; other
// runnable packages are separate programs and excluded). Hosts get their own
// copy because a shared package importing the host would cycle.
_generate_type_registration :: proc(entries: []_TypeGuidRow, w: ^db.World) -> bool {
	runnables := gen_facts.runnable_packages(w)
	defer delete(runnables)

	_write_registration(entries, w, "registration", "moonhug/engine/registration", "..", "", runnables[:])
	for host in runnables {
		_write_registration(entries, w, host.name, host.path, "moonhug:engine", host.name, runnables[:])
	}
	return true
}

// host_name == "" writes the shared all-types package.
_write_registration :: proc(entries: []_TypeGuidRow, w: ^db.World, pkg_name, out_dir, engine_rel, host_name: string, runnables: []gen_facts.Runnable_Pkg) {
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
	fmt.sbprintf(&b, "import \"%s\"\n", engine_rel)
	strings.write_string(&b, "import \"core:sync\"\n")
	// Types declared by installed packages are reached through the packages:
	// collection (docs/Plugins.md).
	pkg_imports: [dynamic]string
	defer delete(pkg_imports)
	for e in entries {
		if !included(e, host_name, runnables) do continue
		if !strings.has_prefix(e.pkg_path, _PACKAGES_PREFIX) do continue
		if e.pkg_name == host_name do continue
		found := false
		for p in pkg_imports do if p == e.pkg_name { found = true; break }
		if !found do append(&pkg_imports, e.pkg_name)
	}
	slice.sort(pkg_imports[:])
	for p in pkg_imports {
		fmt.sbprintf(&b, "import %s \"moonhug:packages/%s\"\n", p, p)
	}
	strings.write_string(&b, "\n")
	strings.write_string(&b, "// Code generated by type_guid_gen. Do not edit.\n\n")
	strings.write_string(&b, "@(private)\n")
	strings.write_string(&b, "_register_type_guids_once: sync.Once\n\n")
	strings.write_string(&b, "register_type_guids :: proc() {\n")
	strings.write_string(&b, "\tsync.once_do(&_register_type_guids_once, proc() {\n")
	for e in entries {
		if !included(e, host_name, runnables) do continue
		type_arg := fmt.tprintf("%s.%s", e.pkg_name, e.type_name)
		if e.tid_expr != "" {
			type_arg = e.tid_expr
		}
		if e.make_proc != "" {
			fmt.sbprintf(
				&b,
				"\t\tengine.register_type(%s, engine.%s__Guid, %s.%s)\n",
				type_arg,
				e.type_name,
				e.pkg_name,
				e.make_proc,
			)
		} else {
			fmt.sbprintf(&b, "\t\tengine.register_type(%s, engine.%s__Guid)\n", type_arg, e.type_name)
		}
	}
	for e in entries {
		if !included(e, host_name, runnables) do continue
		type_arg := fmt.tprintf("%s.%s", e.pkg_name, e.type_name)
		if e.tid_expr != "" {
			type_arg = e.tid_expr
		}
		fmt.sbprintf(&b, "\t\tengine.register_type_key(%s, engine.TypeKey.%s)\n", type_arg, e.type_name)
	}
	strings.write_string(&b, "\t})\n")
	strings.write_string(&b, "}\n")

	db.emit(w, fmt.tprintf("%s/type_registration_generated.odin", out_dir), strings.to_string(b))
}

_generate_create_asset_menus :: proc(entries: []_TypeGuidRow, w: ^db.World) -> bool {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	strings.write_string(&b, "package editor\n\n")
	strings.write_string(&b, "import \"core:path/filepath\"\n")
	strings.write_string(&b, "import \"../engine\"\n")
	strings.write_string(&b, "import \"../engine/serialization\"\n")
	strings.write_string(&b, "import \"menu\"\n\n")
	strings.write_string(&b, "// Code generated by type_guid_gen. Do not edit.\n\n")

	for e in entries {
		if e.create_menu_name == "" do continue
		fmt.sbprintf(&b, "__create_asset__%s :: proc() ", e.type_name)
		strings.write_string(&b, "{\n")
		strings.write_string(&b, "\tfull_path, _ := filepath.join({projectViewData.currentPath, ")
		fmt.sbprintf(&b, "%q", e.create_file_name)
		strings.write_string(&b, "}, context.temp_allocator)\n")
		fmt.sbprintf(&b, "\tinstance := engine.create_instance_by_type_key(engine.TypeKey.%s)\n", e.type_name)
		fmt.sbprintf(&b, "\tserialization.write_asset_to_path(full_path, engine.get_guid_by_type_key(engine.TypeKey.%s), instance)\n", e.type_name)
		strings.write_string(&b, "}\n\n")
	}

	strings.write_string(&b, "register_create_asset_menus :: proc() {\n")
	for e in entries {
		if e.create_menu_name == "" do continue
		menu_path := strings.concatenate({"Assets/Create/", e.create_menu_name})
		fmt.sbprintf(&b, "\tmenu.add_menu_item(%q, \"\", __create_asset__%s, %d)\n", menu_path, e.type_name, e.create_order)
		delete(menu_path)
	}
	strings.write_string(&b, "}\n")

	db.emit(w, "moonhug/editor/create_asset_menus_generated.odin", strings.to_string(b))
	return true
}

_entry_cast_type :: proc(e: _TypeGuidRow) -> string {
	if e.tid_expr != "" {
		return e.tid_expr
	}
	return e.type_name
}

_cleanup_binding_matches_entry :: proc(b: _CleanupRow, e: _TypeGuidRow) -> bool {
	return b.target_type == e.type_name
}

_bindings_for_type_entry :: proc(cleanup_bindings: []_CleanupRow, e: _TypeGuidRow, out: ^[dynamic]_CleanupRow) {
	clear(out)
	for b in cleanup_bindings {
		if _cleanup_binding_matches_entry(b, e) do append(out, b)
	}
}

_cleanup_binding_target_valid :: proc(entries: []_TypeGuidRow, target: string) -> bool {
	for e in entries {
		if _cleanup_binding_matches_entry(_CleanupRow{target_type = target}, e) do return true
	}
	return false
}

_generate_type_procs :: proc(entries: []_TypeGuidRow, cleanup_bindings: []_CleanupRow, w: ^db.World) -> bool {
	for b in cleanup_bindings {
		if !_cleanup_binding_target_valid(entries, b.target_type) {
			fmt.eprintf(
				"type_guid_gen: @(cleanup) references unknown type %q (proc %q)\n",
				b.target_type,
				b.proc_name,
			)
			return false
		}
	}

	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	strings.write_string(&b, "package engine\n\n")
	strings.write_string(&b, "// Code generated by type_guid_gen. Do not edit.\n\n")

	strings.write_string(&b, "__type_resets_init :: proc() {\n")
	for e in entries {
		if e.pkg_name != "engine" do continue // registered at runtime via Component_Desc
		if e.has_reset {
			ct := _entry_cast_type(e)
			fmt.sbprintf(&b, "\ttype_reset_procs[.%s] = proc(ptr: rawptr) {{ reset_%s(cast(^%s)ptr) }}\n", e.type_name, e.type_name, ct)
		}
	}
	strings.write_string(&b, "}\n\n")

	strings.write_string(&b, "__type_cleanups_init :: proc() {\n")
	scratch: [dynamic]_CleanupRow
	defer delete(scratch)
	for e in entries {
		if e.pkg_name != "engine" do continue // registered at runtime via Component_Desc
		_bindings_for_type_entry(cleanup_bindings, e, &scratch)
		ct := _entry_cast_type(e)
		if len(scratch) == 1 {
			b0 := scratch[0]
			fmt.sbprintf(
				&b,
				"\ttype_cleanup_procs[.%s] = proc(ptr: rawptr) {{ %s(cast(^%s)ptr) }}\n",
				e.type_name,
				b0.proc_name,
				ct,
			)
		} else if len(scratch) > 1 {
			fmt.sbprintf(&b, "\ttype_cleanup_procs[.%s] = proc(ptr: rawptr) {{\n", e.type_name)
			for b0 in scratch {
				fmt.sbprintf(&b, "\t\t%s(cast(^%s)ptr)\n", b0.proc_name, ct)
			}
			strings.write_string(&b, "\t}\n")
		} else if e.has_cleanup {
			fmt.sbprintf(&b, "\ttype_cleanup_procs[.%s] = proc(ptr: rawptr) {{ cleanup_%s(cast(^%s)ptr) }}\n", e.type_name, e.type_name, ct)
		}
	}
	strings.write_string(&b, "}\n")

	db.emit(w, "moonhug/engine/type_procs_generated.odin", strings.to_string(b))
	return true
}
