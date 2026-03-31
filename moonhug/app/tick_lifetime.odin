package app

import "../engine"

@(update={order=-50})
tick_lifetime :: proc(dt: f32) {
    w := engine.ctx_world()
    for i in 0..<engine.MAX {
        slot := &w.lifetimes.slots[i]
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

@(update={order=9999})
tick_destroy :: proc(dt: f32) {
    engine.transform_tick_destroy()
}
