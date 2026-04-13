package phase_gen

import "core:fmt"
import "core:odin/ast"
import "core:strings"
import "core:slice"
import "../gen_core"

DEFAULT_PHASE_NAMES :: []string{"EditorInit", "EditorShutdown", "Init", "Shutdown"}

PhaseMode :: enum {
	All,
	Editor,
	App,
}

PhaseEntry :: struct {
	key_name:  string,
	key_index: int,
	order:     int,
	name:      string,
	mode:      PhaseMode,
	pkg_name:  string,
}

PhaseCollectData :: struct {
	entries:     [dynamic]PhaseEntry,
	phase_names: [dynamic]string,
	pkg_name:    string,
}

_parse_phase_mode :: proc(s: string) -> PhaseMode {
	switch s {
	case "Editor": return .Editor
	case "App":    return .App
	}
	return .All
}

_has_phase_attr :: proc(attr: ^ast.Attribute) -> (key_name: string, order: int, mode: PhaseMode, found: bool) {
	if attr == nil do return "", 0, .All, false
	if val, ok := gen_core.AttrFindFieldValue(attr, "phase"); ok {
		if comp, comp_ok := val.derived.(^ast.Comp_Lit); comp_ok {
			if key_ex, ok := gen_core.CompLitGetField(comp, "key"); ok do key_name = gen_core.ExtractKeyName(key_ex)
			if order_ex, ok := gen_core.CompLitGetField(comp, "order"); ok do order = gen_core.ExtractInt(order_ex)
			if mode_ex, ok := gen_core.CompLitGetField(comp, "mode"); ok do mode = _parse_phase_mode(gen_core.ExtractKeyName(mode_ex))
			return key_name, order, mode, key_name != ""
		}
	}
	for elem in attr.elems {
		key, val, ok := gen_core.AttrElemKeyValue(elem)
		if !ok do continue
		switch key {
		case "key":
			key_name = gen_core.ExtractKeyName(val)
		case "order":
			order = gen_core.ExtractInt(val)
		case "mode":
			mode = _parse_phase_mode(gen_core.ExtractKeyName(val))
		}
	}
	return key_name, order, mode, key_name != ""
}

_collect_phase_extra :: proc(pkg: ^ast.Package) -> [dynamic]string {
	names: [dynamic]string
	for _, file in pkg.files {
		for decl in file.decls {
			v_decl, is_value := decl.derived.(^ast.Value_Decl)
			if !is_value do continue
			if len(v_decl.names) == 0 do continue
			ident_name := ""
			if id, ok := v_decl.names[0].derived.(^ast.Ident); ok {
				ident_name = id.name
			}
			if ident_name != "Phase_Extra" do continue
			if len(v_decl.values) == 0 do continue
			enum_type, is_enum := v_decl.values[0].derived.(^ast.Enum_Type)
			if !is_enum || enum_type.fields == nil do continue
			for field in enum_type.fields {
				if id, ok := field.derived.(^ast.Ident); ok {
					append(&names, id.name)
				} else if f, ok := field.derived.(^ast.Field); ok && len(f.names) > 0 {
					if id, ok := f.names[0].derived.(^ast.Ident); ok {
						append(&names, id.name)
					}
				}
			}
			return names
		}
	}
	return names
}

_index_of_phase :: proc(phase_names: []string, key: string) -> int {
	for name, i in phase_names {
		if name == key do return i
	}
	return -1
}

collect :: proc(pkg: ^ast.Package, data: ^PhaseCollectData) -> bool {
	if pkg == nil do return false

	if data.pkg_name == "" {
		data.pkg_name = pkg.name
		for n in DEFAULT_PHASE_NAMES do append(&data.phase_names, n)
	}

	extra := _collect_phase_extra(pkg)
	defer delete(extra)
	for n in extra {
		already := false
		for existing in data.phase_names {
			if existing == n {
				already = true
				break
			}
		}
		if !already do append(&data.phase_names, n)
	}
	

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

			is_no_arg_proc := false
			if len(v_decl.values) > 0 {
				if pl, ok_lit := v_decl.values[0].derived.(^ast.Proc_Lit); ok_lit {
					if pt, ok_type := pl.type.derived.(^ast.Proc_Type); ok_type {
						is_no_arg_proc = pt.params == nil || len(pt.params.list) == 0
					}
				}
			}
			if !is_no_arg_proc do continue

			for attr in v_decl.attributes {
				key_name, order, mode, found := _has_phase_attr(attr)
				if found {
					idx := _index_of_phase(data.phase_names[:], key_name)
					append(&data.entries, PhaseEntry{key_name = key_name, key_index = idx, order = order, name = ident_name, mode = mode, pkg_name = pkg.name})
					break
				}
			}
		}
	}

	return true
}

collect_finalize :: proc(data: ^PhaseCollectData) {
	slice.sort_by(data.entries[:], proc(a, b: PhaseEntry) -> bool {
		if a.key_index != b.key_index do return a.key_index < b.key_index
		return a.order < b.order
	})
}

_write_phase_enum :: proc(b: ^strings.Builder, phase_names: []string) {
	strings.write_string(b, "Phase :: enum {\n")
	for name in phase_names {
		strings.write_string(b, "\t")
		strings.write_string(b, name)
		strings.write_string(b, ",\n")
	}
	strings.write_string(b, "}\n\n")
}

_write_dispatch_proc :: proc(b: ^strings.Builder, proc_name: string, entries: []PhaseEntry) {
	strings.write_string(b, proc_name)
	strings.write_string(b, " :: proc(key: Phase) {\n")
	strings.write_string(b, "\t#partial switch key {\n")
	current_key := ""
	for e in entries {
		if e.key_name != current_key {
			current_key = e.key_name
			fmt.sbprintf(b, "\tcase .%s:\n", current_key)
		}
		strings.write_string(b, "\t\t")
		strings.write_string(b, e.name)
		strings.write_string(b, "()\n")
	}
	strings.write_string(b, "\t}\n")
	strings.write_string(b, "}\n")
}

_split_entries :: proc(data: ^PhaseCollectData) -> (editor: [dynamic]PhaseEntry, app: [dynamic]PhaseEntry) {
	for e in data.entries {
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

generate_editor :: proc(data: ^PhaseCollectData, out_dir: string) -> bool {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	strings.write_string(&b, "package ")
	strings.write_string(&b, data.pkg_name)
	strings.write_string(&b, "\n\n")
	strings.write_string(&b, "// Code generated by phase_gen. Do not edit.\n\n")
	strings.write_string(&b, "import \"../app\"\n\n")

	editor_entries, app_entries := _split_entries(data)
	defer delete(editor_entries)
	defer delete(app_entries)

	strings.write_string(&b, "phase_editor_run :: proc(key: app.Phase) {\n")
	strings.write_string(&b, "\t#partial switch key {\n")
	current_key := ""
	for e in editor_entries {
		if e.key_name != current_key {
			current_key = e.key_name
			fmt.sbprintf(&b, "\tcase .%s:\n", current_key)
		}
		strings.write_string(&b, "\t\t")
		if e.pkg_name != data.pkg_name {
			strings.write_string(&b, e.pkg_name)
			strings.write_string(&b, ".")
		}
		strings.write_string(&b, e.name)
		strings.write_string(&b, "()\n")
	}
	strings.write_string(&b, "\t}\n")
	strings.write_string(&b, "}\n")

	gen_path := strings.concatenate({out_dir, "/phases_generated.odin"})
	return gen_core.WriteGeneratedFile(gen_path, strings.to_string(b))
}

generate_app :: proc(data: ^PhaseCollectData, out_dir: string) -> bool {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	strings.write_string(&b, "package app\n\n")
	strings.write_string(&b, "// Code generated by phase_gen. Do not edit.\n\n")

	_write_phase_enum(&b, data.phase_names[:])

	editor_entries, app_entries := _split_entries(data)
	defer delete(editor_entries)
	defer delete(app_entries)

	_write_dispatch_proc(&b, "phase_run", app_entries[:])

	gen_path := strings.concatenate({out_dir, "/phases_generated.odin"})
	return gen_core.WriteGeneratedFile(gen_path, strings.to_string(b))
}

cleanup :: proc(data: ^PhaseCollectData) {
	delete(data.entries)
	delete(data.phase_names)
}
