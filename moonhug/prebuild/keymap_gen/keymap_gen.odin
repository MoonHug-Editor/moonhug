package keymap_gen

// keymap_gen: declared editor commands and keymaps (docs/core/Keymaps.md).
//
//   @(command={name="Scene/Translate Tool", enabled=scene_can_clear_selection, id="scene.translate", help="Moves the selection along the handle's axes"})
//   scene_tool_translate :: proc() { ... }
//
//   @(command={name="Edit/Duplicate Array", defaults=DUPLICATE_ARRAY_DEFAULT, update=duplicate_array_update, help="..."})
//   edit_duplicate_array :: proc(args: ^Duplicate_Array_Args) { ... }
//   duplicate_array_update :: proc(args: ^Duplicate_Array_Args) -> bool { ... }
//
//   @(keymap={name="Scene Flythrough", modal=true})
//   scene_flythrough_keymap :: proc(km: ^keymap.Keymap) { ... }
//
//   @(command_palette_mode={name="Assets", prefix="#", run=command_palette_assets_run, shortcut="Ctrl+Shift+A", help="Finds an asset by name or folder and opens it"})
//   command_palette_assets :: proc(query: string, rows: ^[dynamic]command_palette.Row) { ... }
//
//   generate - moonhug/editor/editor_keymaps_generated.odin:
//              _register_editor_keymaps(), one keymap.command_add call per
//              command, keymap.command_add_args for one whose proc takes a
//              pointer to its arguments, one command_palette.mode_add call per palette mode,
//              then one
//              keymap.add call per keymap.
//
// `enabled`, `active`, `run` and `update` name procs in the package of the
// declaration. `update` takes the command's own arguments pointer and returns
// a bool, checked here so the error names the declaration.
// Optional fields are left out of the call when empty, false or zero.

import "core:fmt"
import "core:odin/ast"
import "core:slice"
import "core:strings"
import "core:os"
import "../gen_core"
import db "../gen_db"
import "../gen_facts"
import "../menu_gen"

_PKG_NAME :: "editor"

CommandEntry :: struct {
	name:        string, // command name
	id:          string, // the attribute's id, "" for the proc's qualified name
	palette:     bool,   // listed by the command palette, false when the attribute says palette=false
	proc_name:   string, // the run proc
	enabled:     string, // the enabled proc, "" for always enabled
	help:        string, // one sentence on what it does, "" for none
	// The proc takes one pointer, its arguments: keymap.command_add_args.
	args:        bool,
	defaults:    string, // the constant `defaults=` names, "" for the zero value
	ask:         bool,   // ask=true: the arguments show before the first run
	update:      string, // the proc that applies changed arguments in place, "" for none
	args_type:   string, // the proc's one parameter type as written, "^Duplicate_Array_Args"
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

ModeEntry :: struct {
	name:        string, // mode name, its command is Command Palette/<name>
	prefix:      string,
	proc_name:   string, // the list proc
	run:         string, // the run proc
	shortcut:    string, // the chord of its command, "" for none
	id:          string, // its command's id, "" for the list proc's qualified name
	help:        string, // its command's help, "" for none
	source_pkg:  string,
	source_path: string,
	origin:      string,
}

Keymap_GenComp :: struct {
	commands: [dynamic]CommandEntry,
	keymaps:  [dynamic]KeymapEntry,
	modes:    [dynamic]ModeEntry,
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
		modes: [dynamic]ModeEntry
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
					palette     = args.fields["palette"] != "false",
					proc_name   = decl.name,
					enabled     = args.fields["enabled"],
					help        = args.fields["help"],
					args        = _takes_args(decl),
					defaults    = args.fields["defaults"],
					ask         = args.fields["ask"] == "true",
					update      = args.fields["update"],
					args_type   = _first_param_type(decl.decl),
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
			case "command_palette_mode":
				name, prefix, run := args.fields["name"], args.fields["prefix"], args.fields["run"]
				if name == "" || prefix == "" || run == "" {
					fmt.eprintf("command_palette_mode: %s.%s needs name=\"...\", prefix=\"...\" and run=...\n", decl.pkg.name, decl.name)
					continue
				}
				append(&modes, ModeEntry{
					name        = name,
					prefix      = prefix,
					proc_name   = decl.name,
					run         = run,
					shortcut    = args.fields["shortcut"],
					id          = args.fields["id"],
					help        = args.fields["help"],
					source_pkg  = decl.pkg.name,
					source_path = decl.pkg_path,
					origin      = gen_facts.attr_origin(args, gen_facts.decl_rel_path(decl), decl.decl.pos.line, decl.name),
				})
			}
		}

		if len(commands) > 0 || len(keymaps) > 0 || len(modes) > 0 {
			db.set(_keymaps, entity, Keymap_GenComp{commands = commands, keymaps = keymaps, modes = modes})
		} else {
			delete(commands)
			delete(keymaps)
			delete(modes)
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
	modes: [dynamic]ModeEntry
	defer delete(modes)

	decls := db.get_comps_DeclInfo()
	_keymaps := db.get_comps(w, Keymap_GenComp)
	m := db.all_of(db.r(decls), db.r(_keymaps)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		tb := db.get(_keymaps, entity)
		for e in tb.commands do append(&commands, e)
		for e in tb.keymaps do append(&keymaps, e)
		for e in tb.modes do append(&modes, e)
	}

	slice.sort_by(commands[:], proc(a, b: CommandEntry) -> bool {
		if a.name != b.name do return a.name < b.name
		return a.proc_name < b.proc_name
	})
	slice.sort_by(keymaps[:], proc(a, b: KeymapEntry) -> bool {
		if a.name != b.name do return a.name < b.name
		return a.proc_name < b.proc_name
	})
	slice.sort_by(modes[:], proc(a, b: ModeEntry) -> bool {
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
	for e in modes do add_pkg(&packages_used, out_dir, e.source_pkg, e.source_path)
	import_pkgs: [dynamic]string
	defer delete(import_pkgs)
	for pkg in packages_used {
		append(&import_pkgs, pkg)
	}
	slice.sort(import_pkgs[:])

	updates_ok := true
	for e in commands do if e.update != "" && !_check_update(w, e) do updates_ok = false
	if !updates_ok do return false

	strings.write_string(&b, "package editor\n\n")
	strings.write_string(&b, "import __km \"moonhug:editor/keymap\"\n")
	if len(modes) > 0 do strings.write_string(&b, "import __cp \"moonhug:editor/command_palette\"\n")
	for pkg in import_pkgs {
		fmt.sbprintf(&b, "import %s \"%s\"\n", pkg, packages_used[pkg])
	}
	strings.write_string(&b, "\n// Code generated by keymap_gen. Do not edit.\n\n")
	strings.write_string(&b, "_register_editor_keymaps :: proc() {\n")
	for e in commands {
		if e.args {
			// The arguments' type comes from the proc, so `{}` is its zero value.
			defaults := _qualified_name(e.source_pkg, e.defaults) if e.defaults != "" else "{}"
			fmt.sbprintf(&b, "\t__km.command_add_args(%q, %s, defaults = %s", e.name, _qualified_name(e.source_pkg, e.proc_name), defaults)
			if e.ask do strings.write_string(&b, ", ask = true")
			if e.update != "" do fmt.sbprintf(&b, ", update = %s", _qualified_name(e.source_pkg, e.update))
		} else {
			fmt.sbprintf(&b, "\t__km.command_add(%q, %s", e.name, _qualified_name(e.source_pkg, e.proc_name))
		}
		if e.enabled != "" do fmt.sbprintf(&b, ", enabled = %s", _qualified_name(e.source_pkg, e.enabled))
		id := e.id if e.id != "" else fmt.tprintf("%s.%s", e.source_pkg, e.proc_name)
		fmt.sbprintf(&b, ", id = %q", id)
		if !e.palette do strings.write_string(&b, ", palette = false")
		if e.help != "" do fmt.sbprintf(&b, ", help = %q", e.help)
		fmt.sbprintf(&b, ", origin = %q)\n", e.origin)
	}
	for e in modes {
		fmt.sbprintf(&b, "\t__cp.mode_add(%q, %q, %s, %s", e.name, e.prefix, _qualified_name(e.source_pkg, e.proc_name), _qualified_name(e.source_pkg, e.run))
		if e.shortcut != "" do fmt.sbprintf(&b, ", shortcut = %q", e.shortcut)
		fmt.sbprintf(&b, ", id = %q", _mode_command_id(e))
		if e.help != "" do fmt.sbprintf(&b, ", help = %q", e.help)
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
	_warn_missing_help(w, commands[:], modes[:])
	if gen_facts.write_reference_pages do _write_reference(w, commands[:], keymaps[:], modes[:])
	return true
}

// Warns about every command declared without `help`: @(command),
// @(command_palette_mode), and @(menu_item) on an item or a toggle. The
// command palette, the Shortcuts page and the menu show the help, so a
// command without one shows nothing there. A warning, not an error: the
// command still works.
@(private = "file")
_warn_missing_help :: proc(w: ^db.World, commands: []CommandEntry, modes: []ModeEntry) {
	missing := make([dynamic]string, context.temp_allocator)
	for e in commands do if e.help == "" {
		append(&missing, fmt.tprintf("%s: @(command) \"%s\" has no help", _origin_place(e.origin), e.name))
	}
	for e in modes do if e.help == "" {
		append(&missing, fmt.tprintf("%s: @(command_palette_mode) \"%s\" has no help", _origin_place(e.origin), e.name))
	}
	decls := db.get_comps_DeclInfo()
	menus := db.get_comps(w, menu_gen.Menu_GenComp)
	m := db.all_of(db.r(decls), db.r(menus)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		for e in db.get(menus, entity).entries {
			if (e.kind != .Item && e.kind != .Toggle) || e.help != "" do continue
			append(&missing, fmt.tprintf("%s: @(menu_item) \"%s\" has no help", _origin_place(e.origin), e.path))
		}
	}
	slice.sort(missing[:])
	for msg in missing do fmt.eprintfln("prebuild: warning: %s", msg)
}

// Whether a command's proc takes its arguments: one parameter, a pointer.
@(private = "file")
_takes_args :: proc(decl: ^db.DeclInfo) -> bool {
	if decl.decl == nil || len(decl.decl.values) == 0 do return false
	lit, is_proc := decl.decl.values[0].derived.(^ast.Proc_Lit)
	if !is_proc || lit.type == nil || lit.type.params == nil do return false
	params := lit.type.params.list
	if len(params) != 1 || len(params[0].names) != 1 do return false
	_, is_pointer := params[0].type.derived.(^ast.Pointer_Type)
	return is_pointer
}

// A proc's one parameter type as written ("^Duplicate_Array_Args"), and its
// one result type ("bool"). "" for what it does not have exactly one of.
@(private = "file")
_first_param_type :: proc(v_decl: ^ast.Value_Decl) -> string {
	param, _ := _proc_shape(v_decl)
	return param
}

@(private = "file")
_proc_shape :: proc(v_decl: ^ast.Value_Decl) -> (param: string, result: string) {
	if v_decl == nil || len(v_decl.values) == 0 do return
	lit, is_proc := v_decl.values[0].derived.(^ast.Proc_Lit)
	if !is_proc || lit.type == nil do return
	if lit.type.params != nil && len(lit.type.params.list) == 1 && len(lit.type.params.list[0].names) == 1 {
		param = gen_core.RenderValue(lit.type.params.list[0].type)
	}
	if lit.type.results != nil && len(lit.type.results.list) == 1 && len(lit.type.results.list[0].names) <= 1 {
		result = gen_core.RenderValue(lit.type.results.list[0].type)
	}
	return
}

// An @(command)'s `update=` proc: it must be in the command's package, take
// the command's own arguments pointer and return a bool. Checked here so the
// error names the declaration instead of a line of the generated file.
@(private = "file")
_check_update :: proc(w: ^db.World, e: CommandEntry) -> bool {
	place := _origin_place(e.origin)
	if !e.args {
		fmt.eprintfln("prebuild: error: %s: @(command) \"%s\" names update=%s, but its proc takes no arguments", place, e.name, e.update)
		return false
	}
	decls := db.get_comps_DeclInfo()
	m := db.all_of(db.r(decls)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		d := db.get(decls, entity)
		if d.name != e.update || d.pkg_path != e.source_path do continue
		param, result := _proc_shape(d.decl)
		if param == e.args_type && result == "bool" do return true
		fmt.eprintfln("prebuild: error: %s: update=%s must be proc(args: %s) -> bool", place, e.update, e.args_type)
		return false
	}
	fmt.eprintfln("prebuild: error: %s: update=%s is not a proc in package %s", place, e.update, e.source_pkg)
	return false
}

// The id of the command that opens the palette on a mode: the attribute's
// id, else the list proc's qualified name.
@(private = "file")
_mode_command_id :: proc(e: ModeEntry) -> string {
	return e.id if e.id != "" else fmt.tprintf("%s.%s", e.source_pkg, e.proc_name)
}

// The reference page docs/reference/commands/_index.md: every command id
// with its name and where it is declared, the menu's items included, and
// every keymap with its scope. Written by `mh docs`, like the attribute
// pages (attributes_gen), so the override file's ids can be looked up.
@(private = "file")
_write_reference :: proc(w: ^db.World, commands: []CommandEntry, keymaps: []KeymapEntry, modes: []ModeEntry) {
	Row :: struct {
		id, name, pkg, place, help: string,
	}
	rows := make([dynamic]Row, context.temp_allocator)
	for e in commands {
		id := e.id if e.id != "" else fmt.tprintf("%s.%s", e.source_pkg, e.proc_name)
		append(&rows, Row{id, e.name, e.source_pkg, _origin_place(e.origin), e.help})
	}
	for e in modes {
		append(&rows, Row{_mode_command_id(e), fmt.tprintf("Command Palette/%s", e.name), e.source_pkg, _origin_place(e.origin), e.help})
	}
	decls := db.get_comps_DeclInfo()
	menus := db.get_comps(w, menu_gen.Menu_GenComp)
	m := db.all_of(db.r(decls), db.r(menus)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		for e in db.get(menus, entity).entries {
			if e.kind != .Item && e.kind != .Toggle do continue
			append(&rows, Row{menu_gen._command_id(e), e.path, e.source_pkg, _origin_place(e.origin), e.help})
		}
	}
	slice.sort_by(rows[:], proc(a, b: Row) -> bool {
		if a.pkg != b.pkg do return a.pkg < b.pkg
		return a.name < b.name
	})

	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "---\ntitle: \"Commands\"\ndescription: \"Every editor command by its stable id, with its name, its help and where it is declared, and every keymap\"\nweight: 25\n---\n\n")
	strings.write_string(&b, "Generated by `moonhug/prebuild/keymap_gen` when `mh docs` runs. Not edited by hand and not committed.\n\n")
	strings.write_string(&b, "A command is a named proc the editor runs from a key, a menu item or the bridge ([Keymaps](../../core/Keymaps.md)). Its id is what a binding and the shortcuts override files refer to, stable through a rename of the title or a move in the menu. Commands are grouped by the package that declares them. Default chords are not listed here, they are bound in each keymap's proc: the Shortcuts tab of the settings window and the bridge's `commands` tool show the live bindings.\n\n")
	strings.write_string(&b, "## Commands\n\n")
	pkg := ""
	for r in rows {
		if r.pkg != pkg {
			pkg = r.pkg
			fmt.sbprintf(&b, "\n### %s\n\n| Id | Name | Help | Declared |\n|---|---|---|---|\n", pkg)
		}
		help, _ := strings.replace_all(r.help, "|", "\\|", context.temp_allocator)
		fmt.sbprintf(&b, "| `%s` | %s | %s | %s |\n", r.id, r.name, help, gen_core.SourceLinkAt(r.place))
	}
	strings.write_string(&b, "\n## Keymaps\n\n| Name | Scope | Declared |\n|---|---|---|\n")
	for e in keymaps {
		scope := "editor-wide"
		switch {
		case e.modal:       scope = "modal, while its tool runs"
		case e.window != "": scope = fmt.tprintf("%s window", e.window)
		}
		if e.active != "" do scope = fmt.tprintf("%s, when `%s` allows", scope, e.active)
		fmt.sbprintf(&b, "| %s | %s | %s |\n", e.name, scope, gen_core.SourceLinkAt(_origin_place(e.origin)))
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
