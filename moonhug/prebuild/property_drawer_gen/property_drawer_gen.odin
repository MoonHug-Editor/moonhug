package property_drawer_gen

import "core:fmt"
import "core:odin/ast"
import "core:slice"
import "core:strings"
import "../gen_core"

PropertyDrawerEntry :: struct {
	type_name:  string, // type expression for typeid_of(...), e.g. "f32" or "pkg.MyType"
	priority:   int,    // lower first, higher later
	proc_name:  string,
	source_pkg: string, // package where the procedure is defined; empty or same as output => use bare proc_name
}

PropertyDrawerCollectData :: struct {
	entries:  [dynamic]PropertyDrawerEntry,
	pkg_name: string,
}

_type_expr_string :: proc(expr: ^ast.Expr) -> string {
	if expr == nil do return ""
	#partial switch ex in expr.derived {
	case ^ast.Ident:
		return ex.name
	case ^ast.Selector_Expr:
		base := _type_expr_string(ex.expr)
		if ex.field != nil {
			if id, ok := ex.field.derived.(^ast.Ident); ok {
				if base != "" do return fmt.tprintf("%s.%s", base, id.name)
				return id.name
			}
		}
		return base
	case ^ast.Pointer_Type:
		elem := _type_expr_string(ex.elem)
		if elem != "" do return fmt.tprintf("^%s", elem)
		return ""
	case ^ast.Multi_Pointer_Type:
		elem := _type_expr_string(ex.elem)
		if elem != "" do return fmt.tprintf("[^]%s", elem)
		return ""
	case ^ast.Array_Type:
		elem := _type_expr_string(ex.elem)
		if elem == "" do return ""
		if ex.len != nil {
			len_str := gen_core.ExtractString(ex.len)
			if len_str == "" {
				if bl, ok := ex.len.derived.(^ast.Basic_Lit); ok {
					len_str = bl.tok.text
				}
			}
			if len_str != "" do return fmt.tprintf("[%s]%s", len_str, elem)
		}
		return fmt.tprintf("[]%s", elem)
	case ^ast.Dynamic_Array_Type:
		elem := _type_expr_string(ex.elem)
		if elem != "" do return fmt.tprintf("[dynamic]%s", elem)
		return ""
	case:
		return gen_core.ExtractStringExtended(expr)
	}
}

_has_property_drawer_attr :: proc(attr: ^ast.Attribute) -> (type_name: string, priority: int, found: bool) {
	if attr == nil do return "", 0, false
	val, ok := gen_core.AttrFindFieldValue(attr, "property_drawer")
	if !ok do return "", 0, false
	comp, comp_ok := val.derived.(^ast.Comp_Lit)
	if !comp_ok do return "", 0, false

	if type_ex, ok := gen_core.CompLitGetField(comp, "type"); ok do type_name = _type_expr_string(type_ex)
	if priority_ex, ok := gen_core.CompLitGetField(comp, "priority"); ok do priority = gen_core.ExtractInt(priority_ex)
	return type_name, priority, type_name != ""
}

// Collect appends property_drawer attribute data from one parsed package. Caller must call collect_finalize before generate and delete(data.entries).
collect :: proc(pkg: ^ast.Package, data: ^PropertyDrawerCollectData) -> bool {
	if pkg == nil do return false
	if data.pkg_name == "" do data.pkg_name = pkg.name

	for _, file in pkg.files {
		for decl in file.decls {
			v_decl, is_value := decl.derived.(^ast.Value_Decl)
			if !is_value do continue
			if len(v_decl.names) == 0 do continue

			ident_name := ""
			if id, ok_id := v_decl.names[0].derived.(^ast.Ident); ok_id {
				ident_name = id.name
			}
			if ident_name == "" do continue

			is_proc := false
			if len(v_decl.values) > 0 {
				if _, ok_lit := v_decl.values[0].derived.(^ast.Proc_Lit); ok_lit {
					is_proc = true
				}
			}
			if !is_proc do continue

			for attr in v_decl.attributes {
				type_name, priority, found := _has_property_drawer_attr(attr)
				if found {
					append(&data.entries, PropertyDrawerEntry{
						type_name  = type_name,
						priority   = priority,
						proc_name  = ident_name,
						source_pkg = pkg.name,
					})
					break
				}
			}
		}
	}

	return true
}

// Collect_finalize sorts collected entries by priority (lower first, higher later). Call once after all collect calls before generate.
collect_finalize :: proc(data: ^PropertyDrawerCollectData) {
	slice.sort_by(data.entries[:], proc(a, b: PropertyDrawerEntry) -> bool {
		return a.priority < b.priority
	})
}

// _package_from_type_name returns the package prefix for qualified types (e.g. "app" from "app.A"), or "" if local/core type.
_package_from_type_name :: proc(type_name: string) -> string {
	s := type_name
	for len(s) > 0 {
		if s[0] == '^' {
			s = s[1:]
		} else if len(s) >= 2 && s[0] == '[' {
			close := 0
			for close < len(s) {
				if s[close] == ']' { break }
				close += 1
			}
			if close < len(s) {
				s = s[close + 1:]
			} else {
				break
			}
		} else {
			break
		}
	}
	for i in 0 ..< len(s) {
		if s[i] == '.' do return s[:i]
	}
	return ""
}

// Generate writes init_property_drawer_map and related generated code to out_dir (output file is out_dir/property_drawer_generated.odin).
generate :: proc(data: ^PropertyDrawerCollectData, out_dir: string) -> bool {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	// Collect external packages: from type names (typeid_of(pkg.T)) and from procedure locations (pkg.draw_proc).
	packages_used: map[string]bool
	defer delete(packages_used)
	for e in data.entries {
		if pkg := _package_from_type_name(e.type_name); pkg != "" && pkg != data.pkg_name {
			packages_used[pkg] = true
		}
		if e.source_pkg != "" && e.source_pkg != data.pkg_name {
			packages_used[e.source_pkg] = true
		}
	}
	import_pkgs: [dynamic]string
	defer delete(import_pkgs)
	for pkg in packages_used {
		append(&import_pkgs, pkg)
	}
	slice.sort(import_pkgs[:])

	strings.write_string(&b, "package ")
	strings.write_string(&b, data.pkg_name)
	strings.write_string(&b, "\n\n")
	import_prefix := "../"
	if data.pkg_name == "inspector" {
		import_prefix = "../../"
	}
	for pkg in import_pkgs {
		fmt.sbprintf(&b, "import \"%s%s\"\n", import_prefix, pkg)
	}
	if len(packages_used) > 0 do strings.write_string(&b, "\n")
	strings.write_string(&b, "// Code generated by property_drawer_gen. Do not edit.\n\n")
	strings.write_string(&b, "init_property_drawer_map :: proc() {\n")

	for e in data.entries {
		rhs: string
		if e.source_pkg != "" && e.source_pkg != data.pkg_name {
			rhs = fmt.tprintf("%s.%s", e.source_pkg, e.proc_name)
		} else {
			rhs = e.proc_name
		}
		fmt.sbprintf(&b, "\tmapPropertyDrawer[typeid_of(%s)] = %s\n", e.type_name, rhs)
	}

	strings.write_string(&b, "}\n")

	gen_path := strings.concatenate({out_dir, "/property_drawer_generated.odin"})
	return gen_core.WriteGeneratedFile(gen_path, strings.to_string(b))
}

// Cleanup frees collected data. Safe to call multiple times.
cleanup :: proc(data: ^PropertyDrawerCollectData) {
	delete(data.entries)
}
