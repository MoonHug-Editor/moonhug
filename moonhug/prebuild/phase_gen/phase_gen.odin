package phase_gen

// phase_gen: ECS prebuild module.
//
//   provide          - query {DeclInfo}, recognise no-arg procs carrying a
//                      `@(phase=...)` attribute, tag them with Phase_GenComp.
//   generate_editor  - query {DeclInfo, Phase_GenComp}, rebuild rows + phase_names,
//                      sort, build moonhug/editor/phases_generated.odin.
//   generate_app     - same provider data, build moonhug/app/phases_generated.odin.
//
// Both generators share the Phase_GenComp provider output. String-building output is
// identical to the previous collect/generate version.

import "core:fmt"
import "core:strings"
import "core:slice"
import "../gen_core"
import db "../gen_db"
import "../gen_facts"

DEFAULT_PHASE_NAMES :: []string{"EditorInit", "EditorShutdown", "Init", "Shutdown"}

PhaseMode :: enum {
	All,
	Editor,
	App,
}

// Phase_GenComp marks a DeclInfo entity as a phase proc and carries the facts the
// generators need. The proc identifier lives on the entity's DeclInfo (d.name)
// and the owning package on d.pkg.name.
Phase_GenComp :: struct {
	key_name: string,
	order:    int,
	mode:     PhaseMode,
}


@(init)
_register :: proc "contextless" () {
	db.provider("phase/provide", provide)
	db.generator("phase/generate_editor", generate_editor)
	db.generator("phase/generate_app", generate_app)
}


_parse_phase_mode :: proc(s: string) -> PhaseMode {
	switch s {
	case "Editor": return .Editor
	case "App":    return .App
	}
	return .All
}

_index_of_phase :: proc(phase_names: []string, key: string) -> int {
	for name, i in phase_names {
		if name == key do return i
	}
	return -1
}

PhaseEntry :: struct {
	key_name:  string,
	key_index: int,
	order:     int,
	name:      string,
	mode:      PhaseMode,
	pkg_name:  string,
}

provide :: proc(w: ^db.World) -> bool {
	_phases := db.get_or_create_comps(w, Phase_GenComp)
	decls := db.get_comps_DeclInfo()
	procs := db.get_comps(w, gen_facts.Proc_GenComp)
	attrs := db.get_comps(w, gen_facts.Attrs_GenComp)

	m := db.all_of(db.r(decls), db.r(procs), db.r(attrs)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		decl := db.get(decls, entity)
		if decl.name == "" do continue
		if !db.get(procs, entity).no_args do continue

		attr_set := db.get(attrs, entity)
		args, found := gen_facts.attr_find(attr_set, "phase")
		if !found do continue
		key_name := gen_facts.attr_keyname(args, "key")
		if key_name == "" do continue
		db.set(_phases, entity, Phase_GenComp{
			key_name = key_name,
			order    = gen_facts.attr_int(args, "order"),
			mode     = _parse_phase_mode(gen_facts.attr_keyname(args, "mode")),
		})
	}
	return true
}

// _build_phase_names reproduces the old collect: DEFAULT_PHASE_NAMES first, then
// every package's Phase_Extra enum values (deduped, first-seen order). Packages
// are visited in first-seen decl order; per package the first Phase_Extra wins.
_build_phase_names :: proc(w: ^db.World) -> [dynamic]string {
	phase_names: [dynamic]string
	for n in DEFAULT_PHASE_NAMES do append(&phase_names, n)

	seen_pkgs: map[string]bool   // keyed by pkg_path (unique per package)
	defer delete(seen_pkgs)

	decls := db.get_comps_DeclInfo()
	for &d in decls.rows[:db.comps_len(decls)] {
		if d.pkg == nil || seen_pkgs[d.pkg_path] do continue
		seen_pkgs[d.pkg_path] = true

		// First Phase_Extra enum in this package (decl-order within the package).
		extra := _phase_extra_for_pkg(decls, d.pkg_path)
		defer delete(extra)
		for n in extra {
			already := false
			for existing in phase_names {
				if existing == n {
					already = true
					break
				}
			}
			if !already do append(&phase_names, n)
		}
	}
	return phase_names
}

// _phase_extra_for_pkg returns the field names of the first Phase_Extra enum
// declared in the given package, or an empty slice.
_phase_extra_for_pkg :: proc(decls: ^db.Comps(db.DeclInfo), pkg_path: string) -> []string {
	for &d in decls.rows[:db.comps_len(decls)] {
		if d.pkg_path != pkg_path || d.name != "Phase_Extra" do continue
		names := gen_core.EnumFieldNames(d.decl)
		if len(names) > 0 do return names
	}
	return {}
}

// _collect_entries rebuilds the old data.entries from the tagged decls, then
// applies the old collect_finalize sort.
_collect_entries :: proc(w: ^db.World, phase_names: []string) -> [dynamic]PhaseEntry {
	entries: [dynamic]PhaseEntry

	decls := db.get_comps_DeclInfo()
	_phases := db.get_comps(w, Phase_GenComp)
	m := db.all_of(db.r(decls), db.r(_phases)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		decl := db.get(decls, entity)
		phase := db.get(_phases, entity)
		idx := _index_of_phase(phase_names, phase.key_name)
		append(&entries, PhaseEntry{
			key_name  = phase.key_name,
			key_index = idx,
			order     = phase.order,
			name      = decl.name,
			mode      = phase.mode,
			pkg_name  = decl.pkg.name,
		})
	}

	slice.sort_by(entries[:], proc(a, b: PhaseEntry) -> bool {
		if a.key_index != b.key_index do return a.key_index < b.key_index
		return a.order < b.order
	})
	return entries
}

_write_phase_enum :: proc(b: ^strings.Builder, phase_names: []string) {
	strings.write_string(b, "Phase :: enum {\n")
	for name in phase_names {
		strings.write_string(b, "\t")
		strings.write_string(b, name)
		strings.write_string(b, ",\n")
	}
	strings.write_string(b, "}\n\n")
}

_write_dispatch_proc :: proc(b: ^strings.Builder, proc_name: string, entries: []PhaseEntry) {
	strings.write_string(b, proc_name)
	strings.write_string(b, " :: proc(key: Phase) {\n")
	strings.write_string(b, "\t#partial switch key {\n")
	current_key := ""
	for e in entries {
		if e.key_name != current_key {
			current_key = e.key_name
			fmt.sbprintf(b, "\tcase .%s:\n", current_key)
		}
		strings.write_string(b, "\t\t")
		strings.write_string(b, e.name)
		strings.write_string(b, "()\n")
	}
	strings.write_string(b, "\t}\n")
	strings.write_string(b, "}\n")
}

_split_entries :: proc(entries: []PhaseEntry) -> (editor: [dynamic]PhaseEntry, app: [dynamic]PhaseEntry) {
	for e in entries {
		switch e.mode {
		case .Editor:
			append(&editor, e)
		case .App:
			append(&app, e)
		case .All:
			append(&editor, e)
			append(&app, e)
		}
	}
	return
}

generate_editor :: proc(w: ^db.World) -> bool {
	// Old code set data.pkg_name = pkg.name of the first scanned package
	// ("moonhug/editor" -> "editor"); the editor file is written under that name.
	pkg_name := "editor"

	phase_names := _build_phase_names(w)
	defer delete(phase_names)

	entries := _collect_entries(w, phase_names[:])
	defer delete(entries)

	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	strings.write_string(&b, "package ")
	strings.write_string(&b, pkg_name)
	strings.write_string(&b, "\n\n")
	strings.write_string(&b, "// Code generated by phase_gen. Do not edit.\n\n")
	strings.write_string(&b, "import \"../app\"\n\n")

	editor_entries, app_entries := _split_entries(entries[:])
	defer delete(editor_entries)
	defer delete(app_entries)

	strings.write_string(&b, "phase_editor_run :: proc(key: app.Phase) {\n")
	strings.write_string(&b, "\t#partial switch key {\n")
	current_key := ""
	for e in editor_entries {
		if e.key_name != current_key {
			current_key = e.key_name
			fmt.sbprintf(&b, "\tcase .%s:\n", current_key)
		}
		strings.write_string(&b, "\t\t")
		if e.pkg_name != pkg_name {
			strings.write_string(&b, e.pkg_name)
			strings.write_string(&b, ".")
		}
		strings.write_string(&b, e.name)
		strings.write_string(&b, "()\n")
	}
	strings.write_string(&b, "\t}\n")
	strings.write_string(&b, "}\n")

	db.emit(w, "moonhug/editor/phases_generated.odin", strings.to_string(b))
	return true
}

generate_app :: proc(w: ^db.World) -> bool {
	phase_names := _build_phase_names(w)
	defer delete(phase_names)

	entries := _collect_entries(w, phase_names[:])
	defer delete(entries)

	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	strings.write_string(&b, "package app\n\n")
	strings.write_string(&b, "// Code generated by phase_gen. Do not edit.\n\n")

	_write_phase_enum(&b, phase_names[:])

	editor_entries, app_entries := _split_entries(entries[:])
	defer delete(editor_entries)
	defer delete(app_entries)

	_write_dispatch_proc(&b, "phase_run", app_entries[:])

	db.emit(w, "moonhug/app/phases_generated.odin", strings.to_string(b))
	return true
}
