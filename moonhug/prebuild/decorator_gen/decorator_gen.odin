package decorator_gen

// decorator_gen: ECS prebuild module for decorators_generated.odin.
//
//   provide  - walk the decls, recognise struct decls whose fields carry
//              `decor:` struct tags, tag each with a Decorator_GenComp carrying the
//              per-type FieldDecorators (a nested [dynamic] owned by the world
//              for the run).
//   generate - join {decls, Decorator_GenComp}, rebuild TypeDecorators rows,
//              sort, build decorators_generated.odin, emit it (gen_db writes).
//
// String-building output is identical to the previous collect/generate version.

import "core:fmt"
import "core:slice"
import "core:strings"
import db "../gen_db"
import "../gen_facts"

DecoratorCall :: struct {
	call_with_ctx: string, // e.g. `header(ctx, text="Hello")`
}

FieldDecorators :: struct {
	field_name: string,
	calls:      [dynamic]DecoratorCall,
}

TypeDecorators :: struct {
	pkg_name:  string,
	type_name: string,
	fields:    [dynamic]FieldDecorators,
}

// Decorator_GenComp marks a DeclInfo entity as a struct with decorator tags and
// carries the per-type data the generator needs. The nested [dynamic] arrays
// are owned by the world for the run and rebuilt into rows by generate.
Decorator_GenComp :: struct {
	pkg_name: string,
	fields:   [dynamic]FieldDecorators,
}


@(init)
_register :: proc "contextless" () {
	db.provider("decorator/provide", provide)
	db.generator("decorator/generate", generate)
}


// Writes call line to builder; unescapes \" to " so generated Odin source is valid.
_write_call_line :: proc(b: ^strings.Builder, call_with_ctx: string) {
	strings.write_string(b, "\t\t")
	for i := 0; i < len(call_with_ctx); i += 1 {
		if call_with_ctx[i] == '\\' && i+1 < len(call_with_ctx) && call_with_ctx[i+1] == '"' {
			strings.write_byte(b, '"')
			i += 1
		} else {
			strings.write_byte(b, call_with_ctx[i])
		}
	}
	strings.write_string(b, "\n")
}

_parse_decor_calls_from_tag :: proc(tag: string) -> [dynamic]DecoratorCall {
	calls: [dynamic]DecoratorCall
	defer if len(calls) > 0 do delete(calls)

	key := "decor:"
	pos := 0
	for {
		i := strings.index(tag[pos:], key)
		if i < 0 do break
		start := pos + i + len(key)
		pos = start
		// Find end of this decor value: next "decor:" or end of string
		end := strings.index(tag[pos:], key)
		if end >= 0 {
			end += pos
		} else {
			end = len(tag)
		}
		val := tag[start:end]
		// Trim whitespace
		for len(val) > 0 && (val[0] == ' ' || val[0] == '\t' || val[0] == '\n' || val[0] == '\r') {
			val = val[1:]
		}
		for len(val) > 0 {
			c := val[len(val)-1]
			if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
				val = val[:len(val)-1]
			} else do break
		}
		if len(val) == 0 do continue
		// val is e.g. "header(text=\"Hello\")" or "separator()"
		// Prepend "decorator_" to proc name; insert "ctx, " after "(" (or just "ctx" if no args)
		paren := strings.index_rune(val, '(')
		if paren >= 0 {
			proc_name := fmt.tprintf("decorator_%s", val[:paren])
			rest := val[paren+1:]
			call_with_ctx: string
			if len(rest) > 0 && rest[0] == ')' {
				call_with_ctx = fmt.tprintf("%s(ctx)", proc_name)
			} else {
				if strings.contains(rest, "=") {
					call_with_ctx = fmt.tprintf("%s(ctx=ctx, %s", proc_name, rest)
				} else {
					call_with_ctx = fmt.tprintf("%s(ctx, %s", proc_name, rest)
				}
			}
			append(&calls, DecoratorCall{call_with_ctx = call_with_ctx})
		} else {
			append(&calls, DecoratorCall{call_with_ctx = fmt.tprintf("decorator_%s(ctx)", val)})
		}
		pos = end
	}

	result: [dynamic]DecoratorCall
	for c in calls do append(&result, c)
	return result
}

provide :: proc(w: ^db.World) -> bool {
	_decorators := db.get_or_create_comps(w, Decorator_GenComp)
	decls       := db.get_comps_DeclInfo()
	field_comps := db.get_comps(w, gen_facts.Fields_GenComp)

	m := db.all_of(db.r(decls), db.r(field_comps)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		decl := db.get(decls, entity)
		if decl.name == "" do continue

		struct_fields := db.get(field_comps, entity).fields

		fields: [dynamic]FieldDecorators
		has_any := false
		for sf in struct_fields {
			if sf.name == "" do continue
			calls := _parse_decor_calls_from_tag(sf.tag)
			defer delete(calls)
			if len(calls) == 0 {
				append(&fields, FieldDecorators{field_name = sf.name})
				continue
			}
			has_any = true
			fd: FieldDecorators = {field_name = sf.name}
			for c in calls do append(&fd.calls, c)
			append(&fields, fd)
		}
		if has_any {
			db.set(_decorators, entity, Decorator_GenComp{pkg_name = decl.pkg.name, fields = fields})
		} else {
			for fd in fields do delete(fd.calls)
			delete(fields)
		}
	}
	return true
}

generate :: proc(w: ^db.World) -> bool {
	entries: [dynamic]TypeDecorators
	defer {
		for e in entries {
			for fd in e.fields do delete(fd.calls)
			delete(e.fields)
		}
		delete(entries)
	}

	decls := db.get_comps_DeclInfo()
	_decorators := db.get_comps(w, Decorator_GenComp)
	m := db.all_of(db.r(decls), db.r(_decorators)); defer db.matcher_destroy(&m)
	for entity in db.matched(w, &m) {
		decl := db.get(decls, entity)
		deco := db.get(_decorators, entity)
		append(&entries, TypeDecorators{
			pkg_name  = deco.pkg_name,
			type_name = decl.name,
			fields    = deco.fields,
		})
	}

	// Preserve previous collect_finalize ordering: sort by (pkg_name, type_name).
	slice.sort_by(entries[:], proc(a, b: TypeDecorators) -> bool {
		if a.pkg_name != b.pkg_name do return a.pkg_name < b.pkg_name
		return a.type_name < b.type_name
	})

	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	strings.write_string(&b, "package inspector\n\n")
	packages_used: map[string]bool
	defer delete(packages_used)
	for e in entries {
		if e.pkg_name != "" && e.pkg_name != "editor" do packages_used[e.pkg_name] = true
	}
	import_pkgs: [dynamic]string
	defer delete(import_pkgs)
	for pkg in packages_used {
		append(&import_pkgs, pkg)
	}
	slice.sort(import_pkgs[:])
	for pkg in import_pkgs {
		fmt.sbprintf(&b, "import \"../../%s\"\n", pkg)
	}
	if len(import_pkgs) > 0 do strings.write_string(&b, "\n")
	strings.write_string(&b, "// Code generated by decorator_gen. Do not edit.\n\n")

	for e in entries {
		type_prefix := fmt.tprintf("__decorator__%s__", e.type_name)
		type_slice_name := fmt.tprintf("__decorators__%s", e.type_name)
		pkg_prefix := e.pkg_name
		if pkg_prefix != "" do pkg_prefix = fmt.tprintf("%s.", pkg_prefix)
		else do pkg_prefix = ""

		for fd in e.fields {
			if len(fd.calls) == 0 do continue
			proc_name := fmt.tprintf("%s%s", type_prefix, fd.field_name)
			strings.write_string(&b, proc_name)
			strings.write_string(&b, " :: proc(ctx: ^DrawContext) {\n")
			strings.write_string(&b, "\tif ctx.is_pre {\n")
			for c in fd.calls do _write_call_line(&b, c.call_with_ctx)
			strings.write_string(&b, "\t} else {\n")
			for i := len(fd.calls) - 1; i >= 0; i -= 1 do _write_call_line(&b, fd.calls[i].call_with_ctx)
			strings.write_string(&b, "\t}\n")
			strings.write_string(&b, "}\n\n")
		}

		strings.write_string(&b, type_slice_name)
		strings.write_string(&b, ": []DecoratorProc\n\n")
	}

	strings.write_string(&b, "init_decorators :: proc() {\n")
	for e in entries {
		type_slice_name := fmt.tprintf("__decorators__%s", e.type_name)
		type_prefix := fmt.tprintf("__decorator__%s__", e.type_name)
		qual := e.type_name
		if e.pkg_name != "" do qual = fmt.tprintf("%s.%s", e.pkg_name, e.type_name)
		n := len(e.fields)
		fmt.sbprintf(&b, "\t%s = make([]DecoratorProc, %d)\n", type_slice_name, n)
		for fd, idx in e.fields {
			if len(fd.calls) == 0 {
				fmt.sbprintf(&b, "\t%s[%d] = nil\n", type_slice_name, idx)
			} else {
				fmt.sbprintf(&b, "\t%s[%d] = %s%s\n", type_slice_name, idx, type_prefix, fd.field_name)
			}
		}
		strings.write_string(&b, "\tdecorator_registry[typeid_of(")
		strings.write_string(&b, qual)
		strings.write_string(&b, ")] = ")
		strings.write_string(&b, type_slice_name)
		strings.write_string(&b, "\n")
	}
	strings.write_string(&b, "}\n")

	db.emit(w, "moonhug/editor/inspector/decorators_generated.odin", strings.to_string(b))
	return true
}
