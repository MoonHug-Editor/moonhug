package app

import "../../engine"

@(fixed_update={order=-50})
tick_lifetime :: proc(dt: f32) {
    w := engine.ctx_world()
    pool := lifetimes(w)
    if pool == nil do return
    for i in 0..<len(pool.slots) {
        slot := &pool.slots[i]
        if !slot.alive do continue
        lt := &slot.data
        if !lt.enabled do continue
        lt.time_spent += dt
        if lt.time_spent >= lt.duration {
            t := engine.pool_get(&w.transforms, engine.Handle(lt.owner))
            if t != nil do t.destroy = true
        }
    }
}

@(fixed_update={order=9999})
tick_destroy :: proc(dt: f32) {
    engine.transform_tick_destroy()
}
