package core

import "core:mem"

// mem is used only inside comp_zero, a generic proc no package instantiates
// when no plugin declares components.
_ :: mem

Transform_Handle :: distinct Handle

// The TypeKey of the type a Transform_Handle points at. The plugin that
// declares that type sets it from @(init) (the engine, plugins/engine/transform.odin).
// With no such plugin it stays INVALID_TYPE_KEY and no pooled handle is a
// transform.
transform_type_key := INVALID_TYPE_KEY

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
