package engine_gen

// render_node_gen: the render node registry (plugins/engine/render_node_registry.odin).
//
//   @(render_node={summary="ambient occlusion from the scene depth", reads="hdr", writes="ssao:LDR@0.5", settings="ssao_defaults"})
//   ssao_node :: proc(ctx: ^engine.Render_Ctx) { ... }
//
//   provide  - recognise procs in installed packages carrying @(render_node),
//              parse each write (`name[:FORMAT][@scale|@Npx][*]`), check the
//              settings var exists in the same package.
//   generate - check every node name is unique across packages, and emit the
//              registrations:
//              - <engine>/editor/scene_tools/render_nodes_editor_generated.odin:
//                every node, for the editor, registered from @(init)
//              - <runnable>/render_nodes_generated.odin per runnable package:
//                its runtime nodes and the library packages', registered by
//                the generated __standalone_run through __register_render_nodes
//              Which nodes run and in what order is the pipeline asset's
//              (render_pipeline.odin), not the generator's.

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"
import db "moonhug:prebuild/gen_db"
import "moonhug:prebuild/gen_facts"

// One parsed write, mirroring engine.Render_Target_Decl.
Target_Decl :: struct {
	name:   string,
	format: string, // "LDR" or "HDR"
	scale:  f32,
	px:     int,
	final:  bool,
	text:   string, // as written, for messages
}

// The read name reserved for the finished image so far (engine.FINAL_INPUT).
_FINAL_INPUT :: "final"

Render_Node_GenComp :: struct {
	summary:  string,
	file:     string, // repo-relative, for the pipeline window's jump to code
	line:     int,
	reads:    []string,
	writes:   []Target_Decl,
	frame:    bool,   // frame=true: once per frame, before the view's nodes
	settings: string, // the defaults var in the node's package, "" = no settings
	editor:   bool,   // declared in an editor/ package
}

_RG_OUT_PKG      :: "scene_tools"
_EDITOR_OUT_FILE :: _ENGINE_EDITOR_PKG_PATH + "/scene_tools/render_nodes_editor_generated.odin"

@(init)
_register_render_node_gen :: proc "contextless" () {
	db.provider("render_node/provide", render_node_provide)
	db.generator("render_node/generate", render_node_generate)
}

render_node_provide :: proc(w: ^db.World) -> bool {
	nodes := db.get_or_create_comps(w, Render_Node_GenComp)
	decls := db.get_comps_DeclInfo()
	procs := db.get_comps(w, gen_facts.Proc_GenComp)
	attrs := db.get_comps(w, gen_facts.Attrs_GenComp)

	m := db.all_of(db.r(decls), db.r(procs), db.r(attrs)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		decl := db.get(decls, entity)
		if decl.name == "" || !strings.has_prefix(decl.pkg_path, _PACKAGES_PREFIX) do continue
		args, found := gen_facts.attr_find(db.get(attrs, entity), "render_node")
		if !found do continue
		where_ := fmt.tprintf("%s:%d", gen_facts.decl_rel_path(decl), decl.decl.pos.line)
		writes := make([dynamic]Target_Decl)
		frame := args.fields["frame"] == "true"
		for word in _words(args.fields["writes"]) {
			d, err := _parse_decl(word)
			if err == "" && frame && d.px == 0 do err = "a per-frame node's target needs a fixed size (@2048px): there is no view to scale from"
			if err != "" {
				fmt.eprintfln("prebuild: %s: render node %s: writes=%q: %s", where_, decl.name, word, err)
				_provide_failed = true
				continue
			}
			append(&writes, d)
		}
		for t in _words(args.fields["reads"]) {
			if frame && t == _FINAL_INPUT {
				fmt.eprintfln("prebuild: %s: render node %s is per frame and runs before any view has a final image, it cannot read %q", where_, decl.name, t)
				_provide_failed = true
			}
		}
		db.set(nodes, entity, Render_Node_GenComp{
			summary  = args.fields["summary"],
			file     = gen_facts.decl_rel_path(decl),
			line     = decl.decl.pos.line,
			reads    = _words(args.fields["reads"]),
			writes   = writes[:],
			frame    = frame,
			settings = args.fields["settings"],
			editor   = strings.has_suffix(decl.pkg_path, "/editor") || strings.contains(decl.pkg_path, "/editor/"),
		})
	}
	return true
}

@(private = "file")
_provide_failed: bool

@(private = "file")
_words :: proc(s: string) -> []string {
	return strings.fields(s)
}

// `name[:FORMAT][@scale|@Npx][*]` -> a declaration, or an error message.
@(private = "file")
_parse_decl :: proc(word: string) -> (d: Target_Decl, err: string) {
	d = Target_Decl{format = "LDR", scale = 1, text = word}
	rest := word
	if strings.has_suffix(rest, "*") {
		d.final = true
		rest = rest[:len(rest) - 1]
	}
	if at := strings.index_byte(rest, '@'); at >= 0 {
		size := rest[at + 1:]
		rest = rest[:at]
		if strings.has_suffix(size, "px") {
			n, ok := strconv.parse_int(size[:len(size) - 2])
			if !ok || n <= 0 do return d, "the size after @ must be a whole number of pixels (@2048px)"
			d.px = n
		} else {
			f, ok := strconv.parse_f32(size)
			if !ok || f <= 0 || f > 1 do return d, "the scale after @ must be a fraction of the view in (0, 1], or pixels as @Npx"
			d.scale = f
		}
	}
	if colon := strings.index_byte(rest, ':'); colon >= 0 {
		d.format = rest[colon + 1:]
		rest = rest[:colon]
		if d.format != "LDR" && d.format != "HDR" do return d, "the format after : is LDR or HDR"
	}
	d.name = rest
	if d.name == "" do return d, "a target needs a name"
	if d.name == _FINAL_INPUT do return d, "\"final\" is the reserved read name for the finished image, a write cannot use it"
	return d, ""
}

@(private = "file")
_Node_Row :: struct {
	name:   string,
	pkg:    string,
	path:   string, // pkg_path
	where_: string, // file:line, for errors
	using comp: Render_Node_GenComp,
}

render_node_generate :: proc(w: ^db.World) -> bool {
	decls := db.get_comps_DeclInfo()
	nodes := db.get_comps(w, Render_Node_GenComp)

	rows := make([dynamic]_Node_Row, context.temp_allocator)
	m := db.all_of(db.r(decls), db.r(nodes)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		decl := db.get(decls, entity)
		append(&rows, _Node_Row{
			name   = decl.name,
			pkg    = decl.pkg.name,
			path   = decl.pkg_path,
			where_ = fmt.tprintf("%s:%d", gen_facts.decl_rel_path(decl), decl.decl.pos.line),
			comp   = db.get(nodes, entity)^,
		})
	}
	// Stable order: the row order the generated files list nodes in.
	slice.sort_by(rows[:], proc(a, b: _Node_Row) -> bool {
		if a.pkg != b.pkg do return a.pkg < b.pkg
		return a.name < b.name
	})

	ok := !_provide_failed
	// A node's name is what a pipeline asset places, unique across packages.
	for r, i in rows {
		for o in rows[:i] {
			if o.name == r.name {
				fmt.eprintfln("prebuild: %s: render node %s is also declared by package %s (%s), rename one: a pipeline places nodes by name", r.where_, r.name, o.pkg, o.where_)
				ok = false
			}
		}
	}
	if !ok do return false

	_emit_editor(w, rows[:])
	runnables := gen_facts.runnable_packages(w)
	defer delete(runnables)
	for host in runnables do _emit_host(w, host, rows[:], runnables[:])
	return true
}

// The editor's registrations: every node, runtime and editor, from the
// engine's scene tools, which may import any package's runtime and editor
// parts. Registers from @(init). Always written, so removing the last node
// clears the previous file.
@(private = "file")
_emit_editor :: proc(w: ^db.World, rows: []_Node_Row) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	fmt.sbprintf(&b, "package %s\n\n", _RG_OUT_PKG)
	strings.write_string(&b, "// Code generated by render_node_gen. Do not edit.\n")
	strings.write_string(&b, "// Every render node, for the editor (plugins/engine/render_node_registry.odin).\n\n")
	if len(rows) == 0 {
		db.emit(w, _EDITOR_OUT_FILE, strings.to_string(b))
		return
	}
	strings.write_string(&b, "import \"base:runtime\"\n")
	_write_imports(&b, rows, "")
	_write_target_arrays(&b, rows, "")
	strings.write_string(&b, "\n@(init)\n_register_render_nodes :: proc \"contextless\" () {\n\tcontext = runtime.default_context()\n")
	for r, i in rows do _write_register(&b, r, i, "")
	strings.write_string(&b, "}\n")
	db.emit(w, _EDITOR_OUT_FILE, strings.to_string(b))
}

// One runnable package's registrations: its own runtime nodes and the
// library packages', never an editor node or another runnable's. A plain
// proc the generated __standalone_run calls (update_gen), not @(init), so the
// editor, which imports the same package, never registers a node twice.
@(private = "file")
_emit_host :: proc(w: ^db.World, host: gen_facts.Runnable_Pkg, rows: []_Node_Row, runnables: []gen_facts.Runnable_Pkg) {
	mine := make([dynamic]_Node_Row, context.temp_allocator)
	for r in rows {
		if r.editor do continue
		if r.pkg != host.name && gen_facts.is_runnable(runnables, r.pkg) do continue
		append(&mine, r)
	}
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	fmt.sbprintf(&b, "package %s\n\n", host.name)
	strings.write_string(&b, "// Code generated by render_node_gen. Do not edit.\n")
	strings.write_string(&b, "// This package's render nodes and the library packages', registered by __standalone_run.\n\n")
	if len(mine) > 0 do _write_imports(&b, mine[:], host.name)
	_write_target_arrays(&b, mine[:], host.name)
	strings.write_string(&b, "\n__register_render_nodes :: proc() {\n")
	for r, i in mine do _write_register(&b, r, i, host.name)
	strings.write_string(&b, "}\n")
	db.emit(w, fmt.tprintf("%s/render_nodes_generated.odin", host.path), strings.to_string(b))
}

// engine first, then every node package but the file's own, by name.
@(private = "file")
_write_imports :: proc(b: ^strings.Builder, rows: []_Node_Row, own_pkg: string) {
	imports := make(map[string]string, context.temp_allocator) // pkg name -> import path
	for r in rows do if r.pkg != own_pkg && r.pkg not_in imports do imports[r.pkg] = _rg_import_path(r.path)
	names := make([dynamic]string, context.temp_allocator)
	for name in imports do append(&names, name)
	slice.sort(names[:])
	if own_pkg != "engine" do fmt.sbprintf(b, "import engine %q\n", _ENGINE_IMPORT)
	for name in names do if name != "engine" do fmt.sbprintf(b, "import %s %q\n", name, imports[name])
}

// The reads and writes as file-scope arrays, one pair per row. A slice
// literal written inside the registration proc would live on that proc's
// stack, and the registry keeps the slices after the proc returns.
@(private = "file")
_write_target_arrays :: proc(b: ^strings.Builder, rows: []_Node_Row, own_pkg: string) {
	if len(rows) > 0 do strings.write_string(b, "\n")
	for r, i in rows {
		if len(r.reads) > 0 do fmt.sbprintf(b, "@(private = \"file\") _reads_%d := %s\n", i, _string_array(r.reads))
		if len(r.writes) > 0 do fmt.sbprintf(b, "@(private = \"file\") _writes_%d := %s\n", i, _decl_array(r.writes, own_pkg))
	}
}

@(private = "file")
_decl_array :: proc(decls: []Target_Decl, own_pkg: string) -> string {
	prefix := own_pkg == "engine" ? "" : "engine."
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "[?]%sRender_Target_Decl{{", prefix)
	for d, i in decls {
		if i > 0 do strings.write_string(&b, ", ")
		fmt.sbprintf(&b, "{{name = %q, format = .%s, scale = %v, px = %d, final = %t}}", d.name, d.format, d.scale, d.px, d.final)
	}
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

@(private = "file")
_write_register :: proc(b: ^strings.Builder, r: _Node_Row, index: int, own_pkg: string) {
	qual := r.pkg == own_pkg ? "" : fmt.tprintf("%s.", r.pkg)
	prefix := own_pkg == "engine" ? "" : "engine."
	reads := len(r.reads) > 0 ? fmt.tprintf("_reads_%d[:]", index) : "nil"
	writes := len(r.writes) > 0 ? fmt.tprintf("_writes_%d[:]", index) : "nil"
	settings := ""
	if r.settings != "" {
		v := fmt.tprintf("%s%s", qual, r.settings)
		settings = fmt.tprintf(", settings_tid = typeid_of(type_of(%s)), settings_ptr_tid = typeid_of(^type_of(%s)), settings_size = size_of(type_of(%s)), settings_default = &%s", v, v, v, v)
	}
	fmt.sbprintf(b, "\t%srender_node_register(%sRender_Node{{name = %q, pkg = %q, summary = %q, file = %q, line = %d, frame = %t, reads = %s, writes = %s, run = %s%s%s}})\n",
		prefix, prefix, r.name, r.pkg, r.summary, r.file, r.line, r.frame, reads, writes, qual, r.name, settings)
}

@(private = "file")
_string_array :: proc(words: []string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "[?]string{")
	for word, i in words {
		if i > 0 do strings.write_string(&b, ", ")
		fmt.sbprintf(&b, "%q", word)
	}
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

// "moonhug/packages/x/editor" -> "moonhug:packages/x/editor".
@(private = "file")
_rg_import_path :: proc(pkg_path: string) -> string {
	return fmt.tprintf("moonhug:%s", pkg_path[len("moonhug/"):])
}
