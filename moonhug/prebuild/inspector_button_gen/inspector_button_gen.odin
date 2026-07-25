package inspector_button_gen

// inspector_button_gen: ECS prebuild module for inspector_buttons_generated.odin.
//
//   provide  - query {DeclInfo, Proc, Attrs}, recognise procs carrying a
//              @(inspector_button={label="...", row=N, weight=W}) attribute.
//              The proc's FIRST parameter (^Component) selects the component
//              type — extracted from the AST, so no type name is repeated in
//              the attribute.
//   generate - emit inspector_buttons_generated.odin registering per-typeid
//              button lists (sorted by row, label) with rawptr trampolines.
//              The trampoline calls the proc by name — renaming the proc is a
//              compile error in the generated file.

import "core:fmt"
import "core:odin/ast"
import "core:slice"
import "core:strconv"
import "core:strings"
import db "../gen_db"
import "../gen_facts"

_PKG_NAME :: "inspector"

ButtonEntry :: struct {
	comp_pkg:    string, // package of the component type ("app", "engine", ...)
	comp_type:   string, // e.g. "Tank"
	proc_name:   string,
	label:       string,
	row:         int,
	weight:      f64,
	show_in_array: bool,
	source_pkg:  string,
	source_path: string,
}

Button_GenComp :: struct {
	entries: [dynamic]ButtonEntry,
}

@(init)
_register :: proc "contextless" () {
	db.provider("inspector_button/provide", provide)
	db.generator("inspector_button/generate", generate)
}

// The component type name from the proc's first parameter, which must be a
// pointer to a bare (same-package) struct type: `t: ^Tank` -> "Tank".
_first_param_pointee :: proc(decl: ^ast.Value_Decl) -> string {
	if len(decl.values) == 0 do return ""
	pl, is_proc := decl.values[0].derived.(^ast.Proc_Lit)
	if !is_proc do return ""
	pt, ok := pl.type.derived.(^ast.Proc_Type)
	if !ok || pt.params == nil || len(pt.params.list) == 0 do return ""
	ptr_t, is_ptr := pt.params.list[0].type.derived.(^ast.Pointer_Type)
	if !is_ptr do return ""
	ident, is_ident := ptr_t.elem.derived.(^ast.Ident)
	if !is_ident do return ""
	return ident.name
}

provide :: proc(w: ^db.World) -> bool {
	_buttons := db.get_or_create_comps(w, Button_GenComp)
	decls := db.get_comps_DeclInfo()
	procs := db.get_comps(w, gen_facts.Proc_GenComp)
	attrs := db.get_comps(w, gen_facts.Attrs_GenComp)

	m := db.all_of(db.r(decls), db.r(procs), db.r(attrs)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		decl := db.get(decls, entity)
		if decl.name == "" do continue
		attr_set := db.get(attrs, entity)

		entries: [dynamic]ButtonEntry
		for args in attr_set.attrs {
			if args.key != "inspector_button" do continue
			comp_type := _first_param_pointee(decl.decl)
			if comp_type == "" {
				fmt.printf("inspector_button_gen: %s: first parameter must be ^Component (pointer to a same-package struct)\n", decl.name)
				continue
			}
			label := args.fields["label"]
			if label == "" do label = decl.name
			weight := 1.0
			if ws := args.fields["weight"]; ws != "" {
				if v, wok := strconv.parse_f64(ws); wok do weight = v
			}
			// show_in_array: also frame array ELEMENTS of the component type.
			// Default true — set show_in_array=false for singular actions.
			show_in_array := args.fields["show_in_array"] != "false"
			append(&entries, ButtonEntry{
				comp_pkg    = decl.pkg.name,
				comp_type   = comp_type,
				proc_name   = decl.name,
				label       = label,
				row         = gen_facts.attr_int(args, "row"),
				weight      = weight,
				show_in_array = show_in_array,
				source_pkg  = decl.pkg.name,
				source_path = decl.pkg_path,
			})
		}

		if len(entries) > 0 {
			db.set(_buttons, entity, Button_GenComp{entries = entries})
		} else {
			delete(entries)
		}
	}
	return true
}

generate :: proc(w: ^db.World) -> bool {
	entries: [dynamic]ButtonEntry
	defer delete(entries)

	decls := db.get_comps_DeclInfo()
	_buttons := db.get_comps(w, Button_GenComp)
	m := db.all_of(db.r(decls), db.r(_buttons)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		bc := db.get(_buttons, entity)
		for entry in bc.entries {
			append(&entries, entry)
		}
	}

	// Group per component type; inside a type HIGHER row renders HIGHER on
	// screen (descending sort), then (label, proc) keeps two packages
	// contributing buttons deterministic.
	slice.sort_by(entries[:], proc(a, b: ButtonEntry) -> bool {
		if a.comp_pkg != b.comp_pkg do return a.comp_pkg < b.comp_pkg
		if a.comp_type != b.comp_type do return a.comp_type < b.comp_type
		if a.row != b.row do return a.row > b.row
		if a.label != b.label do return a.label < b.label
		return a.proc_name < b.proc_name
	})

	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	packages_used: map[string]bool
	defer delete(packages_used)
	for e in entries {
		if e.comp_pkg != "" do packages_used[e.comp_pkg] = true
	}
	import_pkgs: [dynamic]string
	defer delete(import_pkgs)
	for pkg in packages_used do append(&import_pkgs, pkg)
	slice.sort(import_pkgs[:])

	strings.write_string(&b, "package inspector\n\n")
	for pkg in import_pkgs {
		if pkg == "engine" {
			fmt.sbprintf(&b, "import \"../../%s\"\n", pkg)
		} else {
			fmt.sbprintf(&b, "import %s \"moonhug:packages/%s\"\n", pkg, pkg)
		}
	}
	if len(import_pkgs) > 0 do strings.write_string(&b, "\n")
	strings.write_string(&b, "// Code generated by inspector_button_gen. Do not edit.\n\n")
	strings.write_string(&b, "_register_inspector_buttons :: proc() {\n")

	// Slices must be heap-allocated: a []T{...} literal inside the proc is
	// stack-backed and dangles once registration returns (label garbage,
	// crash on invoke). Freed by shutdown_registries.
	i := 0
	for i < len(entries) {
		j := i
		for j < len(entries) && entries[j].comp_pkg == entries[i].comp_pkg && entries[j].comp_type == entries[i].comp_type {
			j += 1
		}
		e := entries[i]
		qual := fmt.tprintf("%s.%s", e.comp_pkg, e.comp_type)
		strings.write_string(&b, "\t{\n")
		fmt.sbprintf(&b, "\t\tbtns := make([]Inspector_Button, %d)\n", j - i)
		for k in i ..< j {
			be := entries[k]
			fmt.sbprintf(&b,
				"\t\tbtns[%d] = {{label = \"%s\", row = %d, weight = %v, show_in_array = %v, invoke = proc(comp: rawptr) {{ %s.%s(cast(^%s)comp) }}}}\n",
				k - i, be.label, be.row, f32(be.weight), be.show_in_array, be.comp_pkg, be.proc_name, qual)
		}
		fmt.sbprintf(&b, "\t\tinspector_buttons[typeid_of(%s)] = btns\n", qual)
		strings.write_string(&b, "\t}\n")
		i = j
	}

	strings.write_string(&b, "}\n")

	db.emit(w, "moonhug/editor/inspector/inspector_buttons_generated.odin", strings.to_string(b))
	return true
}
