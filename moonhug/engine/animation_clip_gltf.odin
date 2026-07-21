package engine

// glTF animation → AnimationClip conversion, used by the editor's
// "Assets/Extract Assets" (asset_extract_gltf.odin). Lives in the engine next
// to the mesh importer's cgltf use so it's testable without the editor.

import cgltf "vendor:cgltf"
import "core:strings"

// AnimationClip (temp-allocated) from a glTF animation: every TRS channel
// becomes an Animation_Channel keyed by the node's name path. CUBICSPLINE
// samplers keep only the middle element of each [in-tangent, value,
// out-tangent] triplet and play back linearly; morph-weight channels are
// skipped (no morph targets in the renderer).
animation_clip_from_gltf :: proc(an: ^cgltf.animation) -> (clip: AnimationClip, ok: bool) {
	clip.wrap = .Once // Unity's imported-clip default (loop is a play-time choice)
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

		values := make([dynamic][4]f32, count, context.temp_allocator)
		for k in 0 ..< int(count) {
			base := (k * stride + offset) * int(comp)
			v: [4]f32
			for c in 0 ..< int(comp) do v[c] = raw[base + c]
			values[k] = v
		}
		for tm in times do clip.length = max(clip.length, tm)
		append(&clip.channels, Animation_Channel{
			target = _gltf_node_path(ch.target_node),
			path   = path,
			step   = ch.sampler.interpolation == .step,
			times  = times,
			values = values,
		})
	}
	return clip, len(clip.channels) > 0
}

// Node's name path from the hierarchy root down, "/"-joined (temp-allocated).
// Unnamed nodes contribute the placeholder "node".
_gltf_node_path :: proc(node: ^cgltf.node) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	for n := node; n != nil; n = n.parent {
		name := "node"
		if n.name != nil && len(string(n.name)) > 0 do name = string(n.name)
		inject_at(&parts, 0, name)
	}
	return strings.join(parts[:], "/", context.temp_allocator)
}
