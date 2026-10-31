package animation_editor

// Split lanes: a vector row (Position, Scale, Euler, a vector field) kept as
// one channel per lane, each with its own key times, so x can have keys on
// frames y has none. The channels share the row's target and property and
// each masks itself to its lane (Animation_Channel.lanes_off), which is how
// the clip file already says what a channel animates: a split row needs no
// new field. The runtime merges them per lane (playable_graph.odin).
//
// Joined (one channel, lanes sharing key times) is the default, the cheaper
// form: one time and one value per key instead of one per lane, and one
// curve evaluation per sample. Split on demand.
//
// Pure, no imgui: the window's Split Lane Keys and Join Lane Keys items call
// these inside an undo session on the clip document, with the document's
// allocator in context, and the window reselects afterwards (channel
// indices shift).

import "core:math"
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

// Joins the channels `group` (sheet_group_channels, in channel order) into
// the first: the union of their key times (times within half a frame of an
// earlier one fold into it), each lane sampled from the channel that
// animates it at every time, the lanes the group animates enabled. The
// joined keys are Free with each lane's slopes at the time, so every lane
// keeps its curve: a Step key stays Step only where every lane steps. The
// other channels are removed, their memory freed. Returns the joined
// channel's index, which is the first of `group` less the removed channels
// before it (none, as the group is in channel order). Nothing changes when
// the group cannot join (sheet_can_join).
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
	for t, i in times {
		all_step := true
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
				if anim._animation_key_mode(c, k) != .Step do all_step = false
			} else {
				tans[i][0][l] = anim._animation_channel_slope(c, t, from_left = true)[l]
				tans[i][1][l] = anim._animation_channel_slope(c, t)[l]
				all_step = false
			}
		}
		modes[i] = all_step ? .Step : .Free
	}

	d := &clip.channels[dst]
	clear(&d.times)
	append(&d.times, ..times)
	f := anim.animation_channel_floats(d)
	clear(f)
	append(f, ..vals)
	if d.modes == nil do d.modes = make([dynamic]anim.Key_Mode)
	clear(&d.modes)
	append(&d.modes, ..modes)
	if d.tangents == nil do d.tangents = make([dynamic][2][4]f32)
	clear(&d.tangents)
	append(&d.tangents, ..tans)
	d.lanes_off = anim.Channel_Lanes_Off(off)

	// The other channels, last first so the indices before them hold.
	for i := len(group) - 1; i >= 1; i -= 1 do sheet_channel_free(clip, group[i])
	return dst
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
// moved by whole turns, the one nearest the previous key wins. Key modes
// stay (a quaternion row's are Linear or Step), tangents are none. False
// when `ch` is not a quaternion Rotation row.
sheet_rotation_to_euler :: proc(clip: ^anim.AnimationClip, ch: int) -> bool {
	if ch < 0 || ch >= len(clip.channels) do return false
	c := &clip.channels[ch]
	if anim.animation_channel_is_property(c) || c.path != .Rotation do return false
	vals := anim.animation_channel_floats(c)
	prev: [3]f32
	for &v, k in vals {
		q := v
		if l := linalg.length(q); l > 0.0001 do q = (1.0 / l) * q
		e := engine.quat_to_euler_xyz(q)
		if k > 0 do e = _euler_nearest(q, e, prev)
		v = {e.x, e.y, e.z, 0}
		prev = e
	}
	c.path = .Euler
	c.lanes_off = {}
	clear(&c.tangents)
	return true
}

// The euler angles for `q` nearest to `prev`: `e` (a solution of `q`) and
// its alternate solution, each lane shifted by whole turns toward `prev`,
// the candidate with the smallest largest lane step. The alternate is kept
// only when it rebuilds `q`.
@(private = "file")
_euler_nearest :: proc(q: [4]f32, e, prev: [3]f32) -> [3]f32 {
	best := _euler_unwind(e, prev)
	alt := _euler_unwind({e.x + 180, 180 - e.y, e.z + 180}, prev)
	if abs(linalg.dot(anim.animation_quat_from_euler(alt), q)) < 0.9999 do return best
	if _euler_step(alt, prev) < _euler_step(best, prev) do return alt
	return best
}

@(private = "file")
_euler_unwind :: proc(e, prev: [3]f32) -> [3]f32 {
	out := e
	for l in 0 ..< 3 do out[l] = e[l] + 360 * math.round((prev[l] - e[l]) / 360)
	return out
}

@(private = "file")
_euler_step :: proc(e, prev: [3]f32) -> f32 {
	return max(abs(e.x - prev.x), abs(e.y - prev.y), abs(e.z - prev.z))
}

