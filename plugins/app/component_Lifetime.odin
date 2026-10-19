package app

// Self-destruct timer, ticked by comp_fixed_update_Lifetime (fixed update): the owner is
// queued for destroy (transform_destroy_later) once time_spent passes duration. App-level (not engine): scene
// records live in ext_components keyed by the type guid, so the guid below is
// the on-disk identity and must never change.

import "moonhug:packages/engine"

@(component={menu="Demo/Lifetime"})
@(typ_guid={guid = "c3a1e4f2-7b8d-4a2e-9c5f-1d6e3b0f7a8c"})
Lifetime :: struct {
    using base: engine.CompData `inspect:"-"`,
    duration: f32,
    time_spent: f32 `inspect:"-"`,
}

reset_Lifetime :: proc(comp: ^Lifetime) {
    comp.duration = 1
}

on_validate_Lifetime :: proc(comp: ^Lifetime)
{
    if (comp.duration < 0) {
        comp.duration = 0
    }
}

@(comp_fixed_update={order=-50, component=Lifetime})
comp_fixed_update_Lifetime :: proc(dt: f32, lt: ^Lifetime) {
    lt.time_spent += dt
    if lt.time_spent >= lt.duration do engine.transform_destroy_later(lt.owner)
}
