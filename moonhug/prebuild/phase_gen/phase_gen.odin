package phase_gen

// phase_gen: named call points with ordered subscribers.
//
//   @(phase={key=Init, order=N, mode=Editor|App})   // mode empty = both
//   my_init :: proc() { ... }
//
// Keys are DEFAULT_PHASE_NAMES plus every package's Phase_Extra enum values
// (deduped, first-seen order). Subscribers may live in app, editor, engine,
// editor subpackages, or installed packages (runtime and editor/ — editor-side
// subscribers must declare mode=Editor, the app binary can't reach them).
//
//   provide          - recognise no-arg procs carrying `@(phase=...)`, tag with
//                      Phase_GenComp. Validates keys and modes here (single
//                      point, all decls are scanned before providers run).
//   generate_engine  - moonhug/engine/phases_generated.odin: the Phase enum +
//                      the subscriber table doc header. The enum lives in
//                      engine so every package can name keys in code.
//   generate_app     - moonhug/app/phases_generated.odin: `Phase :: engine.Phase`
//                      alias + phase_run dispatcher.
//   generate_editor  - moonhug/editor/phases_generated.odin: phase_editor_run.

import "core:fmt"
import "core:strings"
import "core:slice"
import "../gen_core"
import db "../gen_db"
import "../gen_facts"

DEFAULT_PHASE_NAMES :: []string{"EditorInit", "EditorShutdown", "Init", "Shutdown", "DebugDraw"}

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
	db.generator("phase/generate_engine", generate_engine)
	db.generator("phase/generate_editor", generate_editor)
	db.generator("phase/generate_app", generate_app)
}


_PACKAGES_PREFIX :: "moonhug/packages/"

// Editor-side code is compiled into the editor binary only — its subscribers
// can never appear in the app dispatcher.
_is_editor_side :: proc(pkg_path: string) -> bool {
	return strings.has_prefix(pkg_path, "moonhug/editor") ||
		pkg_path == "moonhug/engine_editor" ||
		strings.has_suffix(pkg_path, "/editor")
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
	pkg_path:  string,
}

provide :: proc(w: ^db.World) -> bool {
	_phases := db.get_or_create_comps(w, Phase_GenComp)
	decls := db.get_comps_DeclInfo()
	procs := db.get_comps(w, gen_facts.Proc_GenComp)
	attrs := db.get_comps(w, gen_facts.Attrs_GenComp)

	phase_names := _build_phase_names(w)
	defer delete(phase_names)

	m := db.all_of(db.r(decls), db.r(procs), db.r(attrs)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		decl := db.get(decls, entity)
		if decl.name == "" do continue
		if !db.get(procs, entity).no_args do continue

		attr_set := db.get(attrs, entity)
		args, found := gen_facts.attr_find(attr_set, "phase")
		if !found do continue

		key_name := gen_facts.attr_keyname(args, "key")
		if _index_of_phase(phase_names[:], key_name) < 0 {
			fmt.eprintf(
				"phase_gen: %s.%s: unknown phase key %q — known keys: %s\n",
				decl.pkg.name, decl.name, key_name, strings.join(phase_names[:], ", ", context.temp_allocator),
			)
			return false
		}

		mode: PhaseMode
		switch mode_str := gen_facts.attr_keyname(args, "mode"); mode_str {
		case "", "All": mode = .All
		case "Editor":  mode = .Editor
		case "App":     mode = .App
		case:
			fmt.eprintf("phase_gen: %s.%s: unknown mode %q (Editor, App, or empty for both)\n", decl.pkg.name, decl.name, mode_str)
			return false
		}
		if _is_editor_side(decl.pkg_path) && mode != .Editor {
			fmt.eprintf("phase_gen: %s.%s: editor-side subscribers must declare mode=Editor (the app binary can't reach %s)\n", decl.pkg.name, decl.name, decl.pkg_path)
			return false
		}

		db.set(_phases, entity, Phase_GenComp{
			key_name = key_name,
			order    = gen_facts.attr_int(args, "order"),
			mode     = mode,
		})
	}
	return true
}

// _build_phase_names: DEFAULT_PHASE_NAMES first, then every package's
// Phase_Extra enum values (deduped, first-seen order). Packages are visited in
// first-seen decl order; per package the first Phase_Extra wins.
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

// _collect_entries rebuilds entries from the tagged decls, sorted by key then order.
_collect_entries :: proc(w: ^db.World, phase_names: []string) -> [dynamic]PhaseEntry {
	entries: [dynamic]PhaseEntry

	decls := db.get_comps_DeclInfo()
	_phases := db.get_comps(w, Phase_GenComp)
	m := db.all_of(db.r(decls), db.r(_phases)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		decl := db.get(decls, entity)
		phase := db.get(_phases, entity)
		append(&entries, PhaseEntry{
			key_name  = phase.key_name,
			key_index = _index_of_phase(phase_names, phase.key_name),
			order     = phase.order,
			name      = decl.name,
			mode      = phase.mode,
			pkg_name  = decl.pkg.name,
			pkg_path  = decl.pkg_path,
		})
	}

	slice.sort_by(entries[:], proc(a, b: PhaseEntry) -> bool {
		if a.key_index != b.key_index do return a.key_index < b.key_index
		if a.order != b.order do return a.order < b.order
		return a.name < b.name
	})
	return entries
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

// Human label for the subscriber table: "app", "editor", "packages:physics2d".
_pkg_label :: proc(e: PhaseEntry) -> string {
	if strings.has_prefix(e.pkg_path, _PACKAGES_PREFIX) {
		return fmt.tprintf("packages:%s", e.pkg_path[len(_PACKAGES_PREFIX):])
	}
	return e.pkg_name
}

// ---- engine: the Phase enum + the subscriber table -------------------------

generate_engine :: proc(w: ^db.World) -> bool {
	phase_names := _build_phase_names(w)
	defer delete(phase_names)
	entries := _collect_entries(w, phase_names[:])
	defer delete(entries)

	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	strings.write_string(&b, "package engine\n\n")
	strings.write_string(&b, "// Code generated by phase_gen. Do not edit.\n//\n")
	strings.write_string(&b, "// Phases -> subscribers (order, proc, package). Mode tags only where a\n")
	strings.write_string(&b, "// subscriber is single-binary; no tag = both dispatchers.\n//\n")
	for key, key_index in phase_names {
		// Phase-level mode: the union of its subscribers' modes.
		saw_editor, saw_app, saw_all := false, false, false
		for e in entries {
			if e.key_index != key_index do continue
			switch e.mode {
			case .Editor: saw_editor = true
			case .App:    saw_app = true
			case .All:    saw_all = true
			}
		}
		tag := ""
		if !saw_all {
			if saw_editor && !saw_app do tag = " [Editor]"
			if saw_app && !saw_editor do tag = " [App]"
		}
		fmt.sbprintf(&b, "// %s%s\n", key, tag)
		for e in entries {
			if e.key_index != key_index do continue
			mode_tag := ""
			if e.mode == .Editor do mode_tag = "  [Editor]"
			if e.mode == .App do mode_tag = "  [App]"
			order_str := fmt.tprintf("%d", e.order)
			spaces := "     "
			pad := spaces[:max(5 - len(order_str), 0)]
			fmt.sbprintf(&b, "//   %s%s  %s  %s%s\n", pad, order_str, e.name, _pkg_label(e), mode_tag)
		}
	}
	strings.write_string(&b, "\nPhase :: enum {\n")
	for name in phase_names {
		fmt.sbprintf(&b, "\t%s,\n", name)
	}
	strings.write_string(&b, "}\n")

	db.emit(w, "moonhug/engine/phases_generated.odin", strings.to_string(b))
	return true
}

// ---- dispatchers ------------------------------------------------------------

// Import path for a subscriber's package, relative to the dispatcher's home.
_import_path :: proc(pkg_path: string, from_editor: bool) -> string {
	if strings.has_prefix(pkg_path, _PACKAGES_PREFIX) {
		return fmt.tprintf("packages:%s", pkg_path[len(_PACKAGES_PREFIX):])
	}
	if from_editor {
		if strings.has_prefix(pkg_path, "moonhug/editor/") {
			return pkg_path[len("moonhug/editor/"):]
		}
	}
	if strings.has_prefix(pkg_path, "moonhug/") {
		return fmt.tprintf("../%s", pkg_path[len("moonhug/"):])
	}
	return pkg_path
}

// Aliased imports for every foreign subscriber package (imports must precede
// all other declarations in the generated file).
_write_imports :: proc(
	b: ^strings.Builder,
	entries: []PhaseEntry,
	home_pkg: string,
	from_editor: bool,
	skip_import: string, // package already imported by the file preamble
) {
	imports: [dynamic]string
	defer delete(imports)
	for e in entries {
		if e.pkg_name == home_pkg || e.pkg_name == skip_import do continue
		found := false
		for p in imports do if p == e.pkg_name { found = true; break }
		if !found do append(&imports, e.pkg_name)
	}
	slice.sort(imports[:])
	for name in imports {
		path := ""
		for e in entries {
			if e.pkg_name == name { path = e.pkg_path; break }
		}
		fmt.sbprintf(b, "import %s %q\n", name, _import_path(path, from_editor))
	}
}

_write_dispatcher :: proc(
	b: ^strings.Builder,
	proc_name: string,
	key_type: string,
	entries: []PhaseEntry,
	home_pkg: string,
) {
	fmt.sbprintf(b, "%s :: proc(key: %s) {{\n", proc_name, key_type)
	strings.write_string(b, "\t#partial switch key {\n")
	current_key := ""
	for e in entries {
		if e.key_name != current_key {
			current_key = e.key_name
			fmt.sbprintf(b, "\tcase .%s:\n", current_key)
		}
		strings.write_string(b, "\t\t")
		if e.pkg_name != home_pkg {
			strings.write_string(b, e.pkg_name)
			strings.write_string(b, ".")
		}
		strings.write_string(b, e.name)
		strings.write_string(b, "()\n")
	}
	strings.write_string(b, "\t}\n")
	strings.write_string(b, "}\n")
}

generate_editor :: proc(w: ^db.World) -> bool {
	phase_names := _build_phase_names(w)
	defer delete(phase_names)
	entries := _collect_entries(w, phase_names[:])
	defer delete(entries)
	editor_entries, app_entries := _split_entries(entries[:])
	defer delete(editor_entries)
	defer delete(app_entries)

	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	strings.write_string(&b, "package editor\n\n")
	strings.write_string(&b, "// Code generated by phase_gen. Do not edit.\n")
	strings.write_string(&b, "// Subscriber table: engine/phases_generated.odin (with the Phase enum).\n\n")
	strings.write_string(&b, "import \"../engine\"\n")
	_write_imports(&b, editor_entries[:], "editor", true, "engine")
	strings.write_string(&b, "\n")
	_write_dispatcher(&b, "phase_editor_run", "engine.Phase", editor_entries[:], "editor")

	db.emit(w, "moonhug/editor/phases_generated.odin", strings.to_string(b))
	return true
}

// One phase_run dispatcher per RUNNABLE package (0..N): the host's own
// subscribers call unqualified, library packages import, other runnable
// packages are excluded (separate programs).
generate_app :: proc(w: ^db.World) -> bool {
	phase_names := _build_phase_names(w)
	defer delete(phase_names)
	entries := _collect_entries(w, phase_names[:])
	defer delete(entries)
	editor_entries, app_entries := _split_entries(entries[:])
	defer delete(editor_entries)
	defer delete(app_entries)

	runnables := gen_facts.runnable_packages(w)
	defer delete(runnables)
	for host in runnables {
		host_entries := make([dynamic]PhaseEntry)
		defer delete(host_entries)
		for e in app_entries {
			if e.pkg_name == host.name || !gen_facts.is_runnable(runnables[:], e.pkg_name) {
				append(&host_entries, e)
			}
		}

		b := strings.builder_make()
		defer strings.builder_destroy(&b)

		fmt.sbprintf(&b, "package %s\n\n", host.name)
		strings.write_string(&b, "// Code generated by phase_gen. Do not edit.\n")
		strings.write_string(&b, "// Subscriber table: engine/phases_generated.odin (with the Phase enum).\n\n")
		strings.write_string(&b, "import \"../../engine\"\n")
		_write_imports(&b, host_entries[:], host.name, false, "engine")
		strings.write_string(&b, "\n// The enum lives in engine so packages can name keys in code.\n")
		strings.write_string(&b, "Phase :: engine.Phase\n\n")
		_write_dispatcher(&b, "phase_run", "Phase", host_entries[:], host.name)

		db.emit(w, fmt.tprintf("%s/phases_generated.odin", host.path), strings.to_string(b))
	}
	return true
}
