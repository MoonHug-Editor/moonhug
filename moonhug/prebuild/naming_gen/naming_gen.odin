package naming_gen

// naming_gen: naming conventions, checked and documented.
//
// A naming convention is code a generator finds by a proc's name: `reset_<T>`
// next to a `@(typ_guid)` type, `decorator_<name>` for `decor:<name>(...)`,
// `apply_<Name>` for an undo command. The owning generator declares it in
// gen_facts (register_naming) and records its subjects in its provide step.
//
//   lint     - a proc that follows a convention and names one of its subjects
//              must be where the owner looks, or it is never called. A proc
//              with a convention's prefix that names no subject is a typo when
//              it is close to a subject, and for a convention that owns its
//              prefix (decorator_, mcp_tool_) it is unused or unregistered.
//              Without this such a proc compiles and silently does nothing.
//   generate - docs/reference/naming/: one folder per layer (host, editor,
//              each plugin) with one page per convention: the procs it names,
//              where they have to be, and every proc found. Written when
//              `mh docs` runs, gitignored, since file:line changes on most
//              edits. The checks run on every build.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import db "../gen_db"
import "../gen_facts"

OUT_DIR :: "docs/reference/naming"

// A proc found for a subject.
Use :: struct {
	subject: string, // "Camera"
	name:    string, // "cleanup_Camera"
	where_:  string, // repo-relative file:line of the proc
}

@(init)
_register :: proc "contextless" () {
	// After the owners: their subjects are recorded in the Provide stage.
	db.generator("naming/generate", generate)
}

generate :: proc(w: ^db.World) -> bool {
	convs := gen_facts.naming_conventions[:]
	slice.sort_by(convs, proc(a, b: gen_facts.Naming_Convention) -> bool {
		oa, ob := _layer_order(a.layer), _layer_order(b.layer)
		if oa != ob do return oa < ob
		if a.layer != b.layer do return a.layer < b.layer
		return a.title < b.title
	})

	// key -> subject name -> subject (the first one recorded)
	subjects := make(map[string]map[string]gen_facts.Naming_Subject, context.temp_allocator)
	for s in gen_facts.naming_subjects {
		if s.key not_in subjects do subjects[s.key] = make(map[string]gen_facts.Naming_Subject, context.temp_allocator)
		m := &subjects[s.key]
		if s.name not_in m do m[s.name] = s
	}

	decls := db.get_comps_DeclInfo()
	procs := db.get_comps(w, gen_facts.Proc_GenComp)
	declared := make(map[string]bool, context.temp_allocator) // every declared name, for typo checks
	for row in decls.rows do declared[row.name] = true
	proc_decls := make([dynamic]^db.DeclInfo, context.temp_allocator)
	m := db.all_of(db.r(decls), db.r(procs)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		d := db.get(decls, entity)
		if d.name == "" || strings.has_suffix(d.file_path, "_generated.odin") do continue
		append(&proc_decls, d)
	}
	slice.sort_by(proc_decls[:], proc(a, b: ^db.DeclInfo) -> bool {
		if a.file_path != b.file_path do return a.file_path < b.file_path
		return a.decl.pos.line < b.decl.pos.line
	})

	uses := make(map[string][dynamic]Use, context.temp_allocator) // convention key -> procs found
	errors := make([dynamic]string, context.temp_allocator)
	warnings := make([dynamic]string, context.temp_allocator)

	for d in proc_decls {
		where_ := fmt.tprintf("%s:%d", gen_facts.decl_rel_path(d), d.decl.pos.line)
		// Pass 1: is it a subject's proc of any convention, and is it where
		// that convention's owner looks?
		claimed := false
		bound := false
		misplaced := make([dynamic]string, context.temp_allocator)
		for &c in convs {
			for p in c.procs {
				if !strings.has_prefix(d.name, p.prefix) || len(d.name) == len(p.prefix) do continue
				rest := d.name[len(p.prefix):]
				s, is_subject := subjects[c.key][rest]
				if !is_subject do continue
				claimed = true
				if _in_scope(&c, d, s) {
					bound = true
					if c.key not_in uses do uses[c.key] = make([dynamic]Use, context.temp_allocator)
					append(&uses[c.key], Use{subject = rest, name = d.name, where_ = where_})
				} else {
					append(&misplaced, fmt.tprintf("%s: `%s` is never called: %s finds `%s<%s>` only in %s", where_, d.name, c.owner, p.prefix, _subject_word(&c), _scope_text(&c, s)))
				}
			}
		}
		if claimed {
			// Placed right for one convention sharing the prefix is enough.
			if !bound do append(&errors, ..misplaced[:])
			continue
		}
		// Pass 2: a convention's prefix with no subject behind it.
		for &c in convs {
			for p in c.procs {
				if !strings.has_prefix(d.name, p.prefix) || len(d.name) == len(p.prefix) do continue
				if c.scope == .Package && d.pkg_path != c.package_path && c.unclaimed != .Near_Miss do continue
				rest := d.name[len(p.prefix):]
				switch c.unclaimed {
				case .Near_Miss:
					if declared[rest] do continue
					names := make([dynamic]string, context.temp_allocator)
					for name in subjects[c.key] do append(&names, name)
					if near := gen_facts.nearest_name(rest, names[:]); near != "" {
						append(&errors, fmt.tprintf("%s: `%s` names no %s, did you mean `%s%s`?", where_, d.name, strings.trim_prefix(c.subject, "a "), p.prefix, near))
					}
				case .Warn:
					append(&warnings, fmt.tprintf("%s: `%s` follows `%s<%s>` but nothing uses `%s`", where_, d.name, p.prefix, _subject_word(&c), rest))
				case .Error:
					append(&errors, fmt.tprintf("%s: `%s` follows `%s<%s>` but is not %s", where_, d.name, p.prefix, _subject_word(&c), c.subject))
				}
			}
		}
	}

	for wn in warnings do fmt.eprintfln("prebuild: warning: %s", wn)
	if len(errors) > 0 {
		for e in errors do fmt.eprintfln("prebuild: %s", e)
		fmt.eprintln("prebuild: these procs are found by name, see the Naming reference (docs/general/Documentation.md)")
		return false
	}

	// The checks above run on every build, the pages only for `mh docs`.
	if !gen_facts.write_reference_pages do return true
	os.make_directory("docs/reference")
	os.make_directory(OUT_DIR)
	_sweep_stale(convs)

	index := strings.builder_make()
	defer strings.builder_destroy(&index)
	strings.write_string(&index, "---\ntitle: \"Naming\"\ndescription: \"Every proc a generator finds by its name, and where it has to be\"\nweight: 18\n---\n\n")
	strings.write_string(&index, "Generated by `moonhug/prebuild/naming_gen` when `mh docs` runs. Not edited by hand and not committed.\n\n")
	strings.write_string(&index, "Some procs are called because of their name: `cleanup_Camera` next to the `Camera` type, `decorator_min` for a `decor:min(...)` field tag. Each convention belongs to the generator that resolves it, which declares it and its subjects, and the prebuild stops on a proc that follows a convention but would never be called. Conventions are grouped by the layer whose generator declares them, `host`, `editor` or a plugin's name.\n\n")
	layer_index := strings.builder_make()
	defer strings.builder_destroy(&layer_index)
	layer := ""
	layer_count := 0
	plugin_rank := 0
	flush_layer :: proc(w: ^db.World, layer: string, b: ^strings.Builder) {
		if layer == "" do return
		db.emit(w, fmt.tprintf("%s/%s/_index.md", OUT_DIR, layer), strings.to_string(b^))
		strings.builder_reset(b)
	}
	for &c, i in convs {
		if c.layer != layer {
			flush_layer(w, layer, &layer_index)
			if layer != "" do fmt.sbprintf(&index, "- [%s](%s/_index.md) — %d %s\n", layer, layer, layer_count, layer_count == 1 ? "convention" : "conventions")
			layer = c.layer
			layer_count = 0
			o := _layer_order(layer)
			if o >= 2 do plugin_rank += 1
			os.make_directory(fmt.tprintf("%s/%s", OUT_DIR, layer))
			fmt.sbprintf(&layer_index, "---\ntitle: \"%s\"\ndescription: \"Naming conventions declared by %s\"\nweight: %d\n---\n\nGenerated by `moonhug/prebuild/naming_gen` when `mh docs` runs. Not edited by hand and not committed.\n\n", layer, gen_facts.layer_noun(layer, o), (o + 1) * 10 + (o >= 2 ? plugin_rank : 0))
		}
		layer_count += 1
		found: []Use
		if list, ok := uses[c.key]; ok do found = list[:]
		fmt.sbprintf(&layer_index, "- [%s](%s.md) — %s (%d)\n", c.title, c.key, _patterns(&c), len(found))
		_emit_page(w, &c, found, (i + 1) * 10)
	}
	flush_layer(w, layer, &layer_index)
	if layer != "" do fmt.sbprintf(&index, "- [%s](%s/_index.md) — %d %s\n", layer, layer, layer_count, layer_count == 1 ? "convention" : "conventions")
	db.emit(w, OUT_DIR + "/_index.md", strings.to_string(index))
	return true
}

@(private = "file")
_in_scope :: proc(c: ^gen_facts.Naming_Convention, d: ^db.DeclInfo, s: gen_facts.Naming_Subject) -> bool {
	switch c.scope {
	case .Subject_File: return d.file_path == s.file_path
	case .Package:      return d.pkg_path == c.package_path
	case .Any:          return true
	}
	return false
}

@(private = "file")
_scope_text :: proc(c: ^gen_facts.Naming_Convention, s: gen_facts.Naming_Subject) -> string {
	switch c.scope {
	case .Subject_File: return fmt.tprintf("the file that declares `%s` (%s)", s.name, s.where_)
	case .Package:      return fmt.tprintf("`%s`", gen_facts.pkg_import_path(c.package_path))
	case .Any:          return "the scanned code"
	}
	return ""
}

// The placeholder for the subject in a pattern: <T> for types, <name> otherwise.
@(private = "file")
_subject_word :: proc(c: ^gen_facts.Naming_Convention) -> string {
	return "T" if strings.contains(c.subject, "type") else "name"
}

@(private = "file")
_patterns :: proc(c: ^gen_facts.Naming_Convention) -> string {
	b := strings.builder_make(context.temp_allocator)
	for p, i in c.procs do fmt.sbprintf(&b, "%s`%s<%s>`", i == 0 ? "" : ", ", p.prefix, _subject_word(c))
	return strings.to_string(b)
}

// host, editor, then plugins, the same order as gen_facts.pkg_layer.
@(private = "file")
_layer_order :: proc(layer: string) -> int {
	switch layer {
	case "host":   return 0
	case "editor": return 1
	}
	return 2
}

@(private = "file")
_emit_page :: proc(w: ^db.World, c: ^gen_facts.Naming_Convention, uses: []Use, weight: int) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	fmt.sbprintf(&b, "---\ntitle: \"%s\"\ndescription: \"%s\"\nweight: %d\ntags: [\"reference\", \"naming\"]\n---\n\n", c.title, _patterns(c), weight)
	fmt.sbprintf(&b, "**Resolved by** `%s` · **Subject** %s · **Found in** ", c.owner, c.subject)
	switch c.scope {
	case .Subject_File: strings.write_string(&b, "the file that declares the subject")
	case .Package:      fmt.sbprintf(&b, "`%s`", gen_facts.pkg_import_path(c.package_path))
	case .Any:          strings.write_string(&b, "any scanned package")
	}
	strings.write_string(&b, "\n\n")
	strings.write_string(&b, c.doc)
	strings.write_string(&b, "\n\n| Proc | Signature | Required | Purpose |\n|---|---|---|---|\n")
	for p in c.procs {
		fmt.sbprintf(&b, "| `%s<%s>` | `%s` | %s | %s |\n", p.prefix, _subject_word(c), gen_facts.md_cell(p.signature), p.required ? "yes" : "no", gen_facts.md_cell(p.summary))
	}
	fmt.sbprintf(&b, "\n## Found (%d)\n\n", len(uses))
	if len(uses) == 0 {
		strings.write_string(&b, "No proc follows it yet.\n")
	} else {
		sorted := slice.clone(uses, context.temp_allocator)
		slice.sort_by(sorted, proc(a, b: Use) -> bool {
			if a.subject != b.subject do return a.subject < b.subject
			return a.name < b.name
		})
		strings.write_string(&b, "| Subject | Proc | Where |\n|---|---|---|\n")
		for u in sorted do fmt.sbprintf(&b, "| `%s` | `%s` | `%s` |\n", u.subject, u.name, u.where_)
	}
	db.emit(w, fmt.tprintf("%s/%s/%s.md", OUT_DIR, c.layer, c.key), strings.to_string(b))
}

// Removes pages this build no longer writes. The folder is mounted into the
// site whole, so a leftover would still be published.
@(private = "file")
_sweep_stale :: proc(convs: []gen_facts.Naming_Convention) {
	keep := make(map[string]bool, context.temp_allocator)
	layers := make(map[string]bool, context.temp_allocator)
	for c in convs {
		layers[c.layer] = true
		keep[fmt.tprintf("%s/%s.md", c.layer, c.key)] = true
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
