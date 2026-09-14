package union_gen

// union_gen: ECS prebuild module.
//
//   provide  - tag every hand-written union decl whose variants ALL carry
//              @(typ_guid) with Union_GenComp. Those are exactly the unions
//              that can go through the guid-tagged serializer
//              (engine/serialization/union_serialization.odin).
//   generate - one <pkg_path>/unions_generated.odin per package with at least
//              one, queuing each union from an @(init) for the engine to
//              register once its marshaler maps exist
//              (serialization.register_union_type).
//
// An @(init), not a SerializationInit phase proc: the phase table is itself
// generated from a scan of the files on disk, and a file this module emits is
// not on disk when that scan runs in the same prebuild. A phase proc here would
// be missing from the table on the first build and present on the second, and
// nothing would fail in between — the registration would just not happen.
//
// Why generated: the registration is a per-type call every package with a
// serialized union has to remember, and forgetting it fails SILENTLY — the
// default marshaler writes the active variant's fields with no tag, and a load
// reads back the union's zero variant. A blend saved and loaded came back a
// clip that way, and only a round-trip test noticed.
//
// Skipped on purpose:
// - unions declared in a generated file: their own generator registers them
//   (sequencer's tween_gen and script_gen), and a second registration is a
//   silent Marshaler_Previously_Found.
// - unions with an untagged variant: they cannot be guid-keyed, and they keep
//   the default marshaler they have today (the editor's undo Command, the
//   inspector's Min_Value, the graph's runtime Playable_Kind). Changing how
//   an existing type serializes is the one thing this module must never do.
// - anything under moonhug/engine: engine/serialization imports the engine,
//   so a file there importing it back is a cycle. The engine declares no
//   unions today either.
//
// A package that loses its last tagged union keeps a stale
// unions_generated.odin until it is deleted by hand — it then fails the build
// loudly rather than misregistering anything.

import "core:fmt"
import "core:strings"
import "core:slice"
import "core:odin/ast"
import db "../gen_db"
import "../gen_facts"

Union_GenComp :: struct {}

@(init)
_register :: proc "contextless" () {
	db.provider("unions/provide", provide)
	db.generator("unions/generate", generate)
}

provide :: proc(w: ^db.World) -> bool {
	_unions := db.get_or_create_comps(w, Union_GenComp)
	decls   := db.get_comps_DeclInfo()
	structs := db.get_comps(w, gen_facts.Struct_GenComp) // struct OR union
	attrs   := db.get_comps(w, gen_facts.Attrs_GenComp)

	// Every @(typ_guid) type, by package-qualified name.
	tagged := make(map[string]bool, context.temp_allocator)
	{
		m := db.all_of(db.r(decls), db.r(attrs)); defer db.matcher_destroy(&m)
		for entity in db.matched(w, &m) {
			if _, has := gen_facts.attr_find(db.get(attrs, entity), "typ_guid"); !has do continue
			decl := db.get(decls, entity)
			if decl.name == "" do continue
			tagged[fmt.tprintf("%s/%s", decl.pkg_path, decl.name)] = true
		}
	}

	m := db.all_of(db.r(decls), db.r(structs)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		if !db.get(structs, entity).is_union do continue
		decl := db.get(decls, entity)
		if decl.name == "" do continue
		if strings.has_suffix(decl.file_path, "_generated.odin") do continue
		if strings.has_prefix(decl.pkg_path, "moonhug/engine") do continue
		if !_all_variants_tagged(decl, tagged) do continue
		db.set(_unions, entity, Union_GenComp{})
	}
	return true
}

// True when every variant is a same-package identifier carrying @(typ_guid).
// A qualified variant (other.Type) is not followed: conservative on purpose,
// since a wrong yes changes how an existing type serializes.
@(private = "file")
_all_variants_tagged :: proc(decl: ^db.DeclInfo, tagged: map[string]bool) -> bool {
	if len(decl.decl.values) == 0 do return false
	ut, ok := decl.decl.values[0].derived_expr.(^ast.Union_Type)
	if !ok || len(ut.variants) == 0 do return false
	for v in ut.variants {
		ident, is_ident := v.derived_expr.(^ast.Ident)
		if !is_ident do return false
		if !tagged[fmt.tprintf("%s/%s", decl.pkg_path, ident.name)] do return false
	}
	return true
}

@(private = "file")
_Row :: struct {
	pkg_path: string,
	pkg:      string, // the package identifier, from the AST — the folder name is not always it
	name:     string,
}

generate :: proc(w: ^db.World) -> bool {
	decls   := db.get_comps_DeclInfo()
	_unions := db.get_comps(w, Union_GenComp)
	if _unions == nil do return true

	rows := make([dynamic]_Row, context.temp_allocator)
	m := db.all_of(db.r(decls), db.r(_unions)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		decl := db.get(decls, entity)
		append(&rows, _Row{pkg_path = decl.pkg_path, pkg = decl.pkg.name, name = decl.name})
	}
	// Deterministic output: by package, then by type name.
	slice.sort_by(rows[:], proc(a, b: _Row) -> bool {
		if a.pkg_path != b.pkg_path do return a.pkg_path < b.pkg_path
		return a.name < b.name
	})

	i := 0
	for i < len(rows) {
		first := rows[i]
		j := i
		for j < len(rows) && rows[j].pkg_path == first.pkg_path do j += 1

		b := strings.builder_make()
		defer strings.builder_destroy(&b)
		fmt.sbprintf(&b, "package %s\n\n", first.pkg)
		strings.write_string(&b, "import \"base:runtime\"\n")
		strings.write_string(&b, "import serialization \"moonhug:engine/serialization\"\n\n")
		strings.write_string(&b, "// Code generated by union_gen. Do not edit.\n")
		strings.write_string(&b, "// Every hand-written union in this package whose variants all carry\n")
		strings.write_string(&b, "// @(typ_guid) goes through the guid-tagged serializer. Queued here at\n")
		strings.write_string(&b, "// program init, registered by the engine once its marshaler maps exist\n")
		strings.write_string(&b, "// (serialization.register_component_serializers).\n\n")
		strings.write_string(&b, "@(init)\n")
		fmt.sbprintf(&b, "_register_%s_unions :: proc \"contextless\" () {{\n", first.pkg)
		strings.write_string(&b, "\tcontext = runtime.default_context()\n")
		for r in rows[i:j] {
			fmt.sbprintf(&b, "\tserialization.register_union_type(%s)\n", r.name)
		}
		strings.write_string(&b, "}\n")
		db.emit(w, fmt.tprintf("%s/unions_generated.odin", first.pkg_path), strings.to_string(b))
		i = j
	}
	return true
}
