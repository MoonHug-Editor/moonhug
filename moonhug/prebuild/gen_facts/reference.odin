package gen_facts

// Helpers for the generators that write docs/reference: attributes_gen and
// field_tags_gen. Both group their pages by layer, render doc comments as
// markdown and suggest the nearest declared name for a typo.

import "core:fmt"
import "core:os"
import "core:strings"
import "../gen_core"
import db "../gen_db"

// The layer a package belongs to, named like its folder (host, editor, the
// plugin's name), and the order layers are listed in: host, editor, then
// every plugin by name.
pkg_layer :: proc(pkg_path: string) -> (name: string, order: int) {
	if strings.has_prefix(pkg_path, "moonhug/host") || strings.has_prefix(pkg_path, "moonhug/registration") do return "host", 0
	if strings.has_prefix(pkg_path, "moonhug/editor") do return "editor", 1
	if strings.has_prefix(pkg_path, "moonhug/packages/") {
		rest := pkg_path[len("moonhug/packages/"):]
		if slash := strings.index_byte(rest, '/'); slash >= 0 do rest = rest[:slash]
		return rest, 2
	}
	return pkg_path, 3
}

// What a layer is, for a sentence: "the editor shell", "the audio plugin".
layer_noun :: proc(layer: string, order: int) -> string {
	switch order {
	case 0: return "the host packages"
	case 1: return "the editor shell"
	}
	return fmt.tprintf("the %s plugin", layer)
}

// "moonhug/editor/inspector" -> "moonhug:editor/inspector".
pkg_import_path :: proc(pkg_path: string) -> string {
	if strings.has_prefix(pkg_path, "moonhug/") do return fmt.tprintf("moonhug:%s", pkg_path[len("moonhug/"):])
	return pkg_path
}

// The import path `alias` names in the declaration's file, without quotes.
file_import :: proc(d: ^db.DeclInfo, alias: string) -> (string, bool) {
	return gen_core.FileImportPath(d.file, alias)
}

// The declaration as a constant compound literal of a named type, see
// gen_core.Const_Lit.
Const_Lit :: gen_core.Const_Lit
const_lit :: proc(d: ^db.DeclInfo) -> (Const_Lit, bool) {
	return gen_core.ConstLit(d.decl)
}

// Each parameter of a proc declaration as written, see gen_core.ProcParams.
proc_params :: proc(d: ^db.DeclInfo) -> []string {
	if d.file == nil do return nil
	return gen_core.ProcParams(d.decl, d.file.src)
}

// The doc comment as markdown: markers stripped, a blank comment line is a
// paragraph break, other lines join with a space.
doc_markdown :: proc(decl: ^db.DeclInfo) -> string {
	if decl.decl == nil || decl.decl.docs == nil do return ""
	b := strings.builder_make(context.temp_allocator)
	para := false
	for tok in decl.decl.docs.list {
		line := tok.text
		if strings.has_prefix(line, "//") do line = line[2:]
		if strings.has_prefix(line, "/*") do line = line[2:]
		if strings.has_suffix(line, "*/") do line = line[:len(line) - 2]
		line = strings.trim_space(line)
		if line == "" {
			if para do strings.write_string(&b, "\n\n")
			para = false
			continue
		}
		if para do strings.write_byte(&b, ' ')
		strings.write_string(&b, line)
		para = true
	}
	return strings.trim_space(strings.to_string(b))
}

// The first sentence of a markdown text, the summary on an index.
first_sentence :: proc(text: string) -> string {
	s := text
	if p := strings.index(s, "\n\n"); p >= 0 do s = s[:p]
	if dot := strings.index(s, ". "); dot >= 0 do s = s[:dot + 1]
	return s
}

// Whether the reference generators write their pages under docs/reference.
// Their checks run on every build, the pages only when `mh docs` passes
// --docs to the prebuild (prebuild.odin main sets this).
write_reference_pages: bool

// The Packages reference page of a package, relative to the reference root:
// moonhug/host/core is packages/host/core.md, moonhug/editor/undo is
// packages/editor/undo.md, moonhug/packages/engine/editor/undo is
// packages/engine/editor_undo.md. mh docs writes the pages (tools/mh/
// package_docs.odin, pkg_page there is the same rule, keep the two in step).
pkg_page :: proc(pkg_path: string) -> (path: string, ok: bool) {
	under :: proc(path, root: string) -> (rest: string, ok: bool) {
		if path == root do return "", true
		if strings.has_prefix(path, root) && path[len(root)] == '/' do return path[len(root) + 1:], true
		return "", false
	}
	flat :: proc(s: string) -> string {
		out, _ := strings.replace_all(s, "/", "_", context.temp_allocator)
		return out
	}
	if rest, in_host := under(pkg_path, "moonhug/host"); in_host do return fmt.tprintf("packages/host/%s.md", rest == "" ? "host" : flat(rest)), true
	if _, in_reg := under(pkg_path, "moonhug/registration"); in_reg do return "packages/host/registration.md", true
	if rest, in_editor := under(pkg_path, "moonhug/editor"); in_editor do return fmt.tprintf("packages/editor/%s.md", rest == "" ? "editor" : flat(rest)), true
	if rest, in_pkgs := under(pkg_path, "moonhug/packages"); in_pkgs {
		name, sub := rest, ""
		if slash := strings.index_byte(rest, '/'); slash >= 0 do name, sub = rest[:slash], rest[slash + 1:]
		return fmt.tprintf("packages/%s/%s.md", name, sub == "" ? name : flat(sub)), true
	}
	return "", false
}

// The closest of `names` to `key`, for a typo. "" when nothing is close.
nearest_name :: proc(key: string, names: []string) -> string {
	best, best_d := "", 3
	for name in names {
		if d := _distance(key, name); d < best_d do best, best_d = name, d
	}
	return best
}

@(private = "file")
_distance :: proc(a, b: string) -> int {
	prev := make([]int, len(b) + 1, context.temp_allocator)
	cur := make([]int, len(b) + 1, context.temp_allocator)
	for j in 0 ..= len(b) do prev[j] = j
	for i in 1 ..= len(a) {
		cur[0] = i
		for j in 1 ..= len(b) {
			cost := a[i - 1] == b[j - 1] ? 0 : 1
			cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
		}
		prev, cur = cur, prev
	}
	return prev[len(b)]
}

// A markdown table cell: no pipes, no newlines.
md_cell :: proc(s: string) -> string {
	out, _ := strings.replace_all(s, "|", "\\|", context.temp_allocator)
	out, _ = strings.replace_all(out, "\n", " ", context.temp_allocator)
	return out
}

// The entries of a directory, nil when it cannot be read (temp).
dir_entries :: proc(dir: string) -> []os.File_Info {
	handle, oerr := os.open(dir)
	if oerr != nil do return nil
	defer os.close(handle)
	entries, rerr := os.read_dir(handle, -1, context.temp_allocator)
	if rerr != nil do return nil
	return entries
}
