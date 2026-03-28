package engine

import "core:math/linalg"

@(typ_guid={guid="916005b6-1c68-49e7-88be-0add6164d3a8"})
Parallel :: struct {
    using base : Tween `inline:""`,
    children: [dynamic]TweenUnion,
}

tick_Parallel :: proc(task:^TweenUnion, delta_time:f32, ctx:TweenContext) -> TweenStatus {
    self := &task.(Parallel)
    if tween_has_delay(&self.base, delta_time) do return .Running

    all_done := true
    for &child in self.children {
        child_base := tween_base(&child)
        if (child_base.status == .Done) do continue
        child_base.status = _tween_tick_child(&child, delta_time, ctx)
        if child_base.status != .Done do all_done = false
    }
    return .Done if all_done else .Running
}

tween_free_Parallel :: proc(tween : ^TweenUnion) {
    task := &tween.(Parallel)
    for &child in task.children do tween_free(&child)
    delete(task.children)
}

// ---

@(typ_guid={guid="24d46399-b3a0-44e7-abd1-6da5d759e935"})
Sequence :: struct {
    using base : Tween `inline:""`,
    children: [dynamic]TweenUnion,
}

tick_Sequence :: proc(task:^TweenUnion, delta_time:f32, ctx:TweenContext) -> TweenStatus {
    self := &task.(Sequence)
    if tween_has_delay(&self.base, delta_time) do return .Running

    for &child in self.children {
        child_base := tween_base(&child)
        if (child_base.status == .Done) do continue
        child_base.status = _tween_tick_child(&child, delta_time, ctx)
        if child_base.status != .Done do return child_base.status
    }
    return .Done
}

tween_free_Sequence :: proc(tween : ^TweenUnion) {
    task := &tween.(Sequence)
    for &child in task.children do tween_free(&child)
    delete(task.children)
}

// ---

@(typ_guid={guid="aa1970c6-51d2-4d27-9dc8-718ad1e51160"})
TweenScaleToLocal :: struct {
    using base : Tween `inline:""`,
    scale    : [3]f32,
    duration : f32,

    elapsed  : f32 `json:"-"`,
    from     : [3]f32 `json:"-"`,
}

tick_TweenScaleToLocal :: proc(task:^TweenUnion, delta_time:f32, ctx:TweenContext) -> TweenStatus {
    self := &task.(TweenScaleToLocal)
    if tween_has_delay(&self.base, delta_time) do return .Running

    w := ctx_world()
    transform := pool_get(&w.transforms, Handle(ctx.subject))
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

tick_TweenRotateToLocal :: proc(task:^TweenUnion, delta_time:f32, ctx:TweenContext) -> TweenStatus {
    self := &task.(TweenRotateToLocal)
    if tween_has_delay(&self.base, delta_time) do return .Running

    w := ctx_world()
    transform := pool_get(&w.transforms, Handle(ctx.subject))
    if transform == nil do return .Done
    if self.duration == 0 {
        transform.rotation = self.rotation
        return .Done
    }
    if self.elapsed == 0 do self.from = transform.rotation
    self.elapsed += delta_time
    t := clamp(self.elapsed / self.duration, 0, 1)
    transform.rotation = quat_from_native(linalg.quaternion_slerp(quat_to_native(self.from), quat_to_native(self.rotation), t))
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

tick_TweenMoveToLocal :: proc(task:^TweenUnion, delta_time:f32, ctx:TweenContext) -> TweenStatus {
    self := &task.(TweenMoveToLocal)
    if tween_has_delay(&self.base, delta_time) do return .Running

    w := ctx_world()
    transform := pool_get(&w.transforms, Handle(ctx.subject))
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

