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
}
