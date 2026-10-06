package gen_facts

// Naming conventions: code a generator finds by the name of a proc, not by an
// attribute or a field tag. `cleanup_Camera` is called because type_guid_gen
// looks for `cleanup_<T>` next to every `@(typ_guid)` type, `decorator_min`
// because a field says `decor:min(...)`.
//
// The generator that resolves a convention declares it here at @(init) and
// records its subjects in its provide step (the types, names or procs the
// convention applies to). naming_gen then documents every convention with the
// procs it found, and stops the build on a proc that follows a convention but
// is never called: in the wrong file, misspelled, or missing its attribute.

import "base:runtime"
import "core:slice"
import "core:strings"

// One proc a convention names, `<prefix><Subject>`.
Naming_Proc :: struct {
	prefix:    string, // "cleanup_"
	signature: string, // "proc(v: ^T)", for the docs
	required:  bool,   // every subject has one, the owner stops the build otherwise
	summary:   string, // what the proc is for, one sentence
}

// Where a convention's procs have to be for the owner to find them.
Naming_Scope :: enum {
	Subject_File, // the file that declares the subject
	Package,      // anywhere in Naming_Convention.package_path
	Any,          // anywhere in the scanned code
}

// What a proc with a convention's prefix and no matching subject is.
Naming_Unclaimed :: enum {
	Near_Miss, // an error only when the rest is a near miss of a subject (a typo)
	Warn,      // always a warning: the prefix belongs to the convention
	Error,     // always an error: the prefix belongs to the convention
}

Naming_Convention :: struct {
	key:          string, // stable id and page name: "type_lifecycle"
	title:        string, // "Type lifecycle procs"
	subject:      string, // what <Subject> names: "a type with @(typ_guid)"
	layer:        string, // "host", "editor" or the declaring plugin's name
	owner:        string, // the generator that resolves it: "type_guid_gen"
	procs:        []Naming_Proc,
	scope:        Naming_Scope,
	package_path: string, // for .Package: "moonhug/editor/inspector"
	unclaimed:    Naming_Unclaimed,
	doc:          string, // markdown, shown on the convention's page
}

// A subject a convention applies to, as recorded by its owner.
Naming_Subject :: struct {
	key:       string, // the convention
	name:      string, // what follows the prefix: "Camera", "min"
	file_path: string, // DeclInfo.file_path of the subject, for .Subject_File
	where_:    string, // repo-relative file:line of the subject, for the docs
}

naming_conventions: [dynamic]Naming_Convention
naming_subjects:    [dynamic]Naming_Subject

// Declares a convention. Call from the owning generator's @(init).
register_naming :: proc(c: Naming_Convention) {
	context.allocator = runtime.default_allocator()
	if naming_conventions == nil do naming_conventions = make([dynamic]Naming_Convention)
	// A `procs = {...}` literal lives on the caller's stack, which is gone once
	// its @(init) returns. The strings in it are literals and stay valid.
	kept := c
	kept.procs = slice.clone(c.procs)
	append(&naming_conventions, kept)
}

// Records a subject of a convention. Call from the owner's provide step, which
// runs before naming_gen. Recording the same subject twice is harmless.
naming_subject :: proc(key, name, file_path, where_: string) {
	// Owners pass temp strings, and naming_gen reads them a stage later.
	context.allocator = runtime.default_allocator()
	if naming_subjects == nil do naming_subjects = make([dynamic]Naming_Subject)
	append(&naming_subjects, Naming_Subject{key = key, name = strings.clone(name), file_path = strings.clone(file_path), where_ = strings.clone(where_)})
}
