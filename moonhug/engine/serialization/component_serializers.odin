package serialization

import "core:encoding/json"
import engine ".."
import "base:runtime"

component_marshalers:   map[typeid]json.User_Marshaler
component_unmarshalers: map[typeid]json.User_Unmarshaler

@(init)
_component_serializers_maps_init :: proc "contextless" () {
	context = runtime.default_context()
	alloc := runtime.default_allocator()
	component_marshalers   = make(map[typeid]json.User_Marshaler,   alloc)
	component_unmarshalers = make(map[typeid]json.User_Unmarshaler, alloc)
}

// Unions that serialize through the guid-tagged form (union_marshal), queued
// before the marshaler maps are installed and registered once they are.
//
// Queued from an @(init) in a GENERATED file (prebuild/union_gen) rather than
// from a SerializationInit phase proc: the phase table is itself generated from
// a scan of the files on disk, and a file emitted during the same prebuild is
// not on disk when that scan runs. A phase proc there misses the first build
// silently — exactly the failure this registration exists to prevent. @(init)
// is the language's, needs no table, and runs whenever the file compiles.
_pending_unions: [dynamic]typeid

register_union_type :: proc(T: typeid) {
	if _pending_unions == nil do _pending_unions = make([dynamic]typeid, runtime.default_allocator())
	append(&_pending_unions, T)
}

Phase_Extra :: enum {
	SerializationInit,
}

@(phase={key=SerializationInit, order=0})
register_component_serializers :: proc() {
    @(static) has_inited:= false
    if has_inited do return
    has_inited = true

    json.set_user_marshalers(&component_marshalers)
    json.set_user_unmarshalers(&component_unmarshalers)

    // Unions queued at program init by generated code (prebuild/union_gen),
    // now that the maps they go into exist.
    for tid in _pending_unions {
        json.register_user_marshaler(tid, union_marshal)
        json.register_user_unmarshaler(tid, union_unmarshal)
    }

    json.register_user_marshaler(engine.Asset_GUID, asset_guid_marshal)
    json.register_user_unmarshaler(engine.Asset_GUID, asset_guid_unmarshal)

    // Pointer typeids needed by nested-scene deep-override application
    // (`_nested_patch_live_field` calls `get_pointer_typeid_by_typeid` to
    // build a typed `any` for `json.unmarshal_any`). Without these, deep
    // overrides silently no-op on field types whose pointer typeid isn't
    // registered. Editor and app must both call this — runtime instances
    // resolve nested scenes the same way as the editor.
    engine.register_pointer_type(bool)
    engine.register_pointer_type(int)
    engine.register_pointer_type(i8)
    engine.register_pointer_type(i16)
    engine.register_pointer_type(i32)
    engine.register_pointer_type(i64)
    engine.register_pointer_type(u8)
    engine.register_pointer_type(u16)
    engine.register_pointer_type(u32)
    engine.register_pointer_type(u64)
    engine.register_pointer_type(f32)
    engine.register_pointer_type(f64)
    engine.register_pointer_type(string)
    engine.register_pointer_type(engine.Asset_GUID)
    engine.register_pointer_type(engine.Curve)
    engine.register_pointer_type(engine.Gradient)
    // Reference types: revert/deep-override of a Ref field unmarshals the
    // baseline back into the live field via these.
    engine.register_pointer_type(engine.Ref_Local)
    engine.register_pointer_type(engine.Ref)
    engine.register_pointer_type(engine.PPtr)
    engine.register_pointer_type(engine.Local_ID)
}
