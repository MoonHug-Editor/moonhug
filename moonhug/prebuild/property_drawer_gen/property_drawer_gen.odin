package property_drawer_gen

// property_drawer_gen: the steps of the inspector's drawing chain
// (moonhug/editor/inspector/inspector_funnel.odin).
//
//   @(property_drawer={type=core.Curve})
//   property_drawer_Curve :: proc(ctx: ^inspector.Ctx) { ... }                    // the type's own drawing, innermost
//
//   @(property_drawer={type=engine.Material, order="middle"})
//   property_drawer_Material_shader_context :: proc(ctx: ^inspector.Ctx) { ... }  // a step around it, calls inspector.draw(ctx)
//
//   The name is the contract, as type_reset_<T> is: the type's own drawing is
//   `property_drawer_<T>`, a step around it `property_drawer_<T>_<what>`, T
//   the type's own name without its package. An array or builtin type has no
//   name to repeat, so its drawer is `property_drawer_<anything>`.
//   `type` is any type expression the declaring file can name, a container
//   type included. `order` is "outer", "middle", "inner" or a number, lower
//   outside; absent means inner, the type's own drawing.
//
//   generate - moonhug/registration/property_drawers_generated.odin:
//              register_property_drawers(), called by the editor and the
//              tests bootstrap right after inspector.init. Steps of one type
//              at one order both run, by name.

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"
import db "../gen_db"
import "../gen_facts"

Drawer_Entry :: struct {
	type_expr: string, // as the generated file writes it
	type_path: string, // the type's package import path, "" for a builtin or core
	order:     int,
	order_set: bool,
	proc_name: string,
	proc_pkg:  string,
	proc_path: string,
	origin:    string,
}

Drawer_GenComp :: struct {
	entry: Drawer_Entry,
}

_ORDER_OUTER :: -1000
_ORDER_MIDDLE :: 0
_ORDER_INNER :: 1000

@(init)
_register :: proc "contextless" () {
	db.provider("property_drawer/provide", provide)
	db.generator("property_drawer/generate", generate)
}

// The import path and qualified spelling of a type a declaration names:
// `pkg.T` through the file's import of `pkg`, a bare `T` through the
// declaring package, a builtin or a composite of builtins as written.
@(private = "file")
_type_of :: proc(decl: ^db.DeclInfo, type_name: string) -> (expr, path: string, ok: bool) {
	// The named part behind array and pointer layers: "[dynamic]pkg.T" -> "pkg.T".
	t := type_name
	start := 0
	for start < len(t) {
		if t[start] == '^' { start += 1; continue }
		if t[start] == '[' {
			close := strings.index_byte(t[start:], ']')
			if close < 0 do return "", "", false
			start += close + 1
			continue
		}
		break
	}
	layers, named := t[:start], t[start:]
	if named == "" do return "", "", false
	if dot := strings.index_byte(named, '.'); dot >= 0 {
		p, found := gen_facts.file_import(decl, named[:dot])
		if !found do return "", "", false
		return type_name, p, true
	}
	if _is_builtin(named) do return type_name, "", true
	return strings.concatenate({layers, decl.pkg.name, ".", named}), gen_facts.pkg_import_path(decl.pkg_path), true
}

@(private = "file")
_is_builtin :: proc(t: string) -> bool {
	switch t {
	case "bool", "b8", "b16", "b32", "b64", "int", "i8", "i16", "i32", "i64", "i128", "uint", "u8", "u16", "u32", "u64", "u128", "uintptr", "f16", "f32", "f64", "string", "cstring", "rune", "byte", "rawptr", "typeid", "any":
		return true
	}
	return false
}

provide :: proc(w: ^db.World) -> bool {
	drawers := db.get_or_create_comps(w, Drawer_GenComp)
	decls := db.get_comps_DeclInfo()
	procs := db.get_comps(w, gen_facts.Proc_GenComp)
	attrs := db.get_comps(w, gen_facts.Attrs_GenComp)

	m := db.all_of(db.r(decls), db.r(attrs)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		decl := db.get(decls, entity)
		if decl.name == "" do continue
		attr_set := db.get(attrs, entity)
		where_ := fmt.tprintf("%s:%d", gen_facts.decl_rel_path(decl), decl.decl.pos.line)

		args, found := gen_facts.attr_find(attr_set, "property_drawer")
		if !found do continue
		if db.get(procs, entity) == nil {
			fmt.eprintfln("prebuild: %s: @(property_drawer) goes on a proc taking ^inspector.Ctx", where_)
			return false
		}
		type_name := args.fields["type"]
		if type_name == "" {
			fmt.eprintfln("prebuild: %s: @(property_drawer) needs type=<Type>", where_)
			return false
		}
		expr, path, ok := _type_of(decl, type_name)
		if !ok {
			fmt.eprintfln("prebuild: %s: @(property_drawer) type %q: not a type this file can name", where_, type_name)
			return false
		}
		// The name repeats the type: property_drawer_<T> for the type's own
		// drawing, property_drawer_<T>_<what> for a step around it. A type with
		// no name of its own (an array, a builtin) only needs the prefix.
		if !strings.has_prefix(decl.name, "property_drawer_") {
			fmt.eprintfln("prebuild: %s: a @(property_drawer) proc is named property_drawer_<Type>, or property_drawer_<Type>_<what> for a step around the drawing", where_)
			return false
		}
		named := type_name
		for len(named) > 0 && (named[0] == '^' || named[0] == '[') {
			if named[0] == '[' {
				named = named[strings.index_byte(named, ']') + 1:]
			} else {
				named = named[1:]
			}
		}
		if named == type_name && !_is_builtin(named) {
			bare := named
			if dot := strings.last_index_byte(bare, '.'); dot >= 0 do bare = bare[dot + 1:]
			own := strings.concatenate({"property_drawer_", bare}, context.temp_allocator)
			has_order := args.fields["order"] != ""
			if !has_order && decl.name != own {
				fmt.eprintfln("prebuild: %s: the drawing of %s is named %s", where_, type_name, own)
				return false
			}
			if has_order && !strings.has_prefix(decl.name, strings.concatenate({own, "_"}, context.temp_allocator)) {
				fmt.eprintfln("prebuild: %s: a step around %s is named %s_<what>", where_, type_name, own)
				return false
			}
		}
		order, order_set := _ORDER_INNER, false
		if o := args.fields["order"]; o != "" {
			order_set = true
			switch o {
			case "outer":  order = _ORDER_OUTER
			case "middle": order = _ORDER_MIDDLE
			case "inner":  order = _ORDER_INNER
			case:
				n, parsed := strconv.parse_int(o)
				if !parsed {
					fmt.eprintfln("prebuild: %s: @(property_drawer) order %q: \"outer\", \"middle\", \"inner\" or a number", where_, o)
					return false
				}
				order = n
			}
		}
		db.set(drawers, entity, Drawer_GenComp{entry = {
			type_expr = expr,
			type_path = path,
			order     = order,
			order_set = order_set,
			proc_name = decl.name,
			proc_pkg  = decl.pkg.name,
			proc_path = decl.pkg_path,
			origin    = gen_facts.attr_origin(args, gen_facts.decl_rel_path(decl), decl.decl.pos.line, decl.name),
		}})
	}
	return true
}

generate :: proc(w: ^db.World) -> bool {
	entries: [dynamic]Drawer_Entry
	defer delete(entries)
	drawers := db.get_comps(w, Drawer_GenComp)
	for &c in drawers.rows[:db.comps_len(drawers)] do append(&entries, c.entry)

	// One alias per import path: the first spelling wins, every type
	// expression is rewritten to it.
	alias_of := make(map[string]string, context.temp_allocator) // import path -> alias
	// The inspector is imported under one fixed alias, so its own drawers and
	// types spell the same whatever alias their file used.
	alias_of["moonhug:editor/inspector"] = "__inspector"
	rename := proc(alias_of: ^map[string]string, expr, path: string) -> string {
		if path == "" do return expr
		// The alias is the qualifier before the first '.' of the named part.
		named_start := 0
		for named_start < len(expr) && (expr[named_start] == '^' || expr[named_start] == '[') {
			if expr[named_start] == '[' {
				named_start += strings.index_byte(expr[named_start:], ']') + 1
			} else {
				named_start += 1
			}
		}
		dot := strings.index_byte(expr[named_start:], '.')
		if dot < 0 do return expr
		alias := expr[named_start:named_start + dot]
		if known, has := alias_of[path]; has {
			if known == alias do return expr
			return strings.concatenate({expr[:named_start], known, expr[named_start + dot:]})
		}
		alias_of[path] = alias
		return expr
	}
	for &e in entries do e.type_expr = rename(&alias_of, e.type_expr, e.type_path)
	for &e in entries {
		path := gen_facts.pkg_import_path(e.proc_path)
		if known, has := alias_of[path]; has {
			e.proc_pkg = known
		} else {
			alias_of[path] = e.proc_pkg
		}
	}

	slice.sort_by(entries[:], proc(a, b: Drawer_Entry) -> bool {
		if a.type_expr != b.type_expr do return a.type_expr < b.type_expr
		if a.order != b.order do return a.order < b.order
		return a.proc_name < b.proc_name
	})

	Import :: struct { alias, path: string }
	imports: [dynamic]Import
	defer delete(imports)
	for path, alias in alias_of do append(&imports, Import{alias, path})
	slice.sort_by(imports[:], proc(a, b: Import) -> bool { return a.alias < b.alias })

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "package registration\n\n")
	strings.write_string(&b, "import __inspector \"moonhug:editor/inspector\"\n")
	for i in imports do if i.alias != "__inspector" do fmt.sbprintf(&b, "import %s \"%s\"\n", i.alias, i.path)
	strings.write_string(&b, "\n// Code generated by property_drawer_gen. Do not edit.\n\n")
	strings.write_string(&b, "// Every @(property_drawer) step, by type and order.\n")
	strings.write_string(&b, "register_property_drawers :: proc() {\n")
	// Steps of one type at one order both run, by name: composition from
	// independent packages is the point, so it is not a conflict.
	for e in entries {
		if e.order_set {
			fmt.sbprintf(&b, "\t__inspector.add_drawer(typeid_of(%s), %s.%s, order = %d, origin = %q)\n", e.type_expr, e.proc_pkg, e.proc_name, e.order, e.origin)
		} else {
			fmt.sbprintf(&b, "\t__inspector.add_drawer(typeid_of(%s), %s.%s, origin = %q)\n", e.type_expr, e.proc_pkg, e.proc_name, e.origin)
		}
	}
	strings.write_string(&b, "}\n")
	db.emit(w, "moonhug/registration/property_drawers_generated.odin", strings.to_string(b))
	return true
}
