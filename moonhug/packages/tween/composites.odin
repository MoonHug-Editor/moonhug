package tween

// The composite tweens: children are live-node handles, filled by the
// runtime at instantiation from the authored blob's "children" array (the
// json:"-" field is found by reflection at registration). The children
// array itself is freed by node_destroy — no cleanup procs needed.

@(typ_guid={guid="916005b6-1c68-49e7-88be-0add6164d3a8"})
Parallel :: struct {
    using base : Tween `inline:""`,
    children: [dynamic]Node_Handle `json:"-" inspect:"-"`,
}

tick_Parallel :: proc(self: ^Parallel, delta_time: f32, ctx: TweenContext) -> TweenStatus {
    if tween_has_delay(&self.base, delta_time) do return .Running

    all_done := true
    for h in self.children {
        child := node_base(h)
        if child == nil || child.status == .Done do continue
        child.status = tick_node(h, delta_time, ctx)
        if child.status != .Done do all_done = false
    }
    return .Done if all_done else .Running
}

// ---

@(typ_guid={guid="24d46399-b3a0-44e7-abd1-6da5d759e935"})
Sequence :: struct {
    using base : Tween `inline:""`,
    children: [dynamic]Node_Handle `json:"-" inspect:"-"`,
}

tick_Sequence :: proc(self: ^Sequence, delta_time: f32, ctx: TweenContext) -> TweenStatus {
    if tween_has_delay(&self.base, delta_time) do return .Running

    for h in self.children {
        child := node_base(h)
        if child == nil || child.status == .Done do continue
        child.status = tick_node(h, delta_time, ctx)
        if child.status != .Done do return child.status
    }
    return .Done
}
