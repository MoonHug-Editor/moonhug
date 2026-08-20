package tween

// The transform-targeting leaf nodes. Any package declares its own the same
// way (plugin_example is the reference): a struct embedding Tween, a tick
// over the concrete type, one register_node call on the TweenNodesInit
// phase (register_builtin_nodes here).

import "core:math/linalg"
import engine "moonhug:engine"

@(typ_guid={guid="aa1970c6-51d2-4d27-9dc8-718ad1e51160"})
TweenScaleToLocal :: struct {
    using base : Tween `inline:""`,
    scale    : [3]f32,
    duration : f32,

    elapsed  : f32 `json:"-"`,
    from     : [3]f32 `json:"-"`,
}

tick_TweenScaleToLocal :: proc(self: ^TweenScaleToLocal, delta_time: f32, ctx: TweenContext) -> Status {
    if tween_has_delay(&self.base, delta_time) do return .Running

    w := engine.ctx_world()
    transform := engine.pool_get(&w.transforms, engine.Handle(ctx.subject))
    if transform == nil do return .Done
    if self.duration == 0 {
        transform.scale = self.scale
        return .Done
    }
    if self.elapsed == 0 do self.from = transform.scale
    self.elapsed += delta_time
    t := clamp(self.elapsed / self.duration, 0, 1)
    transform.scale = self.from + (self.scale - self.from) * t
    return .Done if t >= 1 else .Running
}

// ---

@(typ_guid={guid="b72f3c1a-9e45-4b8d-a3f7-2d1e5c8f0b94"})
TweenRotateToLocal :: struct {
    using base : Tween `inline:""`,
    rotation : [4]f32 `inspect:"" decor:euler()`,
    duration : f32,

    elapsed  : f32 `json:"-"`,
    from     : [4]f32 `json:"-"`,
}

tick_TweenRotateToLocal :: proc(self: ^TweenRotateToLocal, delta_time: f32, ctx: TweenContext) -> Status {
    if tween_has_delay(&self.base, delta_time) do return .Running

    w := engine.ctx_world()
    transform := engine.pool_get(&w.transforms, engine.Handle(ctx.subject))
    if transform == nil do return .Done
    if self.duration == 0 {
        transform.rotation = self.rotation
        return .Done
    }
    if self.elapsed == 0 do self.from = transform.rotation
    self.elapsed += delta_time
    t := clamp(self.elapsed / self.duration, 0, 1)
    transform.rotation = engine.quat_from_native(linalg.quaternion_slerp(engine.quat_to_native(self.from), engine.quat_to_native(self.rotation), t))
    return .Done if t >= 1 else .Running
}

// ---

@(typ_guid={guid="da9d301a-66a3-450c-8c0b-8c696ad60b0b"})
TweenMoveToLocal :: struct {
    using base : Tween `inline:""`,
    position : [3]f32,
    duration : f32,

    elapsed  : f32 `json:"-"`,
    from     : [3]f32 `json:"-"`,
}

tick_TweenMoveToLocal :: proc(self: ^TweenMoveToLocal, delta_time: f32, ctx: TweenContext) -> Status {
    if tween_has_delay(&self.base, delta_time) do return .Running

    w := engine.ctx_world()
    transform := engine.pool_get(&w.transforms, engine.Handle(ctx.subject))
    if transform == nil do return .Done
    if self.duration == 0 {
        transform.position = self.position
        return .Done
    }
    if self.elapsed == 0 do self.from = transform.position
    self.elapsed += delta_time
    t := clamp(self.elapsed / self.duration, 0, 1)
    transform.position = self.from + (self.position - self.from) * t
    return .Done if t >= 1 else .Running
}
