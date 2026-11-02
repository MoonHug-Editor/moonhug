package asset_doc_gen

// asset_doc_gen: the procs a package attaches to an asset type's document in
// the Project Inspector (docs/core/Plugins.md, "Asset types").
//
//   @(asset_doc={type=engine.Material})
//   doc_on_changed_Material :: proc(guid: core.Asset_GUID, doc: any) { ... }
//
//   The name is the contract, as type_reset_<Type> and type_cleanup_<Type> are:
//   doc_on_changed_<Type>  proc(guid: core.Asset_GUID, doc: any)      once per change of the document, by any route
//   doc_on_saved_<Type>    proc(guid: core.Asset_GUID, path: string)  once after the document is saved
//   <Type> is the type's own name, without its package.
//
// Rows around a document's fields are an inspector wrapper on the type
// (inspector_funnel.odin), not a hook here.
//
//   generate - moonhug/registration/asset_docs_generated.odin:
//              register_asset_docs(), called by the editor and the tests
//              bootstrap right after inspector.init. One registration per
//              declaration. The registration package, not the inspector:
//              the declaring packages import the inspector.

import "core:fmt"
import "core:slice"
import "core:strings"
import db "../gen_db"
import "../gen_facts"

_OUT_DIR  :: "moonhug/registration"
_PKG_NAME :: "registration"

Asset_Doc_Entry :: struct {
	type_expr:     string, // "engine.Material", with the alias the generated file imports under
	type_path:     string, // the type's package import path, "" for the inspector's own
	hook:          string,
	proc_name:     string,
	proc_pkg:      string,
	proc_path:     string, // scan path of the proc's package
	origin:        string,
}

AssetDoc_GenComp :: struct {
	entry: Asset_Doc_Entry,
}

@(init)
_register :: proc "contextless" () {
	db.provider("asset_doc/provide", provide)
	db.generator("asset_doc/generate", generate)
}

provide :: proc(w: ^db.World) -> bool {
	hooks := db.get_or_create_comps(w, AssetDoc_GenComp)
	decls := db.get_comps_DeclInfo()
	procs := db.get_comps(w, gen_facts.Proc_GenComp)
	attrs := db.get_comps(w, gen_facts.Attrs_GenComp)

	m := db.all_of(db.r(decls), db.r(attrs)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		decl := db.get(decls, entity)
		if decl.name == "" do continue
		args, found := gen_facts.attr_find(db.get(attrs, entity), "asset_doc")
		if !found do continue
		if db.get(procs, entity) == nil {
			fmt.eprintf("asset_doc: %s.%s must be a proc\n", decl.pkg.name, decl.name)
			return false
		}
		type_name := args.fields["type"]
		if type_name == "" {
			fmt.eprintf("asset_doc: %s.%s needs type=<Type>\n", decl.pkg.name, decl.name)
			return false
		}
		// The hook is the name's prefix, the type its suffix.
		hook, prefix_len := "", 0
		for prefix in ([]string{"doc_on_changed_", "doc_on_saved_"}) {
			if strings.has_prefix(decl.name, prefix) {
				hook = prefix[len("doc_"):len(prefix) - 1]
				prefix_len = len(prefix)
			}
		}
		bare := type_name
		if dot := strings.last_index_byte(bare, '.'); dot >= 0 do bare = bare[dot + 1:]
		if hook == "" || decl.name[prefix_len:] != bare {
			fmt.eprintf("asset_doc: %s.%s must be named doc_on_changed_%s or doc_on_saved_%s\n", decl.pkg.name, decl.name, bare, bare)
			return false
		}
		// The type's package, through the declaring file's import of its alias.
		type_path := ""
		if dot := strings.index_byte(type_name, '.'); dot >= 0 {
			path, ok := gen_facts.file_import(decl, type_name[:dot])
			if !ok {
				fmt.eprintf("asset_doc: %s.%s: %s is not imported by its file\n", decl.pkg.name, decl.name, type_name[:dot])
				return false
			}
			type_path = path
		} else {
			type_path = gen_facts.pkg_import_path(decl.pkg_path)
			type_name = strings.concatenate({decl.pkg.name, ".", type_name})
		}
		db.set(hooks, entity, AssetDoc_GenComp{entry = {
			type_expr = type_name,
			type_path = type_path,
			hook      = hook,
			proc_name = decl.name,
			proc_pkg  = decl.pkg.name,
			proc_path = decl.pkg_path,
			origin    = gen_facts.attr_origin(args, gen_facts.decl_rel_path(decl), decl.decl.pos.line, decl.name),
		}})
	}
	return true
}

generate :: proc(w: ^db.World) -> bool {
	entries: [dynamic]Asset_Doc_Entry
	defer delete(entries)
	hooks := db.get_comps(w, AssetDoc_GenComp)
	for &c in hooks.rows[:db.comps_len(hooks)] do append(&entries, c.entry)

	// One alias per import path: the first file's alias wins, and every type
	// expression is rewritten to it.
	alias_of: map[string]string // import path -> alias
	defer delete(alias_of)
	for &e in entries {
		if e.type_path == "" do continue
		dot := strings.index_byte(e.type_expr, '.')
		alias := e.type_expr[:dot]
		if known, has := alias_of[e.type_path]; has {
			if known != alias do e.type_expr = strings.concatenate({known, e.type_expr[dot:]})
		} else {
			alias_of[e.type_path] = alias
		}
	}
	for &e in entries {
		path := gen_facts.pkg_import_path(e.proc_path)
		if known, has := alias_of[path]; has {
			e.proc_pkg = known
		} else {
			alias_of[path] = e.proc_pkg
		}
	}

	slice.sort_by(entries[:], proc(a, b: Asset_Doc_Entry) -> bool {
		if a.type_expr != b.type_expr do return a.type_expr < b.type_expr
		if a.hook != b.hook do return a.hook < b.hook
		return a.proc_name < b.proc_name
	})

	Import :: struct { alias, path: string }
	imports: [dynamic]Import
	defer delete(imports)
	for path, alias in alias_of do append(&imports, Import{alias, path})
	slice.sort_by(imports[:], proc(a, b: Import) -> bool { return a.alias < b.alias })

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	fmt.sbprintf(&b, "package %s\n\n", _PKG_NAME)
	// With no declaration installed the proc is empty and imports nothing.
	if len(entries) > 0 do strings.write_string(&b, "import __inspector \"moonhug:editor/inspector\"\n")
	for i in imports do fmt.sbprintf(&b, "import %s \"%s\"\n", i.alias, i.path)
	strings.write_string(&b, "\n// Code generated by asset_doc_gen. Do not edit.\n\n")
	strings.write_string(&b, "// Every @(asset_doc) declaration, keyed by its asset type.\n")
	strings.write_string(&b, "register_asset_docs :: proc() {\n")
	for e in entries {
		proc_ref := fmt.tprintf("%s.%s", e.proc_pkg, e.proc_name)
		switch e.hook {
		case "on_changed": fmt.sbprintf(&b, "\t__inspector.doc_changed_register(typeid_of(%s), %s)\n", e.type_expr, proc_ref)
		case "on_saved":   fmt.sbprintf(&b, "\t__inspector.doc_saved_register(typeid_of(%s), %s)\n", e.type_expr, proc_ref)
		}
	}
	strings.write_string(&b, "}\n")
	db.emit(w, _OUT_DIR + "/asset_docs_generated.odin", strings.to_string(b))
	return true
}
