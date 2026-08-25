package engine

// Curve and Gradient — reusable authored-value types (Unity's AnimationCurve
// and Gradient reduced to piecewise-LINEAR segments; tangents and blend modes
// can come later without changing the data shape). Runtime evaluation lives
// here so game binaries evaluate what the editor authored; the drawers live
// in editor/inspector (property_drawer_curve.odin, property_drawer_gradient.odin)
// and apply to ANY component field of these types.

import "core:math"

Curve_Key :: struct {
    t:     f32, // 0..1
    value: f32,
}

// Keys sorted by t. An EMPTY curve evaluates to `empty_value` — over-lifetime
// modules pass 1, so no keys = the module off.
@(typ_guid={guid="8f2c5b1a-9d47-4e63-b8a1-3c50d7e94f26"})
Curve :: struct {
    keys: [dynamic]Curve_Key,
}

curve_eval :: proc(c: ^Curve, t: f32, empty_value: f32 = 1) -> f32 {
    n := len(c.keys)
    if n == 0 do return empty_value
    if t <= c.keys[0].t do return c.keys[0].value
    if t >= c.keys[n - 1].t do return c.keys[n - 1].value
    for i in 1 ..< n {
        k := c.keys[i]
        if t <= k.t {
            a := c.keys[i - 1]
            span := k.t - a.t
            if span <= 1e-6 do return k.value
            return math.lerp(a.value, k.value, (t - a.t) / span)
        }
    }
    return c.keys[n - 1].value
}

Gradient_Key :: struct {
    t:     f32, // 0..1
    color: [4]f32,
}

// Keys sorted by t, colors blend linearly between them. An EMPTY gradient
// evaluates white — over-lifetime modules multiply by it, so no keys = the
// module off.
@(typ_guid={guid="4d81f7c9-2a35-4b06-9e58-1c6a0d43e7b2"})
Gradient :: struct {
    keys: [dynamic]Gradient_Key,
}

gradient_eval :: proc(g: ^Gradient, t: f32) -> [4]f32 {
    n := len(g.keys)
    if n == 0 do return {1, 1, 1, 1}
    if t <= g.keys[0].t do return g.keys[0].color
    if t >= g.keys[n - 1].t do return g.keys[n - 1].color
    for i in 1 ..< n {
        k := g.keys[i]
        if t <= k.t {
            a := g.keys[i - 1]
            span := k.t - a.t
            if span <= 1e-6 do return k.color
            f := (t - a.t) / span
            return math.lerp(a.color, k.color, f)
        }
    }
    return g.keys[n - 1].color
}

// Field cleanups for the override-revert walk (type_cleanup_by_typeid frees
// the live field before unmarshaling the baseline back in).
@(cleanup={type=Curve, priority=0})
type_cleanup_curve_field :: proc(c: ^Curve) {
    delete(c.keys)
}

@(cleanup={type=Gradient, priority=0})
type_cleanup_gradient_field :: proc(g: ^Gradient) {
    delete(g.keys)
}
