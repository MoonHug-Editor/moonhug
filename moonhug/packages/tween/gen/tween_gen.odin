package tween_gen

// tween_gen: pattern template for the shared-get_or_create_comps prebuild pipeline.
//
//   provide  - join the shared Struct_GenComp facts (from gen_facts) with the decls,
//              recognise structs with a `base: Tween` field, and PROVIDE a
//              Tween_GenComp get_or_create_comps into the central registry. Tween_GenComp is public
//              and registry-owned, so any other generator can query tweens too.
//   generate - fetch the shared Tween_GenComp comps by type, sort, build
//              tween_generated.odin, emit it as a GeneratedFile.
//
// There is no @(private) comps and no setup proc: the get_or_create_comps lives in the
// gen_db registry (get_or_create_comps creates it, get_comps fetches it).
// Output is identical to the previous version.

import "core:fmt"
import "core:strings"
import "core:slice"
import "moonhug:prebuild/gen_core"
import db "moonhug:prebuild/gen_db"
import "moonhug:prebuild/gen_facts"
import "moonhug:prebuild/type_guid_gen"

// GUID baked into the generated TweenUnion type. tween_gen owns this fact.
_TWEEN_UNION_GUID :: "a243efe5-6e34-4d1c-886c-83928685df48"

// Tween_GenComp marks a decl as a tween struct and carries the facts the generator
// needs. The type name lives on the entity's DeclInfo. Public + registry-owned
// so any generator may query it (db.get_comps(w, Tween_GenComp)).
Tween_GenComp :: struct {
	has_tick: bool,
	has_free: bool,
}

@(init)
_register :: proc "contextless" () {
	db.provider("tween/provide", provide)
	db.generator("tween/generate", generate)
}

// A variant embeds the base as `base: Tween` (inside packages/tween, via the
// re-export alias) or `base: tween_core.Tween` (a foreign variant package
// importing moonhug:packages/tween/core).
_struct_has_tween_base :: proc(fields: []gen_facts.Struct_Field) -> bool {
	for field in fields {
		if field.name != "base" do continue
		if field.type == "Tween" || strings.has_suffix(field.type, ".Tween") do return true
	}
	return false
}

provide :: proc(w: ^db.World) -> bool {
	decls   := db.get_comps_DeclInfo()
	structs := db.get_comps(w, gen_facts.Struct_GenComp) // shared base fact
	field_comps := db.get_comps(w, gen_facts.Fields_GenComp)
	tweens  := db.get_or_create_comps(w, Tween_GenComp)   // provide into registry

	// Join: entities that are structs (Struct_GenComp) carrying a `base: Tween` field.
	m := db.all_of(db.r(decls), db.r(structs), db.r(field_comps)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		decl := db.get(decls, entity)
		if decl.name == "" do continue

		fields := db.get(field_comps, entity)
		if !_struct_has_tween_base(fields.fields) do continue

		tick_name := strings.concatenate({"tick_", decl.name})
		free_name := strings.concatenate({"tween_free_", decl.name})
		defer delete(tick_name)
		defer delete(free_name)

		db.set(tweens, entity, Tween_GenComp{
			has_tick = gen_core.FileHasProc(decl.file, tick_name),
			has_free = gen_core.FileHasProc(decl.file, free_name),
		})
	}

	// Cross-module: tween_gen emits the TweenUnion type, so it provides the
	// TypeGuid_GenComp for it directly. type_guid_gen's generate discovers it via the
	// shared type_guid comps - no parsing of the generated file from disk.
	if !type_guid_gen.provide_synthetic(w, "TweenUnion", "tween", _TWEEN_UNION_GUID) do return false
	return true
}

_TWEEN_PKG_PATH :: "moonhug/packages/tween"

_TweenRow :: struct {
	type_name: string,
	pkg_name:  string, // declared package name ("" for local rows in packages/tween)
	pkg_path:  string,
	has_tick:  bool,
	has_free:  bool,
}

// Local variants (packages/tween) define ticks over ^TweenUnion and wire
// directly. Foreign variants cannot name the union (importing tween from a
// variant package is a cycle), so their ticks take the concrete type and this
// generator emits union adapters for them.
_row_is_local :: proc(e: _TweenRow) -> bool {
	return e.pkg_path == _TWEEN_PKG_PATH
}

_qualified :: proc(e: _TweenRow) -> string {
	if _row_is_local(e) do return e.type_name
	return fmt.tprintf("%s.%s", e.pkg_name, e.type_name)
}

generate :: proc(w: ^db.World) -> bool {
	rows: [dynamic]_TweenRow
	defer delete(rows)

	decls  := db.get_comps_DeclInfo()
	tweens := db.get_comps(w, Tween_GenComp) // fetch shared comps by type

	m := db.all_of(db.r(decls), db.r(tweens)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		decl := db.get(decls, entity)
		tween := db.get(tweens, entity)
		append(&rows, _TweenRow{
			type_name = decl.name,
			pkg_name  = decl.pkg.name,
			pkg_path  = decl.pkg_path,
			has_tick  = tween.has_tick,
			has_free  = tween.has_free,
		})
	}

	slice.sort_by(rows[:], proc(a, b: _TweenRow) -> bool {
		if a.type_name != b.type_name do return a.type_name < b.type_name
		return a.pkg_path < b.pkg_path
	})

	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	strings.write_string(&b, "package tween\n\n")
	strings.write_string(&b, "import engine \"moonhug:engine\"\n")
	// One import per foreign variant package, aliased by declared name.
	imported: [dynamic]string
	defer delete(imported)
	for e in rows {
		if _row_is_local(e) do continue
		found := false
		for p in imported do if p == e.pkg_path { found = true; break }
		if found do continue
		append(&imported, e.pkg_path)
		fmt.sbprintf(&b, "import %s \"moonhug:%s\"\n", e.pkg_name, e.pkg_path[len("moonhug/"):])
	}
	strings.write_string(&b, "\n// Code generated by tween_gen. Do not edit.\n\n")

	fmt.sbprintf(&b, "@(typ_guid={{guid=\"%s\"}})\n", _TWEEN_UNION_GUID)
	strings.write_string(&b, "TweenUnion :: union #no_nil{\n")
	strings.write_string(&b, "\tTween,\n")
	for e in rows {
		fmt.sbprintf(&b, "\t%s,\n", _qualified(e))
	}
	strings.write_string(&b, "}\n\n")

	// Adapters: foreign ticks and frees take the concrete type.
	for e in rows {
		if _row_is_local(e) do continue
		if e.has_tick {
			fmt.sbprintf(&b, "_tick_%s :: proc(task: ^TweenUnion, delta_time: f32, ctx: TweenContext) -> TweenStatus {{\n", e.type_name)
			fmt.sbprintf(&b, "\treturn %s.tick_%s(&task.(%s), delta_time, ctx)\n", e.pkg_name, e.type_name, _qualified(e))
			strings.write_string(&b, "}\n\n")
		}
		if e.has_free {
			fmt.sbprintf(&b, "_free_%s :: proc(task: ^TweenUnion) {{\n", e.type_name)
			fmt.sbprintf(&b, "\t%s.tween_free_%s(&task.(%s))\n", e.pkg_name, e.type_name, _qualified(e))
			strings.write_string(&b, "}\n\n")
		}
	}

	strings.write_string(&b, "__tween_ticks_init :: proc()\n")
	strings.write_string(&b, "{\n")
	// The runner's own setup runs FIRST -- registrations write into state it
	// creates, and generating the order here is what makes it impossible to
	// get wrong by hand.
	strings.write_string(&b, "\ttween_runner_setup()\n\n")
	for e in rows {
		if !e.has_tick do continue
		if _row_is_local(e) {
			fmt.sbprintf(&b, "\t_tween_runner.ticks[int(engine.TypeKey.%s)] = tick_%s\n", e.type_name, e.type_name)
		} else {
			fmt.sbprintf(&b, "\t_tween_runner.ticks[int(engine.TypeKey.%s)] = _tick_%s\n", e.type_name, e.type_name)
		}
	}
	strings.write_string(&b, "\n")
	for e in rows {
		if !e.has_free do continue
		if _row_is_local(e) {
			fmt.sbprintf(&b, "\t_tween_runner.frees[int(engine.TypeKey.%s)] = tween_free_%s\n", e.type_name, e.type_name)
		} else {
			fmt.sbprintf(&b, "\t_tween_runner.frees[int(engine.TypeKey.%s)] = _free_%s\n", e.type_name, e.type_name)
		}
	}
	strings.write_string(&b, "}\n")

	db.emit(w, "moonhug/packages/tween/tween_generated.odin", strings.to_string(b))
	return true
}
