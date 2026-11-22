package mhgui_gen

// pointer_gen: registers every @(comp_on_pointer) and @(canvas_hit) proc
// with the mhgui plugin (mhgui/pointer.odin, mhgui/raycast.odin).
//
//   @(comp_on_pointer={component=Button})
//   comp_on_pointer_Button :: proc(b: ^Button, ev: ^mhgui.Pointer_Event) { ... }
//
//   @(canvas_hit)
//   canvas_hit_UiShape :: proc(s: ^UiShape, rect: engine.Rect, point: [2]f32) -> bool { ... }
//
// - A pointer proc names its component with `component = T`, a @(component)
//   type of its own package, and is named comp_on_pointer_<T>. A hit proc
//   is named canvas_hit_<T>. Anything else stops the build.
// - Each package with such procs gets mhgui_pointer_generated.odin: an
//   @(init) that registers each one under its type key. The package already
//   imports mhgui, for the event type its procs take.
// - An @(init): this file is not on disk when the phase table is scanned in
//   the same prebuild.
//
// A package that loses its last proc keeps a stale generated file until it is
// deleted by hand: it then fails the build loudly, naming the missing proc.

import "core:fmt"
import "core:slice"
import "core:strings"
import db "moonhug:prebuild/gen_db"
import "moonhug:prebuild/gen_facts"

_POINTER :: "comp_on_pointer"
_HIT :: "canvas_hit"
_MHGUI_PKG :: "moonhug/packages/mhgui"

Pointer_GenComp :: struct {
	component: string, // T
	hit:       bool,   // @(canvas_hit), else @(comp_on_pointer)
}

@(init)
_register :: proc "contextless" () {
	db.provider("mhgui/pointer/provide", pointer_provide)
	db.generator("mhgui/pointer/generate", pointer_generate)
}

pointer_provide :: proc(w: ^db.World) -> bool {
	decls := db.get_comps_DeclInfo()
	attrs := db.get_comps(w, gen_facts.Attrs_GenComp)
	procs := db.get_comps(w, gen_facts.Proc_GenComp)
	tagged := db.get_or_create_comps(w, Pointer_GenComp)

	m := db.all_of(db.r(decls), db.r(procs), db.r(attrs))
	defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		decl := db.get(decls, entity)
		if decl.name == "" do continue
		where_ := fmt.tprintf("%s:%d", gen_facts.decl_rel_path(decl), decl.decl.pos.line)
		if _, is_hit := gen_facts.attr_find(db.get(attrs, entity), _HIT); is_hit {
			prefix := "canvas_hit_"
			if !strings.has_prefix(decl.name, prefix) || len(decl.name) == len(prefix) {
				fmt.eprintf("pointer_gen: %s: a canvas hit proc is named canvas_hit_<Type>, the component's own name\n", where_)
				return false
			}
			db.set(tagged, entity, Pointer_GenComp{component = decl.name[len(prefix):], hit = true})
			continue
		}
		args, has := gen_facts.attr_find(db.get(attrs, entity), _POINTER)
		if !has do continue
		comp := args.fields["component"]
		if comp == "" do comp = gen_facts.attr_keyname(args, "component")
		if comp == "" || strings.contains(comp, ".") {
			fmt.eprintf("pointer_gen: %s: @(%s) names its component with component=T, a type of the same package\n", where_, _POINTER)
			return false
		}
		if want := gen_facts.comp_proc_name(_POINTER, comp); decl.name != want {
			fmt.eprintf("pointer_gen: %s: a @(%s={{component=%s}}) proc is named %s\n", where_, _POINTER, comp, want)
			return false
		}
		db.set(tagged, entity, Pointer_GenComp{component = comp})
	}
	return true
}

@(private = "file")
_Row :: struct {
	pkg_path:  string,
	pkg_name:  string,
	component: string,
	proc_name: string,
	hit:       bool,
}

pointer_generate :: proc(w: ^db.World) -> bool {
	decls := db.get_comps_DeclInfo()
	tagged := db.get_comps(w, Pointer_GenComp)
	if tagged == nil do return true

	// Every @(component), by "<package path>/<T>".
	components := make(map[string]bool, context.temp_allocator)
	{
		comps := db.get_comps(w, gen_facts.Component_GenComp)
		m := db.all_of(db.r(decls), db.r(comps))
		defer db.matcher_destroy(&m)
		for entity in db.matched(w, &m) {
			c := db.get(comps, entity)
			if c.kind != .Component do continue
			components[fmt.tprintf("%s/%s", db.get(decls, entity).pkg_path, db.get(decls, entity).name)] = true
		}
	}

	rows := make([dynamic]_Row, context.temp_allocator)
	m := db.all_of(db.r(decls), db.r(tagged))
	defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		decl := db.get(decls, entity)
		t := db.get(tagged, entity)
		if !components[fmt.tprintf("%s/%s", decl.pkg_path, t.component)] {
			fmt.eprintf("pointer_gen: %s:%d: %s is not a @(component) of package %s\n", gen_facts.decl_rel_path(decl), decl.decl.pos.line, t.component, decl.pkg.name)
			return false
		}
		append(&rows, _Row{pkg_path = decl.pkg_path, pkg_name = decl.pkg.name, component = t.component, proc_name = decl.name, hit = t.hit})
	}
	slice.sort_by(rows[:], proc(a, b: _Row) -> bool {
		if a.pkg_path != b.pkg_path do return a.pkg_path < b.pkg_path
		return a.proc_name < b.proc_name
	})

	for i := 0; i < len(rows); {
		first := rows[i]
		j := i
		any_hit := false
		for j < len(rows) && rows[j].pkg_path == first.pkg_path {
			any_hit |= rows[j].hit
			j += 1
		}
		own := first.pkg_path == _MHGUI_PKG
		qual := own ? "" : "mhgui."

		b := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&b, "package %s\n\n", first.pkg_name)
		strings.write_string(&b, "import \"base:runtime\"\n")
		if any_hit do strings.write_string(&b, "import \"moonhug:packages/engine\"\n")
		if !own do strings.write_string(&b, "import mhgui \"moonhug:packages/mhgui\"\n")
		strings.write_string(&b, "\n// Code generated by mhgui's pointer_gen. Do not edit.\n")
		strings.write_string(&b, "// The package's @(comp_on_pointer) and @(canvas_hit) procs, registered\n")
		strings.write_string(&b, "// with the mhgui plugin under their component's type key.\n\n")
		strings.write_string(&b, "@(init)\n")
		fmt.sbprintf(&b, "_register_%s_mhgui_pointer :: proc \"contextless\" () {{\n", first.pkg_name)
		strings.write_string(&b, "\tcontext = runtime.default_context()\n")
		for r in rows[i:j] {
			if r.hit {
				fmt.sbprintf(&b, "\t%scanvas_hit_register(.%s, proc(comp: rawptr, rect: engine.Rect, point: [2]f32) -> bool {{ return %s(cast(^%s)comp, rect, point) }})\n", qual, r.component, r.proc_name, r.component)
			} else {
				fmt.sbprintf(&b, "\t%sui_pointer_register(.%s, proc(comp: rawptr, ev: ^%sPointer_Event) {{ %s(cast(^%s)comp, ev) }})\n", qual, r.component, qual, r.proc_name, r.component)
			}
		}
		strings.write_string(&b, "}\n")
		db.emit(w, fmt.tprintf("%s/mhgui_pointer_generated.odin", first.pkg_path), strings.to_string(b))
		i = j
	}
	return true
}
