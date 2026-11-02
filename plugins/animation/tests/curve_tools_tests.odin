package animation_tests

// Key interpolation editing in the Animation window (editor/curve_tools.odin):
// the slopes the tangent presets use, the Smooth tangents, the presets, a key
// turning Free without moving the curve, and the window's mode action over a
// selection as one undo step.

import "core:os"
import "core:testing"
import asset_pipeline "moonhug:editor/assets"
import "moonhug:editor/inspector"
import undo "moonhug:editor/undo"
import "moonhug:packages/engine"
import anim "moonhug:packages/animation"
import animation_editor "moonhug:packages/animation/editor"
import common "moonhug:tests/common"

// Three keys on lane x: 0 at 0 s, 2 at 1 s, 1 at 3 s.
@(private = "file")
_TIMES :: [3]f32{0, 1, 3}

@(private = "file")
_VALS :: [3][4]f32{{0, 0, 0, 0}, {2, 0, 0, 0}, {1, 0, 0, 0}}

@(private = "file")
_channel :: proc(path := anim.Animation_Path.Position) -> anim.Animation_Channel {
	ch := anim.Animation_Channel{path = path}
	ch.times = make([dynamic]f32)
	times := _TIMES
	append(&ch.times, ..times[:])
	vals := make([dynamic][4]f32)
	v := _VALS
	append(&vals, ..v[:])
	ch.values = vals
	return ch
}

@(private = "file")
_free :: proc(ch: ^anim.Animation_Channel) {
	clip := anim.AnimationClip{}
	clip.channels = make([dynamic]anim.Animation_Channel)
	append(&clip.channels, ch^)
	anim.type_cleanup_AnimationClip(&clip)
}

@(private = "file")
_near :: proc(a, b: f32, eps: f32 = 1e-4) -> bool {
	return abs(a - b) <= eps
}

// The linear slopes: in from the previous key, out to the next one, 0 past
// either end.
@(test)
test_curve_tools_linear_slopes :: proc(t: ^testing.T) {
	times := _TIMES
	vals := _VALS
	testing.expect_value(t, animation_editor.key_linear_slope_in(times[:], vals[:], 0).x, 0)
	testing.expect_value(t, animation_editor.key_linear_slope_out(times[:], vals[:], 0).x, 2)
	testing.expect_value(t, animation_editor.key_linear_slope_in(times[:], vals[:], 1).x, 2)
	testing.expect_value(t, animation_editor.key_linear_slope_out(times[:], vals[:], 1).x, -0.5)
	testing.expect_value(t, animation_editor.key_linear_slope_in(times[:], vals[:], 2).x, -0.5)
	testing.expect_value(t, animation_editor.key_linear_slope_out(times[:], vals[:], 2).x, 0)
}

// Smooth tangents are flat at the first and last key, and an inner key takes
// the slope between its neighbours on both sides.
@(test)
test_curve_tools_smooth_tangents :: proc(t: ^testing.T) {
	times := _TIMES
	vals := _VALS
	tin, tout := animation_editor.key_smooth_tangents(times[:], vals[:], 0)
	testing.expect(t, tin == {} && tout == {}, "the first key is flat")
	tin, tout = animation_editor.key_smooth_tangents(times[:], vals[:], 2)
	testing.expect(t, tin == {} && tout == {}, "the last key is flat")
	tin, tout = animation_editor.key_smooth_tangents(times[:], vals[:], 1)
	testing.expectf(t, _near(tin.x, 1.0 / 3.0) && tin == tout, "the neighbours' slope (1 - 0) / 3 on both sides, got %v %v", tin.x, tout.x)

	// The sampler uses the same rule: a Smooth key's slope at the key matches.
	ch := _channel()
	defer _free(&ch)
	append(&ch.modes, anim.Key_Mode.Smooth, anim.Key_Mode.Smooth, anim.Key_Mode.Smooth)
	s_in, s_out := anim._animation_key_tangents(&ch, anim.animation_channel_floats(&ch)[:], 1)
	testing.expect(t, s_in == tin && s_out == tout, "the sampler's Smooth tangents")
}

// Each preset's tangents, and applying one makes the key Free with them.
@(test)
test_curve_tools_presets :: proc(t: ^testing.T) {
	times := _TIMES
	vals := _VALS
	Case :: struct {
		preset:    animation_editor.Key_Preset,
		tin, tout: f32,
	}
	cases := [?]Case{
		{.Flat, 0, 0},
		{.Ease_In, 0, -0.5},
		{.Ease_Out, 2, 0},
		{.Auto, 1.0 / 3.0, 1.0 / 3.0},
	}
	for c in cases {
		tin, tout := animation_editor.key_preset_tangents(times[:], vals[:], 1, c.preset)
		testing.expectf(t, _near(tin.x, c.tin) && _near(tout.x, c.tout), "%v: in %v out %v", c.preset, tin.x, tout.x)

		ch := _channel()
		defer _free(&ch)
		animation_editor.channel_apply_preset(&ch, 1, c.preset)
		testing.expect(t, len(ch.modes) == 3 && ch.modes[1] == .Free, "the key turns Free")
		testing.expect(t, ch.modes[0] == .Linear && ch.modes[2] == .Linear, "the other keys keep their Linear mode")
		testing.expect(t, len(ch.tangents) >= 2, "the key has tangents")
		if len(ch.tangents) >= 2 {
			testing.expectf(t, _near(ch.tangents[1][0].x, c.tin) && _near(ch.tangents[1][1].x, c.tout), "%v stored", c.preset)
		}
	}
	// Ease In at the last key has no next key: both tangents flat.
	tin, tout := animation_editor.key_preset_tangents(times[:], vals[:], 2, .Ease_In)
	testing.expect(t, tin == {} && tout == {}, "Ease In at the last key is flat")
}

// A Smooth or Linear key set to Free keeps the tangents it had: the curve
// samples the same between the keys before and after.
@(test)
test_curve_tools_set_free_keeps_the_curve :: proc(t: ^testing.T) {
	for mode in ([2]anim.Key_Mode{.Smooth, .Linear}) {
		ch := _channel()
		defer _free(&ch)
		append(&ch.modes, mode, mode, mode)
		at := [4]f32{0.5, 0.8, 1.7, 2.6}
		before: [4]f32
		for x, i in at do before[i] = anim._animation_channel_sample(&ch, x).x

		animation_editor.channel_set_key_mode(&ch, 1, .Free)
		testing.expect_value(t, ch.modes[1], anim.Key_Mode.Free)
		for x, i in at {
			after := anim._animation_channel_sample(&ch, x).x
			testing.expectf(t, _near(before[i], after, 1e-4), "%v key at %v s: %v vs %v", mode, x, before[i], after)
		}
	}

	// A channel without modes (every key Linear) too.
	ch := _channel()
	defer _free(&ch)
	mid := anim._animation_channel_sample(&ch, 2).x
	animation_editor.channel_set_key_mode(&ch, 2, .Free)
	testing.expect(t, _near(anim._animation_channel_sample(&ch, 2).x, mid), "the last segment stays a line")
}

// A Step key set to Free keeps its in tangent and gets a flat out tangent:
// the segment before it does not move, and the segment after it leaves the
// key flat instead of taking the linear slope to the next key.
@(test)
test_curve_tools_step_to_free_leaves_flat :: proc(t: ^testing.T) {
	ch := _channel()
	defer _free(&ch)
	append(&ch.modes, anim.Key_Mode.Linear, anim.Key_Mode.Step, anim.Key_Mode.Linear)
	before := anim._animation_channel_sample(&ch, 0.5).x

	animation_editor.channel_set_key_mode(&ch, 1, .Free)
	testing.expect_value(t, ch.modes[1], anim.Key_Mode.Free)
	testing.expect(t, len(ch.tangents) >= 2, "the key has tangents")
	if len(ch.tangents) >= 2 {
		testing.expectf(t, _near(ch.tangents[1][0].x, 2), "the in tangent stays the linear slope 2, got %v", ch.tangents[1][0].x)
		testing.expect_value(t, ch.tangents[1][1], [4]f32{})
	}
	after := anim._animation_channel_sample(&ch, 0.5).x
	testing.expectf(t, _near(before, after), "the segment before the key stays: %v vs %v", before, after)
	slope := anim._animation_channel_slope(&ch, 1).x
	testing.expectf(t, _near(slope, 0), "the segment after the key leaves it flat, slope %v", slope)
	near_key := anim._animation_channel_sample(&ch, 1.01).x
	testing.expectf(t, _near(near_key, 2, 1e-3), "just after the key the curve is still at the held value, got %v", near_key)
}

// A channel stored with `step` and no modes holds on every key. Setting a mode
// on one key fills `modes` with Step for the others and clears `step`.
@(test)
test_curve_tools_modes_honour_step :: proc(t: ^testing.T) {
	ch := _channel()
	defer _free(&ch)
	ch.step = true
	animation_editor.channel_set_key_mode(&ch, 1, .Linear)
	testing.expect_value(t, len(ch.modes), 3)
	if len(ch.modes) == 3 {
		testing.expect(t, ch.modes[0] == .Step && ch.modes[1] == .Linear && ch.modes[2] == .Step, "the other keys still hold")
	}
	testing.expect(t, !ch.step, "step is cleared")
	testing.expect_value(t, anim._animation_channel_sample(&ch, 0.5).x, 0)

	// A Rotation row offers Linear and Step only, a discrete row none.
	rot := _channel(.Rotation)
	defer _free(&rot)
	testing.expect_value(t, animation_editor.channel_modes_allowed(&rot), animation_editor.Key_Modes{.Linear, .Step})
	ints := anim.Animation_Channel{}
	ints.values = make([dynamic]i64)
	defer _free(&ints)
	testing.expect_value(t, animation_editor.channel_modes_allowed(&ints), animation_editor.Key_Modes{})
}

// --- Window ----------------------------------------------------------------------------

@(private = "file")
_DIR :: "moonhug/tests/fixtures/_curve_tools_tmp"

// A two-second clip with one Position row stored as STEP: three keys, no
// modes.
@(private = "file")
_CLIP :: `{
  "__type_guid": "0a4f3b1c-8e57-4c2d-9b6a-5d1e7f2c8a90",
  "length": 2.0,
  "channels": [
    {"target": "", "path": 0, "component": "", "field": "", "step": true,
     "times": [0, 1, 2], "values": [[0, 0, 0, 0], [1, 0, 0, 0], [0, 0, 0, 0]]}
  ]
}`

// The mode action of the key context menu on a selection of two keys of a
// STEP row: `modes` comes into being with Step on the unselected key, `step`
// is cleared, and it is one undo step that undo takes back whole.
@(test)
test_curve_tools_window_sets_mode_on_selection :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	s := common.setup_undo(tc)
	context.user_ptr = &tc.uc
	defer common.teardown_undo(tc, s)

	os.make_directory(_DIR)
	path :: _DIR + "/Stepped.anim"
	testing.expect(t, os.write_entire_file(path, transmute([]u8)string(_CLIP)) == nil, "the clip file is written")
	asset_pipeline.asset_pipeline_init()
	engine.asset_db_init(_DIR)
	undo.set_asset_apply(inspector.asset_doc_apply_json)
	undo.set_asset_doc_lookup(inspector.asset_doc_payload_ptr)
	defer {
		animation_editor.animation_view_deselect()
		animation_editor.animation_record_reset()
		inspector.asset_docs_shutdown()
		engine.asset_db_shutdown()
		common.remove_tree(_DIR)
		common.remove_tree(engine.library_dir())
	}
	doc := inspector.asset_doc_get(path)
	testing.expect(t, doc != nil && doc.data.id == typeid_of(anim.AnimationClip), "the clip loads as a document")
	if doc == nil do return
	clip := cast(^anim.AnimationClip)doc.data.data
	testing.expect_value(t, len(clip.channels), 1)
	if len(clip.channels) != 1 do return
	testing.expect(t, clip.channels[0].step && len(clip.channels[0].modes) == 0, "the row is stored as STEP")

	root := engine.transform_new("Root")
	animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 0, armed = false)
	animation_editor.animation_view_select_key(0, 1)
	animation_editor.animation_view_select_key(0, 2, add = true)

	before := s.top
	animation_editor.animation_view_set_key_mode(.Smooth)
	clip = cast(^anim.AnimationClip)doc.data.data
	ch := &clip.channels[0]
	testing.expect_value(t, len(ch.modes), 3)
	if len(ch.modes) == 3 {
		testing.expect_value(t, ch.modes[0], anim.Key_Mode.Step)
		testing.expect_value(t, ch.modes[1], anim.Key_Mode.Smooth)
		testing.expect_value(t, ch.modes[2], anim.Key_Mode.Smooth)
	}
	testing.expect(t, !ch.step, "step is cleared")
	testing.expect(t, doc.dirty, "the document is edited")
	testing.expect_value(t, s.top, before + 1)

	testing.expect(t, undo.apply_undo(s), "undo")
	ch = &(cast(^anim.AnimationClip)doc.data.data).channels[0]
	testing.expect(t, ch.step && len(ch.modes) == 0, "undo restores the STEP row")
	testing.expect(t, undo.apply_redo(s), "redo")
	ch = &(cast(^anim.AnimationClip)doc.data.data).channels[0]
	testing.expect(t, !ch.step && len(ch.modes) == 3 && ch.modes[1] == .Smooth, "redo brings the modes back")

	// A preset over the same selection is one more step, and the keys turn
	// Free with flat tangents.
	before = s.top
	animation_editor.animation_view_apply_preset(.Flat)
	ch = &(cast(^anim.AnimationClip)doc.data.data).channels[0]
	testing.expect_value(t, s.top, before + 1)
	testing.expect(t, ch.modes[1] == .Free && ch.modes[2] == .Free && ch.modes[0] == .Step, "the selected keys turn Free")
	testing.expect(t, len(ch.tangents) == 3 && ch.tangents[1] == {} && ch.tangents[2] == {}, "flat tangents")
}
