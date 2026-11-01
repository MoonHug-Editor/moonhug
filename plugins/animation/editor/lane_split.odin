package animation_editor

// Split lanes: a vector row (Position, Scale, Euler, a vector field) kept as
// one channel per lane, each with its own key times, so x can have keys on
// frames y has none. The channels share the row's target and property and
// each masks itself to its lane (Animation_Channel.lanes_off), which is how
// the clip file already says what a channel animates: a split row has no
// field of its own. The runtime merges them per lane (playable_graph.odin).
//
// Joined (one channel, lanes sharing key times) is the default, the cheaper
// form: one time and one value per key instead of one per lane, and one
// curve evaluation per sample. Split on demand.
//
// Pure, no imgui: the window's Split Lane Keys and Join Lane Keys items call
// these inside an undo session on the clip document, with the document's
// allocator in context, and the window reselects afterwards (channel
// indices shift).

import "core:math/linalg"
import engine "moonhug:packages/engine"
import anim "moonhug:packages/animation"

// Whether row `ch` can split: a vector row with at least two enabled lanes
// and no other channel of its property.
sheet_can_split :: proc(clip: ^anim.AnimationClip, ch: int) -> bool {
	if ch < 0 || ch >= len(clip.channels) do return false
	c := &clip.channels[ch]
	width := anim.animation_channel_mask_width(c)
	if width < 2 do return false
	on := 0
	for l in 0 ..< width do if l not_in c.lanes_off do on += 1
	if on < 2 do return false
	return len(sheet_group_channels(clip, ch, context.temp_allocator)) == 1
}

// Splits row `ch` into one channel per enabled lane: the row keeps its first
// enabled lane, each further lane becomes a copy of the row (times, values,
// modes, tangents) right after it, masked to that lane. Returns the channel
// indices in lane order, on `allocator`. Nothing changes when the row cannot
// split (sheet_can_split), and the result is the row alone.
sheet_split_lanes :: proc(clip: ^anim.AnimationClip, ch: int, allocator := context.temp_allocator) -> []int {
	out := make([dynamic]int, allocator)
	if !sheet_can_split(clip, ch) {
		append(&out, ch)
		return out[:]
	}
	width := anim.animation_channel_mask_width(&clip.channels[ch])
	all: anim.Lane_Set
	for l in 0 ..< width do all += {l}
	src := clip.channels[ch]
	first := true
	at := ch
	for l in 0 ..< width {
		if l in src.lanes_off do continue
		if first {
			clip.channels[ch].lanes_off = anim.Channel_Lanes_Off(all - {l})
			first = false
		} else {
			at += 1
			inject_at(&clip.channels, at, _lane_channel_clone(src, anim.Channel_Lanes_Off(all - {l})))
		}
		append(&out, at)
	}
	return out[:]
}

// A copy of channel `src` with its own strings and arrays, masked to `off`.
@(private = "file")
_lane_channel_clone :: proc(src: anim.Animation_Channel, off: anim.Channel_Lanes_Off) -> anim.Animation_Channel {
	c := src
	c.target = _clone_string(src.target)
	c.component = _clone_string(src.component)
	c.field = _clone_string(src.field)
	c.times = _clone_dynamic(src.times)
	c.values = anim.animation_channel_values_clone(src.values)
	c.modes = _clone_dynamic(src.modes)
	c.tangents = _clone_dynamic(src.tangents)
	c.lanes_off = off
	return c
}

@(private = "file")
_clone_string :: proc(s: string) -> string {
	if s == "" do return ""
	out := make([]u8, len(s))
	copy(out, s)
	return string(out)
}

@(private = "file")
_clone_dynamic :: proc(a: [dynamic]$T) -> [dynamic]T {
	if a == nil do return nil
	out := make([dynamic]T, len(a))
	copy(out[:], a[:])
	return out
}

// Adds a channel for lane `lane` to the split row `group` (sheet_group_channels,
// in channel order), which has none for it: a copy of the group's first
// channel masked to the lane, after the group's last channel. Returns its
// index, or -1 when the group already animates the lane or the lane is past
// the row's width.
sheet_lane_add :: proc(clip: ^anim.AnimationClip, group: []int, lane: int) -> int {
	if len(group) == 0 do return -1
	width := anim.animation_channel_mask_width(&clip.channels[group[0]])
	if lane < 0 || lane >= width || sheet_lane_channel(clip, group, lane) >= 0 do return -1
	all: anim.Lane_Set
	for l in 0 ..< width do all += {l}
	at := group[len(group) - 1] + 1
	inject_at(&clip.channels, at, _lane_channel_clone(clip.channels[group[0]], anim.Channel_Lanes_Off(all - {lane})))
	return at
}

// Whether the channels `group` (sheet_group_channels) can join: a split float
// row, two or more channels.
sheet_can_join :: proc(clip: ^anim.AnimationClip, group: []int) -> bool {
	if len(group) < 2 do return false
	for idx in group do if !anim.animation_channel_is_float(&clip.channels[idx]) do return false
	return true
}

// Whether joining `group` (sheet_can_join) changes the animation: at some
// key time one lane holds (a Step key or a Step segment there) while
// another interpolates. A joined key has one mode for every lane, so the
// hold becomes a ramp. Every other join is exact (sheet_join_lanes).
sheet_join_mixed_step :: proc(clip: ^anim.AnimationClip, group: []int) -> bool {
	if !sheet_can_join(clip, group) do return false
	times := sheet_keys_times(clip, group, context.temp_allocator)
	width := anim.animation_channel_mask_width(&clip.channels[group[0]])
	for t in times {
		step, other := false, false
		for l in 0 ..< width {
			ci := sheet_lane_channel(clip, group, l)
			if ci < 0 do continue
			if _lane_mode_at(clip, &clip.channels[ci], t) == .Step {
				step = true
			} else {
				other = true
			}
		}
		if step && other do return true
	}
	return false
}

// Joins the channels `group` (sheet_group_channels, in channel order) into
// the first: the union of their key times (times within half a frame of an
// earlier one fold into it), each lane sampled from the channel that
// animates it at every time, the lanes the group animates enabled. The
// joined key's mode is the lanes' mode where they agree, Linear or Step,
// else Free with each lane's slopes at the time, which rebuilds a Linear,
// Smooth or Free lane exactly. A Smooth lane becomes Free: its tangents
// are frozen, so later edits do not re-smooth it. Only a Step lane next to
// an interpolating lane changes (sheet_join_mixed_step). A row left all
// Linear or all Step writes no modes and no tangents. The other channels
// are removed, their memory freed. Returns the joined channel's index.
// Nothing changes when the group cannot join (sheet_can_join).
sheet_join_lanes :: proc(clip: ^anim.AnimationClip, group: []int) -> int {
	if !sheet_can_join(clip, group) do return len(group) > 0 ? group[0] : -1
	dst := group[0]
	times := sheet_keys_times(clip, group, context.temp_allocator)
	width := anim.animation_channel_mask_width(&clip.channels[dst])

	// The lane each channel animates, and the lanes the joined row animates.
	lane_ch := [4]int{-1, -1, -1, -1}
	for l in 0 ..< width do lane_ch[l] = sheet_lane_channel(clip, group, l)
	off: anim.Lane_Set
	for l in 0 ..< width do if lane_ch[l] < 0 do off += {l}

	n := len(times)
	vals := make([][4]f32, n, context.temp_allocator)
	modes := make([]anim.Key_Mode, n, context.temp_allocator)
	tans := make([][2][4]f32, n, context.temp_allocator)
	any_free := false
	for t, i in times {
		all_linear, all_step := true, true
		for l in 0 ..< width {
			ci := lane_ch[l]
			if ci < 0 do continue
			c := &clip.channels[ci]
			vals[i][l] = anim._animation_channel_sample(c, t)[l]
			k := _lane_key_near(clip, c, t)
			if k >= 0 {
				kin, kout := anim._animation_key_tangents(c, anim.animation_channel_floats(c)[:], k)
				tans[i][0][l] = kin[l]
				tans[i][1][l] = kout[l]
			} else {
				tans[i][0][l] = anim._animation_channel_slope(c, t, from_left = true)[l]
				tans[i][1][l] = anim._animation_channel_slope(c, t)[l]
			}
			m := _lane_mode_at(clip, c, t)
			if m != .Linear do all_linear = false
			if m != .Step do all_step = false
		}
		switch {
		case all_linear: modes[i] = .Linear
		case all_step:   modes[i] = .Step
		case:
			modes[i] = .Free
			any_free = true
		}
	}
	uniform := true
	for m in modes do if m != modes[0] do uniform = false

	d := &clip.channels[dst]
	clear(&d.times)
	append(&d.times, ..times)
	f := anim.animation_channel_floats(d)
	clear(f)
	append(f, ..vals)
	clear(&d.modes)
	clear(&d.tangents)
	d.step = false
	if uniform && !any_free {
		// All Linear or all Step: the row's `step` flag says it, no modes.
		d.step = modes[0] == .Step
	} else {
		if d.modes == nil do d.modes = make([dynamic]anim.Key_Mode)
		append(&d.modes, ..modes)
		if d.tangents == nil do d.tangents = make([dynamic][2][4]f32)
		append(&d.tangents, ..tans)
	}
	d.lanes_off = anim.Channel_Lanes_Off(off)

	// The other channels, last first so the indices before them hold.
	for i := len(group) - 1; i >= 1; i -= 1 do sheet_channel_free(clip, group[i])
	return dst
}

// The mode of lane channel `c` at `t`: its key's mode when it has a key
// there, else the mode of the segment `t` falls in (the key before it).
// Outside the key range the lane holds a constant, which any mode rebuilds,
// so Linear.
@(private = "file")
_lane_mode_at :: proc(clip: ^anim.AnimationClip, c: ^anim.Animation_Channel, t: f32) -> anim.Key_Mode {
	if k := _lane_key_near(clip, c, t); k >= 0 do return anim._animation_key_mode(c, k)
	n := len(c.times)
	if n < 2 || t < c.times[0] || t > c.times[n - 1] do return .Linear
	// The last key at or before t.
	lo := 0
	for kt, i in c.times do if kt <= t do lo = i
	return anim._animation_key_mode(c, lo)
}

// The key of `c` within half a frame of `t`, -1 for none.
@(private = "file")
_lane_key_near :: proc(clip: ^anim.AnimationClip, c: ^anim.Animation_Channel, t: f32) -> int {
	half := 0.5 / anim.animation_clip_frame_rate(clip)
	for kt, k in c.times do if abs(kt - t) <= half do return k
	return -1
}

// Removes channel `i` from the clip and frees its strings and arrays.
sheet_channel_free :: proc(clip: ^anim.AnimationClip, i: int) {
	ch := &clip.channels[i]
	delete(ch.target)
	delete(ch.component)
	delete(ch.field)
	delete(ch.times)
	anim.animation_channel_values_delete(&ch.values)
	delete(ch.modes)
	delete(ch.tangents)
	ordered_remove(&clip.channels, i)
}

// Turns the quaternion Rotation row `ch` into an Euler row in place: each
// key's quaternion becomes euler angles in degrees, and from the second key
// on the angles are unwound, so a turn through 180 degrees does not flip
// sign between keys: of the two euler solutions of a quaternion, each lane
// moved by whole turns, the one nearest the previous key wins. A key that
// interpolated (Linear, or Free and Smooth from a glTF cubic import, which a
// quaternion row slerps anyway) becomes Linear, a Step key stays Step, and
// the tangents go. False when `ch` is not a quaternion Rotation row.
sheet_rotation_to_euler :: proc(clip: ^anim.AnimationClip, ch: int) -> bool {
	if ch < 0 || ch >= len(clip.channels) do return false
	c := &clip.channels[ch]
	if anim.animation_channel_is_property(c) || c.path != .Rotation do return false
	vals := anim.animation_channel_floats(c)
	prev: [3]f32
	for &v, k in vals {
		q := v
		if l := linalg.length(q); l > 0.0001 do q = (1.0 / l) * q
		e := k > 0 ? anim.animation_euler_nearest(q, prev) : engine.quat_to_euler_xyz(q)
		v = {e.x, e.y, e.z, 0}
		prev = e
	}
	c.path = .Euler
	c.lanes_off = {}
	for &m in c.modes do if m != .Step do m = .Linear
	clear(&c.tangents)
	return true
}
