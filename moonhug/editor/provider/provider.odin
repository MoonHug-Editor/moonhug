package provider

// The shell asks the installed plugins for everything it cannot do itself
// through provider structs: a table of procs the engine fills from its
// @(provider_install) procs (viewport, object lookups, undo targets, the
// simulate world, ...). Each of those structs registers its instance here, and
// one check at the end of EditorInit names what nobody installed.
//
// A provider is either absent or complete. Absent means no plugin supplies
// it, and the shell runs without that capability (an editor with no engine).
// A partly filled provider is a forgotten field or a forgotten install, and
// that is an error here instead of a silent "None" in some panel.

import "base:runtime"
import "core:fmt"
import "core:strings"
import "moonhug:host/log"

Entry :: struct {
	name: string,
	ptr:  rawptr,
	ti:   ^runtime.Type_Info,
}

@(private) _entries: [dynamic]Entry

// Installs a plugin's editor half: marks a proc that fills provider structs or
// adds registry entries (drawers, component wrappers, asset doc hooks,
// thumbnail renderers, ...).
//
// The proc takes no parameters. It runs once, after the inspector registries
// exist, both in the editor (editor_init, right after inspector.init) and in
// the test binary (tests/common), from the generated install_providers. It
// must only set provider fields or add registry entries: it runs before the
// asset scan and before any world or scene exists.
@(extension_point={attribute="provider_install", target="proc", fields=""})
Install_Proc :: proc()

// Called from an @(init) in the package that owns the struct.
register :: proc(name: string, p: ^$T) {
	if _entries == nil do _entries = make([dynamic]Entry, runtime.default_allocator())
	append(&_entries, Entry{name = name, ptr = p, ti = type_info_of(T)})
}

// Proc fields of one provider that are nil, as "Struct.field". Non-proc
// fields are not providers and are skipped.
missing_fields :: proc(e: Entry, allocator := context.temp_allocator) -> (missing: []string, total: int) {
	out := make([dynamic]string, allocator)
	s, ok := runtime.type_info_base(e.ti).variant.(runtime.Type_Info_Struct)
	if !ok do return out[:], 0
	for i in 0 ..< s.field_count {
		if _, is_proc := runtime.type_info_base(s.types[i]).variant.(runtime.Type_Info_Procedure); !is_proc do continue
		total += 1
		field := cast(^rawptr)(uintptr(e.ptr) + s.offsets[i])
		if field^ == nil do append(&out, fmt.aprintf("%s.%s", e.name, s.names[i], allocator = allocator))
	}
	return out[:], total
}

// Asserts on any partly installed provider and logs the absent ones.
verify :: proc(loc := #caller_location) {
	for e in _entries {
		missing, total := missing_fields(e)
		if len(missing) == 0 do continue
		if len(missing) == total {
			log.info(fmt.tprintf("provider: %s has no installer, the editor runs without it", e.name))
			continue
		}
		panic(fmt.tprintf("provider %s is partly installed, missing: %s", e.name, strings.join(missing, ", ", context.temp_allocator)), loc)
	}
}

@(phase={key=EditorInit, order=100, mode=Editor})
_verify_at_editor_init :: proc() {
	verify()
}
