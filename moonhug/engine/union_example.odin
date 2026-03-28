package engine

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
