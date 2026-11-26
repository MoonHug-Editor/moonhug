package engine

import "core:math"

// How a camera maps the world onto its view.
Camera_Projection :: enum u8 {
    Perspective,  // distant things look smaller, fov sets the view angle
    Orthographic, // everything keeps its size at every distance, orthographic_size sets the view height: 2D games, top-down maps
}

@(component={max=32, menu="Rendering/Camera", icon="VIDEOCAM"})
@(typ_guid={guid = "7a3b9c1d-2e4f-5a6b-8c7d-9e0f1a2b3c4d"})
Camera :: struct {
    using base: CompData `inspect:"-"`,
    order:             i32,
    projection:        Camera_Projection,
    // Perspective: the vertical view angle, in degrees.
    fov:               f32 `show_if:"projection=Perspective" decor:range(1, 179)`,
    // Orthographic: half the visible height, in world units. The width
    // follows from the view's aspect.
    orthographic_size: f32 `show_if:"projection=Orthographic" decor:min(0.001)`,
    near_clip:         f32,
    far_clip:          f32,
    clear_color:       [4]f32 `decor:color()`,
    // The render layers this camera draws (Transform.render_layer bits).
    render_layer_mask: u32 `decor:layers(domain="render")`,
    // The render pipeline slot this camera renders through
    // (render_pipeline.odin). Empty is Main. A slot the pipeline does not
    // declare falls back to Main with one warning.
    slot:              string,
}

type_cleanup_Camera :: proc(cam: ^Camera) {
    delete(cam.slot)
    comp_zero(cam)
}

type_reset_Camera :: proc(cam: ^Camera) {
    cam.order = 0
    cam.projection = .Perspective
    cam.fov = 60
    cam.orthographic_size = 5
    cam.near_clip = 0.3
    cam.far_clip = 1000
    cam.clear_color = {0.19, 0.30, 0.47, 1.0}
    cam.render_layer_mask = 0xFFFFFFFF
}

// Half the height the camera sees at distance `d` in front of it, in world
// units: `d` times the tangent of half the fov in perspective, and
// orthographic_size at every distance in orthographic.
camera_half_height_at :: proc(cam: ^Camera, d: f32) -> f32 {
    switch cam.projection {
    case .Orthographic: return cam.orthographic_size
    case .Perspective:
    }
    return d * math.tan(math.to_radians(cam.fov) * 0.5)
}
