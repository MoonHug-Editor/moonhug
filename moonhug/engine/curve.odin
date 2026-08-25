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

// Unity's MinMaxCurve: one value authored as a constant, a random range, a
// curve over a normalized time, or a random range between two curves. The
// zero value is Constant 0.
MinMax_Mode :: enum u8 {
    Constant,             // value_min
    Random_Two_Constants, // between value_min and value_max
    Curve,                // curve_min at t (empty curve falls back to value_min)
    Random_Two_Curves,    // between curve_min and curve_max at t
}

@(typ_guid={guid="6b9e4d27-8c15-4f3a-b0d2-5a7c1e86f943"})
MinMax_Curve :: struct {
    mode:      MinMax_Mode,
    value_min: f32,
    value_max: f32,
    curve_min: Curve,
    curve_max: Curve,
}

minmax_constant :: proc(v: f32) -> MinMax_Curve {
    return {mode = .Constant, value_min = v}
}

minmax_range :: proc(lo, hi: f32) -> MinMax_Curve {
    return {mode = .Random_Two_Constants, value_min = lo, value_max = hi}
}

// `t` is the normalized curve time (a particle system passes cycle time /
// duration), `r` the caller's 0..1 random sample — passed in so the caller
// controls the random stream.
minmax_eval :: proc(mm: ^MinMax_Curve, t, r: f32) -> f32 {
    switch mm.mode {
    case .Constant:
        return mm.value_min
    case .Random_Two_Constants:
        return math.lerp(mm.value_min, mm.value_max, r)
    case .Curve:
        return curve_eval(&mm.curve_min, t, mm.value_min)
    case .Random_Two_Curves:
        return math.lerp(
            curve_eval(&mm.curve_min, t, mm.value_min),
            curve_eval(&mm.curve_max, t, mm.value_max), r)
    }
    return mm.value_min
}

minmax_cleanup :: proc(mm: ^MinMax_Curve) {
    delete(mm.curve_min.keys)
    delete(mm.curve_max.keys)
}

// Field cleanups for the override-revert walk (type_cleanup_by_typeid frees
// the live field before unmarshaling the baseline back in).
@(cleanup={type=Curve, priority=0})
type_cleanup_curve_field :: proc(c: ^Curve) {
    delete(c.keys)
}

@(cleanup={type=MinMax_Curve, priority=0})
type_cleanup_minmax_curve_field :: proc(mm: ^MinMax_Curve) {
    minmax_cleanup(mm)
}

@(cleanup={type=Gradient, priority=0})
type_cleanup_gradient_field :: proc(g: ^Gradient) {
    delete(g.keys)
}
