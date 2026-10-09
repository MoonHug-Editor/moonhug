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
//              Reference section's own index, docs/reference/_index.md, which
//              links the field tag pages field_tags_gen writes. Written when
//              `mh docs` runs, gitignored, since file:line changes on most
//              edits. The checks run on every build.
//
// `target` is documentation only ("proc", "var", "type"), it is not checked.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "../gen_core"
import db "../gen_db"
import "../gen_facts"

REFERENCE_DIR :: "docs/reference"
OUT_DIR :: "docs/reference/attributes"

// Attributes that belong to Odin, plus the two the generators read on any
// declaration: extension_point declares an attribute, and reserved
// (gen_facts.is_reserved) keeps a declaration nothing uses yet without a warning.
BUILTIN := []string{
	"extension_point", "reserved",
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
	reserved:  bool,     // @(reserved) on the anchor: no warning while nothing uses it
	uses:      [dynamic]Use,
}

Use :: struct {
	name:    string,
	pkg:     string,
	where_:  string,
	attr:    string, // "@(key k=v ...)" as rendered by gen_facts.attr_origin
	summary: string,
	order:   int,    // the use's `order` field, for attributes that have one
	key:     string, // the use's `key` field, for attributes that have one: "Init"
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
				doc = gen_facts.doc_markdown(decl),
				reserved = gen_facts.is_reserved(decl),
				uses = make([dynamic]Use, context.temp_allocator),
			}
			declared[name] = d
		}
	}

	// Pass 2: every use, checked against its declaration.
	names := make([dynamic]string, context.temp_allocator)
	for name in declared do append(&names, name)
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
				if near := gen_facts.nearest_name(args.key, names[:]); near != "" do hint = fmt.tprintf(", did you mean @(%s)?", near)
				append(&errors, fmt.tprintf("%s: unknown attribute @(%s) on %s%s", where_, args.key, decl.name, hint))
				continue
			}
			for k in args.fields do _check_field(d, k, decl.name, where_, &errors)
			for k in args.nested do _check_field(d, k, decl.name, where_, &errors)
			origin := gen_facts.attr_origin(args, gen_facts.decl_rel_path(decl), decl.decl.pos.line, decl.name)
			parts := strings.split(origin, "  ", context.temp_allocator)
			append(&d.uses, Use{name = decl.name, pkg = decl.pkg.name, where_ = where_, attr = parts[0], summary = _doc_summary(decl), order = gen_facts.attr_int(args, "order"), key = gen_facts.attr_keyname(args, "key")})
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
		if len(d.uses) == 0 && !d.reserved do fmt.eprintfln("prebuild: warning: @(%s) is declared at %s but nothing uses it", d.attribute, d.where_)
		// An attribute with a `key` field groups its uses by key, in the
		// order the owner registered (gen_facts.register_attr_key_order).
		// One with an `order` field lists them as the generated dispatcher
		// calls them: by order, then package, then name.
		if slice.contains(d.fields, "key") {
			attribute := d.attribute
			context.user_ptr = &attribute
			slice.sort_by(d.uses[:], proc(a, b: Use) -> bool {
				attribute := (cast(^string)context.user_ptr)^
				ia, descending := gen_facts.attr_key_index(attribute, a.key)
				ib, _ := gen_facts.attr_key_index(attribute, b.key)
				if ia != ib do return ia < ib
				if a.key != b.key do return a.key < b.key
				if a.order != b.order do return a.order > b.order if descending else a.order < b.order
				if a.pkg != b.pkg do return a.pkg < b.pkg
				return a.name < b.name
			})
		} else if slice.contains(d.fields, "order") {
			slice.sort_by(d.uses[:], proc(a, b: Use) -> bool {
				if a.order != b.order do return a.order < b.order
				if a.pkg != b.pkg do return a.pkg < b.pkg
				return a.name < b.name
			})
		} else {
			slice.sort_by(d.uses[:], proc(a, b: Use) -> bool {
				if a.pkg != b.pkg do return a.pkg < b.pkg
				return a.name < b.name
			})
		}
		append(&list, d)
	}
	// Grouped by layer (Host, Editor, then each plugin by name), by extending
	// package inside a layer, attributes by name inside a package.
	slice.sort_by(list[:], proc(a, b: ^Declaration) -> bool {
		la, oa := gen_facts.pkg_layer(a.pkg_path)
		lb, ob := gen_facts.pkg_layer(b.pkg_path)
		if oa != ob do return oa < ob
		if la != lb do return la < lb
		if a.pkg_path != b.pkg_path do return a.pkg_path < b.pkg_path
		return a.attribute < b.attribute
	})
	// The checks above run on every build, the pages only for `mh docs`.
	if !gen_facts.write_reference_pages do return true
	os.make_directory(REFERENCE_DIR)
	os.make_directory(OUT_DIR)
	_sweep_stale(list[:])
	db.emit(w, REFERENCE_DIR + "/_index.md", "---\ntitle: \"Reference\"\ndescription: \"Generated from the source: every attribute, field tag and naming convention, and every package\"\nweight: 40\n---\n\nGenerated, not edited by hand and not committed.\n\n- [Attributes](attributes/_index.md) — how code extends the editor, grouped by the layer and the package that declare each attribute. Written by `mh docs`.\n- [Field tags](field_tags/_index.md) — the struct field tag keys the inspector reads, grouped by the layer that declares each key. Written by `mh docs`.\n- [Naming](naming/_index.md) — the procs generators find by their name, grouped by the layer whose generator declares the convention. Written by `mh docs`.\n- [Packages](packages/_index.md) — every public declaration of each package, from `odin doc -doc-format`. Written by `mh docs`.\n")
	index := strings.builder_make()
	defer strings.builder_destroy(&index)
	strings.write_string(&index, "---\ntitle: \"Attributes\"\ndescription: \"Every attribute, the package it extends, and what is registered through it\"\nweight: 10\n---\n\n")
	strings.write_string(&index, "Generated by `moonhug/prebuild/attributes_gen` when `mh docs` runs. Not edited by hand and not committed.\n\n")
	strings.write_string(&index, "Attributes are how code extends the editor. They are grouped by the layer that declares them, `host`, `editor` or a plugin's name, then by the package, with uses counted. An attribute's page explains it and lists every declaration using it.\n")
	// One folder per layer, so the site's left pane shows Host, Editor and
	// each plugin as its own group. The top index lists the layers, a layer's
	// index lists its attributes by extending package.
	strings.write_string(&index, "\n")
	layer_index := strings.builder_make()
	defer strings.builder_destroy(&layer_index)
	layer := ""
	layer_order := 0
	layer_count := 0
	group := ""
	flush_layer :: proc(w: ^db.World, layer: string, b: ^strings.Builder) {
		if layer == "" do return
		db.emit(w, fmt.tprintf("%s/%s/_index.md", OUT_DIR, layer), strings.to_string(b^))
		strings.builder_reset(b)
	}
	for d, i in list {
		if l, o := gen_facts.pkg_layer(d.pkg_path); l != layer {
			flush_layer(w, layer, &layer_index)
			if layer != "" do fmt.sbprintf(&index, "- [%s](%s/_index.md) — %d attributes\n", layer, layer, layer_count)
			layer = l
			layer_order = o
			layer_count = 0
			group = ""
			os.make_directory(fmt.tprintf("%s/%s", OUT_DIR, layer))
			fmt.sbprintf(&layer_index, "---\ntitle: \"%s\"\ndescription: \"Attributes declared by %s, by the package each one extends\"\nweight: %d\n---\n\nGenerated by `moonhug/prebuild/attributes_gen` when `mh docs` runs. Not edited by hand and not committed.\n", layer, gen_facts.layer_noun(layer, layer_order), (layer_order + 1) * 10 + (0 if layer_order < 2 else _plugin_rank(list[:], l)))
		}
		if d.pkg_path != group {
			group = d.pkg_path
			fmt.sbprintf(&layer_index, "\n## `%s`\n\n", gen_facts.pkg_import_path(group))
		}
		layer_count += 1
		fmt.sbprintf(&layer_index, "- [@(%s)](%s.md) — %s (%d)\n", d.attribute, d.attribute, gen_facts.first_sentence(d.doc), len(d.uses))
		_emit_page(w, d, (i + 1) * 10)
	}
	flush_layer(w, layer, &layer_index)
	if layer != "" do fmt.sbprintf(&index, "- [%s](%s/_index.md) — %d attributes\n", layer, layer, layer_count)
	db.emit(w, OUT_DIR + "/_index.md", strings.to_string(index))
	return true
}


// Plugins sort after the host and the editor, by name: their index weight is
// the position among the plugins that declare attributes.
@(private = "file")
_plugin_rank :: proc(list: []^Declaration, layer: string) -> int {
	rank := 0
	seen := ""
	for d in list {
		l, o := gen_facts.pkg_layer(d.pkg_path)
		if o != 2 || l == seen do continue
		seen = l
		rank += 1
		if l == layer do return rank
	}
	return rank
}

@(private = "file")
_emit_page :: proc(w: ^db.World, d: ^Declaration, weight: int) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	desc, _ := strings.replace_all(gen_facts.first_sentence(d.doc), "\"", "\\\"", context.temp_allocator)
	fmt.sbprintf(&b, "---\ntitle: \"@(%s)\"\ndescription: \"%s\"\nweight: %d\ntags: [\"reference\", \"%s\"]\n---\n\n", d.attribute, desc, weight, d.attribute)
	pkg := gen_facts.pkg_import_path(d.pkg_path)
	if page, ok := gen_facts.pkg_page(d.pkg_path); ok {
		fmt.sbprintf(&b, "**Extends** [`%s`](../../%s)", pkg, page)
	} else {
		fmt.sbprintf(&b, "**Extends** `%s`", pkg)
	}
	if d.target != "" do fmt.sbprintf(&b, " · **On** %s", d.target)
	if len(d.fields) > 0 {
		strings.write_string(&b, " · **Fields**")
		for f, i in d.fields do fmt.sbprintf(&b, "%s `%s`", i == 0 ? "" : ",", f)
	}
	fmt.sbprintf(&b, "\n\nDeclared on `%s` at %s.\n\n", d.anchor, gen_core.SourceLinkAt(d.where_))
	strings.write_string(&b, d.doc)
	fmt.sbprintf(&b, "\n\n## Uses (%d)\n\n", len(d.uses))
	if len(d.uses) == 0 {
		strings.write_string(&b, "Nothing uses it yet.\n")
	} else if slice.contains(d.fields, "key") {
		// One table per key, in the owner's order, so a reader sees what
		// runs at each key and in what order.
		key := "\x00"
		for u in d.uses {
			if u.key != key {
				key = u.key
				fmt.sbprintf(&b, "\n### %s\n\n", key if key != "" else "(no key)")
				strings.write_string(&b, "| Declaration | Package | Where | Attribute | Summary |\n|---|---|---|---|---|\n")
			}
			fmt.sbprintf(&b, "| `%s` | %s | %s | `%s` | %s |\n", u.name, u.pkg, gen_core.SourceLinkAt(u.where_), gen_facts.md_cell(u.attr), gen_facts.md_cell(u.summary))
		}
	} else {
		strings.write_string(&b, "| Declaration | Package | Where | Attribute | Summary |\n|---|---|---|---|---|\n")
		for u in d.uses do fmt.sbprintf(&b, "| `%s` | %s | %s | `%s` | %s |\n", u.name, u.pkg, gen_core.SourceLinkAt(u.where_), gen_facts.md_cell(u.attr), gen_facts.md_cell(u.summary))
	}
	layer, _ := gen_facts.pkg_layer(d.pkg_path)
	db.emit(w, fmt.tprintf("%s/%s/%s.md", OUT_DIR, layer, d.attribute), strings.to_string(b))
}

// Removes generated pages this build no longer writes: an attribute that was
// renamed or undeclared, and pages from the layout where attribute pages sat
// directly in docs/reference. The folder is mounted into the site whole, so a
// leftover would still be published.
@(private = "file")
_sweep_stale :: proc(list: []^Declaration) {
	// "<layer slug>/<attribute>.md" for every page this build writes.
	keep := make(map[string]bool, context.temp_allocator)
	layers := make(map[string]bool, context.temp_allocator)
	for d in list {
		layer, _ := gen_facts.pkg_layer(d.pkg_path)
		layers[layer] = true
		keep[fmt.tprintf("%s/%s.md", layer, d.attribute)] = true
	}
	// Pages directly in the reference or attributes folder are from older
	// layouts, a layer folder this build does not write is gone whole.
	for dir in ([]string{OUT_DIR, REFERENCE_DIR}) {
		for e in gen_facts.dir_entries(dir) {
			path := fmt.tprintf("%s/%s", dir, e.name)
			if e.type == .Directory {
				if dir == OUT_DIR && !layers[e.name] do os.remove_all(path)
				continue
			}
			if !strings.has_suffix(e.name, ".md") || e.name == "_index.md" do continue
			os.remove(path)
		}
	}
	for slug in layers {
		dir := fmt.tprintf("%s/%s", OUT_DIR, slug)
		for e in gen_facts.dir_entries(dir) {
			if e.type == .Directory || e.name == "_index.md" do continue
			if keep[fmt.tprintf("%s/%s", slug, e.name)] do continue
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

@(private = "file")
_doc_summary :: proc(decl: ^db.DeclInfo) -> string {
	return gen_facts.first_sentence(gen_facts.doc_markdown(decl))
}
