package postfx

// Colour grading, applied by the tonemap step (plugins/postfx/docs/PostFX.md
// "Colour grading"): in linear light before the operator, white balance and
// a colour filter, then contrast, then hue shift and saturation, and after
// the operator a lookup texture. The linear parts are two 3x3 matrices built
// here once per draw, so the shader does two matrix multiplies whatever is
// set. Every default leaves the colour as it is.

import "core:math"
import "core:math/linalg"
import gfx "moonhug:libs/gfx"
import "moonhug:packages/engine"

Color_Grading :: struct {
	// White balance: warmer (+) or cooler (-), and greener (+) or more
	// magenta (-). Each corrects for light of that cast: +100 treats the
	// scene's white as light of 13000 K, -100 as 3250 K.
	temperature:      f32 `decor:range(-100, 100)`,
	tint:             f32 `decor:range(-100, 100)`,
	// Multiplies every colour: white leaves it as it is.
	color_filter:     [4]f32 `decor:color()`,
	// Around middle grey: + pushes tones apart, -100 makes everything grey.
	contrast:         f32 `decor:range(-100, 100)`,
	// Turns every hue around the colour wheel, in degrees.
	hue_shift:        f32 `decor:range(-180, 180)`,
	// -100 is greyscale, +100 twice the colourfulness.
	saturation:       f32 `decor:range(-100, 100)`,
	// A lookup texture, applied after the operator to the display colour: a
	// strip of N squares N texels on a side (1024 x 32 for N = 32), red across
	// each square, green down it, blue picking the square left to right.
	// assets/neutral_lut_32.png is one that changes nothing: grade a
	// screenshot, apply the same adjustments to it, and assign the result.
	lut:              engine.Asset_GUID `ext:"png"`,
	lut_contribution: f32 `decor:range(0, 1)`,
}

COLOR_GRADING_DEFAULT :: Color_Grading{color_filter = {1, 1, 1, 1}, lut_contribution = 1}

// The tonemap shader's grading inputs: before contrast (white balance and
// filter), after it (hue and saturation), and contrast as a slope in log2.
grading_matrices :: proc(g: Color_Grading) -> (balance, hue_sat: matrix[3, 3]f32, contrast: f32) {
	filter := gfx.srgb_to_linear(g.color_filter)
	balance = linalg.matrix3_scale_f32({filter.r, filter.g, filter.b}) * white_balance_matrix(g.temperature, g.tint)
	hue_sat = _saturation_matrix(1 + clamp(g.saturation, -100, 100) / 100) * _hue_matrix(math.to_radians(g.hue_shift))
	contrast = 1 + clamp(g.contrast, -100, 100) / 100
	return
}

// Linear sRGB to linear sRGB, correcting for light whose white is the
// temperature and tint given (both 0: the identity). The source white sits
// on the black-body curve at 6500 K x 2^(temperature / 100), moved toward
// magenta by tint (green for negative), and is adapted (Bradford) to the
// curve's 6500 K white.
white_balance_matrix :: proc(temperature, tint: f32) -> matrix[3, 3]f32 {
	if temperature == 0 && tint == 0 do return linalg.MATRIX3F32_IDENTITY
	src := _planck_xy(6500 * math.pow(2, clamp(temperature, -100, 100) / 100))
	src.y -= clamp(tint, -100, 100) / 100 * 0.03
	dst := _planck_xy(6500)

	// Linear sRGB (D65) to XYZ, and the Bradford cone response.
	RGB_TO_XYZ :: matrix[3, 3]f32{
		0.4124564, 0.3575761, 0.1804375,
		0.2126729, 0.7151522, 0.0721750,
		0.0193339, 0.1191920, 0.9503041,
	}
	BRADFORD :: matrix[3, 3]f32{
		 0.8951,  0.2664, -0.1614,
		-0.7502,  1.7135,  0.0367,
		 0.0389, -0.0685,  1.0296,
	}
	xyz :: proc(xy: [2]f32) -> [3]f32 {
		return {xy.x / xy.y, 1, (1 - xy.x - xy.y) / xy.y}
	}
	lms_src := BRADFORD * xyz(src)
	lms_dst := BRADFORD * xyz(dst)
	adapt := linalg.inverse(BRADFORD) * linalg.matrix3_scale_f32(lms_dst / lms_src) * BRADFORD
	return linalg.inverse(RGB_TO_XYZ) * adapt * RGB_TO_XYZ
}

// The chromaticity of a black body at `kelvin` (1667 K to 25000 K): the
// cubic fit of Kim et al. to the Planckian locus.
@(private = "file")
_planck_xy :: proc(kelvin: f32) -> [2]f32 {
	t := clamp(kelvin, 1667, 25000)
	t2 := t * t
	t3 := t2 * t
	x := t <= 4000 ? -0.2661239e9 / t3 - 0.2343589e6 / t2 + 0.8776956e3 / t + 0.179910 : -3.0258469e9 / t3 + 2.1070379e6 / t2 + 0.2226347e3 / t + 0.240390
	x2 := x * x
	x3 := x2 * x
	y: f32
	switch {
	case t <= 2222: y = -1.1063814 * x3 - 1.34811020 * x2 + 2.18555832 * x - 0.20219683
	case t <= 4000: y = -0.9549476 * x3 - 1.37418593 * x2 + 2.09137015 * x - 0.16748867
	case:           y =  3.0817580 * x3 - 5.87338670 * x2 + 3.75112997 * x - 0.37001483
	}
	return {x, y}
}

// A turn of every colour around the grey axis (1, 1, 1): greys stay, hues
// move round the wheel.
@(private = "file")
_hue_matrix :: proc(angle: f32) -> matrix[3, 3]f32 {
	if angle == 0 do return linalg.MATRIX3F32_IDENTITY
	return linalg.matrix3_rotate_f32(angle, linalg.normalize([3]f32{1, 1, 1}))
}

// Each colour moved away from (s > 1) or toward (s < 1) its luminance.
@(private = "file")
_saturation_matrix :: proc(s: f32) -> matrix[3, 3]f32 {
	if s == 1 do return linalg.MATRIX3F32_IDENTITY
	luma := [3]f32{0.2126, 0.7152, 0.0722}
	m: matrix[3, 3]f32
	for r in 0 ..< 3 do for c in 0 ..< 3 do m[r, c] = (r == c ? s : 0) + (1 - s) * luma[c]
	return m
}
