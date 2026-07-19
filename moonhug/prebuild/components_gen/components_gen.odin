package components_gen

import "core:fmt"
import "core:strings"
import "core:slice"
import "../gen_core"
import db "../gen_db"
import "../gen_facts"

ComponentEntry :: struct {
	type_name:       string,
	snake_name:      string,
	plural:          string,
	menu_path:       string,
	pkg:             string, // package name ("engine", "app", ...)
	pkg_path:        string, // scan path ("moonhug/app", "moonhug/packages/x")
	max:             int,
	has_on_validate: bool,
	has_on_destroy:  bool,
	has_reset:       bool,
	has_cleanup:     bool,
}

PoolableEntry :: struct {
	type_name:  string,
	snake_name: string,
	plural:     string,
	max:        int,
}

// Component_GenComp marks a DeclInfo entity as either a @get_or_create_comps struct or a
// @poolable struct/union. `kind` selects which entry list the generators put it
// in; the remaining fields carry exactly what the old ComponentEntry /
// PoolableEntry held. The type name lives on the entity's DeclInfo.
ComponentKind :: enum {
	Component,
	Poolable,
}

Component_GenComp :: struct {
	kind:            ComponentKind,
	snake_name:      string,
	plural:          string,
	menu_path:       string,
	pkg:             string,
	pkg_path:        string,
	max:             int,
	has_on_validate: bool,
	has_on_destroy:  bool,
	has_reset:       bool,
	has_cleanup:     bool,
}


@(init)
_register :: proc "contextless" () {
	db.provider("components/provide", provide)
	db.generator("components/generate", generate)
	db.generator("components/scene", generate_scene_file)
	db.generator("components/menus", generate_component_menus)
	db.generator("components/ext", generate_ext_components)
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

_is_vowel :: proc(b: byte) -> bool {
	switch b {
	case 'a', 'e', 'i', 'o', 'u': return true
	}
	return false
}

_pluralize :: proc(s: string) -> string {
	if strings.has_suffix(s, "s") || strings.has_suffix(s, "x") || strings.has_suffix(s, "sh") || strings.has_suffix(s, "ch") {
		return strings.concatenate({s, "es"})
	}
	// consonant + y -> ies (rigidbody -> rigidbodies).
	if len(s) >= 2 && s[len(s)-1] == 'y' && !_is_vowel(s[len(s)-2]) {
		return strings.concatenate({s[:len(s)-1], "ies"})
	}
	return strings.concatenate({s, "s"})
}

_pkg_name :: proc(pkg_path: string) -> string {
	if i := strings.last_index(pkg_path, "/"); i >= 0 && i + 1 < len(pkg_path) {
		return pkg_path[i + 1:]
	}
	return pkg_path
}

// Components in package engine keep their typed World/SceneFile storage;
// components anywhere else go through the runtime component registry (ext
// pools + guid-tagged blob records in scene files).
_is_engine :: proc(e: ComponentEntry) -> bool {
	return e.pkg == "engine" || e.pkg == ""
}


provide :: proc(w: ^db.World) -> bool {
	_components := db.get_or_create_comps(w, Component_GenComp)
	decls   := db.get_comps_DeclInfo()
	structs := db.get_comps(w, gen_facts.Struct_GenComp) // struct OR union
	attrs   := db.get_comps(w, gen_facts.Attrs_GenComp)

	m := db.all_of(db.r(decls), db.r(structs), db.r(attrs)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		decl := db.get(decls, entity)
		type_name := decl.name
		if type_name == "" do continue
		is_union := db.get(structs, entity).is_union

		snake := _to_snake_case(type_name)
		plural := _pluralize(snake)

		attr_set := db.get(attrs, entity)

		// @(component) — structs only. Never in an editor/ subpackage: those
		// compile only into the editor binary, so their components could not
		// load in the app build.
		if args, has_comp := gen_facts.attr_find(attr_set, "component"); has_comp && !is_union {
			if strings.has_suffix(decl.pkg_path, "/editor") {
				fmt.eprintf("components_gen: @(component) %s in editor package %s — components belong in the package root\n", type_name, decl.pkg_path)
				continue
			}
			menu_path := args.fields["menu"]
			if menu_path == "" do menu_path = type_name
			on_validate_name := strings.concatenate({"on_validate_", type_name})
			defer delete(on_validate_name)
			on_destroy_name := strings.concatenate({"on_destroy_", type_name})
			defer delete(on_destroy_name)
			reset_name := strings.concatenate({"reset_", type_name})
			defer delete(reset_name)
			cleanup_name := strings.concatenate({"cleanup_", type_name})
			defer delete(cleanup_name)
			db.set(_components, entity, Component_GenComp{
				kind            = .Component,
				snake_name      = snake,
				plural          = plural,
				menu_path       = menu_path,
				pkg             = _pkg_name(decl.pkg_path),
				pkg_path        = decl.pkg_path,
				max             = gen_facts.attr_int(args, "max"),
				has_on_validate = gen_core.FileHasProc(decl.file, on_validate_name),
				has_on_destroy  = gen_core.FileHasProc(decl.file, on_destroy_name),
				has_reset       = gen_core.FileHasProc(decl.file, reset_name),
				has_cleanup     = gen_core.FileHasProc(decl.file, cleanup_name),
			})
			continue
		}

		// @(poolable) — struct or union.
		if args, has_poolable := gen_facts.attr_find(attr_set, "poolable"); has_poolable {
			db.set(_components, entity, Component_GenComp{
				kind       = .Poolable,
				snake_name = snake,
				plural     = plural,
				max        = gen_facts.attr_int(args, "max"),
			})
		}
	}
	return true
}

// _ComponentData rebuilds the two sorted entry lists the old collect/generate
// produced, from the tagged entities. Callers must call _collect_data /
// _free_data around it.
_ComponentData :: struct {
	entries:          [dynamic]ComponentEntry,
	poolable_entries: [dynamic]PoolableEntry,
}

_collect_data :: proc(w: ^db.World) -> _ComponentData {
	data: _ComponentData

	decls := db.get_comps_DeclInfo()
	_components := db.get_comps(w, Component_GenComp)
	m := db.all_of(db.r(decls), db.r(_components)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		decl := db.get(decls, entity)
		component := db.get(_components, entity)
		switch component.kind {
		case .Component:
			append(&data.entries, ComponentEntry{
				type_name       = decl.name,
				snake_name      = component.snake_name,
				plural          = component.plural,
				menu_path       = component.menu_path,
				pkg             = component.pkg,
				pkg_path        = component.pkg_path,
				max             = component.max,
				has_on_validate = component.has_on_validate,
				has_on_destroy  = component.has_on_destroy,
				has_reset       = component.has_reset,
				has_cleanup     = component.has_cleanup,
			})
		case .Poolable:
			append(&data.poolable_entries, PoolableEntry{
				type_name  = decl.name,
				snake_name = component.snake_name,
				plural     = component.plural,
				max        = component.max,
			})
		}
	}

	// Preserve previous collect_finalize ordering.
	slice.sort_by(data.entries[:], proc(a, b: ComponentEntry) -> bool {
		return a.type_name < b.type_name
	})
	slice.sort_by(data.poolable_entries[:], proc(a, b: PoolableEntry) -> bool {
		return a.type_name < b.type_name
	})
	return data
}

_free_data :: proc(data: ^_ComponentData) {
	delete(data.entries)
	delete(data.poolable_entries)
}

generate_component_menus :: proc(w: ^db.World) -> bool {
	data := _collect_data(w)
	defer _free_data(&data)

	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	strings.write_string(&b, "package editor\n\n")
	strings.write_string(&b, "import engine \"../engine\"\n")
	strings.write_string(&b, "import \"menu\"\n")
	strings.write_string(&b, "import \"undo\"\n\n")

	// Sorted by menu path (not type name) so the emitted registration mirrors
	// the menu. Slashes in @(component={menu="Sub/Name"}) nest submenus like
	// any other menu path; items use the DEFAULT order, so the menu sorter's
	// name tiebreak yields an alphabetical Component menu with submenus
	// interleaved by name.
	menu_entries := make([]ComponentEntry, len(data.entries))
	defer delete(menu_entries)
	copy(menu_entries, data.entries[:])
	slice.sort_by(menu_entries, proc(a, b: ComponentEntry) -> bool {
		return a.menu_path < b.menu_path
	})

	strings.write_string(&b, "register_component_menus :: proc() {\n")
	for e in menu_entries {
		menu_full := strings.concatenate({"Component/", e.menu_path})
		defer delete(menu_full)
		fmt.sbprintf(&b, "\tmenu.add_menu_item(%q, \"\", proc() {{ _component_menu_add(.%s) }})\n", menu_full, e.type_name)
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
	strings.write_string(&b, "\towned, _ := engine.transform_add_comp(tH, key)\n")
	strings.write_string(&b, "\tundo.record_add_component(tH, owned.handle, len(t.components) - 1)\n")
	strings.write_string(&b, "}\n")

	db.emit(w, "moonhug/editor/menu_component_generated.odin", strings.to_string(b))
	return true
}

_pool_type :: proc(b: ^strings.Builder, type_name: string, max: int) {
	if max > 0 {
		fmt.sbprintf(b, "Pool(%s, %d)", type_name, max)
	} else {
		fmt.sbprintf(b, "Pool(%s)", type_name)
	}
}

generate :: proc(w: ^db.World) -> bool {
	data := _collect_data(w)
	defer _free_data(&data)

	// Engine components get typed World/SceneFile storage; external ones are
	// runtime-registered (see generate_ext_components) and live in ext_pools.
	eng: [dynamic]ComponentEntry
	defer delete(eng)
	for e in data.entries do if _is_engine(e) do append(&eng, e)

	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	strings.write_string(&b, "package engine\n\n")

	strings.write_string(&b, "World :: struct {\n")
	for e in eng {
		fmt.sbprintf(&b, "\t%s: ", e.plural)
		_pool_type(&b, e.type_name, e.max)
		strings.write_string(&b, ",\n")
	}
	for e in data.poolable_entries {
		fmt.sbprintf(&b, "\t%s: ", e.plural)
		_pool_type(&b, e.type_name, e.max)
		strings.write_string(&b, ",\n")
	}
	strings.write_string(&b, "\text_pools: [TypeKey]rawptr,\n")
	strings.write_string(&b, "\tpool_table: [TypeKey]Pool_Entry,\n")
	strings.write_string(&b, "}\n\n")

	strings.write_string(&b, "w_init :: proc(w:^World)\n")
	strings.write_string(&b, "{\n")
	for e in eng {
		fmt.sbprintf(&b, "\tpool_init(&w.%s)\n", e.plural)
	}
	for e in data.poolable_entries {
		fmt.sbprintf(&b, "\tpool_init(&w.%s)\n", e.plural)
	}
	strings.write_string(&b, "\t__type_resets_init()\n")
	strings.write_string(&b, "\t__type_cleanups_init()\n")
	strings.write_string(&b, "\t__component_on_validates_init()\n")
	strings.write_string(&b, "\t__component_on_destroys_init()\n")
	for e in eng {
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
	strings.write_string(&b, "\t_w_init_ext_pools(w)\n")
	strings.write_string(&b, "}\n\n")

	strings.write_string(&b, "__component_on_validates_init :: proc() {\n")
	for e in eng {
		if e.has_on_validate {
			fmt.sbprintf(&b, "\tcomponent_on_validate_procs[.%s] = proc(ptr: rawptr) {{ on_validate_%s(cast(^%s)ptr) }}\n", e.type_name, e.type_name, e.type_name)
		}
	}
	strings.write_string(&b, "}\n\n")

	strings.write_string(&b, "__component_on_destroys_init :: proc() {\n")
	for e in eng {
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
	for e, i in eng {
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
	for e, i in eng {
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
	strings.write_string(&b, "\t_world_destroy_ext(w)\n")
	for e in eng {
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

	db.emit(w, "moonhug/engine/components_generated.odin", strings.to_string(b))
	return true
}

generate_scene_file :: proc(w: ^db.World) -> bool {
	data := _collect_data(w)
	defer _free_data(&data)

	eng: [dynamic]ComponentEntry
	defer delete(eng)
	for e in data.entries do if _is_engine(e) do append(&eng, e)

	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	strings.write_string(&b, "package engine\n\n")
	strings.write_string(&b, "import \"core:encoding/json\"\n")
	strings.write_string(&b, "import \"core:strings\"\n\n")

	strings.write_string(&b, "@(typ_guid={guid = \"0d489fce-9c04-4e4d-be12-f3f590d60cea\"})\n")
	strings.write_string(&b, "SceneFile :: struct {\n")
	strings.write_string(&b, "\troot:          Local_ID,\n")
	strings.write_string(&b, "\tnext_local_id: Local_ID,\n")
	strings.write_string(&b, "\ttransforms:    [dynamic]Transform,\n")
	strings.write_string(&b, "\tnested_scenes: [dynamic]NestedScene,\n")
	strings.write_string(&b, "\tbreadcrumbs:   [dynamic]Breadcrumb,\n")
	for e in eng {
		fmt.sbprintf(&b, "\t%s: [dynamic]%s,\n", e.plural, e.type_name)
	}
	strings.write_string(&b, "\text_components: [dynamic]json.Value,\n")
	strings.write_string(&b, "}\n\n")

	strings.write_string(&b, "_scene_load_as_child :: proc(sf: ^SceneFile, parent: Transform_Handle = {}, s: ^Scene = nil, transform_scope_guid: Asset_GUID = {}, skip_scene_local_id_registration := false) -> Transform_Handle {\n")
	strings.write_string(&b, "\tw := ctx_world()\n\n")
	strings.write_string(&b, "\tid_to_transform_handle := make(map[Local_ID]Handle, context.temp_allocator)\n")
	for e in eng {
		fmt.sbprintf(&b, "\tid_to_%s_handle := make(map[Local_ID]Handle, context.temp_allocator)\n", e.snake_name)
	}
	strings.write_string(&b, "\n")
	strings.write_string(&b, "\tif s != nil {\n")
	strings.write_string(&b, "\t\tscene_file_remap_merge_metadata(sf, s)\n")
	strings.write_string(&b, "\t\tfor &ns_data in sf.nested_scenes {\n")
	strings.write_string(&b, "\t\t\tns_copy := ns_data\n")
	strings.write_string(&b, "\t\t\tns_copy.overrides = make([dynamic]Override, len(ns_data.overrides))\n")
	strings.write_string(&b, "\t\t\tfor i in 0..<len(ns_data.overrides) {\n")
	strings.write_string(&b, "\t\t\t\tsrc := &ns_data.overrides[i]\n")
	strings.write_string(&b, "\t\t\t\tns_copy.overrides[i] = Override{\n")
	strings.write_string(&b, "\t\t\t\t\ttarget        = src.target,\n")
	strings.write_string(&b, "\t\t\t\t\tproperty_path = strings.clone(src.property_path),\n")
	strings.write_string(&b, "\t\t\t\t\tvalue         = json.clone_value(src.value),\n")
	strings.write_string(&b, "\t\t\t\t}\n")
	strings.write_string(&b, "\t\t\t}\n")
	strings.write_string(&b, "\t\t\tappend(&s.nested_scenes, ns_copy)\n")
	strings.write_string(&b, "\t\t}\n")
	strings.write_string(&b, "\t}\n\n")
	for e in eng {
		fmt.sbprintf(&b, "\tfor &%s_data in sf.%s {{\n", e.snake_name, e.plural)
		fmt.sbprintf(&b, "\t\thandle, %s := pool_create(&w.%s)\n", e.snake_name, e.plural)
		fmt.sbprintf(&b, "\t\thandle.type_key = .%s\n", e.type_name)
		fmt.sbprintf(&b, "\t\t%s^ = %s_data\n", e.snake_name, e.snake_name)
		fmt.sbprintf(&b, "\t\tid_to_%s_handle[%s_data.local_id] = handle\n", e.snake_name, e.snake_name)
		fmt.sbprintf(&b, "\t\t%s_data = {{}}\n", e.snake_name)
		strings.write_string(&b, "\t}\n\n")
	}
	strings.write_string(&b, "\tid_to_ext_handle := _scene_load_ext_components(sf)\n\n")
	strings.write_string(&b, "\tfor &t_data in sf.transforms {\n")
	strings.write_string(&b, "\t\thandle, t := pool_create(&w.transforms)\n")
	strings.write_string(&b, "\t\thandle.type_key = .Transform\n")
	strings.write_string(&b, "\t\tt^ = t_data\n")
	strings.write_string(&b, "\t\tt.scene = s\n")
	strings.write_string(&b, "\t\tif !asset_guid_is_empty(transform_scope_guid) {\n")
	strings.write_string(&b, "\t\t\tt.scene_asset_guid = transform_scope_guid\n")
	strings.write_string(&b, "\t\t} else if s != nil && !asset_guid_is_empty(s.asset_guid) {\n")
	strings.write_string(&b, "\t\t\tt.scene_asset_guid = s.asset_guid\n")
	strings.write_string(&b, "\t\t} else {\n")
	strings.write_string(&b, "\t\t\tt.scene_asset_guid = {}\n")
	strings.write_string(&b, "\t\t}\n")
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
	for e, i in eng {
		if i == 0 {
			fmt.sbprintf(&b, "\t\t\tif h, ok := resolve_handle(c.local_id, id_to_%s_handle); ok {{\n", e.snake_name)
		} else {
			fmt.sbprintf(&b, "\t\t\t} else if h, ok := resolve_handle(c.local_id, id_to_%s_handle); ok {{\n", e.snake_name)
		}
		strings.write_string(&b, "\t\t\t\tc.handle = h\n")
		fmt.sbprintf(&b, "\t\t\t\t%s := pool_get(&w.%s, h)\n", e.snake_name, e.plural)
		fmt.sbprintf(&b, "\t\t\t\tif %s != nil do %s.owner = Transform_Handle(handle)\n", e.snake_name, e.snake_name)
	}
	if len(eng) > 0 {
		strings.write_string(&b, "\t\t\t} else if h, ok := resolve_handle(c.local_id, id_to_ext_handle); ok {\n")
	} else {
		strings.write_string(&b, "\t\t\tif h, ok := resolve_handle(c.local_id, id_to_ext_handle); ok {\n")
	}
	strings.write_string(&b, "\t\t\t\tc.handle = h\n")
	strings.write_string(&b, "\t\t\t\t_ext_set_owner(w, h, Transform_Handle(handle))\n")
	strings.write_string(&b, "\t\t\t}\n")
	strings.write_string(&b, "\t\t}\n")
	strings.write_string(&b, "\t}\n\n")
	strings.write_string(&b, "\tif s != nil {\n")
	strings.write_string(&b, "\t\tif !skip_scene_local_id_registration {\n")
	strings.write_string(&b, "\t\t\tfor lid, h in id_to_transform_handle {\n")
	strings.write_string(&b, "\t\t\t\tif _, exists := bimap_get(&s.local_ids, lid); !exists {\n")
	strings.write_string(&b, "\t\t\t\t\tbimap_insert(&s.local_ids, lid, h)\n")
	strings.write_string(&b, "\t\t\t\t}\n")
	strings.write_string(&b, "\t\t\t}\n")
	for e in eng {
		fmt.sbprintf(&b, "\t\t\tfor lid, h in id_to_%s_handle {{\n", e.snake_name)
		strings.write_string(&b, "\t\t\t\tbimap_insert(&s.local_ids, lid, h)\n")
		strings.write_string(&b, "\t\t\t}\n")
	}
	strings.write_string(&b, "\t\t\tfor lid, h in id_to_ext_handle {\n")
	strings.write_string(&b, "\t\t\t\tbimap_insert(&s.local_ids, lid, h)\n")
	strings.write_string(&b, "\t\t\t}\n")
	strings.write_string(&b, "\t\t}\n")
	strings.write_string(&b, "\t\tfor bc in sf.breadcrumbs {\n")
	strings.write_string(&b, "\t\t\tscene_breadcrumb_put(s, bc)\n")
	strings.write_string(&b, "\t\t}\n")
	// Resolve PPtr/Ref/Ref_Local handles for each live pooled object. Intra-file
	// references resolve against THIS file's id->handle table (a nested prefab
	// keeps its own local_id namespace — its ids never enter the host bimap);
	// the scene bimap is the fallback for ids outside the file.
	strings.write_string(&b, "\t\t_file_lookup := make(map[Local_ID]Handle, context.temp_allocator)\n")
	strings.write_string(&b, "\t\tfor lid, h in id_to_transform_handle do _file_lookup[lid] = h\n")
	for e in eng {
		fmt.sbprintf(&b, "\t\tfor lid, h in id_to_%s_handle do _file_lookup[lid] = h\n", e.snake_name)
	}
	strings.write_string(&b, "\t\tfor lid, h in id_to_ext_handle do _file_lookup[lid] = h\n")
	for e in eng {
		fmt.sbprintf(&b, "\t\tfor _, h in id_to_%s_handle {{\n", e.snake_name)
		fmt.sbprintf(&b, "\t\t\tp := pool_get(&w.%s, h)\n", e.plural)
		fmt.sbprintf(&b, "\t\t\tif p != nil do _resolve_refs_in_value(p, type_info_of(%s), s, &_file_lookup)\n", e.type_name)
		strings.write_string(&b, "\t\t}\n")
	}
	strings.write_string(&b, "\t\tfor _, h in id_to_ext_handle {\n")
	strings.write_string(&b, "\t\t\t_ext_resolve_refs(w, h, s, &_file_lookup)\n")
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
	strings.write_string(&b, "\tif s != nil {\n")
	strings.write_string(&b, "\t\tnested_scene_ensure_host_pegs(s)\n")
	strings.write_string(&b, "\t}\n\n")
	strings.write_string(&b, "\treturn Transform_Handle(root_handle)\n")
	strings.write_string(&b, "}\n\n")

	// `mapper` decides each record's new lid (nil = mint from the scene counter,
	// the paste/duplicate behavior). nested_scene_resolve passes a composing
	// mapper that projects a prefab instance into the host namespace; override
	// capture passes an un-projecting one. One walk, three uses.
	strings.write_string(&b, "_scene_file_remap_local_ids :: proc(sf: ^SceneFile, s: ^Scene, mapper: proc(user: rawptr, old: Local_ID) -> Local_ID = nil, user: rawptr = nil) {\n")
	strings.write_string(&b, "\tif s == nil do return\n")
	strings.write_string(&b, "\tremap := make(map[Local_ID]Local_ID)\n")
	strings.write_string(&b, "\tdefer delete(remap)\n\n")
	strings.write_string(&b, "\tfor &t in sf.transforms {\n")
	strings.write_string(&b, "\t\tnew_id := _remap_new_id(s, mapper, user, t.local_id)\n")
	strings.write_string(&b, "\t\tremap[t.local_id] = new_id\n")
	strings.write_string(&b, "\t\tt.local_id = new_id\n")
	strings.write_string(&b, "\t}\n\n")
	for e in eng {
		fmt.sbprintf(&b, "\tfor &c in sf.%s {{ new_id := _remap_new_id(s, mapper, user, c.local_id); remap[c.local_id] = new_id; c.local_id = new_id }}\n", e.plural)
	}
	strings.write_string(&b, "\text_temps := _scene_file_remap_ext_begin(sf, s, &remap, mapper, user)\n")
	strings.write_string(&b, "\tfor &ns in sf.nested_scenes { new_id := _remap_new_id(s, mapper, user, ns.local_id); remap[ns.local_id] = new_id; ns.local_id = new_id }\n")
	strings.write_string(&b, "\tfor &bc in sf.breadcrumbs {\n")
	strings.write_string(&b, "\t\told := bc.local_id\n")
	strings.write_string(&b, "\t\tnew_id := _remap_new_id(s, mapper, user, old)\n")
	strings.write_string(&b, "\t\tremap[old] = new_id\n")
	strings.write_string(&b, "\t\tbc.local_id = new_id\n")
	strings.write_string(&b, "\t}\n\n")
	strings.write_string(&b, "\tfor &t in sf.transforms {\n")
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
	strings.write_string(&b, "\tfor &ns in sf.nested_scenes {\n")
	strings.write_string(&b, "\t\tif new_id, ok := remap[ns.transform_parent]; ok {\n")
	strings.write_string(&b, "\t\t\tns.transform_parent = new_id\n")
	strings.write_string(&b, "\t\t}\n")
	strings.write_string(&b, "\t}\n\n")
	strings.write_string(&b, "\tfor &bc in sf.breadcrumbs {\n")
	strings.write_string(&b, "\t\tif new_id, ok := remap[bc.scene_instance]; ok {\n")
	strings.write_string(&b, "\t\t\tbc.scene_instance = new_id\n")
	strings.write_string(&b, "\t\t}\n")
	strings.write_string(&b, "\t}\n\n")
	strings.write_string(&b, "\tfor &ns in sf.nested_scenes {\n")
	strings.write_string(&b, "\t\tif ns.host_breadcrumb_id != 0 {\n")
	strings.write_string(&b, "\t\t\tif nid, ok := remap[ns.host_breadcrumb_id]; ok {\n")
	strings.write_string(&b, "\t\t\t\tns.host_breadcrumb_id = nid\n")
	strings.write_string(&b, "\t\t\t}\n")
	strings.write_string(&b, "\t\t}\n")
	strings.write_string(&b, "\t}\n")
	strings.write_string(&b, "\tfor &bc in sf.breadcrumbs {\n")
	strings.write_string(&b, "\t\tif pptr_guid_is_empty(bc.scene_source.guid) {\n")
	strings.write_string(&b, "\t\t\tif nid, ok := remap[bc.scene_source.local_id]; ok {\n")
	strings.write_string(&b, "\t\t\t\tbc.scene_source.local_id = nid\n")
	strings.write_string(&b, "\t\t\t}\n")
	strings.write_string(&b, "\t\t}\n")
	strings.write_string(&b, "\t}\n\n")
	// Override.target is a PPtr in a foreign-prefab namespace (target.guid
	// names the prefab), so it intentionally does NOT get remapped through
	// this host scene's local_id remap.

	strings.write_string(&b, "\tif new_root, ok := remap[sf.root]; ok {\n")
	strings.write_string(&b, "\t\tsf.root = new_root\n")
	strings.write_string(&b, "\t}\n\n")
	for e in eng {
		fmt.sbprintf(&b, "\tfor &c in sf.%s {{ _remap_refs_in_value(&c, type_info_of(%s), &remap) }}\n", e.plural, e.type_name)
	}
	strings.write_string(&b, "\t_scene_file_remap_ext_finish(ext_temps, &remap)\n")
	strings.write_string(&b, "}\n\n")

	strings.write_string(&b, "scene_file_destroy :: proc(sf: ^SceneFile) {\n")
	strings.write_string(&b, "\tfor &t in sf.transforms {\n")
	strings.write_string(&b, "\t\tdelete(t.name)\n")
	strings.write_string(&b, "\t\tdelete(t.children)\n")
	strings.write_string(&b, "\t\tdelete(t.components)\n")
	strings.write_string(&b, "\t}\n")
	strings.write_string(&b, "\tdelete(sf.transforms)\n")
	strings.write_string(&b, "\tfor &ns in sf.nested_scenes {\n")
	strings.write_string(&b, "\t\tfor &ov in ns.overrides {\n")
	strings.write_string(&b, "\t\t\tdelete(ov.property_path)\n")
	strings.write_string(&b, "\t\t\tjson.destroy_value(ov.value)\n")
	strings.write_string(&b, "\t\t}\n")
	strings.write_string(&b, "\t\tdelete(ns.overrides)\n")
	strings.write_string(&b, "\t}\n")
	strings.write_string(&b, "\tdelete(sf.nested_scenes)\n")
	strings.write_string(&b, "\tdelete(sf.breadcrumbs)\n")
	for e in eng {
		fmt.sbprintf(&b, "\tfor &c in sf.%s {{ type_cleanup(.%s, &c) }}\n", e.plural, e.type_name)
		fmt.sbprintf(&b, "\tdelete(sf.%s)\n", e.plural)
	}
	strings.write_string(&b, "\t_scene_file_destroy_ext(sf)\n")
	strings.write_string(&b, "}\n")

	strings.write_string(&b, "\n")
	strings.write_string(&b, "scene_file_destroy_shallow :: proc(sf: ^SceneFile) {\n")
	strings.write_string(&b, "\tfor &t in sf.transforms {\n")
	strings.write_string(&b, "\t\tdelete(t.name)\n")
	strings.write_string(&b, "\t\tdelete(t.children)\n")
	strings.write_string(&b, "\t\tdelete(t.components)\n")
	strings.write_string(&b, "\t}\n")
	strings.write_string(&b, "\tdelete(sf.transforms)\n")
	strings.write_string(&b, "\tdelete(sf.nested_scenes)\n")
	strings.write_string(&b, "\tdelete(sf.breadcrumbs)\n")
	for e in eng {
		fmt.sbprintf(&b, "\tdelete(sf.%s)\n", e.plural)
	}
	// Ext values are parsed/created fresh and always owned by the SceneFile
	// (never shared with live world memory), so even the shallow destroy
	// releases them fully.
	strings.write_string(&b, "\t_scene_file_destroy_ext(sf)\n")
	strings.write_string(&b, "}\n")

	db.emit(w, "moonhug/engine/scene_generated.odin", strings.to_string(b))
	return true
}

// generate_ext_components: for every NON-engine package that declares
// @(component) structs, emit a <pkg>/components_ext_generated.odin with
// runtime Component_Desc registrations (pool/lifecycle thunks need the
// concrete type, so they must be compiled in the component's own package)
// plus typed pool accessors and a typed get_comp that falls back to engine's.
// "moonhug/app" -> "../engine"; "moonhug/packages/x" -> "../../engine".
_engine_import_path :: proc(pkg_path: string) -> string {
	depth := strings.count(pkg_path, "/") // segments below the repo prefix
	b := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< depth {
		strings.write_string(&b, "../")
	}
	strings.write_string(&b, "engine")
	return strings.to_string(b)
}

generate_ext_components :: proc(w: ^db.World) -> bool {
	data := _collect_data(w)
	defer _free_data(&data)

	// Collect distinct non-engine packages, keeping entry order. Keyed by
	// pkg_path: the generated file lands INSIDE the owning package (thunks
	// need the concrete type), wherever that package lives.
	pkgs: [dynamic]string
	defer delete(pkgs)
	for e in data.entries {
		if _is_engine(e) do continue
		found := false
		for p in pkgs do if p == e.pkg_path { found = true; break }
		if !found do append(&pkgs, e.pkg_path)
	}

	for pkg_path in pkgs {
		pkg := _pkg_name(pkg_path)
		b := strings.builder_make()
		defer strings.builder_destroy(&b)

		fmt.sbprintf(&b, "package %s\n\n", pkg)
		strings.write_string(&b, "import \"core:sync\"\n")
		fmt.sbprintf(&b, "import \"%s\"\n\n", _engine_import_path(pkg_path))
		strings.write_string(&b, "// Code generated by components_gen. Do not edit.\n\n")

		fmt.sbprintf(&b, "@(private)\n_register_%s_components_once: sync.Once\n\n", pkg)
		fmt.sbprintf(&b, "register_%s_components :: proc() {{\n", pkg)
		fmt.sbprintf(&b, "\tsync.once_do(&_register_%s_components_once, proc() {{\n", pkg)
		for e in data.entries {
			if _is_engine(e) || e.pkg_path != pkg_path do continue
			pool_t := fmt.tprintf("engine.Pool(%s, %d)", e.type_name, e.max) if e.max > 0 else fmt.tprintf("engine.Pool(%s)", e.type_name)
			strings.write_string(&b, "\t\tengine.component_register(engine.Component_Desc{\n")
			fmt.sbprintf(&b, "\t\t\ttype_key  = .%s,\n", e.type_name)
			fmt.sbprintf(&b, "\t\t\ttype_guid = engine.%s__Guid,\n", e.type_name)
			fmt.sbprintf(&b, "\t\t\ttid       = typeid_of(%s),\n", e.type_name)
			fmt.sbprintf(&b, "\t\t\tptr_tid   = typeid_of(^%s),\n", e.type_name)
			fmt.sbprintf(&b, "\t\t\tpool_create = proc() -> rawptr {{ p := new(%s); engine.pool_init(p); return p }},\n", pool_t)
			fmt.sbprintf(&b, "\t\t\tpool_destroy = proc(pool: rawptr) {{ free(cast(^%s)pool) }},\n", pool_t)
			fmt.sbprintf(&b, "\t\t\tmake_entry = proc(pool: rawptr) -> engine.Pool_Entry {{ return engine.pool_make_entry(cast(^%s)pool) }},\n", pool_t)
			fmt.sbprintf(&b, "\t\t\teach_alive = proc(pool: rawptr, fn: proc(comp: rawptr)) {{\n\t\t\t\tp := cast(^%s)pool\n\t\t\t\tfor i in 0..<len(p.slots) {{\n\t\t\t\t\tif p.slots[i].alive do fn(&p.slots[i].data)\n\t\t\t\t}}\n\t\t\t}},\n", pool_t)
			if e.has_reset {
				fmt.sbprintf(&b, "\t\t\treset = proc(ptr: rawptr) {{ reset_%s(cast(^%s)ptr) }},\n", e.type_name, e.type_name)
			}
			if e.has_cleanup {
				fmt.sbprintf(&b, "\t\t\tcleanup = proc(ptr: rawptr) {{ cleanup_%s(cast(^%s)ptr) }},\n", e.type_name, e.type_name)
			}
			if e.has_on_validate {
				fmt.sbprintf(&b, "\t\t\ton_validate = proc(ptr: rawptr) {{ on_validate_%s(cast(^%s)ptr) }},\n", e.type_name, e.type_name)
			}
			if e.has_on_destroy {
				fmt.sbprintf(&b, "\t\t\ton_destroy = proc(ptr: rawptr) {{ on_destroy_%s(cast(^%s)ptr) }},\n", e.type_name, e.type_name)
			}
			strings.write_string(&b, "\t\t})\n")
		}
		strings.write_string(&b, "\t})\n")
		strings.write_string(&b, "}\n\n")

		// Typed pool accessors: same names game code used against World fields.
		for e in data.entries {
			if _is_engine(e) || e.pkg_path != pkg_path do continue
			pool_t := fmt.tprintf("engine.Pool(%s, %d)", e.type_name, e.max) if e.max > 0 else fmt.tprintf("engine.Pool(%s)", e.type_name)
			fmt.sbprintf(&b, "%s :: proc(w: ^engine.World) -> ^%s {{\n", e.plural, pool_t)
			fmt.sbprintf(&b, "\treturn cast(^%s) w.ext_pools[engine.TypeKey.%s]\n", pool_t, e.type_name)
			strings.write_string(&b, "}\n\n")
		}

		// Typed get_comp over this package's components, engine fallback.
		strings.write_string(&b, "get_comp :: proc(tH: engine.Transform_Handle, $T: typeid) -> (engine.Owned, ^T) {\n")
		first := true
		for e in data.entries {
			if _is_engine(e) || e.pkg_path != pkg_path do continue
			kw := "when" if first else "else when"
			fmt.sbprintf(&b, "\t%s T == %s {{\n", kw, e.type_name)
			strings.write_string(&b, "\t\tw := engine.ctx_world()\n")
			strings.write_string(&b, "\t\tt := engine.pool_get(&w.transforms, engine.Handle(tH))\n")
			strings.write_string(&b, "\t\tif t == nil do return {}, nil\n")
			fmt.sbprintf(&b, "\t\towned, _ := engine.transform_find_comp(t, .%s)\n", e.type_name)
			strings.write_string(&b, "\t\tif owned.handle.type_key == engine.INVALID_TYPE_KEY do return owned, nil\n")
			fmt.sbprintf(&b, "\t\tpool := %s(w)\n", e.plural)
			strings.write_string(&b, "\t\tif pool == nil do return owned, nil\n")
			strings.write_string(&b, "\t\treturn owned, engine.pool_get(pool, owned.handle)\n")
			strings.write_string(&b, "\t}\n")
			first = false
		}
		strings.write_string(&b, "\telse {\n")
		strings.write_string(&b, "\t\treturn engine.transform_get_comp(tH, T)\n")
		strings.write_string(&b, "\t}\n")
		strings.write_string(&b, "}\n")

		path := fmt.tprintf("%s/components_ext_generated.odin", pkg_path)
		db.emit(w, path, strings.to_string(b))
	}
	return true
}
