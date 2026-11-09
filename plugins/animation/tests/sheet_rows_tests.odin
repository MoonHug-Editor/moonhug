package animation_tests

// The Animation window's sheet rows (editor/sheet_rows.odin): channels grouped
// under one Object row per animated transform, collapse, and the summary key
// times an Object row shows.

import "core:encoding/uuid"
import "core:fmt"
import "core:os"
import "core:testing"
import asset_pipeline "moonhug:editor/assets"
import "moonhug:editor/inspector"
import undo "moonhug:editor/undo"
import "moonhug:packages/engine"
import anim "moonhug:packages/animation"
import animation_editor "moonhug:packages/animation/editor"
import common "moonhug:tests/common"

// A channel on `target` with keys at `times`, temp-allocated. A transform
// channel when `field` is "", else a property channel.
@(private = "file")
_sr_channel :: proc(target: string, path: anim.Animation_Path, times: []f32, field := "") -> anim.Animation_Channel {
	ch := anim.Animation_Channel{target = target, path = path}
	if field != "" {
		ch.component = "0a4f3b1c-8e57-4c2d-9b6a-5d1e7f2c8a90"
		ch.field = field
	}
	ch.times = make([dynamic]f32, context.temp_allocator)
	ch.values = make([dynamic][4]f32, context.temp_allocator)
	for t in times {
		append(&ch.times, t)
		append(&ch.values.([dynamic][4]f32), [4]f32{})
	}
	return ch
}

// Channels 0..3: Arm Position, root Position, Arm Rotation, root light field.
@(private = "file")
_sr_clip :: proc() -> anim.AnimationClip {
	clip := anim.AnimationClip{length = 2, frame_rate = 10}
	clip.channels = make([dynamic]anim.Animation_Channel, context.temp_allocator)
	append(&clip.channels, _sr_channel("Body/Arm", .Position, {0, 1}))
	append(&clip.channels, _sr_channel("", .Position, {0, 2}))
	append(&clip.channels, _sr_channel("Body/Arm", .Rotation, {0.5}))
	append(&clip.channels, _sr_channel("", .Position, {1}, field = "intensity"))
	return clip
}

@(private = "file")
_sr_expect_row :: proc(t: ^testing.T, r: animation_editor.Sheet_Row, kind: animation_editor.Sheet_Row_Kind, target: string, ch: int, loc := #caller_location) {
	testing.expect_value(t, r.kind, kind, loc)
	testing.expect_value(t, r.target, target, loc)
	testing.expect_value(t, r.ch, ch, loc)
	// An Object row has depth 0, a Channel row 1, a Lane row 2, whatever the
	// target's path depth.
	want := 0
	switch kind {
	case .Object:  want = 0
	case .Channel: want = 1
	case .Lane:    want = 2
	}
	testing.expect_value(t, r.depth, want, loc)
}

@(test)
test_sheet_rows_group_by_target_in_first_appearance_order :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	clip := _sr_clip()
	rows := animation_editor.sheet_rows(&clip, nil, nil, context.temp_allocator)
	if !testing.expect_value(t, len(rows), 6) do return
	// Arm appears first, so its group comes first, its channels in channel order.
	_sr_expect_row(t, rows[0], .Object, "Body/Arm", -1)
	_sr_expect_row(t, rows[1], .Channel, "Body/Arm", 0)
	_sr_expect_row(t, rows[2], .Channel, "Body/Arm", 2)
	_sr_expect_row(t, rows[3], .Object, "", -1)
	_sr_expect_row(t, rows[4], .Channel, "", 1)
	_sr_expect_row(t, rows[5], .Channel, "", 3)
}

@(test)
test_sheet_rows_root_first_when_it_appears_first :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	clip := anim.AnimationClip{length = 1}
	clip.channels = make([dynamic]anim.Animation_Channel, context.temp_allocator)
	append(&clip.channels, _sr_channel("", .Scale, {0}))
	append(&clip.channels, _sr_channel("Head", .Position, {0}))
	append(&clip.channels, _sr_channel("", .Rotation, {0}))
	rows := animation_editor.sheet_rows(&clip, nil, nil, context.temp_allocator)
	if !testing.expect_value(t, len(rows), 5) do return
	_sr_expect_row(t, rows[0], .Object, "", -1)
	_sr_expect_row(t, rows[1], .Channel, "", 0)
	_sr_expect_row(t, rows[2], .Channel, "", 2)
	_sr_expect_row(t, rows[3], .Object, "Head", -1)
	_sr_expect_row(t, rows[4], .Channel, "Head", 1)
	testing.expect_value(t, animation_editor.sheet_target_name("", "Hero"), "Hero")
	testing.expect_value(t, animation_editor.sheet_target_name("Body/Arm", "Hero"), "Arm")
	testing.expect_value(t, animation_editor.sheet_target_name("Head", "Hero"), "Head")
}

@(test)
test_sheet_rows_collapse_hides_channels_keeps_object_row :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	clip := _sr_clip()
	collapsed := make(map[string]bool, context.temp_allocator)
	collapsed["Body/Arm"] = true
	rows := animation_editor.sheet_rows(&clip, collapsed, nil, context.temp_allocator)
	if !testing.expect_value(t, len(rows), 4) do return
	_sr_expect_row(t, rows[0], .Object, "Body/Arm", -1)
	_sr_expect_row(t, rows[1], .Object, "", -1)
	_sr_expect_row(t, rows[2], .Channel, "", 1)
	_sr_expect_row(t, rows[3], .Channel, "", 3)

	// A false entry is not collapsed.
	collapsed["Body/Arm"] = false
	testing.expect_value(t, len(animation_editor.sheet_rows(&clip, collapsed, nil, context.temp_allocator)), 6)
}

@(test)
test_sheet_row_of_channel_is_minus_one_when_hidden :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	clip := _sr_clip()
	rows := animation_editor.sheet_rows(&clip, nil, nil, context.temp_allocator)
	testing.expect_value(t, animation_editor.sheet_row_of_channel(&clip, rows, 0), 1)
	testing.expect_value(t, animation_editor.sheet_row_of_channel(&clip, rows, 2), 2)
	testing.expect_value(t, animation_editor.sheet_row_of_channel(&clip, rows, 3), 5)
	testing.expect_value(t, animation_editor.sheet_row_of_channel(&clip, rows, 9), -1)

	collapsed := make(map[string]bool, context.temp_allocator)
	collapsed[""] = true
	rows = animation_editor.sheet_rows(&clip, collapsed, nil, context.temp_allocator)
	testing.expect_value(t, animation_editor.sheet_row_of_channel(&clip, rows, 0), 1)
	testing.expect_value(t, animation_editor.sheet_row_of_channel(&clip, rows, 1), -1)
	testing.expect_value(t, animation_editor.sheet_row_of_channel(&clip, rows, 3), -1)
}

// An expanded vector row (Position, a [3]f32 field) shows a Lane row per
// enabled lane, x to z, one level deeper. A disabled lane has no row. A vector row not in `expanded` shows none,
// and neither does a Rotation row or a scalar field row, expanded or not. A
// collapsed Object row hides its Lane rows with its property rows.
@(test)
test_sheet_rows_lane_rows_under_expanded_vector_rows :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	volume := uuid.to_string(engine.get_guid_by_typeid(engine.Volume), context.temp_allocator)
	clip := anim.AnimationClip{length = 1}
	clip.channels = make([dynamic]anim.Animation_Channel, context.temp_allocator)
	append(&clip.channels, _sr_channel("", .Position, {0}))
	append(&clip.channels, _sr_channel("", .Scale, {0}))
	append(&clip.channels, _sr_channel("", .Rotation, {0}))
	append(&clip.channels, _sr_channel("", .Position, {0}, field = "size"))
	append(&clip.channels, _sr_channel("", .Position, {0}, field = "blend_distance"))
	clip.channels[3].component = volume
	clip.channels[4].component = volume
	clip.channels[3].lanes_off = {1}

	expanded := make(map[string]bool, context.temp_allocator)
	for i in ([?]int{0, 2, 3, 4}) {
		expanded[animation_editor.sheet_channel_key(&clip.channels[i], context.temp_allocator)] = true
	}
	rows := animation_editor.sheet_rows(&clip, nil, expanded, context.temp_allocator)
	if !testing.expect_value(t, len(rows), 11) do return
	_sr_expect_row(t, rows[0], .Object, "", -1)
	_sr_expect_row(t, rows[1], .Channel, "", 0)
	for l in 0 ..< 3 {
		r := rows[2 + l]
		testing.expect_value(t, r.kind, animation_editor.Sheet_Row_Kind.Lane)
		testing.expect_value(t, r.ch, 0)
		testing.expect_value(t, r.lane, l)
		testing.expect_value(t, r.depth, 2)
	}
	_sr_expect_row(t, rows[5], .Channel, "", 1)
	_sr_expect_row(t, rows[6], .Channel, "", 2)
	_sr_expect_row(t, rows[7], .Channel, "", 3)
	// The size row has y disabled: x and z only.
	for l, j in ([2]int{0, 2}) {
		r := rows[8 + j]
		testing.expect_value(t, r.kind, animation_editor.Sheet_Row_Kind.Lane)
		testing.expect_value(t, r.ch, 3)
		testing.expect_value(t, r.lane, l)
	}
	_sr_expect_row(t, rows[10], .Channel, "", 4)

	collapsed := make(map[string]bool, context.temp_allocator)
	collapsed[""] = true
	testing.expect_value(t, len(animation_editor.sheet_rows(&clip, collapsed, expanded, context.temp_allocator)), 1)
	testing.expect_value(t, len(animation_editor.sheet_rows(&clip, nil, nil, context.temp_allocator)), 6)
}

// A split position row (one channel per lane) with a Scale row between its
// channels: channels 0, 2, 3 are Arm Position masked to x, y, z, channel 1 is
// Arm Scale.
@(private = "file")
_sr_split_clip :: proc() -> anim.AnimationClip {
	clip := anim.AnimationClip{length = 2, frame_rate = 10}
	clip.channels = make([dynamic]anim.Animation_Channel, context.temp_allocator)
	append(&clip.channels, _sr_channel("Arm", .Position, {0, 1}))
	append(&clip.channels, _sr_channel("Arm", .Scale, {0}))
	append(&clip.channels, _sr_channel("Arm", .Position, {0.5}))
	append(&clip.channels, _sr_channel("Arm", .Position, {1.03, 1.5}))
	clip.channels[0].lanes_off = {1, 2}
	clip.channels[2].lanes_off = {0, 2}
	clip.channels[3].lanes_off = {0, 1}
	return clip
}

// The channels of one property make one Channel row: `ch` is the first,
// `split` says there are more. Expanded, each Lane row points at the channel
// that animates its lane. sheet_row_of_channel finds the row from any of them.
@(test)
test_sheet_rows_group_split_channels_into_one_row :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	clip := _sr_split_clip()
	rows := animation_editor.sheet_rows(&clip, nil, nil, context.temp_allocator)
	if !testing.expect_value(t, len(rows), 3) do return
	_sr_expect_row(t, rows[0], .Object, "Arm", -1)
	_sr_expect_row(t, rows[1], .Channel, "Arm", 0)
	testing.expect(t, rows[1].split, "the position row is split")
	_sr_expect_row(t, rows[2], .Channel, "Arm", 1)
	testing.expect(t, !rows[2].split, "the scale row is joined")
	for ch in ([?]int{0, 2, 3}) do testing.expect_value(t, animation_editor.sheet_row_of_channel(&clip, rows, ch), 1)
	testing.expect_value(t, animation_editor.sheet_row_of_channel(&clip, rows, 1), 2)

	expanded := make(map[string]bool, context.temp_allocator)
	expanded[animation_editor.sheet_channel_key(&clip.channels[2], context.temp_allocator)] = true
	rows = animation_editor.sheet_rows(&clip, nil, expanded, context.temp_allocator)
	if !testing.expect_value(t, len(rows), 6) do return
	_sr_expect_row(t, rows[1], .Channel, "Arm", 0)
	want_ch := [3]int{0, 2, 3}
	for l in 0 ..< 3 {
		_sr_expect_row(t, rows[2 + l], .Lane, "Arm", want_ch[l])
		testing.expect_value(t, rows[2 + l].lane, l)
	}
	_sr_expect_row(t, rows[5], .Channel, "Arm", 1)

	// A lane no channel animates has no Lane row.
	ordered_remove(&clip.channels, 2)
	rows = animation_editor.sheet_rows(&clip, nil, expanded, context.temp_allocator)
	if !testing.expect_value(t, len(rows), 5) do return
	testing.expect(t, rows[2].lane == 0 && rows[2].ch == 0, "x from channel 0")
	testing.expect(t, rows[3].lane == 2 && rows[3].ch == 2, "z from channel 2")
}

// sheet_group_channels lists a property's channels from any of them,
// sheet_lane_channel picks the one owning a lane, and sheet_keys_times and
// sheet_keys_at summarize the group's keys the way an Object row summarizes
// its target's.
@(test)
test_sheet_group_channels_lanes_and_summary_keys :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	clip := _sr_split_clip()
	group := animation_editor.sheet_group_channels(&clip, 3, context.temp_allocator)
	if !testing.expect_value(t, len(group), 3) do return
	testing.expect_value(t, group[0], 0)
	testing.expect_value(t, group[1], 2)
	testing.expect_value(t, group[2], 3)
	for l in 0 ..< 3 do testing.expect_value(t, animation_editor.sheet_lane_channel(&clip, group, l), group[l])
	testing.expect_value(t, animation_editor.sheet_lane_channel(&clip, group, 3), -1)

	scale := animation_editor.sheet_group_channels(&clip, 1, context.temp_allocator)
	testing.expect(t, len(scale) == 1 && scale[0] == 1, "a joined row is its own group")
	testing.expect_value(t, animation_editor.sheet_lane_channel(&clip, scale, 1), 1)

	// 1.0 and 1.03 are within half a frame (0.05 s at 10 fps): one summary key.
	times := animation_editor.sheet_keys_times(&clip, group, context.temp_allocator)
	want := []f32{0, 0.5, 1, 1.5}
	if !testing.expect_value(t, len(times), len(want)) do return
	for w, i in want do testing.expect_value(t, times[i], w)
	keys := animation_editor.sheet_keys_at(&clip, group, times, 2, context.temp_allocator)
	if testing.expect_value(t, len(keys), 2) {
		testing.expect_value(t, keys[0], animation_editor.Sheet_Key{ch = 0, key = 1})
		testing.expect_value(t, keys[1], animation_editor.Sheet_Key{ch = 3, key = 0})
	}
	keys = animation_editor.sheet_keys_at(&clip, group, times, 1, context.temp_allocator)
	if testing.expect_value(t, len(keys), 1) do testing.expect_value(t, keys[0], animation_editor.Sheet_Key{ch = 2, key = 0})
}

@(test)
test_sheet_object_key_times_merge_within_half_a_frame :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	// 10 fps: half a frame is 0.05 s.
	clip := anim.AnimationClip{length = 2, frame_rate = 10}
	clip.channels = make([dynamic]anim.Animation_Channel, context.temp_allocator)
	append(&clip.channels, _sr_channel("Arm", .Position, {0, 0.5, 1.0}))
	append(&clip.channels, _sr_channel("Arm", .Rotation, {0.03, 0.5, 1.2}))
	append(&clip.channels, _sr_channel("Leg", .Position, {0.7}))
	append(&clip.channels, _sr_channel("Arm", .Scale, {1.04, 1.5}))

	times := animation_editor.sheet_keys_times(&clip, animation_editor.sheet_target_channels(&clip, "Arm", context.temp_allocator), context.temp_allocator)
	// 0 and 0.03 are one, 0.5 twice is one, 1.0 and 1.04 are one. Leg's 0.7
	// belongs to another target.
	want := []f32{0, 0.5, 1.0, 1.2, 1.5}
	if !testing.expect_value(t, len(times), len(want)) do return
	for w, i in want do testing.expect_value(t, times[i], w)

	// The summary key at 1.0 stands for 1.0 and 1.04, across two channels.
	keys := animation_editor.sheet_keys_at(&clip, animation_editor.sheet_target_channels(&clip, "Arm", context.temp_allocator), times, 2, context.temp_allocator)
	if testing.expect_value(t, len(keys), 2) {
		testing.expect_value(t, keys[0], animation_editor.Sheet_Key{ch = 0, key = 2})
		testing.expect_value(t, keys[1], animation_editor.Sheet_Key{ch = 3, key = 0})
	}
	// The one at 0 stands for both keys near the start.
	keys = animation_editor.sheet_keys_at(&clip, animation_editor.sheet_target_channels(&clip, "Arm", context.temp_allocator), times, 0, context.temp_allocator)
	testing.expect_value(t, len(keys), 2)

	testing.expect_value(t, len(animation_editor.sheet_keys_times(&clip, animation_editor.sheet_target_channels(&clip, "Nobody", context.temp_allocator), context.temp_allocator)), 0)
}

@(test)
test_sheet_target_split_depth_and_parent :: proc(t: ^testing.T) {
	Case :: struct {
		target, parent, name: string,
		depth:                int,
	}
	cases := []Case{
		{"", "", "", 0},
		{"Armature", "", "Armature", 1},
		{"Armature/node_2", "Armature", "node_2", 2},
		{"Armature/Hips/Spine", "Armature/Hips", "Spine", 3},
	}
	for c in cases {
		parent, name, depth := animation_editor.sheet_target_split(c.target)
		testing.expect_value(t, parent, c.parent)
		testing.expect_value(t, name, c.name)
		testing.expect_value(t, depth, c.depth)
	}

	// The rows do not carry it: every Object row has depth 0 and its Channel
	// rows 1, a nested target as much as the animated object.
	defer free_all(context.temp_allocator)
	clip := _sr_clip()
	rows := animation_editor.sheet_rows(&clip, nil, nil, context.temp_allocator)
	if !testing.expect_value(t, len(rows), 6) do return
	testing.expect_value(t, rows[0].depth, 0) // Body/Arm
	testing.expect_value(t, rows[1].depth, 1)
	testing.expect_value(t, rows[3].depth, 0) // the animated object
	testing.expect_value(t, rows[4].depth, 1)
}

// --- Retargeting through the window ------------------------------------------------------

@(private = "file")
_SR_DIR :: "moonhug/tests/fixtures/_sheet_rows_tmp"

// A clip document with channels 0..3: Arm Position, root Position, Arm
// Rotation, Leg Scale.
@(private = "file")
_SR_CLIP :: `{
  "__type_guid": "0a4f3b1c-8e57-4c2d-9b6a-5d1e7f2c8a90",
  "length": 1.0,
  "channels": [
    {"target": "Body/Arm", "path": 0, "times": [0], "values": [[0, 0, 0, 0]]},
    {"target": "", "path": 0, "times": [0], "values": [[0, 0, 0, 0]]},
    {"target": "Body/Arm", "path": 1, "times": [0], "values": [[0, 0, 0, 1]]},
    {"target": "Leg", "path": 2, "times": [0], "values": [[1, 1, 1, 0]]}
  ]
}`

@(private = "file")
_sr_targets :: proc(doc: ^inspector.Asset_Doc) -> [4]string {
	clip := cast(^anim.AnimationClip)doc.data.data
	out: [4]string
	for &c, i in clip.channels[:min(len(clip.channels), 4)] do out[i] = c.target
	return out
}

// Retargeting an Object row sets every channel of its target to the new path
// in one undo step, and leaves the other channels alone.
@(test)
test_retarget_object_row_is_one_undo_step :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	s := common.setup_undo(tc)
	context.user_ptr = &tc.uc
	defer common.teardown_undo(tc, s)

	os.make_directory(_SR_DIR)
	path :: _SR_DIR + "/Retarget.anim"
	testing.expect(t, os.write_entire_file(path, transmute([]u8)string(_SR_CLIP)) == nil, "the clip file is written")
	asset_pipeline.asset_pipeline_init()
	engine.asset_db_init(_SR_DIR)
	undo.set_asset_apply(inspector.asset_doc_apply_json)
	undo.set_asset_doc_lookup(inspector.asset_doc_payload_ptr)
	defer {
		animation_editor.animation_record_reset()
		inspector.asset_docs_shutdown()
		engine.asset_db_shutdown()
		common.remove_tree(_SR_DIR)
		common.remove_tree(engine.library_dir())
	}
	doc := inspector.asset_doc_get(path)
	if !testing.expect(t, doc != nil && doc.data.id == typeid_of(anim.AnimationClip), "the clip loads as a document") do return
	if !testing.expect_value(t, len((cast(^anim.AnimationClip)doc.data.data).channels), 4) do return

	root := engine.transform_new("Root")
	animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 0, armed = false)

	before := s.top
	// Spaces around the typed path are trimmed.
	testing.expect(t, animation_editor.animation_window_retarget("Body/Arm", "  Armature/node_2 "), "the retarget applies")
	testing.expect_value(t, _sr_targets(doc), [4]string{"Armature/node_2", "", "Armature/node_2", "Leg"})
	testing.expect_value(t, s.top, before + 1)

	// Nothing to change: no undo step.
	testing.expect(t, !animation_editor.animation_window_retarget("Armature/node_2", "Armature/node_2"), "the same path changes nothing")
	testing.expect(t, !animation_editor.animation_window_retarget("Nobody", "Other"), "a target without channels changes nothing")
	testing.expect_value(t, s.top, before + 1)

	testing.expect(t, undo.apply_undo(s), "undo")
	testing.expect_value(t, _sr_targets(doc), [4]string{"Body/Arm", "", "Body/Arm", "Leg"})
	testing.expect(t, undo.apply_redo(s), "redo")
	testing.expect_value(t, _sr_targets(doc), [4]string{"Armature/node_2", "", "Armature/node_2", "Leg"})

	// The animated object's own row retargets too, to a child path.
	testing.expect(t, animation_editor.animation_window_retarget("", "Body"), "the root row retargets")
	testing.expect_value(t, _sr_targets(doc), [4]string{"Armature/node_2", "Body", "Armature/node_2", "Leg"})
}

// A Position row on A, then one on B, with the lanes `a_lanes` and `b_lanes`.
@(private = "file")
_sr_ab_clip :: proc(a_lanes, b_lanes: string) -> string {
	return fmt.tprintf(`{{
  "__type_guid": "0a4f3b1c-8e57-4c2d-9b6a-5d1e7f2c8a90",
  "length": 1.0,
  "channels": [
    {{"target": "A", "path": 0, "times": [0], "values": [[1, 0, 0, 0]]%s}},
    {{"target": "B", "path": 0, "times": [0], "values": [[0, 0, 3, 0]]%s}}
  ]
}}`, a_lanes, b_lanes)
}

// A retarget that would give a lane of the new path two rows is refused and
// changes nothing: A to B with both rows on every lane. With A masked to x and
// B to z the lanes are disjoint, and both rows end on B.
@(test)
test_retarget_refuses_a_lane_with_two_rows :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	s := common.setup_undo(tc)
	context.user_ptr = &tc.uc
	defer common.teardown_undo(tc, s)

	dir :: "moonhug/tests/fixtures/_retarget_lanes_tmp"
	full :: dir + "/Full.anim"
	masked :: dir + "/Masked.anim"
	os.make_directory(dir)
	testing.expect(t, os.write_entire_file(full, transmute([]u8)_sr_ab_clip("", "")) == nil, "the full clip is written")
	testing.expect(t, os.write_entire_file(masked, transmute([]u8)_sr_ab_clip(`, "lanes": [true, false, false]`, `, "lanes": [false, false, true]`)) == nil, "the masked clip is written")
	asset_pipeline.asset_pipeline_init()
	engine.asset_db_init(dir)
	undo.set_asset_apply(inspector.asset_doc_apply_json)
	undo.set_asset_doc_lookup(inspector.asset_doc_payload_ptr)
	defer {
		animation_editor.animation_record_reset()
		inspector.asset_docs_shutdown()
		engine.asset_db_shutdown()
		common.remove_tree(dir)
		common.remove_tree(engine.library_dir())
	}
	root := engine.transform_new("Root")

	targets :: proc(doc: ^inspector.Asset_Doc) -> [2]string {
		clip := cast(^anim.AnimationClip)doc.data.data
		out: [2]string
		for &c, i in clip.channels[:min(len(clip.channels), 2)] do out[i] = c.target
		return out
	}

	doc := inspector.asset_doc_get(full)
	if !testing.expect(t, doc != nil && doc.data.id == typeid_of(anim.AnimationClip), "the full clip loads as a document") do return
	animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 0, armed = false)
	before := s.top
	testing.expect(t, !animation_editor.animation_window_retarget("A", "B"), "two rows on every lane of B: refused")
	testing.expect_value(t, len((cast(^anim.AnimationClip)doc.data.data).channels), 2)
	testing.expect_value(t, targets(doc), [2]string{"A", "B"})
	testing.expect_value(t, s.top, before)

	doc = inspector.asset_doc_get(masked)
	if !testing.expect(t, doc != nil && doc.data.id == typeid_of(anim.AnimationClip), "the masked clip loads as a document") do return
	animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 0, armed = false)
	testing.expect(t, animation_editor.animation_window_retarget("A", "B"), "x on A and z on B: applied")
	testing.expect_value(t, len((cast(^anim.AnimationClip)doc.data.data).channels), 2)
	testing.expect_value(t, targets(doc), [2]string{"B", "B"})
	_, ok := anim.animation_clip_validate(cast(^anim.AnimationClip)doc.data.data)
	testing.expect(t, ok, "the retargeted clip is valid")
	testing.expect_value(t, s.top, before + 1)
}

// Retargeting carries the row state with the rows: a collapsed Object row
// stays collapsed under its new path, and an expanded vector row of it stays
// expanded. Rows of other targets keep their state.
@(test)
test_retarget_keeps_collapsed_and_expanded_rows :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	s := common.setup_undo(tc)
	context.user_ptr = &tc.uc
	defer common.teardown_undo(tc, s)

	os.make_directory(_SR_DIR)
	path :: _SR_DIR + "/RetargetRows.anim"
	testing.expect(t, os.write_entire_file(path, transmute([]u8)string(_SR_CLIP)) == nil, "the clip file is written")
	asset_pipeline.asset_pipeline_init()
	engine.asset_db_init(_SR_DIR)
	undo.set_asset_apply(inspector.asset_doc_apply_json)
	undo.set_asset_doc_lookup(inspector.asset_doc_payload_ptr)
	defer {
		animation_editor.animation_window_rows_clear()
		animation_editor.animation_record_reset()
		inspector.asset_docs_shutdown()
		engine.asset_db_shutdown()
		common.remove_tree(_SR_DIR)
		common.remove_tree(engine.library_dir())
	}
	doc := inspector.asset_doc_get(path)
	if !testing.expect(t, doc != nil, "the clip loads as a document") do return
	clip := cast(^anim.AnimationClip)doc.data.data
	root := engine.transform_new("Root")
	animation_editor.animation_record_arm(root, engine.PPtr{guid = doc.guid}, 0, armed = false)

	arm_pos := animation_editor.sheet_channel_key(&clip.channels[0], context.temp_allocator)
	leg := animation_editor.sheet_channel_key(&clip.channels[3], context.temp_allocator)
	animation_editor.animation_window_toggle_collapsed("Body/Arm")
	animation_editor.animation_window_toggle_expanded(arm_pos)
	animation_editor.animation_window_toggle_expanded(leg)

	testing.expect(t, animation_editor.animation_window_retarget("Body/Arm", "Armature/node_2"), "the retarget applies")
	moved := animation_editor.sheet_channel_key(&clip.channels[0], context.temp_allocator)
	testing.expect(t, animation_editor.animation_window_is_collapsed("Armature/node_2"), "the collapse follows the row")
	testing.expect(t, !animation_editor.animation_window_is_collapsed("Body/Arm"), "the old path keeps no collapse")
	testing.expect(t, animation_editor.animation_window_is_expanded(moved), "the expanded vector row follows the row")
	testing.expect(t, !animation_editor.animation_window_is_expanded(arm_pos), "the old key is gone")
	testing.expect(t, animation_editor.animation_window_is_expanded(leg), "another target keeps its state")
}

