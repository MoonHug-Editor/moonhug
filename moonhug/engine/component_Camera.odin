package engine

@(component={max=32})
@(typ_guid={guid = "7a3b9c1d-2e4f-5a6b-8c7d-9e0f1a2b3c4d"})
Camera :: struct {
    using base: CompData `inspect:"-"`,
    order:             i32,
    fov:               f32,
    near_clip:         f32,
    far_clip:          f32,
    clear_color:       [4]f32 `decor:color()`,
    render_layer_mask: u32, // TODO: use bit_set[RenderLayer]
}

reset_Camera :: proc(cam: ^Camera) {
    cam.order = 0
    cam.fov = 60
    cam.near_clip = 0.3
    cam.far_clip = 1000
    cam.clear_color = {0.19, 0.30, 0.47, 1.0}
    cam.render_layer_mask = 0xFFFFFFFF
}

