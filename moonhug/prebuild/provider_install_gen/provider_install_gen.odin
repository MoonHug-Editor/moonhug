package provider_install_gen

// provider_install_gen: prebuild module for the two providers_generated.odin files.
//
//   provide  - query {DeclInfo, Attrs}, recognise declarations carrying
//              @(provider_install), tag each with an Install_GenComp. The
//              attribute goes on a proc with no parameters, anything else
//              stops the build.
//   generate - query {DeclInfo, Install_GenComp}, sort by (package path, proc
//              name), emit `install_providers :: proc()` calling each proc,
//              twice with the same body:
//              - moonhug/editor/providers_generated.odin (package editor),
//                called by editor_init right after inspector.init
//              - moonhug/tests/common/providers_generated.odin (package
//                tests_common), called by _register_once, since the test
//                binary runs no editor phases
//
// The calls are explicit, not an @(phase) subscriber: a generated @(phase)
// proc is one prebuild behind. A marked proc in the editor's own package
// (moonhug/editor) stops the build, because tests/common does not import the
// editor root.

import "core:fmt"
import "core:slice"
import "core:strings"
import db "../gen_db"
import "../gen_facts"

_ATTR :: "provider_install"
_EDITOR_PKG_PATH :: "moonhug/editor"
_COLLECTION_ROOT :: "moonhug/"

Install_Entry :: struct {
	name:     string,
	pkg_name: string,
	pkg_path: string,
	// Where the proc is declared, rendered by gen_facts.attr_origin.
	origin:   string,
}

Install_GenComp :: struct {
	entry: Install_Entry,
}

@(init)
_register :: proc "contextless" () {
	db.provider("provider_install/provide", provide)
	db.generator("provider_install/generate", generate)
}

provide :: proc(w: ^db.World) -> bool {
	installs := db.get_or_create_comps(w, Install_GenComp)
	decls := db.get_comps_DeclInfo()
	procs := db.get_comps(w, gen_facts.Proc_GenComp)
	attrs := db.get_comps(w, gen_facts.Attrs_GenComp)

	ok := true
	m := db.all_of(db.r(decls), db.r(attrs)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		decl := db.get(decls, entity)
		if decl.name == "" do continue
		for args in db.get(attrs, entity).attrs {
			if args.key != _ATTR do continue
			at := gen_facts.decl_rel_path(decl)
			if !db.has(procs, entity) || !db.get(procs, entity).no_args {
				fmt.eprintf("provider_install_gen: %s: @(provider_install) %s must be a proc with no parameters\n", at, decl.name)
				ok = false
				break
			}
			if decl.pkg_path == _EDITOR_PKG_PATH {
				fmt.eprintf("provider_install_gen: %s: @(provider_install) %s is in the editor root package, which tests/common does not import: move it to a subpackage\n", at, decl.name)
				ok = false
				break
			}
			if !strings.has_prefix(decl.pkg_path, _COLLECTION_ROOT) {
				fmt.eprintf("provider_install_gen: %s: @(provider_install) %s is outside the moonhug collection\n", at, decl.name)
				ok = false
				break
			}
			db.set(installs, entity, Install_GenComp{entry = Install_Entry{
				name     = decl.name,
				pkg_name = decl.pkg.name,
				pkg_path = decl.pkg_path,
				origin   = gen_facts.attr_origin(args, at, decl.decl.pos.line, decl.name),
			}})
			break
		}
	}
	return ok
}

generate :: proc(w: ^db.World) -> bool {
	entries: [dynamic]Install_Entry
	defer delete(entries)

	decls := db.get_comps_DeclInfo()
	installs := db.get_comps(w, Install_GenComp)
	m := db.all_of(db.r(decls), db.r(installs)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		append(&entries, db.get(installs, entity).entry)
	}

	slice.sort_by(entries[:], proc(a, b: Install_Entry) -> bool {
		if a.pkg_path != b.pkg_path do return a.pkg_path < b.pkg_path
		return a.name < b.name
	})

	// One import per package, named by the package name. Two packages with
	// the same name would need aliases the calls do not use, so they stop the
	// build instead.
	path_of_name := make(map[string]string, context.temp_allocator)
	import_names := make([dynamic]string, context.temp_allocator)
	for e in entries {
		if prev, seen := path_of_name[e.pkg_name]; seen {
			if prev != e.pkg_path {
				fmt.eprintf("provider_install_gen: packages %s and %s are both named %q, rename one\n", prev, e.pkg_path, e.pkg_name)
				return false
			}
			continue
		}
		path_of_name[e.pkg_name] = e.pkg_path
		append(&import_names, e.pkg_name)
	}
	slice.sort(import_names[:])

	editor_ok := _emit(w, "moonhug/editor/providers_generated.odin", "editor", "editor_init calls it right after inspector.init.", entries[:], import_names[:], path_of_name)
	tests_ok := _emit(w, "moonhug/tests/common/providers_generated.odin", "tests_common", "_register_once calls it, the test binary runs no editor phases.", entries[:], import_names[:], path_of_name)
	return editor_ok && tests_ok
}

@(private = "file")
_emit :: proc(w: ^db.World, path, pkg, caller: string, entries: []Install_Entry, import_names: []string, path_of_name: map[string]string) -> bool {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	fmt.sbprintf(&b, "package %s\n\n", pkg)
	strings.write_string(&b, "// Code generated by provider_install_gen. Do not edit.\n")
	strings.write_string(&b, "// Every @(provider_install) proc of the scanned packages, by package path\n")
	fmt.sbprintf(&b, "// then proc name. %s\n\n", caller)
	for name in import_names {
		fmt.sbprintf(&b, "import %s \"moonhug:%s\"\n", name, strings.trim_prefix(path_of_name[name], _COLLECTION_ROOT))
	}
	if len(import_names) > 0 do strings.write_string(&b, "\n")
	strings.write_string(&b, "install_providers :: proc() {\n")
	for e in entries {
		fmt.sbprintf(&b, "\t%s.%s() // %s\n", e.pkg_name, e.name, e.origin)
	}
	strings.write_string(&b, "}\n")
	return db.emit(w, path, strings.to_string(b))
}
