package gen_facts

// The types a serialized value can hold, for the pointer type registry
// (core.register_pointer_type): undo, the clipboard and prefab overrides write
// a field back from JSON through json.unmarshal_any, which needs the field
// type's pointer typeid, and Odin has no way to get ^T from T at run time.
// The type guid generator registers every type found here, so no package
// keeps a hand-written list.

import "core:odin/ast"
import "core:slice"
import "core:strings"
import db "moonhug:prebuild/gen_db"

// One type to register. `expr` is the type as a generated file writes it,
// every named type qualified by its package's name. `pkg_name` and
// `pkg_path` name the package that owns the named type in it: the scan path
// for a scanned package, the import path for one outside the scan
// ("core:math/linalg"), "" for a type of primitives only.
Pointer_Type :: struct {
	expr:     string,
	pkg_name: string,
	pkg_path: string,
	// The named type lives in an editor package: only the editor's
	// registration names it, a game never imports the editor.
	editor:   bool,
}

// Every type a value of one of the root declarations can hold, transitively
// through struct fields: each field's named type with its array layers
// stripped, the layered type itself when register_pointer_type does not cover
// that shape, and the fields of every named type that is a struct in the
// scan. Left out: fields tagged `json:"-"`, pointers, procs, maps, bit sets,
// parametric and inline types, and fixed arrays sized by a constant. Nothing
// writes those as one JSON value. Sorted by `expr`, so the generated file is
// stable.
pointer_types :: proc(w: ^db.World, roots: []^db.DeclInfo) -> []Pointer_Type {
	decls := db.get_comps_DeclInfo()
	fields := db.get_comps(w, Fields_GenComp)

	// Declarations by package path and name, with the package's declared name.
	Pkg_Index :: struct {
		name:  string,
		decls: map[string]db.Entity,
	}
	by_pkg: map[string]^Pkg_Index
	defer {
		for _, idx in by_pkg {
			delete(idx.decls)
			free(idx)
		}
		delete(by_pkg)
	}
	for &d, i in decls.rows[:db.comps_len(decls)] {
		if d.name == "" || d.pkg == nil do continue
		idx, has := by_pkg[d.pkg_path]
		if !has {
			idx = new(Pkg_Index)
			idx.name = d.pkg.name
			by_pkg[d.pkg_path] = idx
		}
		idx.decls[d.name] = db.get_entity(decls, i)
	}

	out: [dynamic]Pointer_Type
	seen: map[string]bool
	defer delete(seen)
	visited: map[string]bool
	defer delete(visited)
	queue: [dynamic]^db.DeclInfo
	defer delete(queue)
	for r in roots do append(&queue, r)

	for len(queue) > 0 {
		d := pop(&queue)
		key := strings.concatenate({d.pkg_path, ".", d.name}, context.temp_allocator)
		if visited[key] do continue
		visited[key] = true
		idx_self, has_self := by_pkg[d.pkg_path]
		if !has_self do continue
		entity, has_entity := idx_self.decls[d.name]
		if !has_entity do continue
		f := db.get(fields, entity)
		if f == nil do continue

		for field in f.fields {
			// A field JSON never carries is never written back from it.
			if strings.contains(field.tag, `json:"-"`) do continue
			layers, base, ok := _split_layers(field.type)
			if !ok do continue
			if !_registrable(base) do continue

			// The named type: where it lives and how the generated file names it.
			qualified, pkg_name, pkg_path := base, "", ""
			next: db.Entity
			has_next := false
			if !_is_primitive(base) {
				if dot := strings.index_byte(base, '.'); dot >= 0 {
					alias, name := base[:dot], base[dot + 1:]
					path, found := file_import(d, alias)
					if !found do continue
					pkg_path = path
					if strings.has_prefix(path, "moonhug:") do pkg_path = strings.concatenate({"moonhug/", path[len("moonhug:"):]})
					if idx, in_scan := by_pkg[pkg_path]; in_scan {
						pkg_name = idx.name
						next, has_next = idx.decls[name]
					} else {
						pkg_name = path
						if slash := strings.last_index_byte(pkg_name, '/'); slash >= 0 do pkg_name = pkg_name[slash + 1:]
						if colon := strings.last_index_byte(pkg_name, ':'); colon >= 0 do pkg_name = pkg_name[colon + 1:]
					}
					qualified = strings.concatenate({pkg_name, ".", name})
				} else {
					pkg_name = idx_self.name
					pkg_path = d.pkg_path
					next, has_next = idx_self.decls[base]
					qualified = strings.concatenate({pkg_name, ".", base})
				}
			}

			editor := _is_editor_path(pkg_path)
			if !seen[qualified] {
				seen[qualified] = true
				append(&out, Pointer_Type{expr = qualified, pkg_name = pkg_name, pkg_path = pkg_path, editor = editor})
			}
			if layers != "" && !_covered_layers(layers) {
				layered := strings.concatenate({layers, qualified})
				if !seen[layered] {
					seen[layered] = true
					append(&out, Pointer_Type{expr = layered, pkg_name = pkg_name, pkg_path = pkg_path, editor = editor})
				}
			}
			if has_next do append(&queue, db.get(decls, next))
		}
	}

	slice.sort_by(out[:], proc(a, b: Pointer_Type) -> bool { return a.expr < b.expr })
	return out[:]
}

// The struct types of every settings var, as roots for pointer_types: the
// settings window records an edit of each field, and undo writes the field
// back from JSON, which needs its type registered. A var names its type
// explicitly (`x: T`) or through its initializer (`x := T{...}`), in its own
// package or through an import. Temp.
settings_roots :: proc(w: ^db.World) -> []^db.DeclInfo {
	out := make([dynamic]^db.DeclInfo, context.temp_allocator)
	decls := db.get_comps_DeclInfo()
	attrs := db.get_comps(w, Attrs_GenComp)
	// Type declarations by package path and name.
	types := make(map[string]^db.DeclInfo, context.temp_allocator)
	for &d in decls.rows[:db.comps_len(decls)] {
		if d.name != "" do types[strings.concatenate({d.pkg_path, ".", d.name}, context.temp_allocator)] = &d
	}
	m := db.all_of(db.r(decls), db.r(attrs)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		d := db.get(decls, entity)
		is_settings := false
		for a in db.get(attrs, entity).attrs {
			switch a.key {
			case "project_settings", "user_settings", "system_settings": is_settings = true
			}
		}
		if !is_settings || d.decl == nil do continue
		expr := d.decl.type
		if expr == nil && len(d.decl.values) > 0 {
			if lit, is_lit := d.decl.values[0].derived.(^ast.Comp_Lit); is_lit do expr = lit.type
		}
		if expr == nil do continue
		pkg_path, name := d.pkg_path, ""
		#partial switch t in expr.derived {
		case ^ast.Ident:
			name = t.name
		case ^ast.Selector_Expr:
			alias, is_ident := t.expr.derived.(^ast.Ident)
			if !is_ident || t.field == nil do continue
			path, found := file_import(d, alias.name)
			if !found do continue
			pkg_path = path
			if strings.has_prefix(path, "moonhug:") do pkg_path = strings.concatenate({"moonhug/", path[len("moonhug:"):]}, context.temp_allocator)
			name = t.field.name
		}
		if name == "" do continue
		if root, ok := types[strings.concatenate({pkg_path, ".", name}, context.temp_allocator)]; ok do append(&out, root)
	}
	return out[:]
}

// The array layers in front of a rendered type and the type behind them:
// "[dynamic][2]Foo" -> "[dynamic][2]", "Foo". ok=false for a pointer, a
// multi-pointer or a fixed array sized by a constant.
@(private = "file")
_split_layers :: proc(rendered: string) -> (layers, base: string, ok: bool) {
	t := strings.trim_space(rendered)
	start := 0
	for strings.has_prefix(t[start:], "[") {
		close := strings.index_byte(t[start:], ']')
		if close < 0 do return "", "", false
		inner := t[start + 1:start + close]
		if inner != "" && inner != "dynamic" {
			for c in inner do if c < '0' || c > '9' do return "", "", false
		}
		start += close + 1
	}
	base = t[start:]
	if strings.has_prefix(base, "^") do return "", "", false
	return t[:start], base, true
}

// True for a type register_pointer_type can take: a plain named type, not a
// proc, map, bit set, parametric or inline type, and not one of the types
// nothing serializes as a value.
@(private = "file")
_registrable :: proc(base: string) -> bool {
	if base == "" do return false
	if strings.contains_any(base, "({ ") do return false
	if strings.has_prefix(base, "map[") || strings.has_prefix(base, "bit_set[") do return false
	if strings.has_prefix(base, "proc") do return false
	switch base {
	case "any", "rawptr", "typeid", "cstring":
		return false
	}
	return true
}

// register_pointer_type(T) covers T, [2]T, [3]T, [4]T and their [dynamic]
// forms itself. Any other layering is registered as its own type.
@(private = "file")
_covered_layers :: proc(layers: string) -> bool {
	switch layers {
	case "[2]", "[3]", "[4]", "[dynamic]", "[dynamic][2]", "[dynamic][3]", "[dynamic][4]":
		return true
	}
	return false
}

// The editor, moonhug/editor and its subpackages, and a plugin's editor
// package and the packages under it.
@(private = "file")
_is_editor_path :: proc(path: string) -> bool {
	return path == "moonhug/editor" || strings.has_prefix(path, "moonhug/editor/") || strings.has_suffix(path, "/editor") || strings.contains(path, "/editor/")
}

@(private = "file")
_is_primitive :: proc(t: string) -> bool {
	switch t {
	case "bool", "b8", "b16", "b32", "b64",
	     "int", "i8", "i16", "i32", "i64", "i128", "uint", "u8", "u16", "u32", "u64", "u128", "uintptr",
	     "f16", "f32", "f64", "string", "rune", "byte":
		return true
	}
	return false
}
