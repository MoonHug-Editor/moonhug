package animation

// glTF animation → AnimationClip conversion, used by the editor's
// "Assets/Extract Assets" (asset_extract_gltf.odin). Lives in the engine next
// to the mesh importer's cgltf use so it's testable without the editor.

import cgltf "vendor:cgltf"
import "moonhug:packages/engine"
import "core:strings"

// AnimationClip (temp-allocated) from a glTF animation: every TRS channel
// becomes an Animation_Channel keyed by the node's name path. Per sampler:
//   - LINEAR: Linear keys (no `modes`)
//   - STEP: `step` set
//   - CUBICSPLINE: each [in-tangent, value, out-tangent] triplet becomes a
//     Free key with those tangents. glTF tangents are already in value units
//     per second, so the clip plays the exact curve. Rotation rows keep the
//     tangents but slerp
// Morph-weight channels are skipped (no morph targets in the renderer).
animation_clip_from_gltf :: proc(data: ^cgltf.data, an: ^cgltf.animation) -> (clip: AnimationClip, ok: bool) {
	clip.wrap = .Once // the imported-clip default (loop is a play-time choice)
	clip.channels = make([dynamic]Animation_Channel, context.temp_allocator)
	for &ch in an.channels {
		if ch.target_node == nil || ch.sampler == nil do continue
		if ch.sampler.input == nil || ch.sampler.output == nil do continue
		path: Animation_Path
		comp: uint
		#partial switch ch.target_path {
		case .translation: path = .Position; comp = 3
		case .rotation:    path = .Rotation; comp = 4
		case .scale:       path = .Scale;    comp = 3
		case: continue
		}

		count := ch.sampler.input.count
		if count == 0 || ch.sampler.output.count == 0 do continue
		times := make([dynamic]f32, count, context.temp_allocator)
		if cgltf.accessor_unpack_floats(ch.sampler.input, raw_data(times), count) < count do continue

		// CUBICSPLINE outputs 3 elements per key; the value is the middle one.
		stride, offset := 1, 0
		if ch.sampler.interpolation == .cubic_spline {
			stride, offset = 3, 1
		}
		out_count := ch.sampler.output.count
		if out_count < count * uint(stride) do continue
		raw := make([]f32, out_count * comp, context.temp_allocator)
		if cgltf.accessor_unpack_floats(ch.sampler.output, raw_data(raw), out_count * comp) < out_count * comp do continue

		lanes :: proc(raw: []f32, element, comp: int) -> (v: [4]f32) {
			for c in 0 ..< comp do v[c] = raw[element * comp + c]
			return
		}
		values := make([dynamic][4]f32, count, context.temp_allocator)
		for k in 0 ..< int(count) do values[k] = lanes(raw, k * stride + offset, int(comp))
		// CUBICSPLINE position and scale keys become Free keys with the glTF
		// tangents. A rotation row slerps and never reads tangents, so a
		// CUBICSPLINE rotation keeps only its values and slerps between them.
		modes: [dynamic]Key_Mode
		tangents: [dynamic][2][4]f32
		if ch.sampler.interpolation == .cubic_spline && path != .Rotation {
			modes = make([dynamic]Key_Mode, count, context.temp_allocator)
			tangents = make([dynamic][2][4]f32, count, context.temp_allocator)
			for k in 0 ..< int(count) {
				modes[k] = .Free
				tangents[k] = {lanes(raw, k * 3, int(comp)), lanes(raw, k * 3 + 2, int(comp))}
			}
		}
		for tm in times do clip.length = max(clip.length, tm)
		append(&clip.channels, Animation_Channel{
			target   = _gltf_node_path(data, ch.target_node),
			path     = path,
			step     = ch.sampler.interpolation == .step,
			times    = times,
			values   = values,
			modes    = modes,
			tangents = tangents,
		})
	}
	return clip, len(clip.channels) > 0
}

// Node's name path from the hierarchy root down, "/"-joined (temp-allocated).
// Names come from engine.gltf_node_name (scene_gltf.odin), matching the transforms
// scene_from_gltf creates.
_gltf_node_path :: proc(data: ^cgltf.data, node: ^cgltf.node) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	for n := node; n != nil; n = n.parent {
		inject_at(&parts, 0, engine.gltf_node_name(data, n))
	}
	return strings.join(parts[:], "/", context.temp_allocator)
}
