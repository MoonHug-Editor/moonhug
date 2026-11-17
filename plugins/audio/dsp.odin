package audio

// The filters the mixer groups and the per-source filter components run:
// two-pole low-pass and high-pass (biquads, from the Audio EQ Cookbook),
// on interleaved float PCM, in place. The audio thread runs `biquad_run`, the
// main thread makes the coefficients.

import "core:math"

// The most channels a filter keeps state for. A wider mix passes through the
// extra channels unfiltered.
BIQUAD_MAX_CHANNELS :: 8

Biquad_Coeffs :: struct {
	b0, b1, b2: f32,
	a1, a2:     f32,
}

// What a filter remembers between blocks, per channel.
Biquad_State :: struct {
	z1, z2: [BIQUAD_MAX_CHANNELS]f32,
}

// The coefficients of a low-pass (`high` false) or high-pass filter at
// `cutoff` Hz with resonance `q` (0.707 is flat, higher rings at the cutoff),
// for audio at `rate` samples per second.
biquad_make :: proc(cutoff, q, rate: f32, high: bool) -> Biquad_Coeffs {
	sr := max(rate, 8000)
	fc := clamp(cutoff, 10, sr * 0.49)
	w0 := 2 * math.PI * fc / sr
	cw := math.cos(w0)
	alpha := math.sin(w0) / (2 * max(q, 0.1))
	a0 := 1 + alpha
	b: [3]f32
	if high {
		b = {(1 + cw) / 2, -(1 + cw), (1 + cw) / 2}
	} else {
		b = {(1 - cw) / 2, 1 - cw, (1 - cw) / 2}
	}
	return {b0 = b[0] / a0, b1 = b[1] / a0, b2 = b[2] / a0, a1 = -2 * cw / a0, a2 = (1 - alpha) / a0}
}

// Filters `pcm`, `channels` interleaved, in place.
biquad_run :: proc "contextless" (pcm: []f32, channels: int, c: Biquad_Coeffs, s: ^Biquad_State) {
	if channels <= 0 do return
	ch := min(channels, BIQUAD_MAX_CHANNELS)
	for i := 0; i < len(pcm); i += 1 {
		k := i % channels
		if k >= ch do continue
		x := pcm[i]
		y := c.b0 * x + s.z1[k]
		s.z1[k] = c.b1 * x - c.a1 * y + s.z2[k]
		s.z2[k] = c.b2 * x - c.a2 * y
		pcm[i] = y
	}
}

// Multiplies `pcm` by `gain`.
gain_run :: proc "contextless" (pcm: []f32, gain: f32) {
	if gain == 1 do return
	for &x in pcm do x *= gain
}

// The largest absolute sample of `pcm`.
peak_of :: proc "contextless" (pcm: []f32) -> f32 {
	p: f32
	for x in pcm do p = max(p, abs(x))
	return p
}

// Decibels to a gain: 0 dB is 1, -6 dB about half. -80 dB and below is 0.
db_to_gain :: proc "contextless" (db: f32) -> f32 {
	if db <= -80 do return 0
	return math.pow(10, db / 20)
}

// A gain to decibels, -80 for silence.
gain_to_db :: proc "contextless" (g: f32) -> f32 {
	if g <= 0.0001 do return -80
	return 20 * math.log10(g)
}
