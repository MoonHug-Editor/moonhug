package app

import "core:encoding/json"
import "../engine"
import ser "../engine/serialization"
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

register_component_serializers :: proc() {
    @(static) has_inited:= false
    if has_inited do return
    has_inited = true

    json.set_user_marshalers(&component_marshalers)
    json.set_user_unmarshalers(&component_unmarshalers)

    json.register_user_marshaler(engine.Asset_GUID, ser.asset_guid_marshal)
    json.register_user_unmarshaler(engine.Asset_GUID, ser.asset_guid_unmarshal)

    json.register_user_marshaler(engine.UnionTest, ser.union_marshal)
    json.register_user_unmarshaler(engine.UnionTest, ser.union_unmarshal)

    json.register_user_marshaler(engine.ImportSettings, ser.union_marshal)
    json.register_user_unmarshaler(engine.ImportSettings, ser.union_unmarshal)

    json.register_user_marshaler(engine.TweenUnion, ser.union_marshal)
    json.register_user_unmarshaler(engine.TweenUnion, ser.union_unmarshal)

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
    engine.register_pointer_type(engine.A)
    engine.register_pointer_type(engine.TweenUnion)
    engine.register_pointer_type(engine.UnionTest)
    // Reference types: revert/deep-override of a Ref field unmarshals the
    // baseline back into the live field via these.
    engine.register_pointer_type(engine.Ref_Local)
    engine.register_pointer_type(engine.Ref)
    engine.register_pointer_type(engine.PPtr)
    engine.register_pointer_type(engine.Local_ID)
}
