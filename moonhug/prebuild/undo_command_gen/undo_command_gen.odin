package undo_command_gen

// undo_command_gen: emits the editor's undo Command union and its dispatch.
//
// A command is a type marked @(undo_command) with four procs in its own file:
//   apply_<Name>(v: ^Name)            redo
//   revert_<Name>(v: ^Name)           undo
//   destroy_<Name>(v: ^Name)          frees what the command owns
//   label_<Name>(v: ^Name) -> string  the history row's default label
// and three optional ones:
//   scenes_<Name>(v: ^Name, out: ^[dynamic]core.Scene_Ref)   scenes it edits: dirtied on apply, purged with the scene
//   assets_<Name>(v: ^Name, out: ^[dynamic]core.Asset_GUID)  assets it edits: purged with the asset
//   describe_<Name>(v: ^Name, b: ^strings.Builder, depth: int)  the history view's detail lines
//
// The union is written into moonhug/editor/undo, so a command's package must
// not import undo: it works on its own world and the stack drives it. The
// shell's own commands (Value, Group, Selection) live in undo itself, and
// Group is the one that cannot be written anywhere else, since it recurses
// into the generated dispatch. A missing required proc fails the prebuild.

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"
import db "../gen_db"
import "../gen_core"
import "../gen_facts"

OUT_FILE :: "moonhug/editor/undo/undo_command_generated.odin"
REQUIRED := []string{"apply", "revert", "destroy", "label"}
OPTIONAL := []string{"scenes", "assets", "describe"}

Undo_Command_GenComp :: struct {
	has: map[string]bool, // proc prefix -> present
}

@(init)
_register :: proc "contextless" () {
	db.provider("undo_command/provide", provide)
	db.generator("undo_command/generate", generate)
	context = runtime.default_context()
	gen_facts.register_naming({
		key     = "undo_command",
		title   = "Undo command procs",
		subject = "a type with @(undo_command)",
		layer   = "editor",
		owner   = "undo_command_gen",
		scope   = .Subject_File,
		procs   = {
			{prefix = "apply_", signature = "proc(v: ^T)", required = true, summary = "Redo: applies the command."},
			{prefix = "revert_", signature = "proc(v: ^T)", required = true, summary = "Undo: reverts the command."},
			{prefix = "destroy_", signature = "proc(v: ^T)", required = true, summary = "Frees what the command owns when the entry leaves the stack."},
			{prefix = "label_", signature = "proc(v: ^T) -> string", required = true, summary = "The history row's default label."},
			{prefix = "scenes_", signature = "proc(v: ^T, out: ^[dynamic]core.Scene_Ref)", summary = "The scenes the command edits: dirtied when it runs, purged with the scene."},
			{prefix = "assets_", signature = "proc(v: ^T, out: ^[dynamic]core.Asset_GUID)", summary = "The assets the command edits: purged with the asset."},
			{prefix = "describe_", signature = "proc(v: ^T, b: ^strings.Builder, depth: int)", summary = "The detail lines the history view shows for the entry."},
		},
		doc     = "Every type marked `@(undo_command)` joins the undo stack's `Command` union, and the generated dispatch calls these by name. A command's package must not import `moonhug:editor/undo`, since the generated union imports it.",
	})
}

provide :: proc(w: ^db.World) -> bool {
	comps := db.get_or_create_comps(w, Undo_Command_GenComp)
	decls := db.get_comps_DeclInfo()
	attrs := db.get_comps(w, gen_facts.Attrs_GenComp)
	m := db.all_of(db.r(decls), db.r(attrs)); defer db.matcher_destroy(&m)
	ok := true
	for entity in db.matched(w, &m) {
		decl := db.get(decls, entity)
		if decl.name == "" do continue
		marked := false
		for args in db.get(attrs, entity).attrs do if args.key == "undo_command" { marked = true; break }
		if !marked do continue
		gen_facts.naming_subject("undo_command", decl.name, decl.file_path, fmt.tprintf("%s:%d", gen_facts.decl_rel_path(decl), decl.decl.pos.line))
		has := make(map[string]bool)
		for p in REQUIRED {
			name := strings.concatenate({p, "_", decl.name}, context.temp_allocator)
			has[p] = gen_core.FileHasProc(decl.file, name)
			if !has[p] {
				fmt.eprintf("undo_command_gen: %s: @(undo_command) %s has no %s proc in its file\n", gen_facts.decl_rel_path(decl), decl.name, name)
				ok = false
			}
		}
		for p in OPTIONAL {
			has[p] = gen_core.FileHasProc(decl.file, strings.concatenate({p, "_", decl.name}, context.temp_allocator))
		}
		db.set(comps, entity, Undo_Command_GenComp{has = has})
	}
	return ok
}

_Row :: struct {
	type_name: string,
	pkg_name:  string,
	pkg_path:  string,
	has:       map[string]bool,
}

// Own-package variants are unqualified, the rest go through their import.
_qual :: proc(r: _Row) -> string {
	if r.pkg_name == "undo" do return r.type_name
	return fmt.tprintf("%s.%s", r.pkg_name, r.type_name)
}

_call :: proc(r: _Row, prefix: string) -> string {
	if r.pkg_name == "undo" do return fmt.tprintf("%s_%s", prefix, r.type_name)
	return fmt.tprintf("%s.%s_%s", r.pkg_name, prefix, r.type_name)
}

generate :: proc(w: ^db.World) -> bool {
	rows: [dynamic]_Row
	defer delete(rows)
	decls := db.get_comps_DeclInfo()
	comps := db.get_comps(w, Undo_Command_GenComp)
	m := db.all_of(db.r(decls), db.r(comps)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		decl := db.get(decls, entity)
		append(&rows, _Row{type_name = decl.name, pkg_name = decl.pkg.name, pkg_path = decl.pkg_path, has = db.get(comps, entity).has})
	}
	// The shell's own commands first, then by name: a stable union whatever is installed.
	slice.sort_by(rows[:], proc(a, b: _Row) -> bool {
		a_own := a.pkg_name == "undo"
		b_own := b.pkg_name == "undo"
		if a_own != b_own do return a_own
		if a.type_name != b.type_name do return a.type_name < b.type_name
		return a.pkg_path < b.pkg_path
	})

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "package undo\n\n")
	strings.write_string(&b, "// Code generated by undo_command_gen. Do not edit.\n")
	strings.write_string(&b, "// A command is a type marked @(undo_command) with apply_/revert_/destroy_/label_\n")
	strings.write_string(&b, "// procs in its file (prebuild/undo_command_gen). Every installed package's\n")
	strings.write_string(&b, "// commands join this union on the next prebuild.\n\n")
	strings.write_string(&b, "import \"core:strings\"\n")
	strings.write_string(&b, "import core \"moonhug:host/core\"\n")
	{
		imported: [dynamic]string
		defer delete(imported)
		for r in rows {
			if r.pkg_name == "undo" do continue
			if slice.contains(imported[:], r.pkg_path) do continue
			append(&imported, r.pkg_path)
			fmt.sbprintf(&b, "import %s \"moonhug:%s\"\n", r.pkg_name, r.pkg_path[len("moonhug/"):])
		}
	}
	strings.write_string(&b, "\nCommand :: union {\n")
	for r in rows do fmt.sbprintf(&b, "\t%s,\n", _qual(r))
	strings.write_string(&b, "}\n\n")

	dispatch :: proc(b: ^strings.Builder, rows: []_Row, header, prefix, args: string, optional := false, after := "") {
		strings.write_string(b, header)
		strings.write_string(b, "\tswitch &v in cmd {\n")
		for r in rows {
			fmt.sbprintf(b, "\tcase %s:\n", _qual(r))
			if !optional || r.has[prefix] {
				fmt.sbprintf(b, "\t\t%s%s(&v%s)\n", after, _call(r, prefix), args)
			} else {
				fmt.sbprintf(b, "\t\t// no %s proc\n", prefix)
			}
		}
		strings.write_string(b, "\t}\n")
	}
	dispatch(&b, rows[:], "_apply_command :: proc(cmd: ^Command) {\n\t_mark_scenes_dirty(cmd)\n", "apply", "")
	strings.write_string(&b, "}\n\n")
	dispatch(&b, rows[:], "_revert_command :: proc(cmd: ^Command) {\n\t_mark_scenes_dirty(cmd)\n", "revert", "")
	strings.write_string(&b, "}\n\n")
	dispatch(&b, rows[:], "_command_destroy :: proc(cmd: ^Command) {\n", "destroy", "")
	strings.write_string(&b, "}\n\n")
	dispatch(&b, rows[:], "default_label :: proc(cmd: ^Command) -> string {\n", "label", "", after = "return ")
	strings.write_string(&b, "\treturn \"\"\n}\n\n")
	dispatch(&b, rows[:], "// Scenes the command edits: dirtied when it runs, purged with the scene.\n_command_scenes :: proc(cmd: ^Command, out: ^[dynamic]core.Scene_Ref) {\n", "scenes", ", out", optional = true)
	strings.write_string(&b, "}\n\n")
	dispatch(&b, rows[:], "// Assets the command edits: purged with the asset.\n_command_assets :: proc(cmd: ^Command, out: ^[dynamic]core.Asset_GUID) {\n", "assets", ", out", optional = true)
	strings.write_string(&b, "}\n\n")
	dispatch(&b, rows[:], "// The history view's detail lines for one entry.\ndescribe :: proc(cmd: ^Command, b: ^strings.Builder, depth: int) {\n", "describe", ", b, depth", optional = true)
	strings.write_string(&b, "}\n")
	db.emit(w, OUT_FILE, strings.to_string(b))
	return true
}
