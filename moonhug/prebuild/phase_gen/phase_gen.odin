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
//   generate_core    - moonhug/host/core/phases_generated.odin: the Phase
//                      enum + the subscriber table doc header. The enum lives
//                      in core, so every package can name keys in code.
//   generate_app     - <host>/phases_generated.odin per runnable package:
//                      `Phase :: core.Phase` alias + phase_run dispatcher.
//   generate_registration - moonhug/registration/phases_generated.odin:
//                      the same dispatcher over every non-runnable package,
//                      for the tests (they need no runnable package).
//   generate_editor  - moonhug/editor/phases_generated.odin: phase_editor_run.

import "core:fmt"
import "core:strings"
import "core:slice"
import "../gen_core"
import db "../gen_db"
import "../gen_facts"

// In the order a process runs them, which is the Phase enum's order and the
// order the reference page lists them in. A package's Phase_Extra names
// follow. SerializationInit and ImportersInit are declared by host packages
// as Phase_Extra and sit here only for their place in the sequence.
DEFAULT_PHASE_NAMES :: []string{
	// The engine's own startup: the player runs it from the generated
	// __standalone_run, the editor's main before EditorInit.
	"EngineInit",
	// Registration: type keys, serializers, importers. A runnable package's
	// phase_run fires them at the top of Init, the editor at EditorInit.
	"SerializationInit", "ImportersInit",
	"EditorInit",
	"Init",
	// After a gameplay scene becomes live: the boot scene, a game's own
	// loads, play start.
	"SceneLoaded",
	// Play-mode transitions, fired by the editor's Simulate (Unity's
	// PlayModeStateChange). Exiting* run before the switch, Entered* after.
	"ExitingEditMode", "EnteredPlayMode",
	// Per frame, inside the open world pass, while debug drawing is on.
	"DebugDraw",
	"ExitingPlayMode", "EnteredEditMode",
	"Shutdown",
	"EditorShutdown",
	"EngineShutdown",
}

// A shutdown phase runs its subscribers in descending order, so a proc paired
// with an init proc by the same `order` undoes it in reverse.
_is_shutdown_phase :: proc(key_name: string) -> bool {
	return strings.has_suffix(key_name, "Shutdown")
}

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
	db.generator("phase/generate_core", generate_core)
	db.generator("phase/generate_editor", generate_editor)
	db.generator("phase/generate_app", generate_app)
	db.generator("phase/generate_registration", generate_registration)
}


_PACKAGES_PREFIX :: "moonhug/packages/"

// Editor-side code is compiled into the editor binary only — its subscribers
// can never appear in the app dispatcher. That is the shell and every
// package's editor/ folder with everything below it.
_is_editor_side :: proc(pkg_path: string) -> bool {
	return strings.has_prefix(pkg_path, "moonhug/editor") ||
		strings.has_suffix(pkg_path, "/editor") ||
		strings.contains(pkg_path, "/editor/")
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
	// The reference page groups @(phase) uses by key in this order.
	{
		names := _build_phase_names(w)
		defer delete(names)
		keys := make([]gen_facts.Attr_Key, len(names), context.temp_allocator)
		for n, i in names do keys[i] = {n, _is_shutdown_phase(n)}
		gen_facts.register_attr_key_order("phase", keys)
	}
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

	// Every field of the comparator matters: proc names collide across
	// packages by convention (each physics package declares `debug_draw`), and
	// slice.sort_by is unstable, so entries equal under the comparator land in
	// ARBITRARY order -- different across runs, and different from the scan
	// order. pkg_path is the unique final tiebreak.
	slice.sort_by(entries[:], proc(a, b: PhaseEntry) -> bool {
		if a.key_index != b.key_index do return a.key_index < b.key_index
		if a.order != b.order do return a.order > b.order if _is_shutdown_phase(a.key_name) else a.order < b.order
		if a.name != b.name do return a.name < b.name
		return a.pkg_path < b.pkg_path
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

// ---- core: the Phase enum + the subscriber table ----------------------------

generate_core :: proc(w: ^db.World) -> bool {
	phase_names := _build_phase_names(w)
	defer delete(phase_names)
	entries := _collect_entries(w, phase_names[:])
	defer delete(entries)

	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	strings.write_string(&b, "package core\n\n")
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

	db.emit(w, "moonhug/host/core/phases_generated.odin", strings.to_string(b))
	return true
}

// ---- dispatchers ------------------------------------------------------------

// Import path for a subscriber's package, relative to the dispatcher's home.
_import_path :: proc(pkg_path: string, from_editor: bool) -> string {
	if strings.has_prefix(pkg_path, _PACKAGES_PREFIX) {
		return fmt.tprintf("moonhug:packages/%s", pkg_path[len(_PACKAGES_PREFIX):])
	}
	if from_editor {
		if strings.has_prefix(pkg_path, "moonhug/editor/") {
			return pkg_path[len("moonhug/editor/"):]
		}
	}
	// Collection form: valid from any dispatcher home, unlike a relative path
	// (the app dispatcher lives two levels down, the editor's one).
	if strings.has_prefix(pkg_path, "moonhug/") {
		return fmt.tprintf("moonhug:%s", pkg_path[len("moonhug/"):])
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

// Lifecycle phases: a host package's entries on these run only while that
// host is the active sim host. Every other phase is a registration phase
// (SerializationInit, ImportersInit, Phase_Extra keys) and runs
// unconditionally — the editor loads every game's types and serializers no
// matter which host Simulate ticks.
_HOST_GATED_PHASES :: [?]string{
	"ExitingEditMode", "EnteredPlayMode", "ExitingPlayMode", "EnteredEditMode",
	"Init", "SceneLoaded", "Shutdown", "DebugDraw",
}

_is_host_gated_phase :: proc(key_name: string) -> bool {
	for p in _HOST_GATED_PHASES do if p == key_name do return true
	return false
}

_write_dispatcher :: proc(
	b: ^strings.Builder,
	proc_name: string,
	key_type: string,
	entries: []PhaseEntry,
	home_pkg: string,
	hosts: []gen_facts.Runnable_Pkg = nil, // editor dispatcher: host-owned lifecycle entries run only for the active sim host
	init_prelude: string = "", // runnable dispatcher: lines at the top of Init, before any subscriber
) {
	fmt.sbprintf(b, "%s :: proc(key: %s) {{\n", proc_name, key_type)
	// One bool per host that owns gated entries, resolved once up front.
	guarded: [dynamic]string
	defer delete(guarded)
	if hosts != nil {
		for e in entries {
			if !gen_facts.is_runnable(hosts, e.pkg_name) do continue
			if !_is_host_gated_phase(e.key_name) do continue
			found := false
			for g in guarded do if g == e.pkg_name { found = true; break }
			if !found do append(&guarded, e.pkg_name)
		}
	}
	for g in guarded {
		fmt.sbprintf(b, "\tsim_host_is_%s := sim_host_is(%q)\n", g, g)
	}
	strings.write_string(b, "\t#partial switch key {\n")
	current_key := ""
	init_seen := false
	for e in entries {
		if e.key_name != current_key {
			current_key = e.key_name
			fmt.sbprintf(b, "\tcase .%s:\n", current_key)
			if current_key == "Init" && init_prelude != "" {
				init_seen = true
				strings.write_string(b, init_prelude)
			}
			if current_key == "SerializationInit" {
				// Every host registers type keys first: subscribers look them up.
				strings.write_string(b, "\t\tassert(core.type_keys_registered(), \"SerializationInit before register_type_guids\")\n")
			}
		}
		strings.write_string(b, "\t\t")
		is_guarded := false
		if _is_host_gated_phase(e.key_name) {
			for g in guarded do if g == e.pkg_name { is_guarded = true; break }
		}
		if is_guarded {
			fmt.sbprintf(b, "if sim_host_is_%s do ", e.pkg_name)
		}
		if e.pkg_name != home_pkg {
			strings.write_string(b, e.pkg_name)
			strings.write_string(b, ".")
		}
		strings.write_string(b, e.name)
		strings.write_string(b, "()\n")
	}
	if init_prelude != "" && !init_seen {
		strings.write_string(b, "\tcase .Init:\n")
		strings.write_string(b, init_prelude)
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
	strings.write_string(&b, "// Subscriber table: host/core/phases_generated.odin (with the Phase enum).\n\n")
	strings.write_string(&b, "import core \"moonhug:host/core\"\n")
	_write_imports(&b, editor_entries[:], "editor", true, "core")
	strings.write_string(&b, "\n")
	hosts := gen_facts.runnable_packages(w)
	defer delete(hosts)
	_write_dispatcher(&b, "phase_editor_run", "core.Phase", editor_entries[:], "editor", hosts[:])

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
		strings.write_string(&b, "// Subscriber table: host/core/phases_generated.odin (with the Phase enum).\n\n")
		strings.write_string(&b, "import core \"moonhug:host/core\"\n")
		_write_imports(&b, host_entries[:], host.name, false, "core")
		strings.write_string(&b, "\n// The enum lives in moonhug:host/core.\n")
		strings.write_string(&b, "Phase :: core.Phase\n\n")
		// Registration and the registration phases come first in Init, in
		// the order the editor and the tests use, so no game writes them.
		prelude := fmt.tprintf("\t\t// Generated: the host's registrations, then the registration phases, before any Init subscriber.\n\t\tregister_%s_components()\n\t\tregister_packages()\n\t\tregister_type_guids()\n\t\tphase_run(.SerializationInit)\n\t\tphase_run(.ImportersInit)\n", host.name)
		_write_dispatcher(&b, "phase_run", "Phase", host_entries[:], host.name, init_prelude = prelude)

		db.emit(w, fmt.tprintf("%s/phases_generated.odin", host.path), strings.to_string(b))
	}
	return true
}

// The app-side dispatcher without a host: every non-runnable package. The test bootstrap runs its registration phases through it, so
// the tests build with no runnable package installed.
generate_registration :: proc(w: ^db.World) -> bool {
	phase_names := _build_phase_names(w)
	defer delete(phase_names)
	entries := _collect_entries(w, phase_names[:])
	defer delete(entries)
	editor_entries, app_entries := _split_entries(entries[:])
	defer delete(editor_entries)
	defer delete(app_entries)

	runnables := gen_facts.runnable_packages(w)
	defer delete(runnables)
	shared := make([dynamic]PhaseEntry)
	defer delete(shared)
	for e in app_entries {
		if !gen_facts.is_runnable(runnables[:], e.pkg_name) do append(&shared, e)
	}

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "package registration\n\n")
	strings.write_string(&b, "// Code generated by phase_gen. Do not edit.\n")
	strings.write_string(&b, "// Subscriber table: host/core/phases_generated.odin (with the Phase enum).\n\n")
	strings.write_string(&b, "import core \"moonhug:host/core\"\n")
	_write_imports(&b, shared[:], "registration", false, "core")
	strings.write_string(&b, "\n")
	_write_dispatcher(&b, "phase_run", "core.Phase", shared[:], "registration")

	db.emit(w, "moonhug/registration/phases_generated.odin", strings.to_string(b))
	return true
}
