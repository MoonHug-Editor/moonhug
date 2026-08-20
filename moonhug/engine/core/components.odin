package core

import "core:mem"

Transform_Handle :: distinct Handle

CompData :: struct {
    owner: Transform_Handle `json:"-"`,
    local_id: Local_ID `inspect:"-"`,
    enabled: bool,
    nested_owned: bool `json:"-" inspect:"-"`,
}

comp_zero :: proc(p: ^$T) where
    offset_of(T, base) == 0,
    type_of(T{}.base) == CompData
{
    mem.zero(rawptr(uintptr(p) + size_of(CompData)), size_of(T) - size_of(CompData))
}
