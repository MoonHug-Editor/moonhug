package gen_core

import "core:fmt"
import "core:os"
import "core:odin/parser"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:strconv"

// ParsePackage parses a package from path. Returns (nil, false) on failure.
ParsePackage :: proc(pkg_path: string) -> (^ast.Package, bool) {
	pkg, ok := parser.parse_package_from_path(pkg_path)
	if !ok {
		fmt.eprintf("gen_core: failed to parse package '%s'\n", pkg_path)
		return nil, false
	}
	return pkg, true
}

// ExtractString returns a string from a Basic_Lit (strips quotes).
ExtractString :: proc(expr: ^ast.Expr) -> string {
	if expr == nil do return ""
	if bl, ok := expr.derived.(^ast.Basic_Lit); ok {
		s := bl.tok.text
		if len(s) >= 2 && s[0] == '"' && s[len(s)-1] == '"' do return s[1 : len(s)-1]
		return s
	}
	return ""
}

// ExtractStringExtended returns a string from Basic_Lit, nameof(ident), Ident, or Selector_Expr (field name).
ExtractStringExtended :: proc(expr: ^ast.Expr) -> string {
	if expr == nil do return ""
	if bl, ok := expr.derived.(^ast.Basic_Lit); ok {
		s := bl.tok.text
		if len(s) >= 2 && s[0] == '"' && s[len(s)-1] == '"' do return s[1 : len(s)-1]
		return s
	}
	if call, ok := expr.derived.(^ast.Call_Expr); ok && call.expr != nil && len(call.args) == 1 {
		if id, ok_callee := call.expr.derived.(^ast.Ident); ok_callee && id.name == "nameof" {
			if arg_id, ok_arg := call.args[0].derived.(^ast.Ident); ok_arg do return arg_id.name
		}
	}
	if id, ok := expr.derived.(^ast.Ident); ok do return id.name
	if sel, ok := expr.derived.(^ast.Selector_Expr); ok && sel.field != nil {
		if fid, ok := sel.field.derived.(^ast.Ident); ok do return fid.name
	}
	return ""
}

// ResolveString resolves an expression to a string: constant lookup (same-package) or ExtractStringExtended.
ResolveString :: proc(expr: ^ast.Expr, constants: ^map[string]string) -> string {
	if expr == nil do return ""
	if id, ok := expr.derived.(^ast.Ident); ok {
		if constants != nil {
			if v, ok2 := constants[id.name]; ok2 do return v
		}
		return id.name
	}
	if sel, ok := expr.derived.(^ast.Selector_Expr); ok && sel.field != nil {
		if fid, ok := sel.field.derived.(^ast.Ident); ok && constants != nil {
			if v, ok2 := constants[fid.name]; ok2 do return v
		}
		if fid, ok := sel.field.derived.(^ast.Ident); ok do return fid.name
	}
	return ExtractStringExtended(expr)
}

// ExtractInt returns an int from Basic_Lit or Unary_Expr(-, expr).
ExtractInt :: proc(expr: ^ast.Expr) -> int {
	if expr == nil do return 0
	#partial switch e in expr.derived {
	case ^ast.Basic_Lit:
		n, _ := strconv.parse_int(e.tok.text)
		return n
	case ^ast.Unary_Expr:
		if e.op.text == "-" {
			return -ExtractInt(e.expr)
		}
		return 0
	case:
		return 0
	}
}

// ExtractKeyName returns enum variant name from Ident, Selector_Expr, Implicit_Selector_Expr, or first arg of Call_Expr.
ExtractKeyName :: proc(expr: ^ast.Expr) -> string {
	if expr == nil do return ""
	#partial switch ex in expr.derived {
	case ^ast.Ident:
		return ex.name
	case ^ast.Selector_Expr:
		if ex.field != nil {
			if id, ok := ex.field.derived.(^ast.Ident); ok do return id.name
		}
		return ""
	case ^ast.Implicit_Selector_Expr:
		if ex.field != nil {
			if id, ok := ex.field.derived.(^ast.Ident); ok do return id.name
		}
		return ""
	case ^ast.Call_Expr:
		if len(ex.args) > 0 do return ExtractKeyName(ex.args[0])
		return ""
	case:
		return ""
	}
}

// BuildConstants builds a map of same-package string constant name -> value from the package AST.
BuildConstants :: proc(pkg: ^ast.Package) -> map[string]string {
	m: map[string]string
	for _, file in pkg.files {
		for decl in file.decls {
			v_decl, is_value := decl.derived.(^ast.Value_Decl)
			if !is_value do continue
			if len(v_decl.names) != 1 || len(v_decl.values) != 1 do continue
			if _, is_struct := v_decl.values[0].derived.(^ast.Struct_Type); is_struct do continue
			bl, ok := v_decl.values[0].derived.(^ast.Basic_Lit)
			if !ok || len(bl.tok.text) < 2 || bl.tok.text[0] != '"' do continue
			name := ""
			if id, ok_id := v_decl.names[0].derived.(^ast.Ident); ok_id do name = id.name
			if name != "" do m[name] = ExtractString(v_decl.values[0])
		}
	}
	return m
}

// AttrElemKeyValue returns the key and value for an attribute element (Field_Value or Field).
AttrElemKeyValue :: proc(elem: ^ast.Expr) -> (key: string, value: ^ast.Expr, found: bool) {
	if elem == nil do return "", nil, false
	#partial switch ex in elem.derived {
	case ^ast.Field_Value:
		if ex.field != nil {
			if id, ok := ex.field.derived.(^ast.Ident); ok {
				return id.name, ex.value, true
			}
		}
		return "", nil, false
	case ^ast.Field:
		if len(ex.names) > 0 {
			if id, ok := ex.names[0].derived.(^ast.Ident); ok {
				return id.name, ex.default_value, true
			}
		}
		return "", nil, false
	case:
		return "", nil, false
	}
}

// AttrFindFieldValue finds the attribute element with the given key and returns its value expression.
AttrFindFieldValue :: proc(attr: ^ast.Attribute, key: string) -> (value: ^ast.Expr, found: bool) {
	if attr == nil || attr.elems == nil do return nil, false
	for elem in attr.elems {
		k, val, ok := AttrElemKeyValue(elem)
		if ok && k == key do return val, true
	}
	return nil, false
}

// CompLitGetField returns the value expression for the named field in a compound literal.
CompLitGetField :: proc(comp: ^ast.Comp_Lit, field_name: string) -> (value: ^ast.Expr, found: bool) {
	if comp == nil || comp.elems == nil do return nil, false
	for sub in comp.elems {
		k, val, ok := AttrElemKeyValue(sub)
		if ok && k == field_name do return val, true
	}
	return nil, false
}

// StructFieldTag returns the raw tag string from an ast.Field (parser already filled field.tag).
StructFieldTag :: proc(field: ^ast.Field) -> string {
	if field == nil do return ""
	if field.tag.kind == .Invalid do return ""
	s := field.tag.text
	if len(s) >= 2 && s[0] == '`' && s[len(s)-1] == '`' do return s[1 : len(s)-1]
	if len(s) >= 2 && s[0] == '"' && s[len(s)-1] == '"' do return s[1 : len(s)-1]
	return s
}

// FileHasProc returns true if the file contains a proc declaration with the given name.
FileHasProc :: proc(file: ^ast.File, name: string) -> bool {
	for decl in file.decls {
		v_decl, is_value := decl.derived.(^ast.Value_Decl)
		if !is_value do continue
		if len(v_decl.names) == 0 do continue
		id, ok := v_decl.names[0].derived.(^ast.Ident)
		if !ok || id.name != name do continue
		if len(v_decl.values) > 0 {
			if _, ok2 := v_decl.values[0].derived.(^ast.Proc_Lit); ok2 {
				return true
			}
		}
	}
	return false
}

// WriteGeneratedFile writes content to path and reports errors. Returns false on failure.
WriteGeneratedFile :: proc(path: string, content: string) -> bool {
	if err := os.write_entire_file(path, transmute([]u8)(content)); err != nil {
		fmt.eprintf("gen_core: failed to write %s\n", path)
		return false
	}
	fmt.println("gen_core: wrote", path)
	return true
}
