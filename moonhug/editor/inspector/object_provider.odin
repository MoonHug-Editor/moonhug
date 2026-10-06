package inspector

// What the inspector asks of whoever owns the objects a reference can point
// at. The shell has no scene tree: it draws Handle, Ref and Ref_Local fields
// and lists candidates in the picker, and the installed engine answers these
// (plugins/engine/editor/drawers/object_provider.odin). With no provider a
// reference field still draws, shows "None" or "Missing", and the picker's
// Scene tab is empty.
//
// `scope` is opaque to the shell: what local ids are minted against, the
// owner's root scene in the engine. nil means no scope, nothing is minted.

import core "moonhug:host/core"
import "base:runtime"
import "moonhug:editor/provider"

Object_Provider :: struct {
	// The object owning a handle: the handle itself for an object, the owner for a component.
	owner_of:          proc(h: core.Handle) -> (core.Transform_Handle, bool),
	object_name:       proc(tH: core.Transform_Handle) -> string,
	// The object's own local id, false when the handle is dead.
	object_local_id:   proc(tH: core.Transform_Handle) -> (core.Local_ID, bool),
	// The scene the object lives in, {} when the handle is dead.
	object_scene:      proc(tH: core.Transform_Handle) -> core.Scene_Ref,
	// The object's parent, false for a root or a dead handle.
	object_parent:     proc(tH: core.Transform_Handle) -> (core.Transform_Handle, bool),
	// The scope of the object owning `owner`.
	owner_scope:       proc(owner: core.Handle) -> rawptr,
	mint_local_id:     proc(scope: rawptr, h: core.Handle) -> core.Local_ID,
	// Every object of `key` inside `scope`, components included for a component key. Temp-allocated.
	find_objects:      proc(key: core.TypeKey, scope: rawptr) -> []core.Found_Object,
	// True when the object carries a component of any of `keys`.
	object_has_any:    proc(tH: core.Transform_Handle, keys: []core.TypeKey) -> bool,
	// False when the object or any ancestor is inactive.
	object_active:     proc(tH: core.Transform_Handle) -> bool,
	// Component keys declared with `tag` in their `ref_tags`. Temp-allocated.
	keys_with_ref_tag: proc(tag: string) -> []core.TypeKey,
}

@(private) _object_provider: Object_Provider

@(init)
_register_object_provider :: proc "contextless" () {
	context = runtime.default_context()
	provider.register("Object_Provider", &_object_provider)
}

set_object_provider :: proc(p: Object_Provider) {
	_object_provider = p
}

object_owner_of :: proc(h: core.Handle) -> (core.Transform_Handle, bool) {
	if _object_provider.owner_of == nil do return {}, false
	return _object_provider.owner_of(h)
}

object_name :: proc(tH: core.Transform_Handle) -> string {
	if _object_provider.object_name == nil do return ""
	return _object_provider.object_name(tH)
}

object_local_id :: proc(tH: core.Transform_Handle) -> (core.Local_ID, bool) {
	if _object_provider.object_local_id == nil do return 0, false
	return _object_provider.object_local_id(tH)
}

object_scene :: proc(tH: core.Transform_Handle) -> core.Scene_Ref {
	if _object_provider.object_scene == nil do return {}
	return _object_provider.object_scene(tH)
}

object_parent :: proc(tH: core.Transform_Handle) -> (core.Transform_Handle, bool) {
	if _object_provider.object_parent == nil do return {}, false
	return _object_provider.object_parent(tH)
}

object_owner_scope :: proc(owner: core.Handle) -> rawptr {
	if _object_provider.owner_scope == nil do return nil
	return _object_provider.owner_scope(owner)
}

object_mint_local_id :: proc(scope: rawptr, h: core.Handle) -> core.Local_ID {
	if _object_provider.mint_local_id == nil do return 0
	return _object_provider.mint_local_id(scope, h)
}

object_find :: proc(key: core.TypeKey, scope: rawptr) -> []core.Found_Object {
	if _object_provider.find_objects == nil do return {}
	return _object_provider.find_objects(key, scope)
}

object_has_any :: proc(tH: core.Transform_Handle, keys: []core.TypeKey) -> bool {
	if _object_provider.object_has_any == nil do return false
	return _object_provider.object_has_any(tH, keys)
}

object_keys_with_ref_tag :: proc(tag: string) -> []core.TypeKey {
	if _object_provider.keys_with_ref_tag == nil do return {}
	return _object_provider.keys_with_ref_tag(tag)
}

object_active :: proc(tH: core.Transform_Handle) -> bool {
	if _object_provider.object_active == nil do return false
	return _object_provider.object_active(tH)
}
