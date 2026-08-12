package tween

// The composite tweens. They hold children of type TweenUnion, which only
// this package can name — leaf variants live in moonhug:packages/tween/nodes
// (or any other package embedding tween_core.Tween).

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
