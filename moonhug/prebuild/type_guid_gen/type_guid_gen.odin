package type_guid_gen

import "core:fmt"
import "core:odin/ast"
import "core:slice"
import "core:strings"
import "../gen_core"

CreateAssetMenuData :: struct {
	file_name: string,
	menu_name: string,
	order:     int,
}

TypeGuidEntry :: struct {
	pkg_name:         string,
	type_name:        string,
	guid:             string,
	make_proc:        string,
	has_reset:        bool,
	has_cleanup:      bool,
	create_file_name: string,
	create_menu_name: string,
	create_order:     int,
}

// TypeGuidCollectData holds data gathered from the collect stage. Caller must delete(data.entries).
TypeGuidCollectData :: struct {
	entries: [dynamic]TypeGuidEntry,
}

_has_typ_guid_attr :: proc(attr: ^ast.Attribute, constants: ^map[string]string) -> (guid: string, makeProcName: string, create: CreateAssetMenuData, has_create_menu: bool, found: bool) {
	if attr == nil do return "", "", {}, false, false
	val, ok := gen_core.AttrFindFieldValue(attr, "typ_guid")
	if !ok do return "", "", {}, false, false
	comp, comp_ok := val.derived.(^ast.Comp_Lit)
	if !comp_ok do return "", "", {}, false, false

	if guid_ex, ok := gen_core.CompLitGetField(comp, "guid"); ok do guid = gen_core.ResolveString(guid_ex, constants)
	if make_ex, ok := gen_core.CompLitGetField(comp, "makeProcName"); ok do makeProcName = gen_core.ResolveString(make_ex, constants)

	create = {}
	if menu_val, menu_ok := gen_core.CompLitGetField(comp, "menu_assets_create"); menu_ok {
		if menu_comp, mc_ok := menu_val.derived.(^ast.Comp_Lit); mc_ok {
			has_create_menu = true
			if fn_ex, ok := gen_core.CompLitGetField(menu_comp, "file_name"); ok do create.file_name = gen_core.ResolveString(fn_ex, constants)
			if mn_ex, ok := gen_core.CompLitGetField(menu_comp, "menu_name"); ok do create.menu_name = gen_core.ResolveString(mn_ex, constants)
			if ord_ex, ok := gen_core.CompLitGetField(menu_comp, "order"); ok do create.order = gen_core.ExtractInt(ord_ex)
		}
	}
	return guid, makeProcName, create, has_create_menu, guid != ""
}

_pkg_name_from_path :: proc(pkg_path: string) -> string {
	if i := strings.last_index(pkg_path, "/"); i >= 0 && i + 1 < len(pkg_path) {
		return pkg_path[i + 1:]
	}
	return pkg_path
}

// Collect appends typ_guid attribute data from one parsed package. Caller must delete(data.entries).
collect :: proc(pkg: ^ast.Package, pkg_path: string, data: ^TypeGuidCollectData) -> bool {
	if pkg == nil do return false

	constants := gen_core.BuildConstants(pkg)
	defer delete(constants)

	pkg_name := _pkg_name_from_path(pkg_path)

	for _, file in pkg.files {
		for decl in file.decls {
			v_decl, is_value := decl.derived.(^ast.Value_Decl)
			if !is_value do continue
			if len(v_decl.names) == 0 do continue

			type_name := ""
			if id, ok_id := v_decl.names[0].derived.(^ast.Ident); ok_id {
				type_name = id.name
			}
			if type_name == "" do continue

			is_struct_or_union := false
			if len(v_decl.values) > 0 {
				_, ok_st := v_decl.values[0].derived.(^ast.Struct_Type)
				_, ok_un := v_decl.values[0].derived.(^ast.Union_Type)
				is_struct_or_union = ok_st || ok_un
			}
			if !is_struct_or_union do continue

			for attr in v_decl.attributes {
				guid, make_proc, create, has_create_menu, found := _has_typ_guid_attr(attr, &constants)
				if found {
					reset_name   := strings.concatenate({"reset_",   type_name})
					cleanup_name := strings.concatenate({"cleanup_", type_name})
					entry := TypeGuidEntry{
						pkg_name         = pkg_name,
						type_name        = type_name,
						guid             = guid,
						make_proc        = make_proc,
						has_reset        = gen_core.FileHasProc(file, reset_name),
						has_cleanup      = gen_core.FileHasProc(file, cleanup_name),
						create_file_name = "",
						create_menu_name = "",
						create_order     = 0,
					}
					delete(reset_name)
					delete(cleanup_name)
					if has_create_menu {
						entry.create_file_name = create.file_name
						if entry.create_file_name == "" do entry.create_file_name = strings.concatenate({type_name, ".asset"})
						entry.create_menu_name = create.menu_name
						if entry.create_menu_name == "" do entry.create_menu_name = type_name
						entry.create_order = create.order
					}
					append(&data.entries, entry)
					break
				}
			}
		}
	}
	return true
}

// Collect_finalize sorts collected entries by type_name. Call once after all collect calls before generate.
collect_finalize :: proc(data: ^TypeGuidCollectData) {
	slice.sort_by(data.entries[:], proc(a, b: TypeGuidEntry) -> bool {
		return a.type_name < b.type_name
	})
}

// generate writes three files:
//   {engine_dir}/type_key_generated.odin           - package engine: TypeKey enum + GUID vars
//   {app_dir}/type_registration_generated.odin     - package app: register_type_guids
//   {editor_dir}/create_asset_menus_generated.odin - package editor: __create_asset__ procs + register_create_asset_menus
generate :: proc(data: ^TypeGuidCollectData, engine_dir: string, app_dir: string, editor_dir: string) -> bool {
	if !_generate_type_key(data, engine_dir) do return false
	if !_generate_type_procs(data, engine_dir) do return false
	if !_generate_type_registration(data, app_dir) do return false
	if !_generate_create_asset_menus(data, editor_dir) do return false
	return true
}

_generate_type_key :: proc(data: ^TypeGuidCollectData, out_dir: string) -> bool {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	strings.write_string(&b, "package engine\n\n")
	strings.write_string(&b, "import \"core:encoding/uuid\"\n\n")
	strings.write_string(&b, "// Code generated by type_guid_gen. Do not edit.\n\n")
	strings.write_string(&b, "TypeKey :: enum u16 {\n")
	for e, i in data.entries {
		fmt.sbprintf(&b, "\t%s = %d,\n", e.type_name, i)
	}
	strings.write_string(&b, "}\n\n")
	strings.write_string(&b, "INVALID_TYPE_KEY :: TypeKey(max(u16))\n\n")
	strings.write_string(&b, "UUID_NIL :: uuid.Identifier{};\n")
	for e in data.entries {
		fmt.sbprintf(&b, "%s__Guid := uuid.read(%q) or_else UUID_NIL\n", e.type_name, e.guid)
	}

	gen_path := strings.concatenate({out_dir, "/type_key_generated.odin"})
	return gen_core.WriteGeneratedFile(gen_path, strings.to_string(b))
}

_generate_type_registration :: proc(data: ^TypeGuidCollectData, out_dir: string) -> bool {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	strings.write_string(&b, "package app\n\n")
	strings.write_string(&b, "import \"../app\"\n")
	strings.write_string(&b, "import \"../engine\"\n")
	strings.write_string(&b, "import \"core:sync\"\n\n")
	strings.write_string(&b, "// Code generated by type_guid_gen. Do not edit.\n\n")
	strings.write_string(&b, "@(private)\n")
	strings.write_string(&b, "_register_type_guids_once: sync.Once\n\n")
	strings.write_string(&b, "register_type_guids :: proc() {\n")
	strings.write_string(&b, "\tsync.once_do(&_register_type_guids_once, proc() {\n")
	for e in data.entries {
		if e.make_proc != "" {
			fmt.sbprintf(&b, "\t\tengine.register_type(%s.%s, engine.%s__Guid, %s.%s)\n", e.pkg_name, e.type_name, e.type_name, e.pkg_name, e.make_proc)
		} else {
			fmt.sbprintf(&b, "\t\tengine.register_type(%s.%s, engine.%s__Guid)\n", e.pkg_name, e.type_name, e.type_name)
		}
	}
	for e in data.entries {
		fmt.sbprintf(&b, "\t\tengine.register_type_key(%s.%s, engine.TypeKey.%s)\n", e.pkg_name, e.type_name, e.type_name)
	}
	strings.write_string(&b, "\t})\n")
	strings.write_string(&b, "}\n")

	gen_path := strings.concatenate({out_dir, "/type_registration_generated.odin"})
	return gen_core.WriteGeneratedFile(gen_path, strings.to_string(b))
}

_generate_create_asset_menus :: proc(data: ^TypeGuidCollectData, out_dir: string) -> bool {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	strings.write_string(&b, "package editor\n\n")
	strings.write_string(&b, "import \"core:path/filepath\"\n")
	strings.write_string(&b, "import \"../engine\"\n")
	strings.write_string(&b, "import \"../engine/serialization\"\n")
	strings.write_string(&b, "import \"menu\"\n\n")
	strings.write_string(&b, "// Code generated by type_guid_gen. Do not edit.\n\n")

	for e in data.entries {
		if e.create_menu_name == "" do continue
		fmt.sbprintf(&b, "__create_asset__%s :: proc() ", e.type_name)
		strings.write_string(&b, "{\n")
		strings.write_string(&b, "\tfull_path, _ := filepath.join({projectViewData.currentPath, ")
		fmt.sbprintf(&b, "%q", e.create_file_name)
		strings.write_string(&b, "}, context.temp_allocator)\n")
		fmt.sbprintf(&b, "\tinstance := engine.create_instance_by_type_key(engine.TypeKey.%s)\n", e.type_name)
		fmt.sbprintf(&b, "\tserialization.write_asset_to_path(full_path, engine.get_guid_by_type_key(engine.TypeKey.%s), instance)\n", e.type_name)
		strings.write_string(&b, "}\n\n")
	}

	strings.write_string(&b, "register_create_asset_menus :: proc() {\n")
	for e in data.entries {
		if e.create_menu_name == "" do continue
		menu_path := strings.concatenate({"Assets/Create/", e.create_menu_name})
		fmt.sbprintf(&b, "\tmenu.add_menu_item(%q, \"\", __create_asset__%s, %d)\n", menu_path, e.type_name, e.create_order)
		delete(menu_path)
	}
	strings.write_string(&b, "}\n")

	gen_path := strings.concatenate({out_dir, "/create_asset_menus_generated.odin"})
	return gen_core.WriteGeneratedFile(gen_path, strings.to_string(b))
}

_generate_type_procs :: proc(data: ^TypeGuidCollectData, out_dir: string) -> bool {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	strings.write_string(&b, "package engine\n\n")
	strings.write_string(&b, "// Code generated by type_guid_gen. Do not edit.\n\n")

	strings.write_string(&b, "__type_resets_init :: proc() {\n")
	for e in data.entries {
		if e.has_reset {
			fmt.sbprintf(&b, "\ttype_reset_procs[.%s] = proc(ptr: rawptr) {{ reset_%s(cast(^%s)ptr) }}\n", e.type_name, e.type_name, e.type_name)
		}
	}
	strings.write_string(&b, "}\n\n")

	strings.write_string(&b, "__type_cleanups_init :: proc() {\n")
	for e in data.entries {
		if e.has_cleanup {
			fmt.sbprintf(&b, "\ttype_cleanup_procs[.%s] = proc(ptr: rawptr) {{ cleanup_%s(cast(^%s)ptr) }}\n", e.type_name, e.type_name, e.type_name)
		}
	}
	strings.write_string(&b, "}\n")

	gen_path := strings.concatenate({out_dir, "/type_procs_generated.odin"})
	return gen_core.WriteGeneratedFile(gen_path, strings.to_string(b))
}

// Cleanup frees collected data. Safe to call multiple times.
cleanup :: proc(data: ^TypeGuidCollectData) {
	delete(data.entries)
}
