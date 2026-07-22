package gen_facts

// gen_facts is the cycle-free bottom layer of shared base-fact components: the
// classification facts that nearly every generator needs and would otherwise
// re-derive from the raw AST. A single classifier provider walks every decl once
// and populates these into the central gen_db registry, so any module reads them
// by type (get_comps) instead of re-casting `v_decl.values[0].derived`.
//
// These types live here, below every *_gen module, because they are the shared
// vocabulary the whole codebase depends on - putting them in any one provider
// package would create import cycles (the "core for problematic cases" rule).
// Per-attribute and module-specific components stay co-located in their own
// provider packages; only the universal base facts live here.
//
// Provided components (all keyed by the same Entity as DeclInfo):
//   Kind_GenComp       - Other | Proc | Struct | Union (the most-shared classification)
//   Proc_GenComp   - present if the decl is a proc; carries proc-level facts
//   Struct_GenComp - present if the decl is a struct or union
//
// These are consumed both in Generate (as join filters: "this entity is a proc
// AND has MenuItemAttr") and by other PROVIDERS (a provider may filter on
// Struct_GenComp before parsing). So the classifier registers at Provide order -1,
// guaranteeing it runs before every default-order provider - structurally, not
// by name. Attribute payloads are NOT here: per-attribute
// providers read `DeclInfo.decl.attributes` directly and emit their own
// typed components.

import "core:odin/ast"
import "core:slice"
import "core:strings"
import "../gen_core"
import db "../gen_db"

// Attr_Args / Struct_Field are gen_core's plain-data view of the AST, re-exported
// here so consumers import only gen_facts. Attrs_GenComp / Fields_GenComp carry
// them per entity, so no module unwraps `^ast.*` itself.
Attr_Args    :: gen_core.Attr_Args
Struct_Field :: gen_core.Struct_Field

// Attrs_GenComp holds every @(...) attribute on a decl, flattened to strings.
// Present if the decl has at least one attribute. Read a key with attr_find /
// attr_int below; gen_facts stays agnostic of what any key MEANS.
Attrs_GenComp :: struct {
	attrs: []Attr_Args,
}

// Fields_GenComp holds a struct decl's fields as plain data. Present if the
// decl is a struct with at least one named field.
Fields_GenComp :: struct {
	fields: []Struct_Field,
}

// attr_find / attr_int: thin pass-throughs to gen_core so consumers needn't
// import gen_core just to read an Attrs_GenComp.
attr_find :: proc(comp: ^Attrs_GenComp, key: string) -> (Attr_Args, bool) {
	if comp == nil do return {}, false
	return gen_core.AttrFind(comp.attrs, key)
}
attr_int :: gen_core.AttrInt

// attr_nested returns a nested compound-literal member of an attribute
// (e.g. typ_guid's "menu_assets_create"), if present.
attr_nested :: proc(args: Attr_Args, key: string) -> (Attr_Args, bool) {
	n, ok := args.nested[key]
	return n, ok
}

// attr_keyname reads a field as an enum-variant name: the last dotted segment,
// reproducing gen_core.ExtractKeyName (e.g. "app.Phase.Init" -> "Init").
attr_keyname :: proc(args: Attr_Args, field: string) -> string {
	s, ok := args.fields[field]
	if !ok do return ""
	if i := strings_last_dot(s); i >= 0 do return s[i+1:]
	return s
}
strings_last_dot :: proc(s: string) -> int {
	for i := len(s) - 1; i >= 0; i -= 1 {
		if s[i] == '.' do return i
	}
	return -1
}

// DeclKind classifies a declaration's value. Computed once by the classifier.
DeclKind :: enum {
	Other,
	Proc,
	Struct,
	Union,
}

// Kind_GenComp is a get_or_create_comps carrying just the classification, on EVERY decl entity.
// (A one-field get_or_create_comps rather than a field on DeclInfo, so gen_db stays
// agnostic of AST-derived facts and the classifier owns it.)
Kind_GenComp :: struct {
	kind: DeclKind,
}

// Proc_GenComp is attached only to entities whose decl is a proc literal.
Proc_GenComp :: struct {
	no_args: bool, // true if the proc takes no parameters (phase_gen needs this)
}

// Struct_GenComp is attached only to entities whose decl is a struct or union.
Struct_GenComp :: struct {
	is_union: bool, // false => struct
}

@(init)
_register :: proc "contextless" () {
	// order -1: runs before all default (order 0) providers, so any provider
	// may compose against these base facts.
	db.provider("gen_facts/classify", classify, order = -1)
}

// classify walks every decl entity once and tags it with Kind_GenComp, plus Proc_GenComp /
// Struct_GenComp where applicable.
classify :: proc(w: ^db.World) -> bool {
	decls := db.get_comps_DeclInfo()

	kinds   := db.get_or_create_comps(w, Kind_GenComp)
	procs   := db.get_or_create_comps(w, Proc_GenComp)
	structs := db.get_or_create_comps(w, Struct_GenComp)
	attrs   := db.get_or_create_comps(w, Attrs_GenComp)
	fields  := db.get_or_create_comps(w, Fields_GenComp)

	// Same-package string constants, built once per package, so attribute values
	// written as `guid = SOME_CONST` resolve to the constant's value.
	constants_cache := make(map[string]map[string]string)
	defer {
		for _, c in constants_cache do delete(c)
		delete(constants_cache)
	}

	for &d, i in decls.rows[:db.comps_len(decls)] {
		e := db.get_entity(decls, i)
		v := d.decl
		if v == nil do continue

		kind := DeclKind.Other
		if len(v.values) > 0 {
			#partial switch pv in v.values[0].derived {
			case ^ast.Proc_Lit:
				kind = .Proc
				no_args := false
				if pt, ok_type := pv.type.derived.(^ast.Proc_Type); ok_type {
					no_args = pt.params == nil || len(pt.params.list) == 0
				}
				db.set(procs, e, Proc_GenComp{no_args = no_args})
			case ^ast.Struct_Type:
				kind = .Struct
				db.set(structs, e, Struct_GenComp{is_union = false})
			case ^ast.Union_Type:
				kind = .Union
				db.set(structs, e, Struct_GenComp{is_union = true})
			}
		}
		db.set(kinds, e, Kind_GenComp{kind = kind})

		// Materialize the AST into plain data once, so no module re-walks it.
		if v.attributes != nil && len(v.attributes) > 0 {
			consts := _pkg_constants(&constants_cache, d.pkg_path, d.pkg)
			if a := gen_core.DeclAttrs(v, consts); len(a) > 0 {
				db.set(attrs, e, Attrs_GenComp{attrs = a})
			}
		}
		if f := gen_core.StructFields(v); len(f) > 0 {
			db.set(fields, e, Fields_GenComp{fields = f})
		}
	}
	return true
}

// _pkg_constants returns the same-package string constants for pkg_path, built
// once and cached. Returns nil if the package has no constants.
_pkg_constants :: proc(cache: ^map[string]map[string]string, pkg_path: string, pkg: ^ast.Package) -> ^map[string]string {
	if c, ok := &cache[pkg_path]; ok do return c
	cache[pkg_path] = gen_core.BuildConstants(pkg)
	return &cache[pkg_path]
}

// ---------------------------------------------------------------------------
// Runnable packages ("app-like", docs/Plugins.md): an installed package whose
// ROOT declares `main :: proc()`. Each one hosts its own generated dispatcher
// set (update_gen, phase_gen, type_guid_gen, packages_gen) and builds as an
// executable. 0..N of them may be installed — the editor depends on none.

Runnable_Pkg :: struct {
	name: string, // package name ("app")
	path: string, // scan path ("moonhug/packages/app")
}

// Sorted by name. Result is allocated with context.allocator — delete it.
runnable_packages :: proc(w: ^db.World) -> [dynamic]Runnable_Pkg {
	out := make([dynamic]Runnable_Pkg)
	decls := db.get_comps_DeclInfo()
	procs := db.get_comps(w, Proc_GenComp)
	m := db.all_of(db.r(decls), db.r(procs))
	defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		decl := db.get(decls, entity)
		if decl.name != "main" do continue
		if !strings.has_prefix(decl.pkg_path, "moonhug/packages/") do continue
		if strings.has_suffix(decl.pkg_path, "/editor") do continue
		dup := false
		for r in out do if r.path == decl.pkg_path { dup = true; break }
		if !dup do append(&out, Runnable_Pkg{name = decl.pkg.name, path = decl.pkg_path})
	}
	slice.sort_by(out[:], proc(a, b: Runnable_Pkg) -> bool { return a.name < b.name })
	return out
}

// True when pkg_name is one of the runnable packages.
is_runnable :: proc(runnables: []Runnable_Pkg, pkg_name: string) -> bool {
	for r in runnables do if r.name == pkg_name do return true
	return false
}
