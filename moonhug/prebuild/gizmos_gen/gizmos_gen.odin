package gizmos_gen

// gizmos_gen: the scene-view gizmo hook (README on_draw_gizmos TODO).
//
//   @(on_draw_gizmos={component=BoxCollider2D})          // every alive instance
//   @(on_draw_gizmos_selected={component=BoxCollider2D}) // only when selected
//   box_collider_gizmos :: proc(c: ^physics2d.BoxCollider2D) { gfx.draw_line(...) }
//
//   provide  - recognise procs carrying either attribute; the value names a
//              @(component) type by its unqualified name.
//   generate - emit moonhug/editor/draw_gizmos_generated.odin: __draw_gizmos()
//              iterates each named component's alive instances (typed World
//              pools for engine components, ext pools via the runtime
//              registry's each_alive for app/package components) and calls
//              the proc. The scene view calls __draw_gizmos while its
//              offscreen pass is open, so procs draw with the gfx line API.
//
// The dispatcher lives in the editor root and calls INTO plugin editor
// packages — the legal layering direction (docs/Plugins.md).

import "core:fmt"
import "core:slice"
import "core:strings"
import db "../gen_db"
import "../gen_facts"
import "../components_gen"

Gizmos_GenComp :: struct {
	component: string, // unqualified @(component) type name
	selected:  bool,   // draw_gizmos_selected
}

@(init)
_register :: proc "contextless" () {
	db.provider("gizmos/provide", provide)
	db.generator("gizmos/generate", generate)
}

provide :: proc(w: ^db.World) -> bool {
	_gizmos := db.get_or_create_comps(w, Gizmos_GenComp)
	decls := db.get_comps_DeclInfo()
	procs := db.get_comps(w, gen_facts.Proc_GenComp)
	attrs := db.get_comps(w, gen_facts.Attrs_GenComp)

	m := db.all_of(db.r(decls), db.r(procs), db.r(attrs)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		decl := db.get(decls, entity)
		if decl.name == "" do continue
		attr_set := db.get(attrs, entity)
		if args, found := gen_facts.attr_find(attr_set, "on_draw_gizmos"); found {
			db.set(_gizmos, entity, Gizmos_GenComp{component = _component_arg(args), selected = false})
		} else if args, sfound := gen_facts.attr_find(attr_set, "on_draw_gizmos_selected"); sfound {
			db.set(_gizmos, entity, Gizmos_GenComp{component = _component_arg(args), selected = true})
		}
	}
	return true
}

_component_arg :: proc(args: gen_facts.Attr_Args) -> string {
	if v := args.fields["component"]; v != "" do return v
	return gen_facts.attr_keyname(args, "component")
}

_Row :: struct {
	proc_name: string,
	pkg:       string, // declared package name; "" when in the editor root
	pkg_path:  string,
	component: string,
	selected:  bool,
	// resolved from components_gen data:
	comp_pkg:      string,
	comp_pkg_path: string,
	comp_plural:   string,
	comp_engine:   bool,
}

_PACKAGES_PREFIX :: "moonhug/packages/"

_import_path :: proc(pkg_path: string) -> string {
	if strings.has_prefix(pkg_path, _PACKAGES_PREFIX) {
		rest := pkg_path[len(_PACKAGES_PREFIX):]
		return fmt.tprintf("moonhug:packages/%s", rest)
	}
	// Relative from moonhug/editor: "moonhug/app_editor" -> "../app_editor",
	// "moonhug/editor/menu" -> "menu".
	if strings.has_prefix(pkg_path, "moonhug/editor/") {
		return pkg_path[len("moonhug/editor/"):]
	}
	if strings.has_prefix(pkg_path, "moonhug/") {
		return fmt.tprintf("../%s", pkg_path[len("moonhug/"):])
	}
	return pkg_path
}

generate :: proc(w: ^db.World) -> bool {
	decls := db.get_comps_DeclInfo()
	_gizmos := db.get_comps(w, Gizmos_GenComp)
	comps := db.get_comps(w, components_gen.Component_GenComp)

	// Component name -> facts (pkg, plural, engine-typed or ext).
	rows: [dynamic]_Row
	defer delete(rows)
	m := db.all_of(db.r(decls), db.r(_gizmos)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		decl := db.get(decls, entity)
		g := db.get(_gizmos, entity)
		if g.component == "" {
			fmt.eprintf("gizmos_gen: %s.%s: draw_gizmos needs component=<Type>\n", decl.pkg.name, decl.name)
			return false
		}
		row := _Row{
			proc_name = decl.name,
			pkg       = decl.pkg.name == "editor" ? "" : decl.pkg.name,
			pkg_path  = decl.pkg_path,
			component = g.component,
			selected  = g.selected,
		}
		// Resolve the component's owning package from components_gen facts.
		found := false
		if comps != nil {
			cm := db.all_of(db.r(decls), db.r(comps)); defer db.matcher_destroy(&cm)
			for ce in db.matched(w, &cm) {
				cdecl := db.get(decls, ce)
				cc := db.get(comps, ce)
				if cc.kind != .Component || cdecl.name != g.component do continue
				row.comp_pkg = cc.pkg
				row.comp_pkg_path = cc.pkg_path
				row.comp_plural = cc.plural
				row.comp_engine = cc.pkg == "engine" || cc.pkg == ""
				found = true
				break
			}
		}
		if !found {
			fmt.eprintf("gizmos_gen: %s.%s: unknown @(component) type %q\n", decl.pkg.name, decl.name, g.component)
			return false
		}
		append(&rows, row)
	}
	slice.sort_by(rows[:], proc(a, b: _Row) -> bool {
		if a.component != b.component do return a.component < b.component
		return a.proc_name < b.proc_name
	})

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "package editor\n\n")
	strings.write_string(&b, "// Code generated by gizmos_gen. Do not edit.\n\n")
	strings.write_string(&b, "import engine \"../engine\"\n")

	// Aliased imports: gizmo-proc packages + component packages (for casts).
	imports: map[string]string // pkg name -> import path
	defer delete(imports)
	for r in rows {
		if r.pkg != "" && r.pkg not_in imports {
			imports[r.pkg] = _import_path(r.pkg_path)
		}
		if !r.comp_engine && r.comp_pkg not_in imports {
			imports[r.comp_pkg] = _import_path(r.comp_pkg_path)
		}
	}
	import_names: [dynamic]string
	defer delete(import_names)
	for name in imports do append(&import_names, name)
	slice.sort(import_names[:])
	for name in import_names {
		fmt.sbprintf(&b, "import %s %q\n", name, imports[name])
	}
	strings.write_string(&b, "\n")

	strings.write_string(&b, "// Called by the scene view while its offscreen pass is open.\n")
	strings.write_string(&b, "__draw_gizmos :: proc() {\n")
	strings.write_string(&b, "\tw := engine.ctx_world()\n")
	strings.write_string(&b, "\t_ = w\n")
	for r in rows {
		call := r.pkg == "" ? r.proc_name : fmt.tprintf("%s.%s", r.pkg, r.proc_name)
		if r.comp_engine {
			fmt.sbprintf(&b, "\tfor i in 0 ..< len(w.%s.slots) {{\n", r.comp_plural)
			fmt.sbprintf(&b, "\t\tslot := &w.%s.slots[i]\n", r.comp_plural)
			strings.write_string(&b, "\t\tif !slot.alive || !slot.data.enabled do continue\n")
			if r.selected {
				strings.write_string(&b, "\t\tif !sel_scene_is(slot.data.owner) do continue\n")
			}
			fmt.sbprintf(&b, "\t\t%s(&slot.data)\n", call)
			strings.write_string(&b, "\t}\n")
		} else {
			// Ext component (app or package): iterate via the runtime registry.
			fmt.sbprintf(&b, "\tif pool := w.ext_pools[engine.TypeKey.%s]; pool != nil {{\n", r.component)
			fmt.sbprintf(&b, "\t\tif desc, ok := engine.component_registry[engine.TypeKey.%s]; ok && desc.each_alive != nil {{\n", r.component)
			strings.write_string(&b, "\t\t\tdesc.each_alive(pool, proc(ptr: rawptr) {\n")
			comp_ref := r.comp_pkg == "app" ? fmt.tprintf("app.%s", r.component) : fmt.tprintf("%s.%s", r.comp_pkg, r.component)
			fmt.sbprintf(&b, "\t\t\t\tc := cast(^%s)ptr\n", comp_ref)
			strings.write_string(&b, "\t\t\t\tif !c.enabled do return\n")
			if r.selected {
				strings.write_string(&b, "\t\t\t\tif !sel_scene_is(c.owner) do return\n")
			}
			fmt.sbprintf(&b, "\t\t\t\t%s(c)\n", call)
			strings.write_string(&b, "\t\t\t})\n")
			strings.write_string(&b, "\t\t}\n")
			strings.write_string(&b, "\t}\n")
		}
	}
	strings.write_string(&b, "}\n")

	db.emit(w, "moonhug/editor/draw_gizmos_generated.odin", strings.to_string(b))
	return true
}
