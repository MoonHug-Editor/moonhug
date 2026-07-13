package engine

// Directional light (sun) consumed by the built-in lit shader
// (docs/Materials.md). One light per scene for now: rendering uses the first
// enabled light it finds; none = the shader's neutral default (white, baked
// direction). Light travels along the transform's forward (-Z), like a
// camera — rotate the transform to aim the sun.

@(component={max=8})
@(typ_guid={guid = "9f36ee91-34b6-4636-a360-ee872af0436b"})
Light :: struct {
    using base: CompData `inspect:"-"`,
    color:     [4]f32 `decor:color()`, // alpha unused
    intensity: f32,
    ambient:   f32 `decor:min(0)`, // unlit floor, 0..1
}

reset_Light :: proc(l: ^Light) {
    l.color = {1, 1, 1, 1}
    l.intensity = 1
    l.ambient = 0.35
}
