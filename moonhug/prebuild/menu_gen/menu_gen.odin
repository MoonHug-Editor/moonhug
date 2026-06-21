package menu_gen

// menu_gen: ECS prebuild module for menu_items_generated.odin.
//
//   provide  - query {DeclInfo}, recognise decls carrying @(menu_item) /
//              @(menu_separator) / @(menu_toggle) attributes, tag each with a
//              Menu_GenComp carrying the per-entry MenuEntry data.
//   generate - query {DeclInfo, Menu_GenComp}, rebuild rows, sort + dedupe, build
//              menu_items_generated.odin, emit it (gen_db writes it).
//
// String-building output is identical to the previous collect/generate version.

import "core:fmt"
import "core:strings"
import "core:slice"
import db "../gen_db"
import "../gen_facts"

// Fixed package name the old prebuild assigned (menu_data.pkg_name = "editor").
_PKG_NAME :: "editor"

MenuEntry :: struct {
	kind:        enum { Item, Toggle, Separator },
	path:        string,
	name:        string,
	shortcut:    string,
	order:       int,
	source_pkg:  string,
	source_path: string,
}

// Menu_GenComp marks a DeclInfo entity as a menu declaration. A single declaration's
// attributes may yield multiple entries, so the tag carries them all.
Menu_GenComp :: struct {
	entries: [dynamic]MenuEntry,
}


@(init)
_register :: proc "contextless" () {
	db.provider("menu/provide", provide)
	db.generator("menu/generate", generate)
}


// Extract path, order, shortcut from a flattened attribute's fields.
_extract_menu_item_comp :: proc(args: gen_facts.Attr_Args) -> (path: string, order: int, shortcut: string) {
	return args.fields["path"], gen_facts.attr_int(args, "order"), args.fields["shortcut"]
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

provide :: proc(w: ^db.World) -> bool {
	_menus := db.get_or_create_comps(w, Menu_GenComp)
	decls  := db.get_comps_DeclInfo()
	procs  := db.get_comps(w, gen_facts.Proc_GenComp)
	attrs  := db.get_comps(w, gen_facts.Attrs_GenComp)

	m := db.all_of(db.r(decls), db.r(attrs)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		decl := db.get(decls, entity)
		ident_name := decl.name
		if ident_name == "" do continue

		is_proc := db.has(procs, entity)
		attr_set := db.get(attrs, entity)

		entries: [dynamic]MenuEntry

		if is_proc {
			// Iterate attributes in source order: a proc may carry several
			// menu_item / menu_separator entries and their order matters.
			for args in attr_set.attrs {
				path, shortcut, separator_path: string
				menu_order: int = 0
				separator_order: int = 0

				if args.key == "menu_item" {
					path, menu_order, shortcut = _extract_menu_item_comp(args)
				}
				if args.key == "menu_separator" {
					separator_path, separator_order, _ = _extract_menu_item_comp(args)
				}

				if path != "" && separator_path == "" {
					append(&entries, MenuEntry{.Item, path, ident_name, shortcut, menu_order, decl.pkg.name, decl.pkg_path})
				} else if separator_path != "" {
					append(&entries, MenuEntry{.Separator, separator_path, "", "", separator_order, "", ""})
				}
			}
		} else {
			for args in attr_set.attrs {
				if args.key == "menu_toggle" {
					path, menu_order, _ := _extract_menu_item_comp(args)
					if path != "" {
						append(&entries, MenuEntry{.Toggle, path, ident_name, "", menu_order, decl.pkg.name, decl.pkg_path})
					}
				}
			}
		}

		if len(entries) > 0 {
			db.set(_menus, entity, Menu_GenComp{entries = entries})
		} else {
			delete(entries)
		}
	}
	return true
}

_qualified_name :: proc(pkg_name: string, e: MenuEntry) -> string {
	if e.source_pkg != "" && e.source_pkg != pkg_name {
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

generate :: proc(w: ^db.World) -> bool {
	out_dir :: "moonhug/editor"

	entries: [dynamic]MenuEntry
	defer delete(entries)

	decls := db.get_comps_DeclInfo()
	_menus := db.get_comps(w, Menu_GenComp)
	m := db.all_of(db.r(decls), db.r(_menus)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		menu := db.get(_menus, entity)
		for entry in menu.entries {
			append(&entries, entry)
		}
	}

	// Preserve previous collect_finalize ordering + dedupe.
	slice.sort_by(entries[:], proc(a, b: MenuEntry) -> bool {
		pa, oa, ka := _sort_key_order(a)
		pb, ob, kb := _sort_key_order(b)
		if pa != pb do return pa < pb
		if oa != ob do return oa < ob
		return ka < kb
	})

	i := 0
	for j in 0 ..< len(entries) {
		if j > 0 && entries[j].path == entries[j - 1].path && entries[j].name == entries[j - 1].name && entries[j].kind != .Separator {
			continue
		}
		entries[i] = entries[j]
		i += 1
	}
	resize(&entries, i)

	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	packages_used: map[string]string
	defer delete(packages_used)
	for e in entries {
		if e.source_pkg != "" && e.source_pkg != _PKG_NAME {
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
	strings.write_string(&b, _PKG_NAME)
	strings.write_string(&b, "\n\n")
	for pkg in import_pkgs {
		fmt.sbprintf(&b, "import \"%s\"\n", packages_used[pkg])
	}
	if len(import_pkgs) > 0 do strings.write_string(&b, "\n")
	strings.write_string(&b, "// Code generated by menu_gen. Do not edit.\n\n")
	strings.write_string(&b, "_register_menu_items :: proc() {\n")
	strings.write_string(&b, "\tmenu.init_menu()\n")

	for e in entries {
		switch e.kind {
		case .Item:
			strings.write_string(&b, "\tmenu.add_menu_item(\"")
			strings.write_string(&b, e.path)
			strings.write_string(&b, "\", \"")
			strings.write_string(&b, e.shortcut)
			strings.write_string(&b, "\", ")
			strings.write_string(&b, _qualified_name(_PKG_NAME, e))
			fmt.sbprintf(&b, ", %d)\n", e.order)
		case .Toggle:
			strings.write_string(&b, "\tmenu.add_menu_toggle(\"")
			strings.write_string(&b, e.path)
			strings.write_string(&b, "\", &")
			strings.write_string(&b, _qualified_name(_PKG_NAME, e))
			fmt.sbprintf(&b, ", %d)\n", e.order)
		case .Separator:
			strings.write_string(&b, "\tmenu.add_menu_separator(\"")
			strings.write_string(&b, e.path)
			fmt.sbprintf(&b, "\", %d)\n", e.order)
		}
	}
	strings.write_string(&b, "}\n")

	db.emit(w, "moonhug/editor/menu_items_generated.odin", strings.to_string(b))
	return true
}
