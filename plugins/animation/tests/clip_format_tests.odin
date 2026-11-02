package animation_tests

// The clip format (clip.odin, plugins/animation/docs/AnimationComponent.md
// "Clip format"): typed rows (floats, ints, references, strings) behind one
// `values` key, per-key interpolation modes and tangents on float rows, the
// glTF CUBICSPLINE bake, and the .anim files already on disk loading as they
// are.

import cgltf "vendor:cgltf"
import "core:encoding/base64"
import "core:encoding/json"
import "core:encoding/uuid"
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "moonhug:packages/engine"
import anim "moonhug:packages/animation"
import common "moonhug:tests/common"

// --- JSON helpers -------------------------------------------------------------------------

// A JSON number as f64, false for anything else.
@(private = "file")
_num :: proc(v: json.Value) -> (f64, bool) {
	#partial switch x in v {
	case json.Integer: return f64(x), true
	case json.Float:   return f64(x), true
	}
	return 0, false
}

// Structural equality of two parsed JSON values, numbers compared by value
// (a writer may print 0 as 0.0).
@(private = "file")
_json_equal :: proc(a, b: json.Value) -> bool {
	if na, ok := _num(a); ok {
		nb, okb := _num(b)
		return okb && abs(na - nb) < 1e-6
	}
	#partial switch x in a {
	case json.String:
		y, ok := b.(json.String)
		return ok && x == y
	case json.Boolean:
		y, ok := b.(json.Boolean)
		return ok && x == y
	case json.Null:
		_, ok := b.(json.Null)
		return ok
	case json.Array:
		y, ok := b.(json.Array)
		if !ok || len(x) != len(y) do return false
		for i in 0 ..< len(x) do if !_json_equal(x[i], y[i]) do return false
		return true
	case json.Object:
		y, ok := b.(json.Object)
		if !ok || len(x) != len(y) do return false
		for k, xv in x {
			yv, has := y[k]
			if !has || !_json_equal(xv, yv) do return false
		}
		return true
	}
	return false
}

// The parsed `values` of channel `i` in marshaled clip bytes.
@(private = "file")
_values_json :: proc(t: ^testing.T, data: []byte, i: int) -> json.Array {
	root, err := json.parse(data, .JSON, true, context.temp_allocator)
	testing.expect(t, err == nil, "the marshaled clip parses")
	chans := root.(json.Object)["channels"].(json.Array)
	return chans[i].(json.Object)["values"].(json.Array)
}

// --- On disk ------------------------------------------------------------------------------

// The shape every .anim and artifact holds: an array of [x, y, z, w] arrays.
// It reads as a float row, and writes back as the same shape with no new keys.
@(test)
test_clip_format_float_shape_round_trips :: proc(t: ^testing.T) {
	src := `{"length": 1.0, "channels": [{"target": "", "path": 1, "component": "", "field": "", "step": false,
		"times": [0.0, 0.35, 1.0],
		"values": [[0.0, 0.0, -0.087156, 0.996195], [0.0, 0.0, -0.965926, 0.258819], [0, 0, 0, 1]]}]}`
	clip: anim.AnimationClip
	err := json.unmarshal(transmute([]byte)src, &clip, .JSON, context.allocator)
	defer anim.type_cleanup_AnimationClip(&clip)
	testing.expect(t, err == nil, "today's shape unmarshals")
	if len(clip.channels) != 1 do return
	ch := &clip.channels[0]
	vals, is_f := ch.values.([dynamic][4]f32)
	testing.expect(t, is_f, "an array of arrays is a float row")
	if !is_f do return
	testing.expect_value(t, len(vals), 3)
	testing.expect_value(t, vals[1], [4]f32{0, 0, -0.965926, 0.258819})
	testing.expect_value(t, vals[2], [4]f32{0, 0, 0, 1})
	testing.expect_value(t, len(ch.modes), 0)
	testing.expect_value(t, len(ch.tangents), 0)

	data, merr := json.marshal(clip, {spec = .JSON}, context.temp_allocator)
	testing.expect(t, merr == nil, "the clip marshals")
	orig, _ := json.parse(transmute([]byte)src, .JSON, true, context.temp_allocator)
	want := orig.(json.Object)["channels"].(json.Array)[0].(json.Object)["values"]
	testing.expect(t, _json_equal(json.Value(_values_json(t, data, 0)), want), "values write back in the same shape")

	root, _ := json.parse(data, .JSON, true, context.temp_allocator)
	obj := root.(json.Object)["channels"].(json.Array)[0].(json.Object)
	testing.expect(t, !("modes" in obj) && !("tangents" in obj), "a channel without modes writes no modes or tangents")
}

// An empty `values` is an empty float row.
@(test)
test_clip_format_empty_values_are_floats :: proc(t: ^testing.T) {
	src := `{"length": 1.0, "channels": [{"target": "", "path": 0, "times": [], "values": []}]}`
	clip: anim.AnimationClip
	err := json.unmarshal(transmute([]byte)src, &clip, .JSON, context.allocator)
	defer anim.type_cleanup_AnimationClip(&clip)
	testing.expect(t, err == nil, "an empty row unmarshals")
	if len(clip.channels) == 1 do testing.expect(t, anim.animation_channel_is_float(&clip.channels[0]), "an empty array is a float row")
}

@(private = "file")
_prop_channel :: proc(field: string, values: anim.Channel_Values, times: []f32) -> anim.Animation_Channel {
	ch := anim.Animation_Channel{
		component = strings.clone("0a4f3b1c-8e57-4c2d-9b6a-5d1e7f2c8a90"),
		field     = strings.clone(field),
		values    = values,
	}
	ch.times = make([dynamic]f32)
	append(&ch.times, ..times)
	return ch
}

// Int, reference and string rows write their element type and read back
// exactly: an int above 2^24 (a float row would round it) and a reference
// with a local id far above 2^24.
@(test)
test_clip_format_typed_rows_round_trip :: proc(t: ^testing.T) {
	// The row reads through its own unmarshaler, never by trying variants.
	testing.expect(t, json._user_unmarshalers != nil && typeid_of(anim.Channel_Values) in json._user_unmarshalers^, "Channel_Values has an unmarshaler")
	testing.expect(t, json._user_marshalers != nil && typeid_of(anim.Channel_Values) in json._user_marshalers^, "Channel_Values has a marshaler")

	big := i64(1) << 24 + 1
	guid := _clip_guid(0x91)
	lid := engine.Local_ID(i64(1) << 40 + 3)

	clip := anim.AnimationClip{length = 1}
	clip.channels = make([dynamic]anim.Animation_Channel)
	ints := make([dynamic]i64)
	append(&ints, big, -5)
	append(&clip.channels, _prop_channel("order", ints, {0, 1}))
	refs := make([dynamic]engine.PPtr)
	append(&refs, engine.PPtr{guid = guid, local_id = lid}, engine.PPtr{})
	append(&clip.channels, _prop_channel("mesh", refs, {0, 1}))
	strs := make([dynamic]string)
	append(&strs, strings.clone("hello", strs.allocator), strings.clone("wörld \"q\"", strs.allocator))
	append(&clip.channels, _prop_channel("slot", strs, {0, 1}))
	defer anim.type_cleanup_AnimationClip(&clip)

	data, merr := json.marshal(clip, {spec = .JSON}, context.temp_allocator)
	testing.expect(t, merr == nil, "the clip marshals")
	_, int_el := _values_json(t, data, 0)[0].(json.Integer)
	_, ref_el := _values_json(t, data, 1)[0].(json.Object)
	_, str_el := _values_json(t, data, 2)[0].(json.String)
	testing.expect(t, int_el, "an int row writes numbers")
	testing.expect(t, ref_el, "a reference row writes objects")
	testing.expect(t, str_el, "a string row writes strings")

	loaded: anim.AnimationClip
	uerr := json.unmarshal(data, &loaded, .JSON, context.allocator)
	defer anim.type_cleanup_AnimationClip(&loaded)
	testing.expect(t, uerr == nil, "the clip unmarshals")
	if len(loaded.channels) != 3 do return

	li, iok := loaded.channels[0].values.([dynamic]i64)
	testing.expect(t, iok && len(li) == 2 && li[0] == big && li[1] == -5, "ints read back exactly")
	lr, rok := loaded.channels[1].values.([dynamic]engine.PPtr)
	testing.expect(t, rok && len(lr) == 2 && lr[0].guid == guid && lr[0].local_id == lid && lr[1] == {}, "references read back exactly")
	ls, sok := loaded.channels[2].values.([dynamic]string)
	testing.expect(t, sok && len(ls) == 2 && ls[0] == "hello" && ls[1] == "wörld \"q\"", "strings read back exactly")

	// The document path (editor asset docs, undo) reads the same way.
	doc: anim.AnimationClip
	derr := engine.unmarshal_over_reset(data, &doc, typeid_of(anim.AnimationClip))
	defer anim.type_cleanup_AnimationClip(&doc)
	testing.expect(t, derr == nil, "the document path unmarshals")
	if len(doc.channels) == 3 {
		di, dok := doc.channels[0].values.([dynamic]i64)
		testing.expect(t, dok && di[0] == big, "the document path keeps the int row")
	}
}

// Modes and tangents write when present and read back.
@(test)
test_clip_format_modes_and_tangents_round_trip :: proc(t: ^testing.T) {
	clip := anim.AnimationClip{length = 2}
	clip.channels = make([dynamic]anim.Animation_Channel)
	ch := _float_channel({0, 2}, {{0, 0, 0, 0}, {1, 0, 0, 0}})
	append(&ch.modes, anim.Key_Mode.Free, anim.Key_Mode.Smooth)
	append(&ch.tangents, [2][4]f32{{0, 0, 0, 0}, {3, 0, 0, 0}})
	append(&clip.channels, ch)
	defer anim.type_cleanup_AnimationClip(&clip)

	data, _ := json.marshal(clip, {spec = .JSON}, context.temp_allocator)
	loaded: anim.AnimationClip
	uerr := json.unmarshal(data, &loaded, .JSON, context.allocator)
	defer anim.type_cleanup_AnimationClip(&loaded)
	testing.expect(t, uerr == nil, "the clip unmarshals")
	if len(loaded.channels) != 1 do return
	l := &loaded.channels[0]
	testing.expect(t, len(l.modes) == 2 && l.modes[0] == .Free && l.modes[1] == .Smooth, "modes read back")
	testing.expect(t, len(l.tangents) == 1 && l.tangents[0][1].x == 3, "tangents read back")
}

// Every tracked .anim file in the repository loads with its keys as the file states
// them, through the artifact path and the document path. Nothing is written.
@(test)
test_clip_format_existing_files_load_unchanged :: proc(t: ^testing.T) {
	paths := [?]string{
		"plugins/animation/samples/timeline_sample/assets/rig_idle.anim",
		"plugins/animation/samples/timeline_sample/assets/rig_swing_body.anim",
		"plugins/animation/samples/timeline_sample/assets/rig_swing_prop.anim",
		"plugins/app/assets/meshes/Animations/InterpolationTest_CubicSpline Rotation.anim",
		"plugins/app/assets/meshes/Animations/InterpolationTest_CubicSpline Scale.anim",
		"plugins/app/assets/meshes/Animations/InterpolationTest_CubicSpline Translation.anim",
		"plugins/app/assets/meshes/Animations/InterpolationTest_Linear Rotation.anim",
		"plugins/app/assets/meshes/Animations/InterpolationTest_Linear Scale.anim",
		"plugins/app/assets/meshes/Animations/InterpolationTest_Linear Translation.anim",
		"plugins/app/assets/meshes/Animations/InterpolationTest_Step Rotation.anim",
		"plugins/app/assets/meshes/Animations/InterpolationTest_Step Scale.anim",
		"plugins/app/assets/meshes/Animations/InterpolationTest_Step Translation.anim",
		"plugins/app/assets/meshes/BoxAnimated/BoxAnimated_0.anim",
		"plugins/app/assets/meshes/ChronographWatch/ChronographWatch_Anim_0.anim",
	}
	for path in paths {
		data, rerr := os.read_entire_file(path, context.temp_allocator)
		testing.expectf(t, rerr == nil, "%s reads", path)
		if rerr != nil do continue
		file, perr := json.parse(data, .JSON, true, context.temp_allocator)
		testing.expectf(t, perr == nil, "%s parses", path)
		file_chans := file.(json.Object)["channels"].(json.Array)

		for doc_path in ([2]bool{false, true}) {
			clip: anim.AnimationClip
			uerr: json.Unmarshal_Error
			if doc_path {
				uerr = engine.unmarshal_over_reset(data, &clip, typeid_of(anim.AnimationClip))
			} else {
				uerr = json.unmarshal(data, &clip, .JSON, context.allocator)
			}
			testing.expectf(t, uerr == nil, "%s unmarshals (document path %v)", path, doc_path)
			testing.expectf(t, len(clip.channels) == len(file_chans), "%s keeps its channels", path)
			for &ch, i in clip.channels {
				if i >= len(file_chans) do break
				fc := file_chans[i].(json.Object)
				vals, is_f := ch.values.([dynamic][4]f32)
				testing.expectf(t, is_f, "%s channel %d is a float row", path, i)
				if !is_f do continue
				fv := fc["values"].(json.Array)
				testing.expectf(t, len(vals) == len(fv) && len(ch.times) == len(fc["times"].(json.Array)), "%s channel %d keeps its keys", path, i)
				for k in 0 ..< min(len(vals), len(fv)) {
					lanes := fv[k].(json.Array)
					for c in 0 ..< len(lanes) {
						n, _ := _num(lanes[c])
						testing.expectf(t, abs(f64(vals[k][c]) - n) < 1e-6, "%s channel %d key %d lane %d: %v vs %v", path, i, k, c, vals[k][c], n)
					}
				}
				step, _ := fc["step"].(json.Boolean)
				testing.expectf(t, ch.step == bool(step), "%s channel %d keeps its step flag", path, i)
			}
			anim.type_cleanup_AnimationClip(&clip)
		}
	}
}

// --- Sampling -----------------------------------------------------------------------------

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
_free_channel :: proc(ch: ^anim.Animation_Channel) {
	clip := anim.AnimationClip{}
	clip.channels = make([dynamic]anim.Animation_Channel)
	append(&clip.channels, ch^)
	anim.type_cleanup_AnimationClip(&clip)
}

@(private = "file")
_near :: proc(a, b: f32, eps: f32 = 1e-4) -> bool {
	return abs(a - b) <= eps
}

// A Step key holds until the next key, through `modes` or through the
// channel's `step` flag when it has no modes.
@(test)
test_clip_format_step_holds :: proc(t: ^testing.T) {
	ch := _float_channel({0, 1, 2}, {{0, 0, 0, 0}, {10, 0, 0, 0}, {20, 0, 0, 0}})
	defer _free_channel(&ch)
	append(&ch.modes, anim.Key_Mode.Step, anim.Key_Mode.Linear)
	testing.expect_value(t, anim._animation_channel_sample(&ch, 0.9).x, 0)
	// The second key is Linear (and the third, past the end of `modes`).
	testing.expect(t, _near(anim._animation_channel_sample(&ch, 1.5).x, 15), "a Linear key lerps")

	clear(&ch.modes)
	ch.step = true
	testing.expect_value(t, anim._animation_channel_sample(&ch, 1.5).x, 10)
}

// Two Linear keys lerp, as a clip without modes always has.
@(test)
test_clip_format_linear_lerps :: proc(t: ^testing.T) {
	ch := _float_channel({0, 2}, {{0, 4, 0, 0}, {10, 8, 0, 0}})
	defer _free_channel(&ch)
	v := anim._animation_channel_sample(&ch, 0.5)
	testing.expect(t, _near(v.x, 2.5) && _near(v.y, 5), "no modes is a lerp")
	append(&ch.modes, anim.Key_Mode.Linear, anim.Key_Mode.Linear)
	v = anim._animation_channel_sample(&ch, 0.5)
	testing.expect(t, _near(v.x, 2.5) && _near(v.y, 5), "Linear keys lerp")
}

// Smooth keys are C1: at an inner key the slope from the left matches the
// slope from the right, and it is the slope between the two neighbours.
@(test)
test_clip_format_smooth_is_c1 :: proc(t: ^testing.T) {
	ch := _float_channel({0, 1, 3}, {{0, 0, 0, 0}, {2, 0, 0, 0}, {1, 0, 0, 0}})
	defer _free_channel(&ch)
	append(&ch.modes, anim.Key_Mode.Smooth, anim.Key_Mode.Smooth, anim.Key_Mode.Smooth)
	h := f32(1e-3)
	at := anim._animation_channel_sample(&ch, 1).x
	left := (at - anim._animation_channel_sample(&ch, 1 - h).x) / h
	right := (anim._animation_channel_sample(&ch, 1 + h).x - at) / h
	testing.expectf(t, _near(left, right, 1e-2), "the slopes meet at the key: %v vs %v", left, right)
	testing.expectf(t, _near(left, 1.0 / 3.0, 1e-2), "the slope is the neighbours' (1 - 0) / 3, got %v", left)
	testing.expect(t, _near(at, 2), "the curve passes through the key")
	// Flat at the ends.
	end := (anim._animation_channel_sample(&ch, h).x - anim._animation_channel_sample(&ch, 0).x) / h
	testing.expectf(t, _near(end, 0, 1e-2), "the first key is flat, got %v", end)
}

// A Free key follows its own tangents: the midpoint is the cubic Hermite value.
@(test)
test_clip_format_free_follows_tangents :: proc(t: ^testing.T) {
	ch := _float_channel({0, 2}, {{0, 0, 0, 0}, {1, 0, 0, 0}})
	defer _free_channel(&ch)
	append(&ch.modes, anim.Key_Mode.Free, anim.Key_Mode.Free)
	append(&ch.tangents, [2][4]f32{{0, 0, 0, 0}, {3, 0, 0, 0}}, [2][4]f32{{-1, 0, 0, 0}, {0, 0, 0, 0}})
	// s = 0.5 over a 2 s span: h00 = h01 = 0.5, h10 = 0.125, h11 = -0.125,
	// m0 = 3 * 2, m1 = -1 * 2: 0.125 * 6 + 0.5 * 1 + 0.125 * 2 = 1.5.
	v := anim._animation_channel_sample(&ch, 1).x
	testing.expectf(t, _near(v, 1.5), "the Hermite midpoint, got %v", v)
	// A Linear key next to a Free one uses the linear slope as its tangent.
	ch.modes[1] = .Linear
	// m1 = (1 - 0) / 2 * 2 = 1: 0.75 + 0.5 - 0.125 = 1.125.
	v = anim._animation_channel_sample(&ch, 1).x
	testing.expectf(t, _near(v, 1.125), "a Linear neighbour's slope, got %v", v)
}

// A rotation row slerps whatever its modes and tangents say, and Step holds.
@(test)
test_clip_format_rotation_ignores_modes :: proc(t: ^testing.T) {
	q0 := [4]f32{0, 0, 0, 1}
	q1 := [4]f32{0, math.SQRT_TWO / 2, 0, math.SQRT_TWO / 2}
	ch := _float_channel({0, 1}, {q0, q1}, .Rotation)
	defer _free_channel(&ch)
	plain := anim._animation_channel_sample(&ch, 0.5)
	append(&ch.modes, anim.Key_Mode.Free, anim.Key_Mode.Smooth)
	append(&ch.tangents, [2][4]f32{{5, 5, 5, 5}, {5, 5, 5, 5}})
	curved := anim._animation_channel_sample(&ch, 0.5)
	for c in 0 ..< 4 do testing.expectf(t, _near(plain[c], curved[c]), "lane %d slerps: %v vs %v", c, plain[c], curved[c])
	ch.modes[0] = .Step
	testing.expect_value(t, anim._animation_channel_sample(&ch, 0.5), q0)
}

// Int, reference and string rows hold between keys, and clamp outside them.
@(test)
test_clip_format_discrete_holds :: proc(t: ^testing.T) {
	ch := anim.Animation_Channel{}
	ch.times = make([dynamic]f32)
	append(&ch.times, 0.5, 1)
	ints := make([dynamic]i64)
	append(&ints, 10, 20)
	ch.values = ints
	defer _free_channel(&ch)
	testing.expect_value(t, anim._animation_channel_sample_value(&ch, 0), anim.Channel_Value(i64(10)))
	testing.expect_value(t, anim._animation_channel_sample_value(&ch, 0.99), anim.Channel_Value(i64(10)))
	testing.expect_value(t, anim._animation_channel_sample_value(&ch, 1), anim.Channel_Value(i64(20)))
	testing.expect_value(t, anim._animation_channel_sample_value(&ch, 5), anim.Channel_Value(i64(20)))

	str := anim.Animation_Channel{}
	str.values = make([dynamic]string)
	anim.animation_channel_insert_key(&str, 0, 0, "first")
	anim.animation_channel_insert_key(&str, 1, 1, "second")
	defer _free_channel(&str)
	testing.expect_value(t, anim._animation_channel_sample_value(&str, 0.7).(string), "first")
	testing.expect_value(t, anim._animation_channel_sample_value(&str, 1).(string), "second")
}

// Adding and removing keys keeps `modes` and `tangents` parallel to `times`,
// and a key added into a Free curve keeps its shape.
@(test)
test_clip_format_key_edits_keep_modes_in_step :: proc(t: ^testing.T) {
	ch := _float_channel({0, 2}, {{0, 0, 0, 0}, {1, 0, 0, 0}})
	defer _free_channel(&ch)
	append(&ch.modes, anim.Key_Mode.Free, anim.Key_Mode.Free)
	append(&ch.tangents, [2][4]f32{{0, 0, 0, 0}, {3, 0, 0, 0}}, [2][4]f32{{-1, 0, 0, 0}, {0, 0, 0, 0}})
	before := [3]f32{anim._animation_channel_sample(&ch, 0.5).x, anim._animation_channel_sample(&ch, 1.3).x, anim._animation_channel_sample(&ch, 1.8).x}

	anim.animation_channel_insert_key(&ch, 1, 1, anim._animation_channel_sample_value(&ch, 1))
	testing.expect(t, len(ch.times) == 3 && len(ch.modes) == 3 && len(ch.tangents) == 3, "the new key has a mode and tangents")
	testing.expect_value(t, ch.modes[1], anim.Key_Mode.Free)
	after := [3]f32{anim._animation_channel_sample(&ch, 0.5).x, anim._animation_channel_sample(&ch, 1.3).x, anim._animation_channel_sample(&ch, 1.8).x}
	for i in 0 ..< 3 do testing.expectf(t, _near(before[i], after[i], 1e-3), "the curve keeps its shape at %d: %v vs %v", i, before[i], after[i])

	anim.animation_channel_remove_key(&ch, 1)
	testing.expect(t, len(ch.times) == 2 && len(ch.modes) == 2 && len(ch.tangents) == 2, "removal keeps the arrays parallel")
}

// The preview copy is deep for every row kind and for modes and tangents.
@(test)
test_clip_format_preview_copy_is_deep :: proc(t: ^testing.T) {
	anim.animation_clip_cache_init()
	defer anim.animation_clip_cache_shutdown()
	clip := anim.AnimationClip{length = 1}
	clip.channels = make([dynamic]anim.Animation_Channel)
	ch := _float_channel({0, 1}, {{1, 0, 0, 0}, {2, 0, 0, 0}})
	append(&ch.modes, anim.Key_Mode.Smooth)
	append(&ch.tangents, [2][4]f32{})
	append(&clip.channels, ch)
	strs := make([dynamic]string)
	append(&strs, strings.clone("x", strs.allocator))
	append(&clip.channels, _prop_channel("slot", strs, {0}))
	defer anim.type_cleanup_AnimationClip(&clip)

	ref := engine.PPtr{guid = _clip_guid(0x92)}
	anim.animation_clip_preview(ref, clip)
	cached := &anim.animation_clip_cache[ref]
	testing.expect(t, len(cached.channels[0].modes) == 1 && cached.channels[0].modes[0] == .Smooth, "modes are copied")
	testing.expect(t, raw_data(cached.channels[0].modes) != raw_data(clip.channels[0].modes), "modes are not shared")
	cs := cached.channels[1].values.([dynamic]string)
	testing.expect(t, cs[0] == "x" && raw_data(cs[0]) != raw_data(strs[0]), "strings are cloned")
}

// --- Euler rows ---------------------------------------------------------------------------

// An Euler row is `"path": 3` on disk: it reads back as an Euler row with its
// angles and its lane mask, and writes the same number.
@(test)
test_clip_format_euler_row_round_trips :: proc(t: ^testing.T) {
	src := `{"length": 1.0, "channels": [{"target": "Arm", "path": 3, "times": [0.0, 1.0],
		"values": [[10, 20, 30, 0], [10, 80, 30, 0]], "lanes": [false, true, false]}]}`
	clip: anim.AnimationClip
	err := json.unmarshal(transmute([]byte)src, &clip, .JSON, context.allocator)
	defer anim.type_cleanup_AnimationClip(&clip)
	testing.expect(t, err == nil, "the Euler row unmarshals")
	if !testing.expect_value(t, len(clip.channels), 1) do return
	ch := &clip.channels[0]
	testing.expect_value(t, ch.path, anim.Animation_Path.Euler)
	testing.expect_value(t, ch.lanes_off, anim.Channel_Lanes_Off{0, 2})
	testing.expect_value(t, anim.animation_channel_mask_width(ch), 3)
	vals, is_f := ch.values.([dynamic][4]f32)
	if testing.expect(t, is_f && len(vals) == 2, "two float keys") do testing.expect_value(t, vals[1], [4]f32{10, 80, 30, 0})

	data, merr := json.marshal(clip, {spec = .JSON}, context.temp_allocator)
	testing.expect(t, merr == nil, "the clip marshals")
	root, _ := json.parse(data, .JSON, true, context.temp_allocator)
	obj := root.(json.Object)["channels"].(json.Array)[0].(json.Object)
	n, is_num := _num(obj["path"])
	testing.expect(t, is_num && n == 3, "the path writes as 3")

	again: anim.AnimationClip
	err = json.unmarshal(data, &again, .JSON, context.allocator)
	defer anim.type_cleanup_AnimationClip(&again)
	testing.expect(t, err == nil, "the written clip unmarshals")
	if len(again.channels) == 1 {
		testing.expect_value(t, again.channels[0].path, anim.Animation_Path.Euler)
		testing.expect_value(t, again.channels[0].lanes_off, anim.Channel_Lanes_Off{0, 2})
		testing.expect_value(t, again.channels[0].values.([dynamic][4]f32)[0], [4]f32{10, 20, 30, 0})
	}
}

// The direct apply of an Euler row masked to y changes only the y angle of
// the transform's rotation: x and z keep the transform's own angles.
@(test)
test_clip_format_euler_row_apply_writes_its_lanes :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	owner := engine.transform_new("Rig")
	w := engine.ctx_world()
	tr := engine.pool_get(&w.transforms, engine.Handle(owner))
	tr.rotation = anim.animation_quat_from_euler({10, 20, 30})
	before := engine.quat_to_euler_xyz(tr.rotation)

	clip := anim.AnimationClip{length = 1}
	clip.channels = make([dynamic]anim.Animation_Channel)
	defer anim.type_cleanup_AnimationClip(&clip)
	ch := _float_channel({0}, {{70, 60, -40, 0}}, .Euler)
	ch.lanes_off = {0, 2}
	append(&clip.channels, ch)

	anim.animation_clip_apply(&clip, owner, 0)
	after := engine.quat_to_euler_xyz(tr.rotation)
	testing.expectf(t, _near(after.x, before.x, 0.01) && _near(after.z, before.z, 0.01), "x and z keep their angles: %v before, %v after", before, after)
	testing.expectf(t, _near(after.y, 60, 0.01), "y takes the row's angle, got %v", after.y)
}

// --- Binding typed rows to fields ---------------------------------------------------------

// An int row writes an i32 above 2^24 exactly, a string row writes the camera's
// slot, a reference row the mesh filter's mesh, and write_defaults puts every
// field back.
@(test)
test_clip_format_typed_rows_drive_fields :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	anim.animation_clip_cache_init()
	defer anim.animation_clip_cache_shutdown()

	owner := engine.transform_new("Rig")
	_, cp := engine.transform_add_comp(owner, .Camera)
	cam := cast(^engine.Camera)cp
	_, mp := engine.transform_add_comp(owner, .MeshFilter)
	mf := cast(^engine.MeshFilter)mp
	cam.slot = strings.clone("Own")
	mesh := engine.PPtr{guid = _clip_guid(0x93), local_id = 7}

	cam_guid := uuid.to_string(engine.get_guid_by_typeid(engine.Camera), context.temp_allocator)
	mf_guid := uuid.to_string(engine.get_guid_by_typeid(engine.MeshFilter), context.temp_allocator)
	big := i64(1) << 24 + 1
	clip := anim.AnimationClip{length = 1, wrap = .Loop}
	clip.channels = make([dynamic]anim.Animation_Channel)
	mk :: proc(comp, field: string, v: anim.Channel_Value) -> anim.Animation_Channel {
		ch := anim.Animation_Channel{component = strings.clone(comp), field = strings.clone(field)}
		ch.values = anim.animation_channel_values_make(v)
		anim.animation_channel_insert_key(&ch, 0, 0, v)
		return ch
	}
	append(&clip.channels, mk(cam_guid, "order", big))
	append(&clip.channels, mk(cam_guid, "slot", "Driven"))
	append(&clip.channels, mk(mf_guid, "mesh", mesh))
	guid := _clip_guid(0x94)
	anim.animation_clip_cache[engine.PPtr{guid = guid}] = clip

	g: anim.Playable_Graph
	anim.playable_graph_init(&g)
	defer anim.playable_graph_destroy(&g)
	b: anim.Animation_Binding
	anim.animation_binding_init(&b, owner)
	defer anim.animation_binding_destroy(&b)
	root := anim.playable_add(&g, anim.Playable_Clip{clip = engine.PPtr{guid = guid}})

	pose := anim.playable_graph_evaluate(&g, root, &b)
	anim.animation_pose_apply(&b, pose)
	testing.expect_value(t, i64(cam.order), big)
	testing.expect_value(t, cam.slot, "Driven")
	testing.expect_value(t, mf.mesh, mesh)

	// Held: a second apply of the same value writes nothing new.
	pose = anim.playable_graph_evaluate(&g, root, &b)
	anim.animation_pose_apply(&b, pose)
	testing.expect_value(t, cam.slot, "Driven")

	anim.animation_binding_write_defaults(&b)
	testing.expect_value(t, cam.order, 0)
	testing.expect_value(t, cam.slot, "Own")
	testing.expect_value(t, mf.mesh, engine.PPtr{})
}

// --- glTF ---------------------------------------------------------------------------------

// A one-node glTF with a CUBICSPLINE translation over 2 s, buffers inline.
// Key 0: value 0, out tangent 3. Key 1: in tangent -1, value 1.
@(private = "file")
_cubic_gltf :: proc() -> string {
	floats := [?]f32{
		0, 2, // times
		0, 0, 0, /**/ 0, 0, 0, /**/ 3, 0, 0, // key 0: in, value, out
		-1, 0, 0, /**/ 1, 0, 0, /**/ 0, 0, 0, // key 1
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
    {{"buffer": 0, "byteOffset": 8, "byteLength": 72}}
  ],
  "accessors": [
    {{"bufferView": 0, "componentType": 5126, "count": 2, "type": "SCALAR", "min": [0], "max": [2]}},
    {{"bufferView": 1, "componentType": 5126, "count": 6, "type": "VEC3"}}
  ],
  "animations": [{{
    "channels": [{{"sampler": 0, "target": {{"node": 0, "path": "translation"}}}}],
    "samplers": [{{"input": 0, "output": 1, "interpolation": "CUBICSPLINE"}}]
  }}]
}}`, len(bytes), b64)
}

// CUBICSPLINE bakes Free keys with the glTF tangents, so the clip plays the
// exact curve: the midpoint is the Hermite value, not the linear 0.5.
@(test)
test_clip_format_gltf_cubic_bakes_free_keys :: proc(t: ^testing.T) {
	text := _cubic_gltf()
	opts := cgltf.options{}
	data, res := cgltf.parse(opts, raw_data(text), uint(len(text)))
	testing.expect(t, res == .success, "the glTF parses")
	if res != .success do return
	defer cgltf.free(data)
	lres := cgltf.load_buffers(opts, data, "inline.gltf")
	testing.expect(t, lres == .success, "the inline buffer loads")
	if lres != .success do return

	clip, ok := anim.animation_clip_from_gltf(data, &data.animations[0])
	testing.expect(t, ok && len(clip.channels) == 1, "one channel converts")
	if !ok || len(clip.channels) != 1 do return
	ch := &clip.channels[0]
	testing.expect(t, !ch.step, "a cubic channel is not a step channel")
	testing.expect(t, len(ch.modes) == 2 && ch.modes[0] == .Free && ch.modes[1] == .Free, "every key is Free")
	testing.expect(t, len(ch.tangents) == 2, "every key has tangents")
	if len(ch.tangents) == 2 {
		testing.expect_value(t, ch.tangents[0][1], [4]f32{3, 0, 0, 0})
		testing.expect_value(t, ch.tangents[1][0], [4]f32{-1, 0, 0, 0})
	}
	vals := ch.values.([dynamic][4]f32)
	testing.expect(t, vals[0] == {0, 0, 0, 0} && vals[1] == {1, 0, 0, 0}, "the values are the middle elements")
	mid := anim._animation_channel_sample(ch, 1).x
	testing.expectf(t, _near(mid, 1.5), "the midpoint is the Hermite value, got %v", mid)
}

// A trim through a Free curve keeps the curve: the trimmed clip samples the
// same values at the same source times.
@(test)
test_clip_format_trim_keeps_curves :: proc(t: ^testing.T) {
	clip := anim.AnimationClip{length = 2}
	clip.channels = make([dynamic]anim.Animation_Channel)
	ch := _float_channel({0, 1, 2}, {{0, 0, 0, 0}, {2, 0, 0, 0}, {1, 0, 0, 0}})
	append(&ch.modes, anim.Key_Mode.Smooth, anim.Key_Mode.Smooth, anim.Key_Mode.Free)
	append(&ch.tangents, [2][4]f32{}, [2][4]f32{}, [2][4]f32{{-2, 0, 0, 0}, {}})
	append(&clip.channels, ch)
	defer anim.type_cleanup_AnimationClip(&clip)
	src := clip.channels[0]
	probes := [?]f32{0.4, 0.8, 1.0, 1.3, 1.6}
	want: [len(probes)]f32
	for p, i in probes do want[i] = anim._animation_channel_sample(&src, p).x

	anim.animation_clip_apply_settings(&clip, {trim_start = 0.25, trim_stop = 1.75})
	out := &clip.channels[0]
	testing.expect(t, len(out.modes) == len(out.times) && len(out.tangents) == len(out.times), "modes and tangents stay parallel")
	for p, i in probes {
		got := anim._animation_channel_sample(out, p - 0.25).x
		testing.expectf(t, _near(got, want[i], 1e-3), "at %v: %v vs %v", p, got, want[i])
	}
}

// A bool field is one byte: writing it leaves the bytes after it alone, and
// reading it reads only its own byte.
@(test)
test_clip_property_bool_write_keeps_its_neighbours :: proc(t: ^testing.T) {
	Packed :: struct {
		before: u8,
		flag:   bool,
		after:  u8,
		tail:   u32,
	}
	s := Packed{before = 7, flag = false, after = 9, tail = 0xDEADBEEF}
	anim._prop_write_value(&s.flag, .Bool, typeid_of(bool), anim.Channel_Value([4]f32{1, 0, 0, 0}))
	testing.expect(t, s.flag, "the bool is set")
	testing.expect_value(t, s.before, 7)
	testing.expect_value(t, s.after, 9)
	testing.expect_value(t, s.tail, u32(0xDEADBEEF))
	s.after = 1
	s.flag = false
	v := anim._prop_read(&s.flag, .Bool, typeid_of(bool))
	testing.expect_value(t, v.x, f32(0))
}

// A cache entry's strings are default-allocator memory: shutting the cache
// down under another allocator (a test's tracking allocator) frees them
// with their own, so the tracker reports no bad free.
@(test)
test_clip_cache_shutdown_frees_entries_with_their_allocator :: proc(t: ^testing.T) {
	anim.animation_clip_cache_init()
	clip := anim.AnimationClip{length = 1}
	clip.channels = make([dynamic]anim.Animation_Channel)
	strs := make([dynamic]string)
	append(&strs, strings.clone("x", strs.allocator))
	append(&clip.channels, _prop_channel("slot", strs, {0}))
	defer anim.type_cleanup_AnimationClip(&clip)
	anim.animation_clip_preview(engine.PPtr{guid = _clip_guid(0x93)}, clip)
	anim.animation_clip_cache_shutdown()
	// The runner's tracking allocator fails the test on a bad free.
}

