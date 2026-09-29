package core

// Per-type lifecycle procs (docs/Components.md, "Lifecycle procs"): a
// @(typ_guid) type declares them by name in its own file, and the generated
// registration (type_guid_gen) puts them in these tables by TypeKey.
//
// - reset_T:       cleanup_T first when the type has one, then the defaults,
//                  so a reset on a live value frees what it owned. A new
//                  instance gets it, and the inspector's Reset runs it on a
//                  live value.
// - cleanup_T:     frees what a value owns and leaves it zeroed. Runs when a
//                  component is destroyed, when a union variant goes, when a
//                  tween node is destroyed.
// - on_validate_T: after an inspector edit and after a value is loaded from
//                  data, to keep the value consistent (a zero that means
//                  "default" becomes the default here).
//
// on_destroy_T stays a component's (engine/components.odin): it is about
// leaving a world, not about the value.

type_reset_procs:       [TypeKey]proc(rawptr)
type_cleanup_procs:     [TypeKey]proc(rawptr)
type_on_validate_procs: [TypeKey]proc(rawptr)

type_register_reset :: proc(key: TypeKey, fn: proc(rawptr)) {
	type_reset_procs[key] = fn
}

type_register_cleanup :: proc(key: TypeKey, fn: proc(rawptr)) {
	type_cleanup_procs[key] = fn
}

type_register_on_validate :: proc(key: TypeKey, fn: proc(rawptr)) {
	type_on_validate_procs[key] = fn
}

type_has_reset :: proc(key: TypeKey) -> bool {
	return type_reset_procs[key] != nil
}

type_has_cleanup :: proc(key: TypeKey) -> bool {
	return type_cleanup_procs[key] != nil
}

type_reset :: proc(key: TypeKey, ptr: rawptr) {
	if fn := type_reset_procs[key]; fn != nil do fn(ptr)
}

type_cleanup :: proc(key: TypeKey, ptr: rawptr) {
	if fn := type_cleanup_procs[key]; fn != nil do fn(ptr)
}

type_cleanup_by_typeid :: proc(tid: typeid, ptr: rawptr) {
	if key, ok := get_type_key_by_typeid(tid); ok do type_cleanup(key, ptr)
}

type_on_validate :: proc(key: TypeKey, ptr: rawptr) {
	if fn := type_on_validate_procs[key]; fn != nil do fn(ptr)
}

type_on_validate_by_typeid :: proc(tid: typeid, ptr: rawptr) {
	if key, ok := get_type_key_by_typeid(tid); ok do type_on_validate(key, ptr)
}
