package tests

// engine.Curve / engine.Gradient evaluation: empty defaults (module off),
// endpoint clamping, linear interpolation, key order.

import "../engine"
import "core:testing"

@(test)
test_curve_eval :: proc(t: ^testing.T) {
	c: engine.Curve
	defer delete(c.keys)

	testing.expect_value(t, engine.curve_eval(&c, 0.5), 1)    // empty = module off
	testing.expect_value(t, engine.curve_eval(&c, 0.5, 0), 0) // caller default

	append(&c.keys, engine.Curve_Key{t = 0.2, value = 1})
	append(&c.keys, engine.Curve_Key{t = 0.8, value = 3})
	testing.expect_value(t, engine.curve_eval(&c, 0), 1)   // clamp before first
	testing.expect_value(t, engine.curve_eval(&c, 1), 3)   // clamp after last
	testing.expect_value(t, engine.curve_eval(&c, 0.5), 2) // midpoint lerp
}

@(test)
test_gradient_eval :: proc(t: ^testing.T) {
	g: engine.Gradient
	defer delete(g.keys)

	testing.expect_value(t, engine.gradient_eval(&g, 0.3), [4]f32{1, 1, 1, 1}) // empty = white

	append(&g.keys, engine.Gradient_Key{t = 0, color = {1, 1, 1, 1}})
	append(&g.keys, engine.Gradient_Key{t = 1, color = {1, 0, 1, 0}})
	testing.expect_value(t, engine.gradient_eval(&g, 0), [4]f32{1, 1, 1, 1})
	testing.expect_value(t, engine.gradient_eval(&g, 1), [4]f32{1, 0, 1, 0})
	mid := engine.gradient_eval(&g, 0.5)
	testing.expect(t, abs(mid.g - 0.5) < 0.001 && abs(mid.a - 0.5) < 0.001, "midpoint blends linearly")
}
