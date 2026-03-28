package menu_gen

import "core:fmt"
import "core:odin/ast"
import "core:strings"
import "core:slice"
import "../gen_core"

MenuEntry :: struct {
	kind:        enum { Item, Toggle, Separator },
	path:        string,
	name:        string,
	shortcut:    string,
	order:       int,
	source_pkg:  string,
	source_path: string,
}

// MenuCollectData holds data gathered from the collect stage. Caller must delete(data.entries).
MenuCollectData :: struct {
	entries:  [dynamic]MenuEntry,
	pkg_name: string,
}

// Extract path, order, shortcut from a compound literal using gen_core.
_extract_menu_item_comp :: proc(comp: ^ast.Comp_Lit) -> (path: string, order: int, shortcut: string) {
	if comp == nil do return "", 0, ""
	if path_ex, ok := gen_core.CompLitGetField(comp, "path"); ok do path = gen_core.ExtractString(path_ex)
	if order_ex, ok := gen_core.CompLitGetField(comp, "order"); ok do order = gen_core.ExtractInt(order_ex)
	if shortcut_ex, ok := gen_core.CompLitGetField(comp, "shortcut"); ok do shortcut = gen_core.ExtractString(shortcut_ex)
	return
}

_parent_path :: proc(path: string) -> string {
	if i := strings.last_index(path, "/"); i >= 0 {
		return path[:i]
	}
	return ""
}

// Sort key: same parent menu, then by order, then Separator before Item/Toggle so separator appears after same-order items above it
_sort_key_order :: proc(e: MenuEntry) -> (parent: string, order: int, kind_rank: int) {
	parent = _parent_path(e.path)
	if parent == "" && e.path != "" do parent = e.path
	order = e.order
	kind_rank = 0
	if e.kind == .Separator do kind_rank = 1
	return
}

// Collect appends menu attribute data from one parsed package. Caller must call collect_finalize before generate and delete(data.entries).
collect :: proc(pkg: ^ast.Package, pkg_path: string, data: ^MenuCollectData) -> bool {
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

			if is_proc {
				for attr in v_decl.attributes {
					path, shortcut, separator_path: string
					menu_order: int = 0
					separator_order: int = 0

					if val, found := gen_core.AttrFindFieldValue(attr, "menu_item"); found {
						if comp, comp_ok := val.derived.(^ast.Comp_Lit); comp_ok {
							path, menu_order, shortcut = _extract_menu_item_comp(comp)
						}
					}
					if val, found := gen_core.AttrFindFieldValue(attr, "menu_separator"); found {
						if comp, comp_ok := val.derived.(^ast.Comp_Lit); comp_ok {
							separator_path, separator_order, _ = _extract_menu_item_comp(comp)
						}
					}

					if path != "" && separator_path == "" {
						append(&data.entries, MenuEntry{.Item, path, ident_name, shortcut, menu_order, pkg.name, pkg_path})
					} else if separator_path != "" {
						append(&data.entries, MenuEntry{.Separator, separator_path, "", "", separator_order, "", ""})
					}
				}
			} else {
				for attr in v_decl.attributes {
					if val, found := gen_core.AttrFindFieldValue(attr, "menu_toggle"); found {
						if comp, comp_ok := val.derived.(^ast.Comp_Lit); comp_ok {
							path, menu_order, _ := _extract_menu_item_comp(comp)
							if path != "" {
								append(&data.entries, MenuEntry{.Toggle, path, ident_name, "", menu_order, pkg.name, pkg_path})
							}
						}
					}
				}
			}
		}
	}

	return true
}

// Collect_finalize sorts collected entries. Call once after all collect calls before generate.
collect_finalize :: proc(data: ^MenuCollectData) {
	slice.sort_by(data.entries[:], proc(a, b: MenuEntry) -> bool {
		pa, oa, ka := _sort_key_order(a)
		pb, ob, kb := _sort_key_order(b)
		if pa != pb do return pa < pb
		if oa != ob do return oa < ob
		return ka < kb
	})

	i := 0
	for j in 0 ..< len(data.entries) {
		if j > 0 && data.entries[j].path == data.entries[j - 1].path && data.entries[j].name == data.entries[j - 1].name && data.entries[j].kind != .Separator {
			continue
		}
		data.entries[i] = data.entries[j]
		i += 1
	}
	resize(&data.entries, i)
}

_qualified_name :: proc(data: ^MenuCollectData, e: MenuEntry) -> string {
	if e.source_pkg != "" && e.source_pkg != data.pkg_name {
		return fmt.tprintf("%s.%s", e.source_pkg, e.name)
	}
	return e.name
}

_relative_import_path :: proc(out_dir: string, source_path: string) -> string {
	out_dir_slash := strings.concatenate({out_dir, "/"})
	if strings.has_prefix(source_path, out_dir_slash) {
		return source_path[len(out_dir_slash):]
	}
	out_parts := strings.split(out_dir, "/")
	src_parts := strings.split(source_path, "/")
	common := 0
	for common < len(out_parts) && common < len(src_parts) && out_parts[common] == src_parts[common] {
		common += 1
	}
	ups := len(out_parts) - common
	b := strings.builder_make()
	for _ in 0 ..< ups {
		strings.write_string(&b, "../")
	}
	for i in common ..< len(src_parts) {
		if i > common do strings.write_string(&b, "/")
		strings.write_string(&b, src_parts[i])
	}
	return strings.to_string(b)
}

generate :: proc(data: ^MenuCollectData, out_dir: string) -> bool {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	packages_used: map[string]string
	defer delete(packages_used)
	for e in data.entries {
		if e.source_pkg != "" && e.source_pkg != data.pkg_name {
			if e.source_pkg not_in packages_used {
				packages_used[e.source_pkg] = _relative_import_path(out_dir, e.source_path)
			}
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
	for pkg in import_pkgs {
		fmt.sbprintf(&b, "import \"%s\"\n", packages_used[pkg])
	}
	if len(import_pkgs) > 0 do strings.write_string(&b, "\n")
	strings.write_string(&b, "// Code generated by menu_gen. Do not edit.\n\n")
	strings.write_string(&b, "_register_menu_items :: proc() {\n")
	strings.write_string(&b, "\tmenu.init_menu()\n")

	for e in data.entries {
		switch e.kind {
		case .Item:
			strings.write_string(&b, "\tmenu.add_menu_item(\"")
			strings.write_string(&b, e.path)
			strings.write_string(&b, "\", \"")
			strings.write_string(&b, e.shortcut)
			strings.write_string(&b, "\", ")
			strings.write_string(&b, _qualified_name(data, e))
			fmt.sbprintf(&b, ", %d)\n", e.order)
		case .Toggle:
			strings.write_string(&b, "\tmenu.add_menu_toggle(\"")
			strings.write_string(&b, e.path)
			strings.write_string(&b, "\", &")
			strings.write_string(&b, _qualified_name(data, e))
			fmt.sbprintf(&b, ", %d)\n", e.order)
		case .Separator:
			strings.write_string(&b, "\tmenu.add_menu_separator(\"")
			strings.write_string(&b, e.path)
			fmt.sbprintf(&b, "\", %d)\n", e.order)
		}
	}
	strings.write_string(&b, "}\n")

	gen_path := strings.concatenate({out_dir, "/menu_items_generated.odin"})
	return gen_core.WriteGeneratedFile(gen_path, strings.to_string(b))
}

// Cleanup frees collected data. Safe to call multiple times.
cleanup :: proc(data: ^MenuCollectData) {
	delete(data.entries)
}
