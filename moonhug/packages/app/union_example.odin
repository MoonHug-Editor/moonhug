package app

// Union serialization example. GameSettings carries these fields to exercise
// the generic union marshalers (engine/serialization) and union undo through
// the inspector.

import "core:encoding/json"
import "moonhug:engine"
import serialization "moonhug:engine/serialization"

UnionTest :: union #no_nil
{
    A,
    B,
    C,
}

@(typ_guid={guid = "f49ac13b-63cc-4374-a567-0e02b2c3d479"})
A :: struct {
    b: int,
    c: string,
}

@(typ_guid={guid = "f50ac13b-63cc-4374-a567-0e02b2c3d479"})
B :: struct {
    b_string: string,
}

@(typ_guid={guid = "f51ac13b-63cc-4374-a567-0e02b2c3d479"})
C :: struct{
    c_int: int,
}

@(phase={key=SerializationInit, order=1})
union_example_serialization_init :: proc() {
    @(static) done := false
    if done do return
    done = true
    json.register_user_marshaler(UnionTest, serialization.union_marshal)
    json.register_user_unmarshaler(UnionTest, serialization.union_unmarshal)
    engine.register_pointer_type(A)
    engine.register_pointer_type(UnionTest)
}
