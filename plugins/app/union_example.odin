package app

// Union serialization example. GameSettings carries these fields to exercise
// the generic union marshalers (engine/serialization) and union undo through
// the inspector.

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

// Nothing registers the union by hand: union_gen sees that every variant
// carries @(typ_guid) and emits the marshaler pair into unions_generated.odin.
// The variants' pointer types come with their @(typ_guid).
