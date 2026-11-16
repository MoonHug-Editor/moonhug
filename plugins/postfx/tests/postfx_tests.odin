package postfx_tests

// The tonemap's colour grading math (grading.odin): the defaults change
// nothing, and each control moves colour the way its description says.

import "core:math/linalg"
import "core:testing"
import postfx "moonhug:packages/postfx"
import "moonhug:packages/engine"

@(private = "file")
_near :: proc(a, b: [3]f32, eps: f32 = 1e-3) -> bool {
	return abs(a.x - b.x) < eps && abs(a.y - b.y) < eps && abs(a.z - b.z) < eps
}

@(test)
test_grading_defaults_are_identity :: proc(t: ^testing.T) {
	balance, hue_sat, contrast := postfx.grading_matrices(postfx.COLOR_GRADING_DEFAULT)
	testing.expect(t, balance == linalg.MATRIX3F32_IDENTITY, "white balance and filter")
	testing.expect(t, hue_sat == linalg.MATRIX3F32_IDENTITY, "hue and saturation")
	testing.expect_value(t, contrast, f32(1))
}

// Warmer: a white lit scene comes out redder than blue. Cooler: the other
// way. Greener tint: green above red and blue. Small moves stay small.
@(test)
test_white_balance_directions :: proc(t: ^testing.T) {
	white := [3]f32{1, 1, 1}
	warm := postfx.white_balance_matrix(50, 0) * white
	cool := postfx.white_balance_matrix(-50, 0) * white
	green := postfx.white_balance_matrix(0, 50) * white
	testing.expectf(t, warm.r > warm.b, "warmer is redder: %v", warm)
	testing.expectf(t, cool.b > cool.r, "cooler is bluer: %v", cool)
	testing.expectf(t, green.g > green.r && green.g > green.b, "greener tint: %v", green)
	slight := postfx.white_balance_matrix(5, 0) * white
	testing.expectf(t, _near(slight, white, 0.05), "a small warm move stays near white: %v", slight)
}

// A 120 degree turn around the grey axis takes red to green; greys stay.
// Saturation -100 leaves only luminance.
@(test)
test_hue_and_saturation :: proc(t: ^testing.T) {
	g := postfx.COLOR_GRADING_DEFAULT
	g.hue_shift = 120
	_, hue, _ := postfx.grading_matrices(g)
	testing.expectf(t, _near(hue * [3]f32{1, 0, 0}, {0, 1, 0}), "red turns to green: %v", hue * [3]f32{1, 0, 0})
	testing.expectf(t, _near(hue * [3]f32{0.3, 0.3, 0.3}, {0.3, 0.3, 0.3}), "grey stays")

	g = postfx.COLOR_GRADING_DEFAULT
	g.saturation = -100
	_, sat, _ := postfx.grading_matrices(g)
	c := sat * [3]f32{1, 0.5, 0.25}
	luma := f32(0.2126 * 1 + 0.7152 * 0.5 + 0.0722 * 0.25)
	testing.expectf(t, _near(c, {luma, luma, luma}), "greyscale at its luminance: %v", c)
}

// The bloom's chain: every level it renders into is a target it declares,
// each downsample level half the size of the one before, and each upsample
// level the size of the downsample level it combines with.
@(test)
test_bloom_chain_declares_its_levels :: proc(t: ^testing.T) {
	step := engine.render_step_find("postfx_bloom")
	if !testing.expect(t, step != nil, "the bloom step is registered") do return
	scale_of :: proc(step: ^engine.Render_Step, name: string) -> f32 {
		for d in step.writes do if d.name == name do return d.scale
		return -1
	}
	prev := scale_of(step, postfx.BLOOM_SOURCE)
	testing.expect_value(t, prev, f32(0.5))
	testing.expect_value(t, scale_of(step, postfx.BLOOM_TARGET), f32(0.5))
	downs := postfx.BLOOM_DOWN
	ups := postfx.BLOOM_UP
	for name, i in downs {
		s := scale_of(step, name)
		testing.expectf(t, s == prev / 2, "%s is half the level before it, %v", name, s)
		if i < len(ups) do testing.expectf(t, scale_of(step, ups[i]) == s, "%s is the size of %s", ups[i], name)
		prev = s
	}
}
