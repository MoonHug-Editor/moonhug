package audio_tests

// The spatial model: logarithmic distance rolloff clamped to [min, max],
// balance pan from the listener-space azimuth, spatial_blend lerping both
// toward plain 2D.

import "core:math"
import "core:testing"
import "moonhug:engine"
import audio "moonhug:packages/audio"

_close :: proc(a, b: f32) -> bool { return abs(a - b) < 0.001 }

@(test)
test_spatial_gains :: proc(t: ^testing.T) {
	id := engine.QUAT_IDENTITY

	// 2D: everything neutral regardless of positions.
	flat := audio.spatial_gains({0, 0, 0}, id, {100, 0, 0}, 1, 500, 0)
	testing.expect(t, _close(flat.gain, 1) && _close(flat.left, 1) && _close(flat.right, 1))

	// Inside min_distance: full volume, and a centered-front source stays
	// balanced.
	front := audio.spatial_gains({0, 0, 0}, id, {0, 0, 0.5}, 1, 500, 1)
	testing.expect(t, _close(front.gain, 1), "full volume inside min_distance")
	testing.expect(t, _close(front.left, front.right), "front source is centered")

	// Logarithmic rolloff: gain = min/d.
	far := audio.spatial_gains({0, 0, 0}, id, {0, 0, 4}, 1, 500, 1)
	testing.expect(t, _close(far.gain, 0.25), "min/d rolloff")

	// Held past max_distance.
	past := audio.spatial_gains({0, 0, 0}, id, {0, 0, 900}, 1, 500, 1)
	at_max := audio.spatial_gains({0, 0, 0}, id, {0, 0, 500}, 1, 500, 1)
	testing.expect(t, _close(past.gain, at_max.gain), "attenuation holds past max")

	// A source on the listener's +x pans right (right > left).
	right := audio.spatial_gains({0, 0, 0}, id, {5, 0, 0}, 1, 500, 1)
	testing.expect(t, right.right > right.left, "+x source pans right")
	testing.expect(t, _close(right.left, 0), "hard right at full blend")

	// The listener's ORIENTATION matters: yawed 180, the same source is on
	// the listener's left.
	yaw180 := engine.quat_from_euler_xyz(0, 180, 0)
	turned := audio.spatial_gains({0, 0, 0}, yaw180, {5, 0, 0}, 1, 500, 1)
	testing.expect(t, turned.left > turned.right, "yawed listener flips the pan")

	// Half blend halves both effects.
	half := audio.spatial_gains({0, 0, 0}, id, {0, 0, 4}, 1, 500, 0.5)
	testing.expect(t, _close(half.gain, 1 + (0.25 - 1) * 0.5), "blend lerps attenuation")

	// Distance includes the vertical axis, pan does not.
	above := audio.spatial_gains({0, 0, 0}, id, {0, 4, 0}, 1, 500, 1)
	testing.expect(t, _close(above.gain, 0.25), "vertical distance attenuates")
	testing.expect(t, _close(above.left, above.right), "vertical offset does not pan")

	_ = math.PI
}

@(test)
test_audiosource_spatial_defaults :: proc(t: ^testing.T) {
	src: audio.AudioSource
	audio.reset_AudioSource(&src)
	testing.expect_value(t, src.pitch, f32(1))
	testing.expect_value(t, src.mute, false)
	testing.expect_value(t, src.spatial_blend, f32(0))
	testing.expect_value(t, src.min_distance, f32(1))
	testing.expect_value(t, src.max_distance, f32(500))
}
