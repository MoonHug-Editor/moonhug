package audio

// Pure spatial math:
// - distance rolloff (Audio_Rolloff): full volume inside min_distance, then
//   quieter out to max_distance
// - balance pan from the listener-space azimuth (x/z plane), continuous
//   with 2D at center
// - spatial_blend lerps both effects between 2D (0) and 3D (1)

import "core:math"
import "core:math/linalg"
import engine "moonhug:packages/engine"

// How a 3D source gets quieter between min_distance and max_distance.
Audio_Rolloff :: enum u8 {
	Logarithmic,   // min / distance, as sound does. Past max_distance it stays at min / max: never silent
	Linear,        // a straight line from full at min_distance to silent at max_distance
	Smooth_Cutoff, // Logarithmic near the source, faded to silent at max_distance
}

// The volume, 0 to 1, at `distance` from the source.
rolloff_gain :: proc(rolloff: Audio_Rolloff, distance, min_distance, max_distance: f32) -> f32 {
	mn := max(min_distance, 0.001)
	mx := max(max_distance, mn)
	if distance <= mn do return 1
	log := mn / min(distance, mx)
	switch rolloff {
	case .Logarithmic:
		return log
	case .Linear:
		if distance >= mx do return 0
		return 1 - (distance - mn) / (mx - mn)
	case .Smooth_Cutoff:
		if distance >= mx do return 0
		t := (distance - mn) / (mx - mn)
		window := 1 - t * t
		return log * window * window
	}
	return log
}

Spatial_Gains :: struct {
	gain:  f32, // distance attenuation, multiply into the track gain
	left:  f32, // stereo balance, 1/1 = centered
	right: f32,
}

spatial_gains :: proc(
	listener_pos: [3]f32, listener_rot: [4]f32,
	source_pos: [3]f32,
	min_distance, max_distance, blend: f32,
	rolloff := Audio_Rolloff.Logarithmic,
) -> Spatial_Gains {
	if blend <= 0 do return {1, 1, 1}

	rel_world := source_pos - listener_pos
	q := engine.quat_to_native(listener_rot)
	rel := linalg.quaternion128_mul_vector3(linalg.quaternion_inverse(q), rel_world)

	atten := rolloff_gain(rolloff, linalg.length(rel), min_distance, max_distance)

	pan: f32
	horiz := math.sqrt(rel.x * rel.x + rel.z * rel.z)
	if horiz > 0.0001 do pan = clamp(rel.x / horiz, -1, 1)

	b := min(blend, 1)
	pan *= b
	return {
		gain  = 1 + (atten - 1) * b,
		left  = clamp(1 - pan, 0, 1),
		right = clamp(1 + pan, 0, 1),
	}
}
