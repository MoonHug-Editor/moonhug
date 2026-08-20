package mcp_tool_gen

// mcp_tool_gen: MCP bridge tools (docs/McpBridge.md).
//
//   @(mcp_tool={description="What the agent sees"})
//   mcp_tool_set_name :: proc(p: json.Object) -> (string, Mcp_Error) { ... }
//
//   generate - moonhug/editor/mcp_tools_generated.odin:
//              _mcp_tool_table() returning one Mcp_Tool_Def per declaration
//              (name, description, schema JSON, handler, write flag).
//
// The tool NAME is the proc name minus the `mcp_tool_` prefix. Parameters are
// declared with `param:` fields on the attribute — one per parameter, value
// "<type>[!]:<description>", where <type> is string/integer/number/boolean
// and a trailing ! marks it required:
//
//   @(mcp_tool={description="...", param_path="string!:Menu path to invoke"})
//
// so the JSON Schema the agent sees is derived from the declaration and can
// never drift from the handler. A tool declares WHAT it takes, never what it
// touches: the bridge is enabled or disabled as a whole (Mcp_Settings), so no
// hand-classified read/write flag can be forgotten or get out of date.

import "core:fmt"
import "core:slice"
import "core:strings"
import db "../gen_db"
import "../gen_facts"

_PKG_NAME :: "editor"

ToolParam :: struct {
	name:        string,
	type_name:   string, // JSON Schema type
	description: string,
	required:    bool,
}

ToolEntry :: struct {
	tool_name:   string, // MCP name (proc name minus the prefix)
	proc_name:   string,
	description: string,
	params:      [dynamic]ToolParam,
	source_pkg:  string,
	source_path: string,
}

Mcp_Tool_GenComp :: struct {
	entries: [dynamic]ToolEntry,
}

_PROC_PREFIX :: "mcp_tool_"
_PARAM_PREFIX :: "param_"

@(init)
_register :: proc "contextless" () {
	db.provider("mcp_tool/provide", provide)
	db.generator("mcp_tool/generate", generate)
}

// "string!:Menu path to invoke" -> (string, true, "Menu path to invoke")
_parse_param_spec :: proc(spec: string) -> (type_name: string, required: bool, description: string, ok: bool) {
	colon := strings.index_byte(spec, ':')
	if colon < 0 {
		type_name = strings.trim_space(spec)
	} else {
		type_name = strings.trim_space(spec[:colon])
		description = strings.trim_space(spec[colon + 1:])
	}
	if strings.has_suffix(type_name, "!") {
		required = true
		type_name = type_name[:len(type_name) - 1]
	}
	switch type_name {
	case "string", "integer", "number", "boolean":
		return type_name, required, description, true
	// Arrays carry their element type in the spec ("integer[]"), because JSON
	// Schema needs an `items` sub-object to say what the array holds.
	case "string[]", "integer[]", "number[]", "boolean[]":
		return type_name, required, description, true
	}
	return "", false, "", false
}

provide :: proc(w: ^db.World) -> bool {
	_tools := db.get_or_create_comps(w, Mcp_Tool_GenComp)
	decls := db.get_comps_DeclInfo()
	procs := db.get_comps(w, gen_facts.Proc_GenComp)
	attrs := db.get_comps(w, gen_facts.Attrs_GenComp)

	m := db.all_of(db.r(decls), db.r(procs), db.r(attrs)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		decl := db.get(decls, entity)
		if decl.name == "" do continue
		attr_set := db.get(attrs, entity)

		entries: [dynamic]ToolEntry
		for args in attr_set.attrs {
			if args.key != "mcp_tool" do continue
			if !strings.has_prefix(decl.name, _PROC_PREFIX) {
				fmt.eprintf("mcp_tool: %s.%s must be named %s<tool_name>\n", decl.pkg.name, decl.name, _PROC_PREFIX)
				continue
			}
			description := args.fields["description"]
			if description == "" {
				fmt.eprintf("mcp_tool: %s.%s needs description=\"...\" (the agent reads it)\n", decl.pkg.name, decl.name)
				continue
			}

			params: [dynamic]ToolParam
			for key, value in args.fields {
				if !strings.has_prefix(key, _PARAM_PREFIX) do continue
				pname := key[len(_PARAM_PREFIX):]
				if pname == "" do continue
				type_name, required, pdesc, ok := _parse_param_spec(value)
				if !ok {
					fmt.eprintf("mcp_tool: %s.%s param %q needs \"<string|integer|number|boolean>[!]:<description>\"\n",
						decl.pkg.name, decl.name, pname)
					continue
				}
				append(&params, ToolParam{
					name = pname, type_name = type_name,
					description = pdesc, required = required,
				})
			}
			// Attribute fields come from a map — sort so the emitted schema
			// is stable across builds.
			slice.sort_by(params[:], proc(a, b: ToolParam) -> bool {
				return a.name < b.name
			})

			append(&entries, ToolEntry{
				tool_name   = decl.name[len(_PROC_PREFIX):],
				proc_name   = decl.name,
				description = description,
				params      = params,
				source_pkg  = decl.pkg.name,
				source_path = decl.pkg_path,
			})
		}

		if len(entries) > 0 {
			db.set(_tools, entity, Mcp_Tool_GenComp{entries = entries})
		} else {
			delete(entries)
		}
	}
	return true
}

// JSON Schema for one tool, as an Odin string literal body (already escaped
// for embedding with %q at emit time).
_schema_json :: proc(e: ToolEntry) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"type":"object","properties":{`)
	for p, i in e.params {
		if i > 0 do strings.write_string(&b, ",")
		if strings.has_suffix(p.type_name, "[]") {
			elem := p.type_name[:len(p.type_name) - 2]
			fmt.sbprintf(&b, `"%s":{{"type":"array","items":{{"type":"%s"}},"description":"%s"}}`,
				p.name, elem, p.description)
			continue
		}
		fmt.sbprintf(&b, `"%s":{{"type":"%s","description":"%s"}}`, p.name, p.type_name, p.description)
	}
	strings.write_string(&b, "}")
	required_count := 0
	for p in e.params {
		if p.required do required_count += 1
	}
	if required_count > 0 {
		strings.write_string(&b, `,"required":[`)
		written := 0
		for p in e.params {
			if !p.required do continue
			if written > 0 do strings.write_string(&b, ",")
			fmt.sbprintf(&b, `"%s"`, p.name)
			written += 1
		}
		strings.write_string(&b, "]")
	}
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

_qualified_name :: proc(e: ToolEntry) -> string {
	if e.source_pkg != "" && e.source_pkg != _PKG_NAME {
		return fmt.tprintf("%s.%s", e.source_pkg, e.proc_name)
	}
	return e.proc_name
}

_relative_import_path :: proc(out_dir: string, source_path: string) -> string {
	out_dir_slash := strings.concatenate({out_dir, "/"}, context.temp_allocator)
	if strings.has_prefix(source_path, out_dir_slash) {
		return source_path[len(out_dir_slash):]
	}
	out_parts := strings.split(out_dir, "/", context.temp_allocator)
	src_parts := strings.split(source_path, "/", context.temp_allocator)
	common := 0
	for common < len(out_parts) && common < len(src_parts) && out_parts[common] == src_parts[common] {
		common += 1
	}
	b := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< len(out_parts) - common {
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

	entries: [dynamic]ToolEntry
	defer delete(entries)

	decls := db.get_comps_DeclInfo()
	_tools := db.get_comps(w, Mcp_Tool_GenComp)
	m := db.all_of(db.r(decls), db.r(_tools)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		tb := db.get(_tools, entity)
		for entry in tb.entries {
			append(&entries, entry)
		}
	}

	slice.sort_by(entries[:], proc(a, b: ToolEntry) -> bool {
		if a.tool_name != b.tool_name do return a.tool_name < b.tool_name
		return a.proc_name < b.proc_name
	})

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

	strings.write_string(&b, "package editor\n\n")
	for pkg in import_pkgs {
		fmt.sbprintf(&b, "import %s \"%s\"\n", pkg, packages_used[pkg])
	}
	if len(import_pkgs) > 0 do strings.write_string(&b, "\n")
	strings.write_string(&b, "// Code generated by mcp_tool_gen. Do not edit.\n\n")
	strings.write_string(&b, "_mcp_tool_table :: proc() -> []Mcp_Tool_Def {\n")
	strings.write_string(&b, "\t@(static) table := [?]Mcp_Tool_Def{\n")
	for e in entries {
		fmt.sbprintf(&b, "\t\t{{name = %q, description = %q, schema = %q, handler = %s}},\n",
			e.tool_name, e.description, _schema_json(e), _qualified_name(e))
	}
	strings.write_string(&b, "\t}\n")
	strings.write_string(&b, "\treturn table[:]\n")
	strings.write_string(&b, "}\n")

	db.emit(w, "moonhug/editor/mcp_tools_generated.odin", strings.to_string(b))
	return true
}
