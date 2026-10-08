package app

// Self-destruct timer, ticked by fixed_update_Lifetime (fixed update): the owner is
// destroyed once time_spent passes duration. App-level (not engine): scene
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

@(fixed_update={order=-50, component=Lifetime})
fixed_update_Lifetime :: proc(dt: f32, lt: ^Lifetime) {
    lt.time_spent += dt
    if lt.time_spent >= lt.duration {
        t := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(lt.owner))
        if t != nil do t.destroy = true
    }
}
