package animation_editor

// The pure parts of key interpolation editing in the Animation window: the
// slopes the presets use, the modes a row offers, and the edits that set a
// key's mode or tangents while keeping `modes` and `tangents` parallel to
// `times` (plugins/animation/docs/concepts/ClipFormat.md "Interpolation").
// Nothing here touches imgui or the document. A caller that edits a document
// sets context.allocator to the document's allocator first, since `modes` and
// `tangents` may be created here.

import "core:math/linalg"
import anim "moonhug:packages/animation"

// The in slope of key `k` when it is Linear: the straight line from the
// previous key, 0 at the first key.
key_linear_slope_in :: proc(times: []f32, vals: [][4]f32, k: int) -> [4]f32 {
	if k <= 0 || k >= len(vals) do return {}
	return anim.animation_key_slope(times, vals, k - 1, k)
}

// The out slope of key `k` when it is Linear: the straight line to the next
// key, 0 at the last key.
key_linear_slope_out :: proc(times: []f32, vals: [][4]f32, k: int) -> [4]f32 {
	if k < 0 || k >= len(vals) - 1 do return {}
	return anim.animation_key_slope(times, vals, k, k + 1)
}

// The tangents of key `k` when it is Smooth, by the sampler's own rule.
key_smooth_tangents :: proc(times: []f32, vals: [][4]f32, k: int) -> (tin, tout: [4]f32) {
	return anim.animation_key_smooth_tangents(times, vals, k)
}

// Tangent presets. Each one turns the key Free with these tangents:
//   - Flat: both zero (ease in and out)
//   - Ease_In: in zero, out the linear slope to the next key
//   - Ease_Out: out zero, in the linear slope from the previous key
//   - Auto: the Smooth tangents
Key_Preset :: enum {
	Flat,
	Ease_In,
	Ease_Out,
	Auto,
}

key_preset_tangents :: proc(times: []f32, vals: [][4]f32, k: int, preset: Key_Preset) -> (tin, tout: [4]f32) {
	switch preset {
	case .Flat:
	case .Ease_In:
		tout = key_linear_slope_out(times, vals, k)
	case .Ease_Out:
		tin = key_linear_slope_in(times, vals, k)
	case .Auto:
		tin, tout = key_smooth_tangents(times, vals, k)
	}
	return
}

Key_Modes :: bit_set[anim.Key_Mode]

// The modes a row's keys can take:
//   - a float row: all four
//   - a transform Rotation row: Linear and Step, since rotations slerp and
//     ignore tangents
//   - an int, reference or string row: none, its keys always hold
channel_modes_allowed :: proc(ch: ^anim.Animation_Channel) -> Key_Modes {
	if !anim.animation_channel_is_float(ch) do return {}
	if !anim.animation_channel_is_property(ch) && ch.path == .Rotation do return {.Linear, .Step}
	return {.Linear, .Smooth, .Step, .Free}
}

// Gives every key an entry in `modes`, each holding the mode the sampler
// already uses for it: a channel without `modes` fills it with Step when
// `step` is set, else Linear, and a short `modes` grows with Linear. `step`
// is cleared, since a channel with `modes` ignores it.
channel_modes_materialize :: proc(ch: ^anim.Animation_Channel) {
	n := len(ch.times)
	fill := anim.Key_Mode.Linear
	if len(ch.modes) == 0 && ch.step do fill = .Step
	for len(ch.modes) < n do append(&ch.modes, fill)
	ch.step = false
}

// Sets key `k`'s in and out tangents and makes it Free. `tangents` grows
// with flat entries up to the key.
channel_set_key_tangents :: proc(ch: ^anim.Animation_Channel, k: int, tin, tout: [4]f32) {
	assert(k >= 0 && k < len(ch.times), "animation: tangent edit of a key the row does not have")
	channel_modes_materialize(ch)
	ch.modes[k] = .Free
	for len(ch.tangents) <= k do append(&ch.tangents, [2][4]f32{})
	ch.tangents[k] = {tin, tout}
}

// Sets key `k`'s mode. A Linear or Smooth key turning Free keeps the tangents
// the sampler computes for its current mode, so the curve does not move.
// A Step key turning Free keeps its in tangent and gets a flat out tangent. A
// Free key cannot hold, so the segment after it becomes a cubic curve that
// leaves the key flat and reaches the next key's value.
// Setting a mode the row does not allow is a caller bug.
channel_set_key_mode :: proc(ch: ^anim.Animation_Channel, k: int, mode: anim.Key_Mode) {
	assert(k >= 0 && k < len(ch.times), "animation: mode edit of a key the row does not have")
	assert(mode in channel_modes_allowed(ch), "animation: the row does not allow that mode")
	if mode == .Free {
		was := anim._animation_key_mode(ch, k)
		if was == .Free do return
		tin, tout := anim._animation_key_tangents(ch, anim.animation_channel_floats(ch)[:], k)
		if was == .Step do tout = {}
		channel_set_key_tangents(ch, k, tin, tout)
		return
	}
	channel_modes_materialize(ch)
	ch.modes[k] = mode
}

// Applies a preset to key `k`: the key becomes Free with the preset's
// tangents.
channel_apply_preset :: proc(ch: ^anim.Animation_Channel, k: int, preset: Key_Preset) {
	assert(.Free in channel_modes_allowed(ch), "animation: presets need a row that allows Free keys")
	tin, tout := key_preset_tangents(ch.times[:], anim.animation_channel_floats(ch)[:], k, preset)
	channel_set_key_tangents(ch, k, tin, tout)
}

// --- Tangent handles ----------------------------------------------------------------------
//
// The curve view maps time to x at `pps` pixels per second and value to y at
// `vpx` pixels per value unit, y growing downward.

// The screen offset from a key point to its out handle for slope `m`: `len`
// pixels along the tangent, toward later time. The in handle is the negated
// offset of its own slope.
tangent_handle_offset :: proc(m, pps, vpx, len: f32) -> [2]f32 {
	d := [2]f32{pps, -m * vpx}
	l := linalg.length(d)
	if l <= 0 do return {len, 0}
	return d * (len / l)
}

// The slope a handle dragged to screen offset `d` from its key point gives. An
// out handle stays right of the key and an in handle left of it, at least
// one pixel, so the slope stays finite.
tangent_from_handle :: proc(d: [2]f32, pps, vpx: f32, out: bool) -> f32 {
	dx := out ? max(d.x, 1) : min(d.x, -1)
	dt := dx / max(pps, 0.0001)
	dv := -d.y / max(vpx, 0.0001)
	return dv / dt
}
