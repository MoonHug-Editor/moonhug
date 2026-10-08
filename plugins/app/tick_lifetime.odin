package app

import "moonhug:packages/engine"

@(fixed_update={order=-50, component=Lifetime})
tick_lifetime :: proc(dt: f32, lt: ^Lifetime) {
    lt.time_spent += dt
    if lt.time_spent >= lt.duration {
        t := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(lt.owner))
        if t != nil do t.destroy = true
    }
}

@(fixed_update={order=9999})
tick_destroy :: proc(dt: f32) {
    engine.transform_tick_destroy()
}
