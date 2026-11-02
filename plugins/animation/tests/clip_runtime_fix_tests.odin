package animation_tests

// Runtime clip behaviour: a Text property write owns its string on the
// default allocator, a glTF CUBICSPLINE rotation keeps no tangents, and a trim
// edge outside the key range holds.

import "base:runtime"
import cgltf "vendor:cgltf"
import "core:encoding/base64"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"
import anim "moonhug:packages/animation"

@(private = "file")
_float_channel :: proc(times: []f32, values: [][4]f32, path := anim.Animation_Path.Position) -> anim.Animation_Channel {
	ch := anim.Animation_Channel{path = path}
	ch.times = make([dynamic]f32)
	append(&ch.times, ..times)
	vals := make([dynamic][4]f32)
	append(&vals, ..values)
	ch.values = vals
	return ch
}

@(private = "file")
_near :: proc(a, b: f32, eps: f32 = 1e-4) -> bool {
	return abs(a - b) <= eps
}

// A Text write under the temp allocator survives free_all: the field's string
// lives on the default allocator.
@(test)
test_clip_runtime_text_write_pins_default_allocator :: proc(t: ^testing.T) {
	field: string
	defer delete(field, runtime.default_allocator())
	{
		context.allocator = context.temp_allocator
		src := strings.clone("walk", context.temp_allocator)
		anim._prop_write_value(&field, .Text, typeid_of(string), src)
	}
	free_all(context.temp_allocator)
	// Reuse the temp memory so a string left there reads different text.
	_ = strings.clone("XXXXXXXXXXXXXXXX", context.temp_allocator)
	testing.expect_value(t, field, "walk")

	// A second write frees the first string on the same allocator.
	{
		context.allocator = context.temp_allocator
		anim._prop_write_value(&field, .Text, typeid_of(string), "run")
	}
	free_all(context.temp_allocator)
	testing.expect_value(t, field, "run")
}

// A one-node glTF with a CUBICSPLINE translation and a CUBICSPLINE rotation
// over 2 s, buffers inline. Translation key 0: value 0, out tangent 3. Key 1:
// in tangent -1, value 1. Rotation: identity to 90 degrees about z with
// nonzero tangents.
@(private = "file")
_cubic_trs_gltf :: proc() -> string {
	h :: 0.70710678
	floats := [?]f32{
		0, 2, // times
		0, 0, 0, /**/ 0, 0, 0, /**/ 3, 0, 0, // translation key 0: in, value, out
		-1, 0, 0, /**/ 1, 0, 0, /**/ 0, 0, 0, // translation key 1
		0, 0, 1, 0, /**/ 0, 0, 0, 1, /**/ 0, 0, 1, 0, // rotation key 0
		0, 0, 1, 0, /**/ 0, 0, h, h, /**/ 0, 0, 1, 0, // rotation key 1
	}
	bytes := slice.to_bytes(floats[:])
	b64 := base64.encode(bytes, allocator = context.temp_allocator)
	return fmt.tprintf(`{{
  "asset": {{"version": "2.0"}},
  "scene": 0,
  "scenes": [{{"nodes": [0]}}],
  "nodes": [{{"name": "Cube"}}],
  "buffers": [{{"byteLength": %d, "uri": "data:application/octet-stream;base64,%s"}}],
  "bufferViews": [
    {{"buffer": 0, "byteOffset": 0, "byteLength": 8}},
    {{"buffer": 0, "byteOffset": 8, "byteLength": 72}},
    {{"buffer": 0, "byteOffset": 80, "byteLength": 96}}
  ],
  "accessors": [
    {{"bufferView": 0, "componentType": 5126, "count": 2, "type": "SCALAR", "min": [0], "max": [2]}},
    {{"bufferView": 1, "componentType": 5126, "count": 6, "type": "VEC3"}},
    {{"bufferView": 2, "componentType": 5126, "count": 6, "type": "VEC4"}}
  ],
  "animations": [{{
    "channels": [
      {{"sampler": 0, "target": {{"node": 0, "path": "translation"}}}},
      {{"sampler": 1, "target": {{"node": 0, "path": "rotation"}}}}
    ],
    "samplers": [
      {{"input": 0, "output": 1, "interpolation": "CUBICSPLINE"}},
      {{"input": 0, "output": 2, "interpolation": "CUBICSPLINE"}}
    ]
  }}]
}}`, len(bytes), b64)
}

// A CUBICSPLINE rotation keeps only its values: no modes, no tangents, not
// step. The translation row keeps its Free keys and tangents.
@(test)
test_clip_runtime_gltf_cubic_rotation_drops_tangents :: proc(t: ^testing.T) {
	text := _cubic_trs_gltf()
	opts := cgltf.options{}
	data, res := cgltf.parse(opts, raw_data(text), uint(len(text)))
	testing.expect(t, res == .success, "the glTF parses")
	if res != .success do return
	defer cgltf.free(data)
	lres := cgltf.load_buffers(opts, data, "inline.gltf")
	testing.expect(t, lres == .success, "the inline buffer loads")
	if lres != .success do return

	clip, ok := anim.animation_clip_from_gltf(data, &data.animations[0])
	testing.expect(t, ok && len(clip.channels) == 2, "two channels convert")
	if !ok || len(clip.channels) != 2 do return
	for &ch in clip.channels {
		#partial switch ch.path {
		case .Rotation:
			testing.expect(t, !ch.step, "a cubic rotation is not a step row")
			testing.expect_value(t, len(ch.modes), 0)
			testing.expect_value(t, len(ch.tangents), 0)
			vals := ch.values.([dynamic][4]f32)
			testing.expect(t, len(vals) == 2 && vals[0] == {0, 0, 0, 1}, "the values are the middle elements")
		case .Position:
			testing.expect(t, len(ch.modes) == 2 && ch.modes[0] == .Free && ch.modes[1] == .Free, "translation keys are Free")
			testing.expect(t, len(ch.tangents) == 2, "translation keys keep tangents")
			if len(ch.tangents) == 2 {
				testing.expect_value(t, ch.tangents[0][1], [4]f32{3, 0, 0, 0})
			}
		case:
			testing.fail_now(t, "only position and rotation rows expected")
		}
	}
}

// A trim edge outside the key range is a hold: a Free row whose first key has
// a nonzero in tangent and whose last key has a nonzero out tangent samples
// the edge key values outside the key range after the trim.
@(test)
test_clip_runtime_trim_edge_outside_keys_holds :: proc(t: ^testing.T) {
	clip := anim.AnimationClip{length = 2.5}
	clip.channels = make([dynamic]anim.Animation_Channel)
	ch := _float_channel({1, 2}, {{3, 0, 0, 0}, {5, 0, 0, 0}})
	append(&ch.modes, anim.Key_Mode.Free, anim.Key_Mode.Free)
	append(&ch.tangents, [2][4]f32{{4, 0, 0, 0}, {2, 0, 0, 0}}, [2][4]f32{{2, 0, 0, 0}, {-6, 0, 0, 0}})
	append(&clip.channels, ch)
	defer anim.type_cleanup_AnimationClip(&clip)
	src := clip.channels[0]
	mid_want := anim._animation_channel_sample(&src, 1.5).x

	anim.animation_clip_apply_settings(&clip, {trim_start = 0.5, trim_stop = 2.5})
	out := &clip.channels[0]
	testing.expect(t, len(out.modes) == len(out.times) && len(out.tangents) == len(out.times), "modes and tangents stay parallel")
	for p in ([?]f32{0.5, 0.75}) {
		got := anim._animation_channel_sample(out, p - 0.5).x
		testing.expectf(t, _near(got, 3), "before the first key at %v: %v", p, got)
	}
	got := anim._animation_channel_sample(out, 2.25 - 0.5).x
	testing.expectf(t, _near(got, 5), "past the last key at 2.25: %v", got)
	got = anim._animation_channel_sample(out, 1.5 - 0.5).x
	testing.expectf(t, _near(got, mid_want, 1e-3), "inside the key range the curve stays: %v vs %v", got, mid_want)
}
