package field_tags_gen

// field_tags_gen: struct field tag keys, declared, checked and documented.
//
// A key is DECLARED as a package-level constant whose value is a Field_Tag
// literal: `TAG_REF :: Field_Tag{key = "ref", form = .Value}` in package
// inspector, or `inspector.Field_Tag{...}` in a package that imports
// moonhug:editor/inspector, which is how a plugin declares its own keys. The
// constant's doc comment explains the key, its first sentence is the summary.
//
//   lint     - every key in every struct field tag of the scanned code is
//              declared and written in its declared form, a Value key comes
//              where Odin's reflect.struct_tag_lookup reads it, and only a
//              Call key repeats. Without this a misspelled key compiles and
//              silently does nothing.
//   generate - docs/reference/field_tags/: one folder per layer (host, editor,
//              each plugin) with one page per key (form, declaration,
//              explanation, every field using it), the `decor` page listing
//              every decorator decorator_gen resolves. Written when `mh docs`
//              runs, gitignored, since file:line changes on most edits. The
//              checks run on every build.
//
// Generated files and test packages are not checked: the scan skips tests,
// and a generated file's tags come from its generator.

import "core:fmt"
import "core:os"
import "core:path/slashpath"
import "core:slice"
import "core:strings"
import db "../gen_db"
import "../gen_facts"

OUT_DIR :: "docs/reference/field_tags"

// The package that declares Field_Tag, and the decorator procs decorator_gen
// calls from its generated file there.
INSPECTOR_PKG :: "moonhug/editor/inspector"
INSPECTOR_IMPORT :: "moonhug:editor/inspector"
DECORATOR_PREFIX :: "decorator_"

// Field_Tag_Form, as the declarations name it.
Form :: enum {
	Value, // key:"text"
	Flag,  // key, or key:""
	Call,  // key:name(args) or key:name
}

Declaration :: struct {
	key:        string,
	form:       Form,
	const_name: string, // TAG_REF
	pkg_path:   string, // the declaring package
	where_:     string, // repo-relative file:line
	doc:        string, // the constant's doc comment, markdown paragraphs
	uses:       [dynamic]Use,
}

Use :: struct {
	field:  string, // Struct.field
	pkg:    string,
	where_: string,
	tag:    string, // the whole tag as written, whitespace runs collapsed
}

// One key of a tag as written.
Token :: struct {
	key:  string,
	text: string, // after the colon: `"text"` with its quotes, `name(args)`, "" for a bare word
	form: Form,
}

Decorator :: struct {
	name:   string, // as written in a tag: `min` for decorator_min
	params: string, // the parameters after ctx, as written
	doc:    string, // first sentence of the doc comment
	where_: string,
	uses:   int,
}

@(init)
_register :: proc "contextless" () {
	db.generator("field_tags/generate", generate)
}

generate :: proc(w: ^db.World) -> bool {
	decls := db.get_comps_DeclInfo()
	fields := db.get_comps(w, gen_facts.Fields_GenComp)

	declared := make(map[string]^Declaration, context.temp_allocator)
	errors := make([dynamic]string, context.temp_allocator)

	// Pass 1: the declarations, Field_Tag constants.
	for &decl in decls.rows[:db.comps_len(decls)] {
		if decl.decl == nil || decl.name == "" do continue
		lit, ok := gen_facts.const_lit(&decl)
		if !ok || !_is_field_tag_type(&decl, lit.type) do continue
		where_ := fmt.tprintf("%s:%d", gen_facts.decl_rel_path(&decl), decl.decl.pos.line)
		key := lit.fields["key"]
		form_name := lit.fields["form"]
		if dot := strings.last_index_byte(form_name, '.'); dot >= 0 do form_name = form_name[dot + 1:]
		if key == "" {
			append(&errors, fmt.tprintf("%s: Field_Tag %s needs key = \"...\"", where_, decl.name))
			continue
		}
		form: Form
		switch form_name {
		case "Value": form = .Value
		case "Flag":  form = .Flag
		case "Call":  form = .Call
		case "":
			append(&errors, fmt.tprintf("%s: Field_Tag %s needs form = .Value, .Flag or .Call", where_, decl.name))
			continue
		case:
			append(&errors, fmt.tprintf("%s: Field_Tag %s has an unknown form `%s`, it is .Value, .Flag or .Call", where_, decl.name, form_name))
			continue
		}
		if prev, dup := declared[key]; dup {
			append(&errors, fmt.tprintf("%s: field tag `%s` is declared twice, here as %s and at %s as %s", where_, key, decl.name, prev.where_, prev.const_name))
			continue
		}
		d := new(Declaration, context.temp_allocator)
		d^ = Declaration{
			key = key, form = form, const_name = decl.name, pkg_path = decl.pkg_path, where_ = where_,
			doc = gen_facts.doc_markdown(&decl),
			uses = make([dynamic]Use, context.temp_allocator),
		}
		declared[key] = d
	}
	names := make([dynamic]string, context.temp_allocator)
	for key in declared do append(&names, key)

	// Pass 2: every field tag, checked against the declarations.
	decorator_uses := make(map[string]int, context.temp_allocator)
	m := db.all_of(db.r(decls), db.r(fields)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		decl := db.get(decls, entity)
		if decl.name == "" || _skipped(decl) do continue
		rel := gen_facts.decl_rel_path(decl)
		for f in db.get(fields, entity).fields {
			if strings.trim_space(f.tag) == "" do continue
			field := fmt.tprintf("%s.%s", decl.name, f.name)
			where_ := fmt.tprintf("%s:%d", rel, f.line)
			tokens, perr := _parse_tag(f.tag)
			if perr != "" {
				append(&errors, fmt.tprintf("%s: cannot read the field tag on `%s`: %s", where_, field, perr))
				continue
			}
			visible := _lookup_visible(f.tag)
			seen := make(map[string]bool, context.temp_allocator)
			for tok in tokens {
				d, ok := declared[tok.key]
				if !ok {
					hint := ""
					if near := gen_facts.nearest_name(tok.key, names[:]); near != "" do hint = fmt.tprintf(", did you mean `%s`?", near)
					append(&errors, fmt.tprintf("%s: unknown field tag `%s` on `%s`%s", where_, tok.key, field, hint))
					continue
				}
				if !_form_fits(d.form, tok) {
					append(&errors, fmt.tprintf("%s: field tag `%s` on `%s` is written as %s, it is %s", where_, tok.key, field, _form_noun(tok.form), _form_written(d.key, d.form)))
					continue
				}
				if seen[tok.key] {
					if d.form != .Call do append(&errors, fmt.tprintf("%s: field tag `%s` appears twice on `%s`, only a call may repeat", where_, tok.key, field))
					if tok.form == .Call do decorator_uses[_call_name(tok.text)] += 1
					continue
				}
				seen[tok.key] = true
				if d.form == .Value && !visible[tok.key] {
					append(&errors, fmt.tprintf("%s: field tag `%s` on `%s` comes after a bare word, a call or a line break, where Odin's reflect.struct_tag_lookup stops reading, move it to the front", where_, tok.key, field))
					continue
				}
				if tok.form == .Call do decorator_uses[_call_name(tok.text)] += 1
				append(&d.uses, Use{field = field, pkg = decl.pkg.name, where_ = where_, tag = _collapse(f.tag)})
			}
		}
	}

	if len(errors) > 0 {
		slice.sort(errors[:])
		for e in errors do fmt.eprintfln("prebuild: %s", e)
		fmt.eprintln("prebuild: field tag keys are declared as Field_Tag constants and read with tag_value / tag_has, see docs/general/Documentation.md")
		return false
	}

	// Pass 3: the pages.
	list := make([dynamic]^Declaration, context.temp_allocator)
	for _, d in declared {
		if len(d.uses) == 0 do fmt.eprintfln("prebuild: warning: field tag `%s` is declared at %s but no field uses it", d.key, d.where_)
		slice.sort_by(d.uses[:], proc(a, b: Use) -> bool {
			if a.pkg != b.pkg do return a.pkg < b.pkg
			return a.field < b.field
		})
		append(&list, d)
	}
	// Grouped by layer (host, editor, then each plugin by name), by declaring
	// package inside a layer, keys by name inside a package.
	slice.sort_by(list[:], proc(a, b: ^Declaration) -> bool {
		la, oa := gen_facts.pkg_layer(a.pkg_path)
		lb, ob := gen_facts.pkg_layer(b.pkg_path)
		if oa != ob do return oa < ob
		if la != lb do return la < lb
		if a.pkg_path != b.pkg_path do return a.pkg_path < b.pkg_path
		return a.key < b.key
	})
	decorators := _decorators(w, decorator_uses)

	// The checks above run on every build, the pages only for `mh docs`.
	if !gen_facts.write_reference_pages do return true
	os.make_directory("docs/reference")
	os.make_directory(OUT_DIR)
	_sweep_stale(list[:])

	index := strings.builder_make()
	defer strings.builder_destroy(&index)
	strings.write_string(&index, "---\ntitle: \"Field tags\"\ndescription: \"Every struct field tag key, the form it is written in, and the fields that use it\"\nweight: 15\n---\n\n")
	strings.write_string(&index, "Generated by `moonhug/prebuild/field_tags_gen` when `mh docs` runs. Not edited by hand and not committed.\n\n")
	strings.write_string(&index, "A field tag tells the inspector how to draw a field and what it accepts: `ref:\"Transform\"`, `ext:\"mat\" expand`, `decor:min(0)`. Each key is declared as a `Field_Tag` constant, and the prebuild stops on a key that is not declared or not written in its declared form. [Documentation](../../general/Documentation.md) explains how to declare one. Keys are grouped by the layer that declares them, `host`, `editor` or a plugin's name, with uses counted.\n\n")
	layer_index := strings.builder_make()
	defer strings.builder_destroy(&layer_index)
	layer := ""
	layer_count := 0
	plugin_rank := 0
	group := ""
	flush_layer :: proc(w: ^db.World, layer: string, b: ^strings.Builder) {
		if layer == "" do return
		db.emit(w, fmt.tprintf("%s/%s/_index.md", OUT_DIR, layer), strings.to_string(b^))
		strings.builder_reset(b)
	}
	for d, i in list {
		if l, o := gen_facts.pkg_layer(d.pkg_path); l != layer {
			flush_layer(w, layer, &layer_index)
			if layer != "" do fmt.sbprintf(&index, "- [%s](%s/_index.md) — %d %s\n", layer, layer, layer_count, layer_count == 1 ? "key" : "keys")
			layer = l
			layer_count = 0
			group = ""
			if o >= 2 do plugin_rank += 1
			os.make_directory(fmt.tprintf("%s/%s", OUT_DIR, layer))
			fmt.sbprintf(&layer_index, "---\ntitle: \"%s\"\ndescription: \"Field tag keys declared by %s, by declaring package\"\nweight: %d\n---\n\nGenerated by `moonhug/prebuild/field_tags_gen` when `mh docs` runs. Not edited by hand and not committed.\n", layer, gen_facts.layer_noun(layer, o), (o + 1) * 10 + (o >= 2 ? plugin_rank : 0))
		}
		if d.pkg_path != group {
			group = d.pkg_path
			fmt.sbprintf(&layer_index, "\n## `%s`\n\n", gen_facts.pkg_import_path(group))
		}
		layer_count += 1
		fmt.sbprintf(&layer_index, "- [`%s`](%s.md) — %s (%d)\n", d.key, d.key, gen_facts.first_sentence(d.doc), len(d.uses))
		_emit_page(w, d, (i + 1) * 10, decorators[:])
	}
	flush_layer(w, layer, &layer_index)
	if layer != "" do fmt.sbprintf(&index, "- [%s](%s/_index.md) — %d %s\n", layer, layer, layer_count, layer_count == 1 ? "key" : "keys")
	db.emit(w, OUT_DIR + "/_index.md", strings.to_string(index))
	return true
}

// A Field_Tag literal: `Field_Tag{...}` inside package inspector, or
// `<alias>.Field_Tag{...}` where the alias imports it.
@(private = "file")
_is_field_tag_type :: proc(decl: ^db.DeclInfo, type_name: string) -> bool {
	if type_name == "Field_Tag" do return decl.pkg_path == INSPECTOR_PKG
	if !strings.has_suffix(type_name, ".Field_Tag") do return false
	alias := type_name[:len(type_name) - len(".Field_Tag")]
	path, ok := gen_facts.file_import(decl, alias)
	if !ok do return false
	if path == INSPECTOR_IMPORT do return true
	if strings.has_prefix(path, ".") do return slashpath.join({decl.pkg_path, path}, context.temp_allocator) == INSPECTOR_PKG
	return false
}

// Generated files carry their generator's tags, test packages are not part
// of any build that reads tags, external code is not MoonHug's.
@(private = "file")
_skipped :: proc(decl: ^db.DeclInfo) -> bool {
	if strings.has_suffix(decl.file_path, "_generated.odin") do return true
	p := decl.pkg_path
	return strings.contains(p, "/external/") || strings.has_prefix(p, "moonhug/external") || strings.has_suffix(p, "/tests") || strings.contains(p, "/tests/")
}

@(private = "file")
_space :: proc(c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

// Splits a tag into its keys: whitespace separates them, a quoted string or a
// call's parentheses keep theirs. The same grammar as the inspector's
// tag_value / tag_has (moonhug/editor/inspector/field_tags.odin). err is a
// reason when the tag does not follow it.
@(private = "file")
_parse_tag :: proc(tag: string) -> (tokens: []Token, err: string) {
	out := make([dynamic]Token, context.temp_allocator)
	s := tag
	i := 0
	for {
		for i < len(s) && _space(s[i]) do i += 1
		if i >= len(s) do break
		start := i
		for i < len(s) && !_space(s[i]) && s[i] != ':' && s[i] != '"' && s[i] != '(' && s[i] != ')' do i += 1
		tok := Token{key = s[start:i], form = .Flag}
		if tok.key == "" do return nil, fmt.tprintf("expected a key at `%s`", _excerpt(s[start:]))
		if i < len(s) && !_space(s[i]) {
			if s[i] != ':' do return nil, fmt.tprintf("expected `:` or a space after `%s`", tok.key)
			i += 1
			from := i
			if i < len(s) && s[i] == '"' {
				tok.form = .Value
				i += 1
				for i < len(s) && s[i] != '"' {
					if s[i] == '\\' do i += 1
					i += 1
				}
				if i >= len(s) do return nil, fmt.tprintf("the value of `%s` has no closing quote", tok.key)
				i += 1
			} else {
				tok.form = .Call
				name_start := i
				for i < len(s) && !_space(s[i]) && s[i] != '(' && s[i] != ')' && s[i] != '"' do i += 1
				if i == name_start do return nil, fmt.tprintf("`%s:` has no value, write `%s:\"text\"` or `%s:name(args)`", tok.key, tok.key, tok.key)
				if i < len(s) && s[i] == '(' {
					depth := 0
					for i < len(s) {
						c := s[i]
						if c == '"' {
							i += 1
							for i < len(s) && s[i] != '"' {
								if s[i] == '\\' do i += 1
								i += 1
							}
							if i >= len(s) do return nil, fmt.tprintf("a string in `%s` has no closing quote", tok.key)
							i += 1
							continue
						}
						i += 1
						if c == '(' do depth += 1
						if c == ')' {
							depth -= 1
							if depth == 0 do break
						}
					}
					if depth != 0 do return nil, fmt.tprintf("`%s:%s` has no closing `)`", tok.key, _excerpt(s[name_start:]))
				}
			}
			tok.text = s[from:i]
			if i < len(s) && !_space(s[i]) do return nil, fmt.tprintf("expected a space after `%s:%s`", tok.key, tok.text)
		}
		append(&out, tok)
	}
	return out[:], ""
}

// The keys Odin's reflect.struct_tag_lookup reads in `tag`: it walks
// key:"value" pairs separated by spaces and stops at anything else, a bare
// word, a call, a tab or a line break. A port of its loop.
@(private = "file")
_lookup_visible :: proc(tag: string) -> map[string]bool {
	out := make(map[string]bool, context.temp_allocator)
	t := tag
	for t != "" {
		i := 0
		for i < len(t) && t[i] == ' ' do i += 1
		t = t[i:]
		if len(t) == 0 do break
		i = 0
		loop: for i < len(t) {
			switch t[i] {
			case ':', '"':
				break loop
			case 0x00 ..< ' ', 0x7f ..= 0x9f:
				break loop
			}
			i += 1
		}
		if i == 0 || i + 1 >= len(t) do break
		if t[i] != ':' || t[i + 1] != '"' do break
		name := t[:i]
		t = t[i + 1:]
		i = 1
		for i < len(t) && t[i] != '"' {
			if t[i] == '\\' do i += 1
			i += 1
		}
		if i >= len(t) do break
		t = t[i + 1:]
		out[name] = true
	}
	return out
}

// A Flag key may be written key:"" as well, which is what struct_tag_lookup
// reads.
@(private = "file")
_form_fits :: proc(declared: Form, tok: Token) -> bool {
	if declared == .Flag && tok.form == .Value do return tok.text == `""`
	return declared == tok.form
}

@(private = "file")
_form_noun :: proc(f: Form) -> string {
	switch f {
	case .Value: return "a value"
	case .Flag:  return "a bare word"
	case .Call:  return "a call"
	}
	return ""
}

// How a key of a form is written, for the pages and the lint.
@(private = "file")
_form_written :: proc(key: string, f: Form) -> string {
	switch f {
	case .Value: return fmt.tprintf("a value, written `%s:\"text\"`", key)
	case .Flag:  return fmt.tprintf("a flag, written as the bare word `%s`", key)
	case .Call:  return fmt.tprintf("a call, written `%s:name(args)`", key)
	}
	return ""
}

// `min(0.5)` -> `min`.
@(private = "file")
_call_name :: proc(text: string) -> string {
	if p := strings.index_byte(text, '('); p >= 0 do return text[:p]
	return text
}

@(private = "file")
_excerpt :: proc(s: string) -> string {
	return s[:min(len(s), 24)]
}

// The tag on one line: every run of whitespace becomes one space.
@(private = "file")
_collapse :: proc(tag: string) -> string {
	return strings.join(strings.fields(tag, context.temp_allocator), " ", context.temp_allocator)
}

// Every decorator decorator_gen can resolve: a `decorator_<name>` proc in
// package inspector, where its generated file calls them.
@(private = "file")
_decorators :: proc(w: ^db.World, uses: map[string]int) -> [dynamic]Decorator {
	out := make([dynamic]Decorator, context.temp_allocator)
	decls := db.get_comps_DeclInfo()
	procs := db.get_comps(w, gen_facts.Proc_GenComp)
	m := db.all_of(db.r(decls), db.r(procs)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		decl := db.get(decls, entity)
		if decl.pkg_path != INSPECTOR_PKG || !strings.has_prefix(decl.name, DECORATOR_PREFIX) do continue
		if strings.has_suffix(decl.file_path, "_generated.odin") do continue
		name := decl.name[len(DECORATOR_PREFIX):]
		params := gen_facts.proc_params(decl)
		append(&out, Decorator{
			name = name,
			params = strings.join(params[min(1, len(params)):], ", ", context.temp_allocator),
			doc = gen_facts.first_sentence(gen_facts.doc_markdown(decl)),
			where_ = fmt.tprintf("%s:%d", gen_facts.decl_rel_path(decl), decl.decl.pos.line),
			uses = uses[name],
		})
	}
	slice.sort_by(out[:], proc(a, b: Decorator) -> bool { return a.name < b.name })
	return out
}

@(private = "file")
_emit_page :: proc(w: ^db.World, d: ^Declaration, weight: int, decorators: []Decorator) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	desc, _ := strings.replace_all(gen_facts.first_sentence(d.doc), "\"", "\\\"", context.temp_allocator)
	fmt.sbprintf(&b, "---\ntitle: \"%s\"\ndescription: \"%s\"\nweight: %d\ntags: [\"reference\", \"field-tags\"]\n---\n\n", d.key, desc, weight)
	switch d.form {
	case .Value: fmt.sbprintf(&b, "**Form** value, written `%s:\"text\"`", d.key)
	case .Flag:  fmt.sbprintf(&b, "**Form** flag, written as the bare word `%s` (`%s:\"\"` reads the same)", d.key, d.key)
	case .Call:  fmt.sbprintf(&b, "**Form** call, written `%s:name(args)`, and a tag may carry several", d.key)
	}
	fmt.sbprintf(&b, " · **Package** `%s`\n\nDeclared as `%s` at `%s`.\n\n", gen_facts.pkg_import_path(d.pkg_path), d.const_name, d.where_)
	strings.write_string(&b, d.doc)
	strings.write_string(&b, "\n")
	if d.key == "decor" && d.pkg_path == INSPECTOR_PKG {
		fmt.sbprintf(&b, "\n## Decorators (%d)\n\n", len(decorators))
		strings.write_string(&b, "A `decorator_<name>` proc in `moonhug:editor/inspector` is written `decor:<name>(args)`, the arguments being its parameters after `ctx`.\n\n")
		strings.write_string(&b, "| Decorator | Parameters | Summary | Where | Uses |\n|---|---|---|---|---|\n")
		for dec in decorators {
			params := dec.params == "" ? "" : fmt.tprintf("`%s`", gen_facts.md_cell(dec.params))
			fmt.sbprintf(&b, "| `%s` | %s | %s | `%s` | %d |\n", dec.name, params, gen_facts.md_cell(dec.doc), dec.where_, dec.uses)
		}
	}
	fmt.sbprintf(&b, "\n## Uses (%d)\n\n", len(d.uses))
	if len(d.uses) == 0 {
		strings.write_string(&b, "No field uses it yet.\n")
	} else {
		strings.write_string(&b, "| Field | Package | Where | Tag |\n|---|---|---|---|\n")
		for u in d.uses do fmt.sbprintf(&b, "| `%s` | %s | `%s` | `%s` |\n", u.field, u.pkg, u.where_, gen_facts.md_cell(u.tag))
	}
	layer, _ := gen_facts.pkg_layer(d.pkg_path)
	db.emit(w, fmt.tprintf("%s/%s/%s.md", OUT_DIR, layer, d.key), strings.to_string(b))
}

// Removes pages this build no longer writes: a key that was renamed or
// undeclared, a layer that declares none any more. The folder is mounted into
// the site whole, so a leftover would still be published.
@(private = "file")
_sweep_stale :: proc(list: []^Declaration) {
	keep := make(map[string]bool, context.temp_allocator)
	layers := make(map[string]bool, context.temp_allocator)
	for d in list {
		layer, _ := gen_facts.pkg_layer(d.pkg_path)
		layers[layer] = true
		keep[fmt.tprintf("%s/%s.md", layer, d.key)] = true
	}
	for e in gen_facts.dir_entries(OUT_DIR) {
		path := fmt.tprintf("%s/%s", OUT_DIR, e.name)
		if e.type == .Directory {
			if !layers[e.name] do os.remove_all(path)
			continue
		}
		if e.name != "_index.md" do os.remove(path)
	}
	for layer in layers {
		dir := fmt.tprintf("%s/%s", OUT_DIR, layer)
		for e in gen_facts.dir_entries(dir) {
			if e.type == .Directory || e.name == "_index.md" do continue
			if keep[fmt.tprintf("%s/%s", layer, e.name)] do continue
			os.remove(fmt.tprintf("%s/%s", dir, e.name))
		}
	}
}
