package engine_gen

// update_gen: ECS prebuild module.
//
//   provide  - iterate the decls, recognise proc decls in package "app" (or an
//              installed package's runtime package) carrying an `@update` or
//              `@fixed_update` attribute, add Update_GenComp.
//   generate - iterate the {decls, updates} join view, sort by order, build
//              update_generated.odin with BOTH dispatchers, `__ticks` (the
//              dispatchers as engine.Tick_Hooks) and `__frame_tick`, which runs
//              a frame through engine.frame_tick. The game's loop and the
//              editor's sim host table use those two, never the dispatchers.
//
// __update runs per frame (view-side work). __fixed_update runs per fixed
// tick, driven by the app loop's accumulator (plugins/engine/fixed_tick.odin); a
// subscriber's divisor=N runs it every Nth tick at fixed_dt * N. __late_update
// runs after __update, the last stage before rendering.
//
// Both attributes take two shapes, interleaved by order in one dispatcher:
//
//   @(update={order=1})                     // a system: loops itself
//   tween_tick :: proc(dt: f32)
//
//   @(fixed_update={component=Spinner})     // per item: the loop is generated
//   fixed_update_Spinner :: proc(dt: f32, s: ^Spinner)
//
// The per-item shape names a @(component) or @(poolable) type. By convention
// the proc is named `update_<T>` or `fixed_update_<T>` after its attribute.
// The generated wrapper `__<proc>` iterates its pool, skips disabled
// components (a poolable has no `enabled`, every alive item runs) and calls
// the proc.

import "core:fmt"
import "core:strings"
import "core:slice"
import db "moonhug:prebuild/gen_db"
import "moonhug:prebuild/gen_facts"

Update_Kind :: enum {
	Frame, // @(update)
	Late,  // @(late_update)
	Fixed, // @(fixed_update)
}

// Update_GenComp marks a DeclInfo entity as an @update / @fixed_update proc.
// The proc's name lives on the entity's DeclInfo.
Update_GenComp :: struct {
	kind:      Update_Kind,
	order:     int,
	divisor:   int,    // fixed only; run every Nth tick (>= 1)
	component: string, // per-item shape: the unqualified type name, "" for a system
}


@(init)
_register_update :: proc "contextless" () {
	db.provider("update/provide", update_provide)
	db.generator("update/generate", update_generate)
}


update_provide :: proc(w: ^db.World) -> bool {
	_updates := db.get_or_create_comps(w, Update_GenComp)
	decls   := db.get_comps_DeclInfo()
	procs   := db.get_comps(w, gen_facts.Proc_GenComp)
	attrs   := db.get_comps(w, gen_facts.Attrs_GenComp)

	// @update / @fixed_update procs in package "app" or in an installed
	// package's runtime package (moonhug/packages/<name>, never its editor/
	// subpackage or anything below it — the dispatchers are compiled into the
	// app binary).
	m := db.all_of(db.r(decls), db.r(procs), db.r(attrs)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		decl := db.get(decls, entity)
		if decl.name == "" do continue
		is_package := strings.has_prefix(decl.pkg_path, _PACKAGES_PREFIX) && !strings.has_suffix(decl.pkg_path, "/editor") && !strings.contains(decl.pkg_path, "/editor/")
		if !is_package do continue
		attr_set := db.get(attrs, entity)
		if args, found := gen_facts.attr_find(attr_set, "update"); found {
			db.set(_updates, entity, Update_GenComp{kind = .Frame, order = gen_facts.attr_int(args, "order"), component = _component_arg(args)})
		} else if args, lfound := gen_facts.attr_find(attr_set, "late_update"); lfound {
			db.set(_updates, entity, Update_GenComp{kind = .Late, order = gen_facts.attr_int(args, "order"), component = _component_arg(args)})
		} else if args, ffound := gen_facts.attr_find(attr_set, "fixed_update"); ffound {
			divisor := gen_facts.attr_int(args, "divisor")
			if divisor < 1 do divisor = 1
			db.set(_updates, entity, Update_GenComp{kind = .Fixed, order = gen_facts.attr_int(args, "order"), divisor = divisor, component = _component_arg(args)})
		}
	}
	return true
}

_PACKAGES_PREFIX :: "moonhug/packages/"

_UpdateRow :: struct {
	name:    string,
	pkg:     string, // "" for app procs; package name for packages: imports
	path:    string, // pkg_path: a subpackage imports by its folder, not its name
	order:   int,
	divisor: int,
	// Per-item shape, resolved from components_gen facts. component == "" is a system.
	component:     string,
	comp_pkg:      string, // the type's package, "" or "engine" for the engine
	comp_pkg_path: string,
	comp_plural:   string, // the pool accessor, or the World field for a poolable
	comp_poolable: bool,
}

// One dispatcher file PER RUNNABLE PACKAGE (a package with `main`, 0..N of
// them — docs/core/Plugins.md): the host's own ticks call unqualified, library
// package ticks go through collection imports, OTHER runnable packages are
// excluded (they're separate programs).
update_generate :: proc(w: ^db.World) -> bool {
	frame_rows: [dynamic]_UpdateRow
	late_rows:  [dynamic]_UpdateRow
	fixed_rows: [dynamic]_UpdateRow
	defer { delete(frame_rows); delete(late_rows); delete(fixed_rows) }

	decls := db.get_comps_DeclInfo()
	_updates := db.get_comps(w, Update_GenComp)
	comps := db.get_comps(w, gen_facts.Component_GenComp)
	m := db.all_of(db.r(decls), db.r(_updates)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		decl := db.get(decls, entity)
		update := db.get(_updates, entity)
		row := _UpdateRow{
			name      = decl.name,
			pkg       = decl.pkg.name,
			path      = decl.pkg_path,
			order     = update.order,
			divisor   = update.divisor,
			component = update.component,
		}
		if row.component != "" && !_resolve_component(w, decls, comps, &row) {
			fmt.eprintf("update_gen: %s.%s: component=%s is not a @(component) or @(poolable) type\n", decl.pkg.name, decl.name, row.component)
			return false
		}
		switch update.kind {
		case .Frame: append(&frame_rows, row)
		case .Late:  append(&late_rows, row)
		case .Fixed: append(&fixed_rows, row)
		}
	}

	// The wrapper is named after the proc, so two packages' per-item procs
	// with one name would generate one wrapper twice.
	_check_unique :: proc(rows: []_UpdateRow) -> bool {
		for a, i in rows do for b in rows[i + 1:] {
			if a.component != "" && b.component != "" && a.name == b.name {
				fmt.eprintf("update_gen: %s.%s and %s.%s share a name, rename one\n", a.pkg, a.name, b.pkg, b.name)
				return false
			}
		}
		return true
	}
	if !_check_unique(frame_rows[:]) || !_check_unique(late_rows[:]) || !_check_unique(fixed_rows[:]) do return false

	// Preserve previous collect_finalize ordering: sort by order.
	sort_rows :: proc(rows: []_UpdateRow) {
		// Total order — same-order ticks (the common case: no explicit order)
		// would otherwise emit in entity iteration order and churn between
		// builds. Call order within a tie is arbitrary but now STABLE.
		slice.sort_by(rows, proc(a, b: _UpdateRow) -> bool {
			if a.order != b.order do return a.order < b.order
			if a.pkg != b.pkg do return a.pkg < b.pkg
			return a.name < b.name
		})
	}
	sort_rows(frame_rows[:])
	sort_rows(late_rows[:])
	sort_rows(fixed_rows[:])

	runnables := gen_facts.runnable_packages(w)
	defer delete(runnables)
	for host in runnables {
		_generate_host(w, host, frame_rows[:], late_rows[:], fixed_rows[:], runnables[:])
	}
	return true
}

// Fills the pool facts of a per-item row from components_gen's facts.
_resolve_component :: proc(w: ^db.World, decls: ^db.Comps(db.DeclInfo), comps: ^db.Comps(gen_facts.Component_GenComp), row: ^_UpdateRow) -> bool {
	if comps == nil do return false
	cm := db.all_of(db.r(decls), db.r(comps)); defer db.matcher_destroy(&cm)
	for ce in db.matched(w, &cm) {
		cdecl := db.get(decls, ce)
		if cdecl.name != row.component do continue
		cc := db.get(comps, ce)
		row.comp_plural = cc.plural
		row.comp_poolable = cc.kind == .Poolable
		row.comp_pkg = cc.pkg
		row.comp_pkg_path = cc.pkg_path
		if cc.pkg == "" || cc.pkg == "engine" {
			row.comp_pkg = "engine"
			row.comp_pkg_path = "moonhug/packages/engine"
		}
		return true
	}
	return false
}

_generate_host :: proc(w: ^db.World, host: gen_facts.Runnable_Pkg, frame_rows, late_rows, fixed_rows: []_UpdateRow, runnables: []gen_facts.Runnable_Pkg) {
	// The host's slice of the rows: own entries + library packages.
	_included :: proc(e: _UpdateRow, host: string, runnables: []gen_facts.Runnable_Pkg) -> bool {
		return e.pkg == host || !gen_facts.is_runnable(runnables, e.pkg)
	}

	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	fmt.sbprintf(&b, "package %s\n\n", host.name)
	strings.write_string(&b, "// Code generated by update_gen. Do not edit.\n\n")

	// Package ticks call through aliased collection imports, interleaved with
	// the host's own ticks by order (docs/core/Plugins.md).
	imports: [dynamic]_UpdateRow
	defer delete(imports)
	_add_import :: proc(imports: ^[dynamic]_UpdateRow, pkg, path: string) {
		for p in imports^ do if p.pkg == pkg do return
		append(imports, _UpdateRow{pkg = pkg, path = path})
	}
	_collect_imports :: proc(imports: ^[dynamic]_UpdateRow, rows: []_UpdateRow, host: string, runnables: []gen_facts.Runnable_Pkg) {
		for e in rows {
			if !_included(e, host, runnables) do continue
			if e.pkg != host do _add_import(imports, e.pkg, e.path)
			// A per-item wrapper reaches the type's pool through its package.
			if e.component != "" && e.comp_pkg != host do _add_import(imports, e.comp_pkg, e.comp_pkg_path)
		}
	}
	_collect_imports(&imports, frame_rows, host.name, runnables)
	_collect_imports(&imports, late_rows, host.name, runnables)
	_collect_imports(&imports, fixed_rows, host.name, runnables)
	// __ticks and __frame_tick are engine types, divisor guards read its tick
	// counter, wrappers its world.
	_add_import(&imports, "engine", "moonhug/packages/engine")
	slice.sort_by(imports[:], proc(a, b: _UpdateRow) -> bool { return a.pkg < b.pkg })
	for p in imports {
		fmt.sbprintf(&b, "import %s \"moonhug:packages/%s\"\n", p.pkg, p.path[len(_PACKAGES_PREFIX):])
	}
	if len(imports) > 0 do strings.write_string(&b, "\n")

	// A system is called where it lives, a per-item proc through its wrapper.
	_call_name :: proc(e: _UpdateRow, host: string, kind: Update_Kind) -> string {
		if e.component != "" do return _wrapper_name(e, kind)
		if e.pkg != host do return fmt.tprintf("%s.%s", e.pkg, e.name)
		return e.name
	}

	for e in frame_rows do if _included(e, host.name, runnables) && e.component != "" do _write_wrapper(&b, e, host.name, .Frame)
	for e in late_rows do if _included(e, host.name, runnables) && e.component != "" do _write_wrapper(&b, e, host.name, .Late)
	for e in fixed_rows do if _included(e, host.name, runnables) && e.component != "" do _write_wrapper(&b, e, host.name, .Fixed)

	_write_frame_dispatcher :: proc(b: ^strings.Builder, name: string, rows: []_UpdateRow, kind: Update_Kind, host: string, runnables: []gen_facts.Runnable_Pkg) {
		fmt.sbprintf(b, "%s :: proc(dt: f32) {{\n", name)
		for e in rows {
			if !_included(e, host, runnables) do continue
			fmt.sbprintf(b, "\t%s(dt)\n", _call_name(e, host, kind))
		}
		strings.write_string(b, "}\n\n")
	}
	_write_frame_dispatcher(&b, "__update", frame_rows, .Frame, host.name, runnables)
	strings.write_string(&b, "// After __update, the last stage before the frame renders.\n")
	_write_frame_dispatcher(&b, "__late_update", late_rows, .Late, host.name, runnables)

	// Fixed-tick dispatcher (plugins/engine/docs/FixedTick.md): the app loop's accumulator
	// calls this 0..k times per frame with the constant fixed_dt. divisor=N
	// subscribers run every Nth tick at fixed_dt * N.
	strings.write_string(&b, "__fixed_update :: proc(fixed_dt: f32) {\n")
	for e in fixed_rows {
		if !_included(e, host.name, runnables) do continue
		if e.divisor > 1 {
			fmt.sbprintf(&b, "\tif engine.fixed_tick_index() %% %d == 0 do %s(fixed_dt * %d)\n", e.divisor, _call_name(e, host.name, .Fixed), e.divisor)
		} else {
			fmt.sbprintf(&b, "\t%s(fixed_dt)\n", _call_name(e, host.name, .Fixed))
		}
	}
	strings.write_string(&b, "}\n\n")

	strings.write_string(&b, "// The dispatchers as one value, and a frame of simulation through engine.frame_tick.\n")
	strings.write_string(&b, "__ticks :: engine.Tick_Hooks{fixed_update = __fixed_update, update = __update, late_update = __late_update}\n\n")
	strings.write_string(&b, "__frame_tick :: proc(dt: f32, step: bool) {\n")
	strings.write_string(&b, "\tengine.frame_tick(__ticks, dt, step)\n")
	strings.write_string(&b, "}\n")

	db.emit(w, fmt.tprintf("%s/update_generated.odin", host.path), strings.to_string(b))
}

// `__fixed_update_Spinner` for `fixed_update_Spinner`: a profile or a
// breakpoint reads as the proc it wraps.
_wrapper_name :: proc(e: _UpdateRow, kind: Update_Kind) -> string {
	return fmt.tprintf("__%s", e.name)
}

_attr_name :: proc(kind: Update_Kind) -> string {
	switch kind {
	case .Frame: return "update"
	case .Late:  return "late_update"
	case .Fixed: return "fixed_update"
	}
	return ""
}

// The loop a per-item proc does not write: every enabled instance of its type
// in the current world, in pool order.
_write_wrapper :: proc(b: ^strings.Builder, e: _UpdateRow, host: string, kind: Update_Kind) {
	call := e.name if e.pkg == host else fmt.tprintf("%s.%s", e.pkg, e.name)
	pool: string
	if e.comp_poolable {
		pool = fmt.tprintf("&w.%s", e.comp_plural)
	} else if e.comp_pkg == host {
		pool = fmt.tprintf("%s(w)", e.comp_plural)
	} else {
		pool = fmt.tprintf("%s.%s(w)", e.comp_pkg, e.comp_plural)
	}
	fmt.sbprintf(b, "// @(%s={{component=%s}}) %s\n", _attr_name(kind), e.component, call)
	fmt.sbprintf(b, "%s :: proc(dt: f32) {{\n", _wrapper_name(e, kind))
	strings.write_string(b, "\tw := engine.ctx_world()\n")
	fmt.sbprintf(b, "\tit := engine.pool_iterator(%s)\n", pool)
	strings.write_string(b, "\tfor c, _ in engine.pool_next(&it) {\n")
	if !e.comp_poolable do strings.write_string(b, "\t\tif !c.enabled do continue\n")
	fmt.sbprintf(b, "\t\t%s(dt, c)\n", call)
	strings.write_string(b, "\t}\n")
	strings.write_string(b, "}\n\n")
}
