package animation_tests

// Split lanes (editor/lane_split.odin): a vector row kept as one channel per
// lane, each masked to its lane and with its own key times. Split copies the
// row once per enabled lane, Join merges the channels back into one row on
// the union of their key times, with Free tangents so every lane keeps its
// curve, and Add Lane gives a split row a channel for a lane it lacks.

import "core:encoding/uuid"
import "core:math/linalg"
import "core:strings"
import "core:testing"
import "moonhug:packages/engine"
import anim "moonhug:packages/animation"
import animation_editor "moonhug:packages/animation/editor"

// Appends a float row on "Arm" with keys at `times` holding `values`, heap
// allocated so anim.type_cleanup_AnimationClip frees it. `modes` is optional.
// A property row of `field` on a Light when `field` is set, else a
// transform row on `path`.
@(private = "file")
_ls_row :: proc(clip: ^anim.AnimationClip, path: anim.Animation_Path, times: []f32, values: [][4]f32, off: anim.Channel_Lanes_Off = {}, modes: []anim.Key_Mode = nil, field := "") {
	ch := anim.Animation_Channel{target = strings.clone("Arm"), path = path, lanes_off = off}
	if field != "" {
		ch.component = strings.clone(uuid.to_string(engine.get_guid_by_typeid(engine.Light), context.temp_allocator))
		ch.field = strings.clone(field)
	}
	ch.times = make([dynamic]f32)
	ch.values = make([dynamic][4]f32)
	append(&ch.times, ..times)
	append(&ch.values.([dynamic][4]f32), ..values)
	if modes != nil {
		ch.modes = make([dynamic]anim.Key_Mode)
		append(&ch.modes, ..modes)
	}
	append(&clip.channels, ch)
}

@(private = "file")
_ls_clip :: proc() -> anim.AnimationClip {
	clip := anim.AnimationClip{length = 2, frame_rate = 10}
	clip.channels = make([dynamic]anim.Animation_Channel)
	return clip
}

@(private = "file")
_ls_floats :: proc(clip: ^anim.AnimationClip, ch: int) -> [][4]f32 {
	return anim.animation_channel_floats(&clip.channels[ch])[:]
}

// Splitting a Position row with two keys gives three channels in lane order,
// each masked to its lane, each a copy of the row's times, values and modes.
// A channel after the row stays after the new ones.
@(test)
test_lane_split_makes_one_channel_per_lane :: proc(t: ^testing.T) {
	clip := _ls_clip()
	defer anim.type_cleanup_AnimationClip(&clip)
	_ls_row(&clip, .Position, {0, 1}, {{1, 2, 3, 0}, {4, 5, 6, 0}}, modes = {.Smooth, .Linear})
	_ls_row(&clip, .Scale, {0}, {{1, 1, 1, 0}})

	testing.expect(t, animation_editor.sheet_can_split(&clip, 0), "a 3-lane row can split")
	got := animation_editor.sheet_split_lanes(&clip, 0, context.temp_allocator)
	if !testing.expect_value(t, len(got), 3) do return
	testing.expect_value(t, got[0], 0)
	testing.expect_value(t, got[1], 1)
	testing.expect_value(t, got[2], 2)
	if !testing.expect_value(t, len(clip.channels), 4) do return

	masks := [3]anim.Channel_Lanes_Off{{1, 2}, {0, 2}, {0, 1}}
	for i in 0 ..< 3 {
		c := &clip.channels[i]
		testing.expect_value(t, c.lanes_off, masks[i])
		testing.expect_value(t, c.path, anim.Animation_Path.Position)
		testing.expect_value(t, c.target, "Arm")
		if !testing.expect_value(t, len(c.times), 2) do continue
		testing.expect_value(t, c.times[0], 0)
		testing.expect_value(t, c.times[1], 1)
		vals := _ls_floats(&clip, i)
		testing.expect_value(t, vals[0], [4]f32{1, 2, 3, 0})
		testing.expect_value(t, vals[1], [4]f32{4, 5, 6, 0})
		if testing.expect_value(t, len(c.modes), 2) do testing.expect_value(t, c.modes[0], anim.Key_Mode.Smooth)
	}
	testing.expect_value(t, clip.channels[3].path, anim.Animation_Path.Scale)
	// The copies own their arrays: an edit of one leaves the others alone.
	_ls_floats(&clip, 1)[0].y = 9
	testing.expect_value(t, _ls_floats(&clip, 0)[0].y, 2)
	testing.expect_value(t, _ls_floats(&clip, 2)[0].y, 2)

	group := animation_editor.sheet_group_channels(&clip, 1, context.temp_allocator)
	testing.expect_value(t, len(group), 3)
}

// A scalar row, a row with one enabled lane, a Rotation row and a row that is
// already split cannot split, and splitting one changes nothing.
@(test)
test_lane_split_refuses_scalar_single_lane_and_split_rows :: proc(t: ^testing.T) {
	clip := _ls_clip()
	defer anim.type_cleanup_AnimationClip(&clip)
	_ls_row(&clip, .Position, {0}, {{1, 0, 0, 0}}, field = "intensity")
	_ls_row(&clip, .Scale, {0}, {{1, 2, 3, 0}}, off = {0, 1})
	_ls_row(&clip, .Rotation, {0}, {{0, 0, 0, 1}})
	_ls_row(&clip, .Position, {0}, {{1, 2, 3, 0}}, off = {1, 2})
	_ls_row(&clip, .Position, {0}, {{1, 2, 3, 0}}, off = {0})

	for ch in 0 ..< 5 {
		testing.expectf(t, !animation_editor.sheet_can_split(&clip, ch), "row %d cannot split", ch)
		got := animation_editor.sheet_split_lanes(&clip, ch, context.temp_allocator)
		testing.expect(t, len(got) == 1 && got[0] == ch, "the result is the row alone")
	}
	testing.expect_value(t, len(clip.channels), 5)
	testing.expect(t, !animation_editor.sheet_can_split(&clip, 9), "an index past the end cannot split")
}

// Joining three channels with different key times gives one row on the union
// of the times, every lane enabled, Free keys. Each lane holds the value its
// channel had at every time, and between the keys the joined curve follows
// each lane's old curve. An unrelated channel after the group stays.
@(test)
test_lane_join_keeps_every_lanes_curve :: proc(t: ^testing.T) {
	clip := _ls_clip()
	defer anim.type_cleanup_AnimationClip(&clip)
	_ls_row(&clip, .Position, {0, 1, 2}, {{0, 0, 0, 0}, {2, 0, 0, 0}, {1, 0, 0, 0}}, off = {1, 2}, modes = {.Smooth, .Smooth, .Smooth})
	_ls_row(&clip, .Position, {0, 0.5, 2}, {{0, 0, 0, 0}, {0, 1, 0, 0}, {0, 3, 0, 0}}, off = {0, 2})
	_ls_row(&clip, .Position, {0.25, 1.5}, {{0, 0, 5, 0}, {0, 0, -1, 0}}, off = {0, 1}, modes = {.Smooth, .Linear})
	_ls_row(&clip, .Scale, {0}, {{1, 1, 1, 0}})

	group := animation_editor.sheet_group_channels(&clip, 0, context.temp_allocator)
	if !testing.expect_value(t, len(group), 3) do return
	testing.expect(t, animation_editor.sheet_can_join(&clip, group), "three float channels can join")

	// Each lane sampled from its own channel before the join.
	probes := []f32{0, 0.1, 0.25, 0.3, 0.5, 0.7, 1, 1.2, 1.5, 1.75, 1.9, 2}
	before := make([][3]f32, len(probes), context.temp_allocator)
	for p, i in probes {
		for l in 0 ..< 3 do before[i][l] = anim._animation_channel_sample(&clip.channels[l], p)[l]
	}

	testing.expect_value(t, animation_editor.sheet_join_lanes(&clip, group), 0)
	if !testing.expect_value(t, len(clip.channels), 2) do return
	testing.expect_value(t, clip.channels[1].path, anim.Animation_Path.Scale)

	c := &clip.channels[0]
	testing.expect_value(t, c.lanes_off, anim.Channel_Lanes_Off{})
	want_times := []f32{0, 0.25, 0.5, 1, 1.5, 2}
	if !testing.expect_value(t, len(c.times), len(want_times)) do return
	for w, i in want_times do testing.expect_value(t, c.times[i], w)
	testing.expect_value(t, len(c.modes), len(want_times))
	for m in c.modes do testing.expect_value(t, m, anim.Key_Mode.Free)
	testing.expect_value(t, len(c.tangents), len(want_times))

	for p, i in probes {
		v := anim._animation_channel_sample(c, p)
		for l in 0 ..< 3 {
			testing.expectf(t, abs(v[l] - before[i][l]) < 1e-3, "lane %d at %v: %v after the join, %v before", l, p, v[l], before[i][l])
		}
	}
}

// A lane none of the joined channels animates ends disabled.
@(test)
test_lane_join_disables_a_lane_without_a_channel :: proc(t: ^testing.T) {
	clip := _ls_clip()
	defer anim.type_cleanup_AnimationClip(&clip)
	_ls_row(&clip, .Position, {0, 1}, {{1, 0, 0, 0}, {2, 0, 0, 0}}, off = {1, 2})
	_ls_row(&clip, .Position, {0.5}, {{0, 0, 7, 0}}, off = {0, 1})

	group := animation_editor.sheet_group_channels(&clip, 0, context.temp_allocator)
	testing.expect_value(t, animation_editor.sheet_join_lanes(&clip, group), 0)
	if !testing.expect_value(t, len(clip.channels), 1) do return
	testing.expect_value(t, clip.channels[0].lanes_off, anim.Channel_Lanes_Off{1})
	testing.expect_value(t, len(clip.channels[0].times), 3)
}

// Add Lane gives a split row a channel for a lane it lacks: a copy of the
// group's first channel masked to the lane, right after the group. A lane the
// group has, or one past the row's width, adds nothing.
@(test)
test_lane_add_appends_a_masked_channel_after_the_group :: proc(t: ^testing.T) {
	clip := _ls_clip()
	defer anim.type_cleanup_AnimationClip(&clip)
	_ls_row(&clip, .Position, {0, 1}, {{1, 2, 3, 0}, {4, 5, 6, 0}}, off = {1, 2})
	_ls_row(&clip, .Position, {0.5}, {{0, 0, 7, 0}}, off = {0, 1})
	_ls_row(&clip, .Scale, {0}, {{1, 1, 1, 0}})

	group := animation_editor.sheet_group_channels(&clip, 0, context.temp_allocator)
	testing.expect_value(t, animation_editor.sheet_lane_channel(&clip, group, 1), -1)
	testing.expect_value(t, animation_editor.sheet_lane_add(&clip, group, 1), 2)
	if !testing.expect_value(t, len(clip.channels), 4) do return
	added := &clip.channels[2]
	testing.expect_value(t, added.lanes_off, anim.Channel_Lanes_Off{0, 2})
	testing.expect_value(t, len(added.times), 2)
	testing.expect_value(t, _ls_floats(&clip, 2)[1], [4]f32{4, 5, 6, 0})
	testing.expect_value(t, clip.channels[3].path, anim.Animation_Path.Scale)

	group = animation_editor.sheet_group_channels(&clip, 0, context.temp_allocator)
	testing.expect_value(t, len(group), 3)
	testing.expect_value(t, animation_editor.sheet_lane_add(&clip, group, 1), -1)
	testing.expect_value(t, animation_editor.sheet_lane_add(&clip, group, 3), -1)
	testing.expect_value(t, len(clip.channels), 4)
}

// Split then Join gives the row back: the same key times and values, every
// lane enabled.
@(test)
test_lane_split_then_join_round_trips :: proc(t: ^testing.T) {
	clip := _ls_clip()
	defer anim.type_cleanup_AnimationClip(&clip)
	times := []f32{0, 0.5, 1.5}
	values := [][4]f32{{1, 2, 3, 0}, {4, -5, 6, 0}, {0, 1, 2, 0}}
	_ls_row(&clip, .Position, times, values)

	group := animation_editor.sheet_split_lanes(&clip, 0, context.temp_allocator)
	if !testing.expect_value(t, len(clip.channels), 3) do return
	testing.expect_value(t, animation_editor.sheet_join_lanes(&clip, group), 0)
	if !testing.expect_value(t, len(clip.channels), 1) do return
	c := &clip.channels[0]
	testing.expect_value(t, c.lanes_off, anim.Channel_Lanes_Off{})
	if !testing.expect_value(t, len(c.times), len(times)) do return
	for w, i in times do testing.expect_value(t, c.times[i], w)
	for w, i in values do testing.expect_value(t, _ls_floats(&clip, 0)[i].xyz, w.xyz)
}

// A quaternion row converts to an Euler row whose angles are continuous
// across keys: a turn 0, 170, 190 (the last keyed as -170) reads back in
// order, every key rebuilding its quaternion.
@(test)
test_lane_quaternion_row_converts_to_unwound_euler :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	clip := anim.AnimationClip{length = 2, frame_rate = 30}
	clip.channels = make([dynamic]anim.Animation_Channel, context.temp_allocator)
	ch := anim.Animation_Channel{target = "Arm", path = .Rotation}
	ch.times = make([dynamic]f32, context.temp_allocator)
	append(&ch.times, 0, 1, 2)
	vals := make([dynamic][4]f32, context.temp_allocator)
	for y in ([3]f32{0, 170, -170}) do append(&vals, anim.animation_quat_from_euler({0, y, 0}))
	ch.values = vals
	ch.tangents = make([dynamic][2][4]f32, context.temp_allocator)
	append(&clip.channels, ch)
	src := make([dynamic][4]f32, context.temp_allocator)
	append(&src, ..vals[:])

	testing.expect(t, animation_editor.sheet_rotation_to_euler(&clip, 0), "a quaternion row converts")
	c := &clip.channels[0]
	testing.expect_value(t, c.path, anim.Animation_Path.Euler)
	out := anim.animation_channel_floats(c)
	want := [3]f32{0, 170, 190}
	for k in 0 ..< 3 {
		testing.expectf(t, abs(out[k].y - want[k]) < 0.01 && abs(out[k].x) < 0.01 && abs(out[k].z) < 0.01, "key %d reads %v, want y %v", k, out[k], want[k])
		q := anim.animation_quat_from_euler(out[k].xyz)
		testing.expectf(t, abs(linalg.dot(q, src[k])) > 0.9999, "key %d rebuilds its quaternion", k)
	}
	testing.expect(t, !animation_editor.sheet_rotation_to_euler(&clip, 0), "an Euler row does not convert again")
}

// Convert to Euler turns the keys that interpolated into Linear keys and
// keeps Step keys, with no tangents left: a glTF cubic import marks a
// quaternion row's keys Free, which the row never used.
@(test)
test_lane_quaternion_row_converts_modes_to_linear_or_step :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	clip := anim.AnimationClip{length = 2, frame_rate = 30}
	clip.channels = make([dynamic]anim.Animation_Channel, context.temp_allocator)
	ch := anim.Animation_Channel{target = "Arm", path = .Rotation}
	ch.times = make([dynamic]f32, context.temp_allocator)
	append(&ch.times, 0, 1, 2)
	vals := make([dynamic][4]f32, context.temp_allocator)
	for y in ([3]f32{0, 30, 60}) do append(&vals, anim.animation_quat_from_euler({0, y, 0}))
	ch.values = vals
	ch.modes = make([dynamic]anim.Key_Mode, context.temp_allocator)
	append(&ch.modes, anim.Key_Mode.Free, anim.Key_Mode.Smooth, anim.Key_Mode.Step)
	ch.tangents = make([dynamic][2][4]f32, context.temp_allocator)
	append(&ch.tangents, [2][4]f32{}, [2][4]f32{}, [2][4]f32{})
	append(&clip.channels, ch)

	testing.expect(t, animation_editor.sheet_rotation_to_euler(&clip, 0), "converts")
	c := &clip.channels[0]
	testing.expect_value(t, len(c.modes), 3)
	testing.expect_value(t, c.modes[0], anim.Key_Mode.Linear)
	testing.expect_value(t, c.modes[1], anim.Key_Mode.Linear)
	testing.expect_value(t, c.modes[2], anim.Key_Mode.Step)
	testing.expect_value(t, len(c.tangents), 0)
}

// Lanes that are all Linear join to a Linear row with no modes and no
// tangents. A Step lane next to a Linear lane is the one lossy join, and
// the join reports it. Lanes that all step join to a Step row.
@(test)
test_lane_join_keeps_shared_modes_and_reports_mixed_step :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	// The joined rows' new arrays go to the temp allocator with the rest.
	context.allocator = context.temp_allocator
	clip := anim.AnimationClip{length = 2, frame_rate = 30}
	clip.channels = make([dynamic]anim.Animation_Channel, context.temp_allocator)
	_ls_row(&clip, .Position, {0, 1}, {{0, 0, 0, 0}, {2, 0, 0, 0}}, off = {1, 2})
	_ls_row(&clip, .Position, {0, 0.5, 2}, {{0, 0, 0, 0}, {0, 1, 0, 0}, {0, 3, 0, 0}}, off = {0, 2})
	group := animation_editor.sheet_group_channels(&clip, 0, context.temp_allocator)
	testing.expect(t, !animation_editor.sheet_join_mixed_step(&clip, group), "linear lanes join exactly")
	dst := animation_editor.sheet_join_lanes(&clip, group)
	c := &clip.channels[dst]
	testing.expect_value(t, len(c.times), 4)
	testing.expect_value(t, len(c.modes), 0)
	testing.expect_value(t, len(c.tangents), 0)
	testing.expect(t, !c.step, "a linear row")
	// x at 0.5 sits on its line, y at 1 on its.
	v := anim.animation_channel_floats(c)
	testing.expectf(t, abs(v[1].x - 1) < 1e-5 && abs(v[2].y - 1.6666666) < 1e-4, "inserted keys lie on the lanes, got %v %v", v[1], v[2])

	clip2 := anim.AnimationClip{length = 2, frame_rate = 30}
	clip2.channels = make([dynamic]anim.Animation_Channel, context.temp_allocator)
	_ls_row(&clip2, .Position, {0, 1}, {{0, 0, 0, 0}, {2, 0, 0, 0}}, off = {1, 2}, modes = {.Step, .Step})
	_ls_row(&clip2, .Position, {0, 1}, {{0, 0, 0, 0}, {0, 3, 0, 0}}, off = {0, 2})
	group2 := animation_editor.sheet_group_channels(&clip2, 0, context.temp_allocator)
	testing.expect(t, animation_editor.sheet_join_mixed_step(&clip2, group2), "a step lane next to a linear lane is reported")

	clip3 := anim.AnimationClip{length = 2, frame_rate = 30}
	clip3.channels = make([dynamic]anim.Animation_Channel, context.temp_allocator)
	_ls_row(&clip3, .Position, {0, 1}, {{0, 0, 0, 0}, {2, 0, 0, 0}}, off = {1, 2}, modes = {.Step, .Step})
	_ls_row(&clip3, .Position, {0, 1}, {{0, 0, 0, 0}, {0, 3, 0, 0}}, off = {0, 2}, modes = {.Step, .Step})
	group3 := animation_editor.sheet_group_channels(&clip3, 0, context.temp_allocator)
	testing.expect(t, !animation_editor.sheet_join_mixed_step(&clip3, group3), "lanes that all step join exactly")
	d3 := &clip3.channels[animation_editor.sheet_join_lanes(&clip3, group3)]
	testing.expect(t, d3.step && len(d3.modes) == 0, "a step row with no modes")
}

