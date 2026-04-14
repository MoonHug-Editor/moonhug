package components_gen

import "core:fmt"
import "core:odin/ast"
import "core:strings"
import "core:slice"
import "../gen_core"

ComponentEntry :: struct {
	type_name:       string,
	snake_name:      string,
	plural:          string,
	menu_path:       string,
	max:             int,
	has_on_validate: bool,
	has_on_destroy:  bool,
}

PoolableEntry :: struct {
	type_name:  string,
	snake_name: string,
	plural:     string,
	max:        int,
}

ComponentCollectData :: struct {
	entries:          [dynamic]ComponentEntry,
	poolable_entries: [dynamic]PoolableEntry,
}

_to_snake_case :: proc(name: string) -> string {
	b := strings.builder_make()
	for r, i in name {
		if r >= 'A' && r <= 'Z' {
			if i > 0 do strings.write_byte(&b, '_')
			strings.write_rune(&b, rune(int(r) + 32))
		} else {
			strings.write_rune(&b, r)
		}
	}
	return strings.to_string(b)
}

_pluralize :: proc(s: string) -> string {
	if strings.has_suffix(s, "s") || strings.has_suffix(s, "x") || strings.has_suffix(s, "sh") || strings.has_suffix(s, "ch") {
		return strings.concatenate({s, "es"})
	}
	return strings.concatenate({s, "s"})
}


_has_poolable_attr :: proc(v_decl: ^ast.Value_Decl) -> (max: int, found: bool) {
	for attr in v_decl.attributes {
		if attr.elems == nil do continue
		for elem in attr.elems {
			if id, ok := elem.derived.(^ast.Ident); ok && id.name == "poolable" {
				return 0, true
			}
			key, val, kv_ok := gen_core.AttrElemKeyValue(elem)
			if kv_ok && key == "poolable" {
				if comp, comp_ok := val.derived.(^ast.Comp_Lit); comp_ok {
					if max_ex, m_ok := gen_core.CompLitGetField(comp, "max"); m_ok {
						return gen_core.ExtractInt(max_ex), true
					}
				}
				return 0, true
			}
		}
	}
	return 0, false
}

_has_component_attr :: proc(v_decl: ^ast.Value_Decl) -> (menu_path: string, max: int, found: bool) {
	for attr in v_decl.attributes {
		if attr.elems == nil do continue
		for elem in attr.elems {
			if id, ok := elem.derived.(^ast.Ident); ok && id.name == "component" {
				return "", 0, true
			}
			key, val, kv_ok := gen_core.AttrElemKeyValue(elem)
			if kv_ok && key == "component" {
				if comp, comp_ok := val.derived.(^ast.Comp_Lit); comp_ok {
					menu_ex, m_ok := gen_core.CompLitGetField(comp, "menu")
					max_ex, mx_ok := gen_core.CompLitGetField(comp, "max")
					path := ""
					mx := 0
					if m_ok do path = gen_core.ExtractString(menu_ex)
					if mx_ok do mx = gen_core.ExtractInt(max_ex)
					return path, mx, true
				}
			}
		}
	}
	return "", 0, false
}

collect :: proc(pkg: ^ast.Package, data: ^ComponentCollectData) -> bool {
	if pkg == nil do return false

	for _, file in pkg.files {
		for decl in file.decls {
			v_decl, is_value := decl.derived.(^ast.Value_Decl)
			if !is_value do continue
			if len(v_decl.names) == 0 || len(v_decl.values) == 0 do continue

			_, is_struct := v_decl.values[0].derived.(^ast.Struct_Type)
			_, is_union := v_decl.values[0].derived.(^ast.Union_Type)
			if !is_struct && !is_union do continue

			type_name := ""
			if id, ok_id := v_decl.names[0].derived.(^ast.Ident); ok_id {
				type_name = id.name
			}
			if type_name == "" do continue

			snake := _to_snake_case(type_name)
			plural := _pluralize(snake)

			menu_path, comp_max, has_comp := _has_component_attr(v_decl)
			if has_comp && is_struct {
				if menu_path == "" do menu_path = type_name
			on_validate_name := strings.concatenate({"on_validate_", type_name})
			defer delete(on_validate_name)
			on_destroy_name := strings.concatenate({"on_destroy_", type_name})
			defer delete(on_destroy_name)
			append(&data.entries, ComponentEntry{
				type_name       = type_name,
				snake_name      = snake,
				plural          = plural,
				menu_path       = menu_path,
				max             = comp_max,
				has_on_validate = gen_core.FileHasProc(file, on_validate_name),
				has_on_destroy  = gen_core.FileHasProc(file, on_destroy_name),
			})
				continue
			}

			if poolable_max, has_poolable := _has_poolable_attr(v_decl); has_poolable {
				append(&data.poolable_entries, PoolableEntry{
					type_name  = type_name,
					snake_name = snake,
					plural     = plural,
					max        = poolable_max,
				})
			}
		}
	}
	return true
}

collect_finalize :: proc(data: ^ComponentCollectData) {
	slice.sort_by(data.entries[:], proc(a, b: ComponentEntry) -> bool {
		return a.type_name < b.type_name
	})
	slice.sort_by(data.poolable_entries[:], proc(a, b: PoolableEntry) -> bool {
		return a.type_name < b.type_name
	})
}

generate_component_menus :: proc(data: ^ComponentCollectData, out_dir: string) -> bool {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	strings.write_string(&b, "package editor\n\n")
	strings.write_string(&b, "import engine \"../engine\"\n")
	strings.write_string(&b, "import \"menu\"\n\n")

	strings.write_string(&b, "register_component_menus :: proc() {\n")
	for e in data.entries {
		menu_full := strings.concatenate({"Component/", e.menu_path})
		defer delete(menu_full)
		fmt.sbprintf(&b, "\tmenu.add_menu_item(%q, \"\", proc() {{ _component_menu_add(.%s) }}, 0)\n", menu_full, e.type_name)
	}
	strings.write_string(&b, "}\n\n")

	strings.write_string(&b, "_component_menu_add :: proc(key: engine.TypeKey) {\n")
	strings.write_string(&b, "\ttH := hierarchy_get_selected()\n")
	strings.write_string(&b, "\tif tH == _HANDLE_NONE do return\n")
	strings.write_string(&b, "\tw := engine.ctx_world()\n")
	strings.write_string(&b, "\tt := engine.pool_get(&w.transforms, engine.Handle(tH))\n")
	strings.write_string(&b, "\tif t == nil do return\n")
	strings.write_string(&b, "\t_, existing_idx := engine.transform_find_comp(t, key)\n")
	strings.write_string(&b, "\tif existing_idx >= 0 do return\n")
	strings.write_string(&b, "\tengine.transform_add_comp(tH, key)\n")
	strings.write_string(&b, "}\n")

	gen_path := strings.concatenate({out_dir, "/menu_component_generated.odin"})
	return gen_core.WriteGeneratedFile(gen_path, strings.to_string(b))
}

_pool_type :: proc(b: ^strings.Builder, type_name: string, max: int) {
	if max > 0 {
		fmt.sbprintf(b, "Pool(%s, %d)", type_name, max)
	} else {
		fmt.sbprintf(b, "Pool(%s)", type_name)
	}
}

generate :: proc(data: ^ComponentCollectData, out_dir: string) -> bool {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	strings.write_string(&b, "package engine\n\n")

	strings.write_string(&b, "World :: struct {\n")
	for e in data.entries {
		fmt.sbprintf(&b, "\t%s: ", e.plural)
		_pool_type(&b, e.type_name, e.max)
		strings.write_string(&b, ",\n")
	}
	for e in data.poolable_entries {
		fmt.sbprintf(&b, "\t%s: ", e.plural)
		_pool_type(&b, e.type_name, e.max)
		strings.write_string(&b, ",\n")
	}
	strings.write_string(&b, "\ttransforms: Pool(Transform),\n")
	strings.write_string(&b, "\tpool_table: [TypeKey]Pool_Entry,\n")
	strings.write_string(&b, "}\n\n")

	strings.write_string(&b, "w_init :: proc(w:^World)\n")
	strings.write_string(&b, "{\n")
	for e in data.entries {
		fmt.sbprintf(&b, "\tpool_init(&w.%s)\n", e.plural)
	}
	for e in data.poolable_entries {
		fmt.sbprintf(&b, "\tpool_init(&w.%s)\n", e.plural)
	}
	strings.write_string(&b, "\tpool_init(&w.transforms)\n")
	strings.write_string(&b, "\t__type_resets_init()\n")
	strings.write_string(&b, "\t__type_cleanups_init()\n")
	strings.write_string(&b, "\t__component_on_validates_init()\n")
	strings.write_string(&b, "\t__component_on_destroys_init()\n")
	for e in data.entries {
		fmt.sbprintf(&b, "\tw.pool_table[TypeKey.%s] = pool_make_entry(&w.%s)\n", e.type_name, e.plural)
		fmt.sbprintf(&b, "\tw.pool_table[TypeKey.%s].collect_fn = proc(comp: rawptr, sf: rawptr) {{\n", e.type_name)
		fmt.sbprintf(&b, "\t\tc := cast(^%s)comp\n", e.type_name)
		strings.write_string(&b, "\t\ts := cast(^SceneFile)sf\n")
		strings.write_string(&b, "\t\tc_copy := c^\n")
		strings.write_string(&b, "\t\tc_copy.owner = {}\n")
		fmt.sbprintf(&b, "\t\tappend(&s.%s, c_copy)\n", e.plural)
		strings.write_string(&b, "\t}\n")
	}
	for e in data.poolable_entries {
		fmt.sbprintf(&b, "\tw.pool_table[TypeKey.%s] = pool_make_entry(&w.%s)\n", e.type_name, e.plural)
	}
	strings.write_string(&b, "}\n\n")

	strings.write_string(&b, "__component_on_validates_init :: proc() {\n")
	for e in data.entries {
		if e.has_on_validate {
			fmt.sbprintf(&b, "\tcomponent_on_validate_procs[.%s] = proc(ptr: rawptr) {{ on_validate_%s(cast(^%s)ptr) }}\n", e.type_name, e.type_name, e.type_name)
		}
	}
	strings.write_string(&b, "}\n\n")

	strings.write_string(&b, "__component_on_destroys_init :: proc() {\n")
	for e in data.entries {
		if e.has_on_destroy {
			fmt.sbprintf(&b, "\tcomponent_on_destroy_procs[.%s] = proc(ptr: rawptr) {{ on_destroy_%s(cast(^%s)ptr) }}\n", e.type_name, e.type_name, e.type_name)
		}
	}
	strings.write_string(&b, "}\n\n")

	strings.write_string(&b, "transform_find_comp :: proc(t: ^Transform, key: TypeKey) -> (Owned, int) {\n")
	strings.write_string(&b, "\tfor c, i in t.components {\n")
	strings.write_string(&b, "\t\tif c.handle.type_key == key do return c, i\n")
	strings.write_string(&b, "\t}\n")
	strings.write_string(&b, "\treturn {}, -1\n")
	strings.write_string(&b, "}\n\n")

	strings.write_string(&b, "transform_get_comp :: proc(tH: Transform_Handle, $T: typeid) -> (Owned, ^T) {\n")
	strings.write_string(&b, "\tw := ctx_world()\n")
	strings.write_string(&b, "\tt := pool_get(&w.transforms, Handle(tH))\n")
	strings.write_string(&b, "\tif t == nil do return {}, nil\n")
	for e, i in data.entries {
		if i == 0 {
			fmt.sbprintf(&b, "\twhen T == %s ", e.type_name)
		} else {
			fmt.sbprintf(&b, "\telse when T == %s ", e.type_name)
		}
		fmt.sbprintf(&b, "{{\n\t\towned, _ := transform_find_comp(t, .%s)\n\t\tif owned.handle.type_key == INVALID_TYPE_KEY do return owned, nil\n\t\treturn owned, pool_get(&w.%s, owned.handle)\n\t}}\n", e.type_name, e.plural)
	}
	strings.write_string(&b, "\treturn {}, nil\n")
	strings.write_string(&b, "}\n\n")

	strings.write_string(&b, "transform_destroy_components :: proc(tH: Transform_Handle) {\n")
	strings.write_string(&b, "\tw := ctx_world()\n")
	strings.write_string(&b, "\tt := pool_get(&w.transforms, Handle(tH))\n")
	strings.write_string(&b, "\tif t == nil do return\n")
	strings.write_string(&b, "\tfor &c in t.components {\n")
	strings.write_string(&b, "\t\tif c.handle.type_key == INVALID_TYPE_KEY do continue\n")
	strings.write_string(&b, "\t\tif world_pool_valid(w, c.handle) {\n")
	strings.write_string(&b, "\t\t\tptr := world_pool_get(w, c.handle)\n")
	strings.write_string(&b, "\t\t\tif ptr != nil do component_on_destroy(c.handle.type_key, ptr)\n")
	strings.write_string(&b, "\t\t\tworld_pool_destroy(w, c.handle)\n")
	strings.write_string(&b, "\t\t}\n")
	strings.write_string(&b, "\t\tc.handle.type_key = INVALID_TYPE_KEY\n")
	strings.write_string(&b, "\t}\n")
	strings.write_string(&b, "\tdelete(t.components)\n")
	strings.write_string(&b, "\tt.components = {}\n")
	strings.write_string(&b, "}\n\n")

	strings.write_string(&b, "transform_destroy_comp :: proc(tH: Transform_Handle, $T: typeid) {\n")
	strings.write_string(&b, "\tw := ctx_world()\n")
	strings.write_string(&b, "\tt := pool_get(&w.transforms, Handle(tH))\n")
	strings.write_string(&b, "\tif t == nil do return\n")
	for e, i in data.entries {
		if i == 0 {
			fmt.sbprintf(&b, "\twhen T == %s ", e.type_name)
		} else {
			fmt.sbprintf(&b, "\telse when T == %s ", e.type_name)
		}
		fmt.sbprintf(&b, "{{\n\t\towned, idx := transform_find_comp(t, .%s)\n\t\tif idx < 0 do return\n\t\tpool_destroy(&w.%s, owned.handle)\n\t\tordered_remove(&t.components, idx)\n\t}}\n", e.type_name, e.plural)
	}
	strings.write_string(&b, "}\n\n")

	if len(data.poolable_entries) > 0 {
		strings.write_string(&b, "world_pool_get_typed :: proc(w: ^World, handle: Handle, $T: typeid) -> ^T {\n")
		for e, i in data.poolable_entries {
			if i == 0 {
				fmt.sbprintf(&b, "\twhen T == %s ", e.type_name)
			} else {
				fmt.sbprintf(&b, "\telse when T == %s ", e.type_name)
			}
			fmt.sbprintf(&b, "{{\n\t\treturn pool_get(&w.%s, handle)\n\t}}\n", e.plural)
		}
		strings.write_string(&b, "\treturn nil\n")
		strings.write_string(&b, "}\n\n")
	}

	strings.write_string(&b, "world_destroy_all :: proc(w: ^World) {\n")
	for e in data.entries {
		if e.has_on_destroy {
			fmt.sbprintf(&b, "\tfor i in 0..<len(w.%s.slots) {{\n", e.plural)
			fmt.sbprintf(&b, "\t\tslot := &w.%s.slots[i]\n", e.plural)
			strings.write_string(&b, "\t\tif !slot.alive do continue\n")
			fmt.sbprintf(&b, "\t\ton_destroy_%s(&slot.data)\n", e.type_name)
			strings.write_string(&b, "\t}\n")
		}
	}
	strings.write_string(&b, "\tfor i in 0..<len(w.transforms.slots) {\n")
	strings.write_string(&b, "\t\tslot := &w.transforms.slots[i]\n")
	strings.write_string(&b, "\t\tif !slot.alive do continue\n")
	strings.write_string(&b, "\t\tt := &slot.data\n")
	strings.write_string(&b, "\t\tdelete(t.name)\n")
	strings.write_string(&b, "\t\tdelete(t.children)\n")
	strings.write_string(&b, "\t\tdelete(t.components)\n")
	strings.write_string(&b, "\t}\n")
	strings.write_string(&b, "}\n")

	gen_path := strings.concatenate({out_dir, "/components_generated.odin"})
	return gen_core.WriteGeneratedFile(gen_path, strings.to_string(b))
}

generate_scene_file :: proc(data: ^ComponentCollectData, out_dir: string) -> bool {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	strings.write_string(&b, "package engine\n\n")

	strings.write_string(&b, "@(typ_guid={guid = \"0d489fce-9c04-4e4d-be12-f3f590d60cea\"})\n")
	strings.write_string(&b, "SceneFile :: struct {\n")
	strings.write_string(&b, "\troot:          Local_ID,\n")
	strings.write_string(&b, "\tnext_local_id: Local_ID,\n")
	strings.write_string(&b, "\ttransforms:    [dynamic]Transform,\n")
	for e in data.entries {
		fmt.sbprintf(&b, "\t%s: [dynamic]%s,\n", e.plural, e.type_name)
	}
	strings.write_string(&b, "}\n\n")

	strings.write_string(&b, "_scene_load_as_child :: proc(sf: ^SceneFile, parent: Transform_Handle = {}, s: ^Scene = nil) -> Transform_Handle {\n")
	strings.write_string(&b, "\tw := ctx_world()\n\n")
	strings.write_string(&b, "\tid_to_transform_handle := make(map[Local_ID]Handle, context.temp_allocator)\n")
	for e in data.entries {
		fmt.sbprintf(&b, "\tid_to_%s_handle := make(map[Local_ID]Handle, context.temp_allocator)\n", e.snake_name)
	}
	strings.write_string(&b, "\n")
	for e in data.entries {
		fmt.sbprintf(&b, "\tfor &%s_data in sf.%s {{\n", e.snake_name, e.plural)
		fmt.sbprintf(&b, "\t\thandle, %s := pool_create(&w.%s)\n", e.snake_name, e.plural)
		fmt.sbprintf(&b, "\t\thandle.type_key = .%s\n", e.type_name)
		fmt.sbprintf(&b, "\t\t%s^ = %s_data\n", e.snake_name, e.snake_name)
		fmt.sbprintf(&b, "\t\tid_to_%s_handle[%s_data.local_id] = handle\n", e.snake_name, e.snake_name)
		strings.write_string(&b, "\t}\n\n")
	}
	strings.write_string(&b, "\tfor &t_data in sf.transforms {\n")
	strings.write_string(&b, "\t\thandle, t := pool_create(&w.transforms)\n")
	strings.write_string(&b, "\t\tt^ = t_data\n")
	strings.write_string(&b, "\t\tt.scene = s\n")
	strings.write_string(&b, "\t\tif t.rotation == {0, 0, 0, 0} do t.rotation = QUAT_IDENTITY\n")
	strings.write_string(&b, "\t\tt_data.name = \"\"\n")
	strings.write_string(&b, "\t\tt_data.children = {}\n")
	strings.write_string(&b, "\t\tt_data.components = {}\n")
	strings.write_string(&b, "\t\tid_to_transform_handle[t_data.local_id] = handle\n")
	strings.write_string(&b, "\t}\n\n")
	strings.write_string(&b, "\tfor _, handle in id_to_transform_handle {\n")
	strings.write_string(&b, "\t\tt := pool_get(&w.transforms, handle)\n")
	strings.write_string(&b, "\t\tif t == nil do continue\n\n")
	strings.write_string(&b, "\t\tif h, ok := resolve_handle(t.parent.pptr.local_id, id_to_transform_handle); ok {\n")
	strings.write_string(&b, "\t\t\tt.parent.handle = h\n")
	strings.write_string(&b, "\t\t}\n\n")
	strings.write_string(&b, "\t\tfor &child in t.children {\n")
	strings.write_string(&b, "\t\t\tif h, ok := resolve_handle(child.pptr.local_id, id_to_transform_handle); ok {\n")
	strings.write_string(&b, "\t\t\t\tchild.handle = h\n")
	strings.write_string(&b, "\t\t\t}\n")
	strings.write_string(&b, "\t\t}\n\n")
	strings.write_string(&b, "\t\tfor &c in t.components {\n")
	for e, i in data.entries {
		if i == 0 {
			fmt.sbprintf(&b, "\t\t\tif h, ok := resolve_handle(c.local_id, id_to_%s_handle); ok {{\n", e.snake_name)
		} else {
			fmt.sbprintf(&b, "\t\t\t} else if h, ok := resolve_handle(c.local_id, id_to_%s_handle); ok {{\n", e.snake_name)
		}
		strings.write_string(&b, "\t\t\t\tc.handle = h\n")
		fmt.sbprintf(&b, "\t\t\t\t%s := pool_get(&w.%s, h)\n", e.snake_name, e.plural)
		fmt.sbprintf(&b, "\t\t\t\tif %s != nil do %s.owner = Transform_Handle(handle)\n", e.snake_name, e.snake_name)
	}
	if len(data.entries) > 0 {
		strings.write_string(&b, "\t\t\t}\n")
	}
	strings.write_string(&b, "\t\t}\n")
	strings.write_string(&b, "\t}\n\n")
	strings.write_string(&b, "\troot_handle: Handle\n")
	strings.write_string(&b, "\tif sf.root != 0 {\n")
	strings.write_string(&b, "\t\tif h, ok := id_to_transform_handle[sf.root]; ok {\n")
	strings.write_string(&b, "\t\t\troot_handle = h\n")
	strings.write_string(&b, "\t\t}\n")
	strings.write_string(&b, "\t}\n\n")
	strings.write_string(&b, "\tif parent != {} && pool_valid(&w.transforms, Handle(parent)) && root_handle != {} {\n")
	strings.write_string(&b, "\t\troot_t := pool_get(&w.transforms, root_handle)\n")
	strings.write_string(&b, "\t\tif root_t != nil {\n")
	strings.write_string(&b, "\t\t\troot_t.parent = make_transform_ref(parent)\n")
	strings.write_string(&b, "\t\t\tp := pool_get(&w.transforms, Handle(parent))\n")
	strings.write_string(&b, "\t\t\tif p != nil {\n")
	strings.write_string(&b, "\t\t\t\tappend(&p.children, Ref{ pptr=PPtr{local_id = root_t.local_id}, handle = root_handle })\n")
	strings.write_string(&b, "\t\t\t}\n")
	strings.write_string(&b, "\t\t}\n")
	strings.write_string(&b, "\t}\n\n")
	strings.write_string(&b, "\treturn Transform_Handle(root_handle)\n")
	strings.write_string(&b, "}\n\n")

	strings.write_string(&b, "_scene_file_remap_local_ids :: proc(sf: ^SceneFile, s: ^Scene) {\n")
	strings.write_string(&b, "\tif s == nil do return\n")
	strings.write_string(&b, "\tremap := make(map[Local_ID]Local_ID)\n")
	strings.write_string(&b, "\tdefer delete(remap)\n\n")
	strings.write_string(&b, "\tfor &t in sf.transforms {\n")
	strings.write_string(&b, "\t\tnew_id := scene_next_id(s)\n")
	strings.write_string(&b, "\t\tremap[t.local_id] = new_id\n")
	strings.write_string(&b, "\t\tt.local_id = new_id\n")
	strings.write_string(&b, "\t}\n\n")
	for e in data.entries {
		fmt.sbprintf(&b, "\tfor &c in sf.%s {{ new_id := scene_next_id(s); remap[c.local_id] = new_id; c.local_id = new_id }}\n", e.plural)
	}
	strings.write_string(&b, "\n\tfor &t in sf.transforms {\n")
	strings.write_string(&b, "\t\tif t.parent.pptr.local_id != 0 {\n")
	strings.write_string(&b, "\t\t\tif new_id, ok := remap[t.parent.pptr.local_id]; ok {\n")
	strings.write_string(&b, "\t\t\t\tt.parent.pptr.local_id = new_id\n")
	strings.write_string(&b, "\t\t\t}\n")
	strings.write_string(&b, "\t\t}\n")
	strings.write_string(&b, "\t\tfor &child in t.children {\n")
	strings.write_string(&b, "\t\t\tif new_id, ok := remap[child.pptr.local_id]; ok {\n")
	strings.write_string(&b, "\t\t\t\tchild.pptr.local_id = new_id\n")
	strings.write_string(&b, "\t\t\t}\n")
	strings.write_string(&b, "\t\t}\n")
	strings.write_string(&b, "\t\tfor &c in t.components {\n")
	strings.write_string(&b, "\t\t\tif new_id, ok := remap[c.local_id]; ok {\n")
	strings.write_string(&b, "\t\t\t\tc.local_id = new_id\n")
	strings.write_string(&b, "\t\t\t}\n")
	strings.write_string(&b, "\t\t}\n")
	strings.write_string(&b, "\t}\n\n")
	strings.write_string(&b, "\tif new_root, ok := remap[sf.root]; ok {\n")
	strings.write_string(&b, "\t\tsf.root = new_root\n")
	strings.write_string(&b, "\t}\n\n")
	for e in data.entries {
		fmt.sbprintf(&b, "\tfor &c in sf.%s {{ _remap_refs_in_value(&c, type_info_of(%s), &remap) }}\n", e.plural, e.type_name)
	}
	strings.write_string(&b, "}\n\n")

	strings.write_string(&b, "scene_file_destroy :: proc(sf: ^SceneFile) {\n")
	strings.write_string(&b, "\tfor &t in sf.transforms {\n")
	strings.write_string(&b, "\t\tdelete(t.name)\n")
	strings.write_string(&b, "\t\tdelete(t.children)\n")
	strings.write_string(&b, "\t\tdelete(t.components)\n")
	strings.write_string(&b, "\t}\n")
	strings.write_string(&b, "\tdelete(sf.transforms)\n")
	for e in data.entries {
		fmt.sbprintf(&b, "\tdelete(sf.%s)\n", e.plural)
	}
	strings.write_string(&b, "}\n")

	gen_path := strings.concatenate({out_dir, "/scene_generated.odin"})
	return gen_core.WriteGeneratedFile(gen_path, strings.to_string(b))
}

cleanup :: proc(data: ^ComponentCollectData) {
	delete(data.entries)
	delete(data.poolable_entries)
}
