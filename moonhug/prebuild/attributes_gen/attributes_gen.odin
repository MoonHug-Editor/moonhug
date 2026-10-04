package attributes_gen

// attributes_gen: the engine's attributes, declared, checked and documented.
//
// An attribute is DECLARED by `@(extension_point={attribute, target, fields})`
// on the declaration that receives its registrations, in the package it
// extends: @(toolbar) on editor.toolbar_add_item, @(component) on
// engine.component_register. That declaration's doc comment explains the
// attribute, and its package is the package the attribute extends.
//
//   lint     - every attribute used in scanned code is Odin's or declared, and
//              uses only the fields its declaration lists. The build passes
//              -ignore-unknown-attributes, so without this a misspelled
//              @(menu_iten) or `ordr=` compiles and silently does nothing.
//   generate - docs/reference/attributes/: one page per declared attribute
//              (explanation, extended package, fields, then every declaration
//              using it), and an index grouped by extended package. Also the
//              Reference section's own index, docs/reference/_index.md. Rewritten every build and
//              gitignored, since file:line changes on most edits.
//
// `target` is documentation only ("proc", "var", "type"), it is not checked.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import db "../gen_db"
import "../gen_facts"

REFERENCE_DIR :: "docs/reference"
OUT_DIR :: "docs/reference/attributes"

// Attributes that belong to Odin, plus the one that declares the others.
BUILTIN := []string{
	"extension_point",
	"private", "test", "init", "fini", "static", "deferred_in", "deferred_out", "deferred_in_out", "deferred_none",
	"require", "require_results", "export", "link_name", "link_prefix", "link_suffix", "link_section", "linkage",
	"objc_class", "objc_name", "objc_type", "objc_is_class_method", "objc_implement", "objc_superclass",
	"default_calling_convention", "optimization_mode", "cold", "no_instrumentation", "instrumentation_enter",
	"instrumentation_exit", "entry_point_only", "rodata", "thread_local", "extra_linker_flags", "builtin",
	"enable_target_feature", "require_target_feature", "fast_math", "disabled", "no_sanitize_address",
	"no_sanitize_memory", "no_sanitize_thread", "warning", "deprecated",
}

Declaration :: struct {
	attribute: string,
	target:    string,
	fields:    []string, // a trailing * matches by prefix: "param_*"
	anchor:    string,   // the declaration it sits on
	pkg_path:  string,   // "moonhug/editor": the package it extends
	where_:    string,   // repo-relative file:line
	doc:       string,   // the anchor's doc comment, markdown paragraphs
	uses:      [dynamic]Use,
}

Use :: struct {
	name:    string,
	pkg:     string,
	where_:  string,
	attr:    string, // "@(key k=v ...)" as rendered by gen_facts.attr_origin
	summary: string,
}

@(init)
_register :: proc "contextless" () {
	db.generator("attributes/generate", generate)
}

generate :: proc(w: ^db.World) -> bool {
	decls := db.get_comps_DeclInfo()
	attrs := db.get_comps(w, gen_facts.Attrs_GenComp)

	declared := make(map[string]^Declaration, context.temp_allocator)
	errors := make([dynamic]string, context.temp_allocator)

	// Pass 1: the declarations.
	m := db.all_of(db.r(decls), db.r(attrs)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		decl := db.get(decls, entity)
		for args in db.get(attrs, entity).attrs {
			if args.key != "extension_point" do continue
			where_ := fmt.tprintf("%s:%d", gen_facts.decl_rel_path(decl), decl.decl.pos.line)
			name := args.fields["attribute"]
			if name == "" {
				append(&errors, fmt.tprintf("%s: @(extension_point) on %s needs attribute=\"...\"", where_, decl.name))
				continue
			}
			if prev, dup := declared[name]; dup {
				append(&errors, fmt.tprintf("%s: @(%s) is declared twice, here and at %s", where_, name, prev.where_))
				continue
			}
			d := new(Declaration, context.temp_allocator)
			d^ = Declaration{
				attribute = name, target = args.fields["target"],
				fields = strings.fields(args.fields["fields"], context.temp_allocator),
				anchor = decl.name, pkg_path = decl.pkg_path, where_ = where_,
				doc = _doc_markdown(decl),
				uses = make([dynamic]Use, context.temp_allocator),
			}
			declared[name] = d
		}
	}

	// Pass 2: every use, checked against its declaration.
	m2 := db.all_of(db.r(decls), db.r(attrs)); defer db.matcher_destroy(&m2)
	for entity in db.matched(w, &m2) {
		decl := db.get(decls, entity)
		if decl.name == "" do continue
		for args in db.get(attrs, entity).attrs {
			if slice.contains(BUILTIN, args.key) do continue
			where_ := fmt.tprintf("%s:%d", gen_facts.decl_rel_path(decl), decl.decl.pos.line)
			d, ok := declared[args.key]
			if !ok {
				hint := ""
				if near := _nearest(args.key, declared); near != "" do hint = fmt.tprintf(", did you mean @(%s)?", near)
				append(&errors, fmt.tprintf("%s: unknown attribute @(%s) on %s%s", where_, args.key, decl.name, hint))
				continue
			}
			for k in args.fields do _check_field(d, k, decl.name, where_, &errors)
			for k in args.nested do _check_field(d, k, decl.name, where_, &errors)
			origin := gen_facts.attr_origin(args, gen_facts.decl_rel_path(decl), decl.decl.pos.line, decl.name)
			parts := strings.split(origin, "  ", context.temp_allocator)
			append(&d.uses, Use{name = decl.name, pkg = decl.pkg.name, where_ = where_, attr = parts[0], summary = _doc_summary(decl)})
		}
	}

	if len(errors) > 0 {
		slice.sort(errors[:])
		for e in errors do fmt.eprintfln("prebuild: %s", e)
		fmt.eprintln("prebuild: attributes are declared by @(extension_point) on the declaration that receives them, see docs/general/Documentation.md")
		return false
	}

	// Pass 3: the pages.
	list := make([dynamic]^Declaration, context.temp_allocator)
	for _, d in declared {
		if len(d.uses) == 0 do fmt.eprintfln("prebuild: warning: @(%s) is declared at %s but nothing uses it", d.attribute, d.where_)
		slice.sort_by(d.uses[:], proc(a, b: Use) -> bool {
			if a.pkg != b.pkg do return a.pkg < b.pkg
			return a.name < b.name
		})
		append(&list, d)
	}
	// Grouped by extended package, attributes by name inside a group.
	slice.sort_by(list[:], proc(a, b: ^Declaration) -> bool {
		if a.pkg_path != b.pkg_path do return a.pkg_path < b.pkg_path
		return a.attribute < b.attribute
	})
	os.make_directory(REFERENCE_DIR)
	os.make_directory(OUT_DIR)
	_sweep_stale(list[:])
	db.emit(w, REFERENCE_DIR + "/_index.md", "---\ntitle: \"Reference\"\ndescription: \"Generated from the source: every attribute and every engine and editor package\"\nweight: 40\n---\n\nGenerated, not edited by hand and not committed.\n\n- [Attributes](attributes/_index.md) — how code extends the engine and the editor, grouped by the package each attribute extends. Written on every build.\n- [Packages](packages/_index.md) — every public declaration of each engine and editor package, from `odin doc`. Written by `mh docs`.\n")
	index := strings.builder_make()
	defer strings.builder_destroy(&index)
	strings.write_string(&index, "---\ntitle: \"Attributes\"\ndescription: \"Every attribute, the package it extends, and what is registered through it\"\nweight: 10\n---\n\n")
	strings.write_string(&index, "Generated on every build by `moonhug/prebuild/attributes_gen`. Not edited by hand and not committed.\n\n")
	strings.write_string(&index, "Attributes are how code extends the engine and the editor. Each is grouped under the package it extends, with its uses counted. An attribute's page explains it and lists every declaration using it.\n")
	group := ""
	for d, i in list {
		if d.pkg_path != group {
			group = d.pkg_path
			fmt.sbprintf(&index, "\n## `%s`\n\n", _import_path(group))
		}
		fmt.sbprintf(&index, "- [@(%s)](%s.md) — %s (%d)\n", d.attribute, d.attribute, _first_sentence(d.doc), len(d.uses))
		_emit_page(w, d, (i + 1) * 10)
	}
	db.emit(w, OUT_DIR + "/_index.md", strings.to_string(index))
	return true
}

@(private = "file")
_emit_page :: proc(w: ^db.World, d: ^Declaration, weight: int) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	desc, _ := strings.replace_all(_first_sentence(d.doc), "\"", "\\\"", context.temp_allocator)
	fmt.sbprintf(&b, "---\ntitle: \"@(%s)\"\ndescription: \"%s\"\nweight: %d\ntags: [\"reference\", \"%s\"]\n---\n\n", d.attribute, desc, weight, d.attribute)
	pkg := _import_path(d.pkg_path)
	if slug, ok := _package_page(d.pkg_path); ok {
		fmt.sbprintf(&b, "**Extends** [`%s`](../packages/%s.md)", pkg, slug)
	} else {
		fmt.sbprintf(&b, "**Extends** `%s`", pkg)
	}
	if d.target != "" do fmt.sbprintf(&b, " · **On** %s", d.target)
	if len(d.fields) > 0 {
		strings.write_string(&b, " · **Fields**")
		for f, i in d.fields do fmt.sbprintf(&b, "%s `%s`", i == 0 ? "" : ",", f)
	}
	fmt.sbprintf(&b, "\n\nDeclared on `%s` at `%s`.\n\n", d.anchor, d.where_)
	strings.write_string(&b, d.doc)
	fmt.sbprintf(&b, "\n\n## Uses (%d)\n\n", len(d.uses))
	if len(d.uses) == 0 {
		strings.write_string(&b, "Nothing uses it yet.\n")
	} else {
		strings.write_string(&b, "| Declaration | Package | Where | Attribute | Summary |\n|---|---|---|---|---|\n")
		for u in d.uses do fmt.sbprintf(&b, "| `%s` | %s | `%s` | `%s` | %s |\n", u.name, u.pkg, u.where_, _cell(u.attr), _cell(u.summary))
	}
	db.emit(w, fmt.tprintf("%s/%s.md", OUT_DIR, d.attribute), strings.to_string(b))
}

// Removes generated pages this build no longer writes: an attribute that was
// renamed or undeclared, and pages from the layout where attribute pages sat
// directly in docs/reference. The folder is mounted into the site whole, so a
// leftover would still be published.
@(private = "file")
_sweep_stale :: proc(list: []^Declaration) {
	keep := make(map[string]bool, context.temp_allocator)
	keep["_index.md"] = true
	for d in list do keep[fmt.tprintf("%s.md", d.attribute)] = true
	for dir in ([]string{OUT_DIR, REFERENCE_DIR}) {
		handle, oerr := os.open(dir)
		if oerr != nil do continue
		defer os.close(handle)
		entries, rerr := os.read_dir(handle, -1, context.temp_allocator)
		if rerr != nil do continue
		for e in entries {
			if e.type == .Directory || !strings.has_suffix(e.name, ".md") || e.name == "_index.md" do continue
			if dir == OUT_DIR && keep[e.name] do continue
			os.remove(fmt.tprintf("%s/%s", dir, e.name))
		}
	}
}

@(private = "file")
_check_field :: proc(d: ^Declaration, key: string, name: string, where_: string, errors: ^[dynamic]string) {
	for f in d.fields {
		if f == key do return
		if strings.has_suffix(f, "*") && strings.has_prefix(key, f[:len(f) - 1]) do return
	}
	known := strings.join(d.fields, ", ", context.temp_allocator)
	append(errors, fmt.tprintf("%s: @(%s) on %s has no field `%s` (its fields: %s)", where_, d.attribute, name, key, known))
}

// "moonhug/editor/inspector" -> "moonhug:editor/inspector".
@(private = "file")
_import_path :: proc(pkg_path: string) -> string {
	if strings.has_prefix(pkg_path, "moonhug/") do return fmt.tprintf("moonhug:%s", pkg_path[len("moonhug/"):])
	return pkg_path
}

// The `odin doc` page `mh docs` writes for this package, when it writes one:
// engine, editor and engine_editor packages only.
@(private = "file")
_package_page :: proc(pkg_path: string) -> (slug: string, ok: bool) {
	for root in ([]string{"moonhug/engine", "moonhug/editor", "moonhug/engine_editor"}) {
		if pkg_path == root || strings.has_prefix(pkg_path, fmt.tprintf("%s/", root)) {
			s, _ := strings.replace_all(pkg_path[len("moonhug/"):], "/", "_", context.temp_allocator)
			return s, true
		}
	}
	return "", false
}

// The closest declared name, for a typo. "" when nothing is close.
@(private = "file")
_nearest :: proc(key: string, declared: map[string]^Declaration) -> string {
	best, best_d := "", 3
	for name in declared {
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

// The doc comment as markdown: markers stripped, a blank comment line is a
// paragraph break, other lines join with a space.
@(private = "file")
_doc_markdown :: proc(decl: ^db.DeclInfo) -> string {
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

@(private = "file")
_first_sentence :: proc(text: string) -> string {
	s := text
	if p := strings.index(s, "\n\n"); p >= 0 do s = s[:p]
	if dot := strings.index(s, ". "); dot >= 0 do s = s[:dot + 1]
	return s
}

@(private = "file")
_doc_summary :: proc(decl: ^db.DeclInfo) -> string {
	return _first_sentence(_doc_markdown(decl))
}

// A markdown table cell: no pipes, no newlines.
@(private = "file")
_cell :: proc(s: string) -> string {
	out, _ := strings.replace_all(s, "|", "\\|", context.temp_allocator)
	out, _ = strings.replace_all(out, "\n", " ", context.temp_allocator)
	return out
}
