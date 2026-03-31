package engine

@(component={max=10})
@(typ_guid={guid = "d3f1a2b4-7e8c-4d5f-9a0b-1c2e3f4a5b6c"})
Player :: struct {
    using base: CompData `inspect:"-"`,
    speed:  f32,
    colors: [dynamic][4]f32,
    animations: [dynamic]TweenUnion,
}
