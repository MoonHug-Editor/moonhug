package view_chrome_gen

// view_chrome_gen: ECS prebuild module for view_chrome_generated.odin.
//
//   provide  - recognise @(view_toolbar={view=..., order=N}) on a proc, and
//              @(view_menu={view=..., label=..., order=N}) on a proc (action)
//              or a bool variable (toggle).
//   generate - sort, dedupe, emit registrations into editor/view_chrome.odin.
//
// ONE attribute per surface, and what it is attached to says the rest: a proc
// is an action, a bool variable is a toggle. Same rule menu_item uses, so
// there is one convention to learn rather than two.

import "core:fmt"
import "core:strings"
import "core:slice"
import db "../gen_db"
import "../gen_facts"

_PKG_NAME :: "editor"

Chrome_Kind :: enum { Toolbar, Action, Toggle }

ChromeEntry :: struct {
	kind:        Chrome_Kind,
	view:        string,
	label:       string,
	name:        string,
	order:       int,
	enabled:     string, // predicate proc name in the source package
	checked:     string, // tick predicate, actions only
	source_pkg:  string,
	source_path: string,
}

Chrome_GenComp :: struct {
	entries: [dynamic]ChromeEntry,
}

@(init)
_register :: proc "contextless" () {
	db.provider("view_chrome/provide", provide)
	db.generator("view_chrome/generate", generate)
}

provide :: proc(w: ^db.World) -> bool {
	_chrome := db.get_or_create_comps(w, Chrome_GenComp)
	decls := db.get_comps_DeclInfo()
	procs := db.get_comps(w, gen_facts.Proc_GenComp)
	attrs := db.get_comps(w, gen_facts.Attrs_GenComp)

	m := db.all_of(db.r(decls), db.r(attrs)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		decl := db.get(decls, entity)
		if decl.name == "" do continue
		is_proc := db.has(procs, entity)
		attr_set := db.get(attrs, entity)

		entries: [dynamic]ChromeEntry
		for args in attr_set.attrs {
			view := args.fields["view"]
			if view == "" do continue
			order := gen_facts.attr_int(args, "order")

			switch args.key {
			case "view_toolbar":
				// A widget draws itself, so only a proc can be one.
				if !is_proc do continue
				append(&entries, ChromeEntry{
					kind = .Toolbar, view = view, name = decl.name, order = order,
					source_pkg = decl.pkg.name, source_path = decl.pkg_path,
				})
			case "view_menu":
				label := args.fields["label"]
				if label == "" do continue
				append(&entries, ChromeEntry{
					kind = is_proc ? .Action : .Toggle,
					view = view, label = label, name = decl.name, order = order,
					enabled = args.fields["enabled"], checked = args.fields["checked"],
					source_pkg = decl.pkg.name, source_path = decl.pkg_path,
				})
			}
		}

		if len(entries) > 0 {
			db.set(_chrome, entity, Chrome_GenComp{entries = entries})
		} else {
			delete(entries)
		}
	}
	return true
}

_qualified_name :: proc(pkg_name: string, e: ChromeEntry) -> string {
	if e.source_pkg != "" && e.source_pkg != pkg_name {
		return fmt.tprintf("%s.%s", e.source_pkg, e.name)
	}
	return e.name
}

_qualified_ident :: proc(pkg_name, source_pkg, ident: string) -> string {
	if source_pkg != "" && source_pkg != pkg_name {
		return fmt.tprintf("%s.%s", source_pkg, ident)
	}
	return ident
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

	entries: [dynamic]ChromeEntry
	defer delete(entries)

	decls := db.get_comps_DeclInfo()
	_chrome := db.get_comps(w, Chrome_GenComp)
	m := db.all_of(db.r(decls), db.r(_chrome)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		tb := db.get(_chrome, entity)
		for entry in tb.entries do append(&entries, entry)
	}

	// (view, kind, order, label, name): stable regardless of which package
	// registered first, which is what keeps a generated file from churning.
	slice.sort_by(entries[:], proc(a, b: ChromeEntry) -> bool {
		if a.view != b.view do return a.view < b.view
		if a.kind != b.kind do return a.kind < b.kind
		if a.order != b.order do return a.order < b.order
		if a.label != b.label do return a.label < b.label
		return a.name < b.name
	})

	i := 0
	for j in 0 ..< len(entries) {
		if j > 0 && entries[j] == entries[j - 1] do continue
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
	for pkg in packages_used do append(&import_pkgs, pkg)
	slice.sort(import_pkgs[:])

	strings.write_string(&b, "package ")
	strings.write_string(&b, _PKG_NAME)
	strings.write_string(&b, "\n\n")
	for pkg in import_pkgs {
		fmt.sbprintf(&b, "import %s \"%s\"\n", pkg, packages_used[pkg])
	}
	if len(import_pkgs) > 0 do strings.write_string(&b, "\n")
	strings.write_string(&b, "// Code generated by view_chrome_gen. Do not edit.\n\n")
	strings.write_string(&b, "_register_view_chrome :: proc() {\n")
	for e in entries {
		qualified := _qualified_name(_PKG_NAME, e)
		switch e.kind {
		case .Toolbar:
			fmt.sbprintf(&b, "\tview_toolbar_add_item(\"%s\", %s, %d)\n", e.view, qualified, e.order)
		case .Toggle:
			fmt.sbprintf(&b, "\tview_menu_add_toggle(\"%s\", \"%s\", &%s, %d", e.view, e.label, qualified, e.order)
			if e.enabled != "" {
				fmt.sbprintf(&b, ", %s", _qualified_ident(_PKG_NAME, e.source_pkg, e.enabled))
			}
			strings.write_string(&b, ")\n")
		case .Action:
			fmt.sbprintf(&b, "\tview_menu_add_action(\"%s\", \"%s\", %s, %d", e.view, e.label, qualified, e.order)
			if e.enabled != "" || e.checked != "" {
				enabled := e.enabled != "" ? _qualified_ident(_PKG_NAME, e.source_pkg, e.enabled) : "nil"
				fmt.sbprintf(&b, ", %s", enabled)
			}
			if e.checked != "" {
				fmt.sbprintf(&b, ", %s", _qualified_ident(_PKG_NAME, e.source_pkg, e.checked))
			}
			strings.write_string(&b, ")\n")
		}
	}
	strings.write_string(&b, "}\n")

	db.emit(w, "moonhug/editor/view_chrome_generated.odin", strings.to_string(b))
	return true
}
