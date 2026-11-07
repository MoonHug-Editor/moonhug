package keymap_gen

// keymap_gen: declared editor commands and keymaps (docs/core/Keymaps.md).
//
//   @(command={name="Scene/Translate Tool", enabled=scene_can_clear_selection, id="scene.translate"})
//   scene_tool_translate :: proc() { ... }
//
//   @(keymap={name="Scene Flythrough", modal=true})
//   scene_flythrough_keymap :: proc(km: ^keymap.Keymap) { ... }
//
//   generate - moonhug/editor/editor_keymaps_generated.odin:
//              _register_editor_keymaps(), one keymap.command_add call per
//              command, then one keymap.add call per keymap.
//
// `enabled` and `active` name procs in the package of the declaration.
// Optional fields are left out of the call when empty, false or zero.

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:os"
import db "../gen_db"
import "../gen_facts"
import "../menu_gen"

_PKG_NAME :: "editor"

CommandEntry :: struct {
	name:        string, // command name
	id:          string, // the attribute's id, "" for the proc's qualified name
	proc_name:   string, // the run proc
	enabled:     string, // the enabled proc, "" for always enabled
	source_pkg:  string,
	source_path: string,
	origin:      string, // where it was declared, rendered by gen_facts.attr_origin
}

KeymapEntry :: struct {
	name:        string, // keymap name
	window:      string, // window id, "" for the whole editor
	proc_name:   string, // the fill proc
	active:      string, // the active proc, "" for none
	consume:     bool,
	modal:       bool,
	priority:    int,
	source_pkg:  string,
	source_path: string,
	origin:      string,
}

Keymap_GenComp :: struct {
	commands: [dynamic]CommandEntry,
	keymaps:  [dynamic]KeymapEntry,
}

@(init)
_register :: proc "contextless" () {
	db.provider("keymap/provide", provide)
	db.generator("keymap/generate", generate)
}

provide :: proc(w: ^db.World) -> bool {
	_keymaps := db.get_or_create_comps(w, Keymap_GenComp)
	decls := db.get_comps_DeclInfo()
	procs := db.get_comps(w, gen_facts.Proc_GenComp)
	attrs := db.get_comps(w, gen_facts.Attrs_GenComp)

	m := db.all_of(db.r(decls), db.r(procs), db.r(attrs)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		decl := db.get(decls, entity)
		if decl.name == "" do continue
		attr_set := db.get(attrs, entity)

		commands: [dynamic]CommandEntry
		keymaps: [dynamic]KeymapEntry
		for args in attr_set.attrs {
			switch args.key {
			case "command":
				name := args.fields["name"]
				if name == "" {
					fmt.eprintf("command: %s.%s needs name=\"...\"\n", decl.pkg.name, decl.name)
					continue
				}
				append(&commands, CommandEntry{
					name        = name,
					id          = args.fields["id"],
					proc_name   = decl.name,
					enabled     = args.fields["enabled"],
					source_pkg  = decl.pkg.name,
					source_path = decl.pkg_path,
					origin      = gen_facts.attr_origin(args, gen_facts.decl_rel_path(decl), decl.decl.pos.line, decl.name),
				})
			case "keymap":
				name := args.fields["name"]
				if name == "" {
					fmt.eprintf("keymap: %s.%s needs name=\"...\"\n", decl.pkg.name, decl.name)
					continue
				}
				append(&keymaps, KeymapEntry{
					name        = name,
					window      = args.fields["window"],
					proc_name   = decl.name,
					active      = args.fields["active"],
					consume     = args.fields["consume"] == "true",
					modal       = args.fields["modal"] == "true",
					priority    = gen_facts.attr_int(args, "priority"),
					source_pkg  = decl.pkg.name,
					source_path = decl.pkg_path,
					origin      = gen_facts.attr_origin(args, gen_facts.decl_rel_path(decl), decl.decl.pos.line, decl.name),
				})
			}
		}

		if len(commands) > 0 || len(keymaps) > 0 {
			db.set(_keymaps, entity, Keymap_GenComp{commands = commands, keymaps = keymaps})
		} else {
			delete(commands)
			delete(keymaps)
		}
	}
	return true
}

// A proc name as seen from the editor package: prefixed with its package when declared elsewhere.
_qualified_name :: proc(source_pkg: string, name: string) -> string {
	if source_pkg != "" && source_pkg != _PKG_NAME {
		return fmt.tprintf("%s.%s", source_pkg, name)
	}
	return name
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

	commands: [dynamic]CommandEntry
	defer delete(commands)
	keymaps: [dynamic]KeymapEntry
	defer delete(keymaps)

	decls := db.get_comps_DeclInfo()
	_keymaps := db.get_comps(w, Keymap_GenComp)
	m := db.all_of(db.r(decls), db.r(_keymaps)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		tb := db.get(_keymaps, entity)
		for e in tb.commands do append(&commands, e)
		for e in tb.keymaps do append(&keymaps, e)
	}

	slice.sort_by(commands[:], proc(a, b: CommandEntry) -> bool {
		if a.name != b.name do return a.name < b.name
		return a.proc_name < b.proc_name
	})
	slice.sort_by(keymaps[:], proc(a, b: KeymapEntry) -> bool {
		if a.name != b.name do return a.name < b.name
		return a.proc_name < b.proc_name
	})

	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	packages_used: map[string]string
	defer delete(packages_used)
	add_pkg :: proc(packages_used: ^map[string]string, out_dir, source_pkg, source_path: string) {
		if source_pkg == "" || source_pkg == _PKG_NAME do return
		if source_pkg in packages_used do return
		packages_used[source_pkg] = _relative_import_path(out_dir, source_path)
	}
	for e in commands do add_pkg(&packages_used, out_dir, e.source_pkg, e.source_path)
	for e in keymaps do add_pkg(&packages_used, out_dir, e.source_pkg, e.source_path)
	import_pkgs: [dynamic]string
	defer delete(import_pkgs)
	for pkg in packages_used {
		append(&import_pkgs, pkg)
	}
	slice.sort(import_pkgs[:])

	strings.write_string(&b, "package editor\n\n")
	strings.write_string(&b, "import __km \"moonhug:editor/keymap\"\n")
	for pkg in import_pkgs {
		fmt.sbprintf(&b, "import %s \"%s\"\n", pkg, packages_used[pkg])
	}
	strings.write_string(&b, "\n// Code generated by keymap_gen. Do not edit.\n\n")
	strings.write_string(&b, "_register_editor_keymaps :: proc() {\n")
	for e in commands {
		fmt.sbprintf(&b, "\t__km.command_add(%q, %s", e.name, _qualified_name(e.source_pkg, e.proc_name))
		if e.enabled != "" do fmt.sbprintf(&b, ", enabled = %s", _qualified_name(e.source_pkg, e.enabled))
		id := e.id if e.id != "" else fmt.tprintf("%s.%s", e.source_pkg, e.proc_name)
		fmt.sbprintf(&b, ", id = %q", id)
		fmt.sbprintf(&b, ", origin = %q)\n", e.origin)
	}
	for e in keymaps {
		fmt.sbprintf(&b, "\t__km.add(%q, %q, %s", e.name, e.window, _qualified_name(e.source_pkg, e.proc_name))
		if e.active != "" do fmt.sbprintf(&b, ", active = %s", _qualified_name(e.source_pkg, e.active))
		if e.consume do strings.write_string(&b, ", consume = true")
		if e.modal do strings.write_string(&b, ", modal = true")
		if e.priority != 0 do fmt.sbprintf(&b, ", priority = %d", e.priority)
		fmt.sbprintf(&b, ", origin = %q)\n", e.origin)
	}
	strings.write_string(&b, "}\n")

	db.emit(w, "moonhug/editor/editor_keymaps_generated.odin", strings.to_string(b))
	if gen_facts.write_reference_pages do _write_reference(w, commands[:], keymaps[:])
	return true
}

// The reference page docs/reference/commands/_index.md: every command id
// with its name and where it is declared, the menu's items included, and
// every keymap with its scope. Written by `mh docs`, like the attribute
// pages (attributes_gen), so the override file's ids can be looked up.
@(private = "file")
_write_reference :: proc(w: ^db.World, commands: []CommandEntry, keymaps: []KeymapEntry) {
	Row :: struct {
		id, name, pkg, place: string,
	}
	rows := make([dynamic]Row, context.temp_allocator)
	for e in commands {
		id := e.id if e.id != "" else fmt.tprintf("%s.%s", e.source_pkg, e.proc_name)
		append(&rows, Row{id, e.name, e.source_pkg, _origin_place(e.origin)})
	}
	decls := db.get_comps_DeclInfo()
	menus := db.get_comps(w, menu_gen.Menu_GenComp)
	m := db.all_of(db.r(decls), db.r(menus)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		for e in db.get(menus, entity).entries {
			if e.kind != .Item && e.kind != .Toggle do continue
			append(&rows, Row{menu_gen._command_id(e), e.path, e.source_pkg, _origin_place(e.origin)})
		}
	}
	slice.sort_by(rows[:], proc(a, b: Row) -> bool {
		if a.pkg != b.pkg do return a.pkg < b.pkg
		return a.name < b.name
	})

	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "---\ntitle: \"Commands\"\ndescription: \"Every editor command by its stable id, with its name and where it is declared, and every keymap\"\nweight: 25\n---\n\n")
	strings.write_string(&b, "Generated by `moonhug/prebuild/keymap_gen` when `mh docs` runs. Not edited by hand and not committed.\n\n")
	strings.write_string(&b, "A command is a named proc the editor runs from a key, a menu item or the bridge ([Keymaps](../../core/Keymaps.md)). Its id is what a binding and the shortcuts override files refer to, stable through a rename of the title or a move in the menu. Commands are grouped by the package that declares them. Default chords are not listed here, they are bound in each keymap's proc: the Shortcuts tab of the settings window and the bridge's `commands` tool show the live bindings.\n\n")
	strings.write_string(&b, "## Commands\n\n")
	pkg := ""
	for r in rows {
		if r.pkg != pkg {
			pkg = r.pkg
			fmt.sbprintf(&b, "\n### %s\n\n| Id | Name | Declared |\n|---|---|---|\n", pkg)
		}
		fmt.sbprintf(&b, "| `%s` | %s | %s |\n", r.id, r.name, r.place)
	}
	strings.write_string(&b, "\n## Keymaps\n\n| Name | Scope | Declared |\n|---|---|---|\n")
	for e in keymaps {
		scope := "editor-wide"
		switch {
		case e.modal:       scope = "modal, while its tool runs"
		case e.window != "": scope = fmt.tprintf("%s window", e.window)
		}
		if e.active != "" do scope = fmt.tprintf("%s, when `%s` allows", scope, e.active)
		fmt.sbprintf(&b, "| %s | %s | %s |\n", e.name, scope, _origin_place(e.origin))
	}
	os.make_directory_all("docs/reference/commands")
	db.emit(w, "docs/reference/commands/_index.md", strings.to_string(b))
}

// The "path:line" part of an origin string, which reads
// `@(attr ...)  path:line  proc`.
@(private = "file")
_origin_place :: proc(origin: string) -> string {
	rest := origin
	if i := strings.index(rest, ")  "); i >= 0 do rest = rest[i + 3:]
	if i := strings.index(rest, "  "); i >= 0 do rest = rest[:i]
	return rest
}
