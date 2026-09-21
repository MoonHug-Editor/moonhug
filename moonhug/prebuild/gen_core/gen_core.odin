package gen_core

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:odin/parser"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:slice"
import "core:strconv"
import "core:strings"

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

// ── Typed facade: AST → plain data ───────────────────────────────────────────
// gen_core is the ONLY place (besides type_guid_gen, which needs constant
// resolution + nested literals) that speaks core:odin/ast. The procs below turn
// raw declarations into plain Odin structs so the *_gen modules never unwrap
// `^ast.*` themselves. A "value" is rendered to a canonical string by
// RenderValue, which is a superset of ExtractString / ExtractStringExtended /
// ExtractKeyName / _type_expr_string / ExtractInt-as-digits — so a single rule
// reproduces every module's previous extraction byte-for-byte.

// Struct_Field is one field of a struct/union declaration, names echoing
// core:reflect.Struct_Field (name/type/tag) — but `type` is a written NAME,
// not a resolved typeid: at prebuild there is only syntax.
Struct_Field :: struct {
	name: string,
	type: string, // rendered type expression: "Transform", "engine.Tween", "^Foo", "[4]int"
	tag:  string, // raw struct tag (see StructFieldTag)
	line: int,    // the field's own line, for origin strings (see TagOrigin)
}

// Attr_Args is one @(...) attribute element, flattened to plain data. `key` is
// the attribute name ("component", "menu_item", …); `fields` holds its compound-
// literal members rendered via RenderValue; `nested` holds members that are
// themselves compound literals (e.g. typ_guid's menu_assets_create={...}), one
// level deep. A bare attribute like @(poolable) yields {key="poolable"} — present,
// empty. If a same-package string-constant map is supplied to DeclAttrs, a field
// whose value is a bare identifier matching a constant is resolved to that
// constant's value (reproducing the old ResolveString).
Attr_Args :: struct {
	key:    string,
	fields: map[string]string,
	nested: map[string]Attr_Args,
}

// RenderValue renders an expression to the canonical string the old extractors
// produced: Basic_Lit string → unquoted; number → digits; Ident/Selector →
// name; nameof(x) → x; unary minus → "-N"; pointer/array types → "^T"/"[N]T".
RenderValue :: proc(expr: ^ast.Expr) -> string {
	if expr == nil do return ""
	#partial switch ex in expr.derived {
	case ^ast.Basic_Lit:
		s := ex.tok.text
		if len(s) >= 2 && s[0] == '"' && s[len(s)-1] == '"' do return s[1 : len(s)-1]
		return s
	case ^ast.Ident:
		return ex.name
	case ^ast.Implicit_Selector_Expr:
		if ex.field != nil {
			if id, ok := ex.field.derived.(^ast.Ident); ok do return id.name
		}
		return ""
	case ^ast.Selector_Expr:
		base := RenderValue(ex.expr)
		if ex.field != nil {
			if id, ok := ex.field.derived.(^ast.Ident); ok {
				if base != "" do return fmt.tprintf("%s.%s", base, id.name)
				return id.name
			}
		}
		return base
	case ^ast.Pointer_Type:
		elem := RenderValue(ex.elem)
		if elem != "" do return fmt.tprintf("^%s", elem)
		return ""
	case ^ast.Multi_Pointer_Type:
		elem := RenderValue(ex.elem)
		if elem != "" do return fmt.tprintf("[^]%s", elem)
		return ""
	case ^ast.Array_Type:
		elem := RenderValue(ex.elem)
		len_str := RenderValue(ex.len)
		return fmt.tprintf("[%s]%s", len_str, elem)
	case ^ast.Dynamic_Array_Type:
		return fmt.tprintf("[dynamic]%s", RenderValue(ex.elem))
	case ^ast.Unary_Expr:
		if ex.op.text == "-" do return fmt.tprintf("-%s", RenderValue(ex.expr))
		return ""
	case ^ast.Call_Expr:
		if ex.expr != nil && len(ex.args) == 1 {
			if id, ok := ex.expr.derived.(^ast.Ident); ok && id.name == "nameof" {
				if arg_id, ok_arg := ex.args[0].derived.(^ast.Ident); ok_arg do return arg_id.name
			}
		}
		return ""
	case:
		return ""
	}
}

// _render_resolved renders a value, then resolves a bare-identifier result
// against the same-package string-constant map (nil = no resolution), matching
// the old ResolveString. Type names and dotted paths are unaffected.
_render_resolved :: proc(expr: ^ast.Expr, constants: ^map[string]string) -> string {
	s := RenderValue(expr)
	if constants != nil {
		if v, ok := constants[s]; ok do return v
	}
	return s
}

// DeclAttrs flattens every @(...) attribute element on a declaration into
// Attr_Args (compound-literal members in `fields`, nested literals in `nested`,
// one level deep). `constants` (optional) resolves identifier-valued fields to
// same-package string constants. Returns a fresh slice; caller owns it.
DeclAttrs :: proc(v_decl: ^ast.Value_Decl, constants: ^map[string]string = nil) -> []Attr_Args {
	out: [dynamic]Attr_Args
	if v_decl == nil do return out[:]
	for attr in v_decl.attributes {
		if attr.elems == nil do continue
		for elem in attr.elems {
			// bare ident: @(poolable), @(component), @(update)
			if id, ok := elem.derived.(^ast.Ident); ok {
				append(&out, Attr_Args{key = id.name})
				continue
			}
			key, val, ok := AttrElemKeyValue(elem)
			if !ok do continue
			args := Attr_Args{key = key}
			if comp, comp_ok := val.derived.(^ast.Comp_Lit); comp_ok {
				for sub in comp.elems {
					k, v, kv_ok := AttrElemKeyValue(sub)
					if !kv_ok do continue
					if subcomp, sub_ok := v.derived.(^ast.Comp_Lit); sub_ok {
						// one-level-deep nested literal (e.g. menu_assets_create={...})
						nested := Attr_Args{key = k}
						for n in subcomp.elems {
							nk, nv, nok := AttrElemKeyValue(n)
							if nok do nested.fields[nk] = _render_resolved(nv, constants)
						}
						args.nested[k] = nested
					} else {
						args.fields[k] = _render_resolved(v, constants)
					}
				}
			} else {
				// scalar value form: @(key=value) — store under "".
				args.fields[""] = _render_resolved(val, constants)
			}
			append(&out, args)
		}
	}
	return out[:]
}

// AttrFind returns the first Attr_Args with the given key.
AttrFind :: proc(attrs: []Attr_Args, key: string) -> (Attr_Args, bool) {
	for a in attrs {
		if a.key == key do return a, true
	}
	return {}, false
}

// AttrInt parses an int field the same way ExtractInt did (handles "-N").
AttrInt :: proc(args: Attr_Args, field: string) -> int {
	s, ok := args.fields[field]
	if !ok do return 0
	n, _ := strconv.parse_int(s)
	return n
}

// EnumFieldNames returns the variant names of an enum declaration, in order.
// Empty slice if the decl is not an enum. Caller owns the slice.
EnumFieldNames :: proc(v_decl: ^ast.Value_Decl) -> []string {
	out: [dynamic]string
	if v_decl == nil || len(v_decl.values) == 0 do return out[:]
	enum_type, is_enum := v_decl.values[0].derived.(^ast.Enum_Type)
	if !is_enum || enum_type.fields == nil do return out[:]
	for field in enum_type.fields {
		if id, ok := field.derived.(^ast.Ident); ok {
			append(&out, id.name)
		} else if f, ok := field.derived.(^ast.Field); ok && len(f.names) > 0 {
			if id, ok := f.names[0].derived.(^ast.Ident); ok do append(&out, id.name)
		}
	}
	return out[:]
}

// StructFields extracts a struct/union declaration's fields as plain data.
// Returns an empty slice if the decl is not a struct or union. Caller owns it.
StructFields :: proc(v_decl: ^ast.Value_Decl) -> []Struct_Field {
	out: [dynamic]Struct_Field
	if v_decl == nil || len(v_decl.values) == 0 do return out[:]
	st_fields: ^ast.Field_List
	#partial switch t in v_decl.values[0].derived {
	case ^ast.Struct_Type: st_fields = t.fields
	case ^ast.Union_Type:  return out[:] // unions have variants, not named fields
	case: return out[:]
	}
	if st_fields == nil do return out[:]
	for field_expr in st_fields.list {
		f, ok := field_expr.derived.(^ast.Field)
		if !ok || len(f.names) == 0 do continue
		name := ""
		if id, ok_id := f.names[0].derived.(^ast.Ident); ok_id do name = id.name
		if name == "" do continue
		append(&out, Struct_Field{
			name = name,
			type = RenderValue(f.type),
			tag  = StructFieldTag(f),
			line = f.names[0].pos.line,
		})
	}
	return out[:]
}

// AttrOrigin renders where one registration came from, in the form
//
//   @(view_tab_bar view="Inspector" order=0)  moonhug/editor/inspector_lock.odin:31  _inspector_lock_button
//
// A generator emits this into the registration call as `origin = "..."`, the
// registry stores it, and debug tooltips append it to the element's tooltip — so
// the attribute behind any piece of editor UI is one hover away.
//
// Fields are sorted by key: a map iterates in an unspecified order, and an
// unsorted rendering would make the generated file churn between builds. A
// value that parses as an integer prints bare, anything else is quoted, which
// reproduces how the attribute is written in source.
AttrOrigin :: proc(args: Attr_Args, file_path: string, line: int, decl_name: string) -> string {
	keys: [dynamic]string
	defer delete(keys)
	for k in args.fields do append(&keys, k)
	slice.sort(keys[:])

	b := strings.builder_make()
	strings.write_string(&b, "@(")
	strings.write_string(&b, args.key)
	for k in keys {
		v := args.fields[k]
		// The scalar form @(key=value) stores its value under the empty key.
		if k == "" {
			strings.write_string(&b, "=")
		} else {
			strings.write_string(&b, " ")
			strings.write_string(&b, k)
			strings.write_string(&b, "=")
		}
		if _, is_int := strconv.parse_int(v); is_int && v != "" {
			strings.write_string(&b, v)
		} else {
			fmt.sbprintf(&b, "%q", v)
		}
	}
	fmt.sbprintf(&b, ")  %s:%d  %s", file_path, line, decl_name)
	return strings.to_string(b)
}

// TagOrigin is AttrOrigin for a registration written as a struct TAG rather
// than an @(...) attribute, in the form
//
//   `decor:range(min=0, max=1)`  moonhug/packages/app/tank.odin:12  Tank.blend
//
// `tag_text` is the tag as written, `decl_name` the owner and field joined
// ("Tank.blend"). The layout matches AttrOrigin so debug tooltips read the same
// either way.
TagOrigin :: proc(tag_text: string, file_path: string, line: int, decl_name: string) -> string {
	return fmt.aprintf("`%s`  %s:%d  %s", tag_text, file_path, line, decl_name)
}

// WriteGeneratedFile writes content to path (creating the parent directory —
// e.g. moonhug/engine/registration exists only as generated output) and reports
// errors. Returns false on failure.
WriteGeneratedFile :: proc(path: string, content: string) -> bool {
	// filepath.dir returns a view into path — nothing to free.
	if dir := filepath.dir(path); dir != "." {
		os.make_directory(dir)
	}
	if err := os.write_entire_file(path, transmute([]u8)(content)); err != nil {
		fmt.eprintf("gen_core: failed to write %s\n", path)
		return false
	}
	fmt.println("gen_core: wrote", path)
	return true
}
