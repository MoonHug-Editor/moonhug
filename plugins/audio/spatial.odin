package audio

// Pure spatial math, Unity's model:
// - logarithmic rolloff: full volume inside min_distance, min/d beyond it,
//   held constant past max_distance
// - balance pan from the listener-space azimuth (x/z plane), continuous
//   with 2D at center
// - spatial_blend lerps both effects between 2D (0) and 3D (1)

import "core:math"
import "core:math/linalg"
import engine "moonhug:engine"

Spatial_Gains :: struct {
	gain:  f32, // distance attenuation, multiply into the track gain
	left:  f32, // stereo balance, 1/1 = centered
	right: f32,
}

spatial_gains :: proc(
	listener_pos: [3]f32, listener_rot: [4]f32,
	source_pos: [3]f32,
	min_distance, max_distance, blend: f32,
) -> Spatial_Gains {
	if blend <= 0 do return {1, 1, 1}

	rel_world := source_pos - listener_pos
	q := engine.quat_to_native(listener_rot)
	rel := linalg.quaternion128_mul_vector3(linalg.quaternion_inverse(q), rel_world)

	mn := max(min_distance, 0.001)
	mx := max(max_distance, mn)
	d := clamp(linalg.length(rel), mn, mx)
	atten := mn / d

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
