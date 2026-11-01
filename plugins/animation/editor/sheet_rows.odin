package animation_editor

// The Animation window's sheet rows: the channels grouped by the transform
// they animate, and by the property they animate. Pure, no imgui, so the
// grouping is testable on its own.
//
// - One Object row per distinct channel target, in order of first appearance
//   among the channels. "" is the animated object itself.
// - A Channel row per property of that target, in order of the property's
//   first channel, right after its Object row, unless the target is
//   collapsed. A property is one channel (a joined row), or one channel per
//   lane (a split row, lane_split.odin): the channels sharing the row's
//   sheet_channel_key. The row's `ch` is the property's first channel and
//   `split` says whether there are more (sheet_group_channels lists them).
// - An Object row has depth 0, its Channel rows 1, their Lane rows 2.
// - A Channel row of a vector (a float row with a lane mask of 2 to 4 lanes,
//   anim.animation_channel_mask_width: Position, Scale, Euler, a vector
//   field, never Rotation) is expandable: expanded, a Lane row per enabled
//   lane follows it, x to w. A Lane row's `ch` is the channel that animates
//   its lane: the row's own channel when joined, the lane's channel when
//   split. A disabled lane has no row. Collapsed is the default.
// - The view maps between sheet rows and channel indices only through
//   sheet_rows, sheet_group_channels and sheet_row_of_channel. A channel
//   index is never a row index.

import "core:fmt"
import "core:slice"
import "core:strings"
import anim "moonhug:packages/animation"

Sheet_Row_Kind :: enum {
	Object,
	Channel,
	Lane, // one lane of a vector Channel row
}

Sheet_Row :: struct {
	kind:   Sheet_Row_Kind,
	target: string, // the channel target, borrowed from the clip
	ch:     int,    // channel index, -1 for an Object row: a Channel row's first channel, a Lane row's own
	depth:  int,    // indent level: 0 for an Object row, 1 for its Channel rows, 2 for their Lane rows
	lane:   int,    // a Lane row's lane, 0 x to 3 w, -1 for the other kinds
	split:  bool,   // a Channel row whose property has a channel per lane
}

// One key of a clip: channel index and key index in it.
Sheet_Key :: struct {
	ch:  int,
	key: int,
}

// The visible rows of `clip`. A target in `collapsed` (value true) shows its
// Object row only. A vector Channel row whose sheet_channel_key is in
// `expanded` (value true) shows a Lane row per enabled lane.
sheet_rows :: proc(clip: ^anim.AnimationClip, collapsed: map[string]bool, expanded: map[string]bool, allocator := context.allocator) -> []Sheet_Row {
	rows := make([dynamic]Sheet_Row, 0, len(clip.channels) * 2, allocator)
	for &first, i in clip.channels {
		if _sheet_target_seen(clip, first.target, i) do continue
		append(&rows, Sheet_Row{kind = .Object, target = first.target, ch = -1, depth = 0, lane = -1})
		if collapsed[first.target] do continue
		for &c, j in clip.channels[i:] {
			if c.target != first.target do continue
			group := sheet_group_channels(clip, i + j, context.temp_allocator)
			if group[0] != i + j do continue // grouped into an earlier row
			append(&rows, Sheet_Row{kind = .Channel, target = c.target, ch = i + j, depth = 1, lane = -1, split = len(group) > 1})
			if len(expanded) == 0 do continue
			width := anim.animation_channel_mask_width(&c)
			if width < 2 || !expanded[sheet_channel_key(&c, context.temp_allocator)] do continue
			for l in 0 ..< width {
				lc := sheet_lane_channel(clip, group, l)
				if lc < 0 do continue
				append(&rows, Sheet_Row{kind = .Lane, target = c.target, ch = lc, depth = 2, lane = l})
			}
		}
	}
	return rows[:]
}

// The channels of the property channel `ch` animates, in channel order,
// `ch` among them: one for a joined row, one per lane for a split row
// (anim.animation_clip_property_channels).
sheet_group_channels :: proc(clip: ^anim.AnimationClip, ch: int, allocator := context.allocator) -> []int {
	return anim.animation_clip_property_channels(clip, ch, allocator)
}

// The channel of `group` (sheet_group_channels) that animates lane `lane`:
// the first with the lane enabled, -1 when none has it.
sheet_lane_channel :: proc(clip: ^anim.AnimationClip, group: []int, lane: int) -> int {
	for idx in group {
		c := &clip.channels[idx]
		if lane < anim.animation_channel_mask_width(c) && lane not_in c.lanes_off do return idx
	}
	return -1
}

// The channels of `target`, in channel order.
sheet_target_channels :: proc(clip: ^anim.AnimationClip, target: string, allocator := context.allocator) -> []int {
	out := make([dynamic]int, allocator)
	for &c, i in clip.channels do if c.target == target do append(&out, i)
	return out[:]
}

// What identifies a channel across edits, for a view's per-row state (the
// expanded vector rows): target, then the transform path or the component and
// field. A channel index shifts when a row is removed, this does not. The
// channels of a split row share it.
sheet_channel_key :: proc(ch: ^anim.Animation_Channel, allocator := context.allocator) -> string {
	if anim.animation_channel_is_property(ch) {
		return strings.concatenate({ch.target, "\x1f", ch.component, "\x1f", ch.field}, allocator)
	}
	return fmt.aprintf("%s\x1f%v", ch.target, ch.path, allocator = allocator)
}

// Whether a channel before index `before` already has `target`.
@(private = "file")
_sheet_target_seen :: proc(clip: ^anim.AnimationClip, target: string, before: int) -> bool {
	for &c in clip.channels[:before] {
		if c.target == target do return true
	}
	return false
}

// The Channel row of the property channel `ch` animates, -1 when the
// property is hidden or absent.
sheet_row_of_channel :: proc(clip: ^anim.AnimationClip, rows: []Sheet_Row, ch: int) -> int {
	if ch < 0 || ch >= len(clip.channels) do return -1
	for r, i in rows {
		if r.kind == .Channel && anim.animation_channel_same_property(&clip.channels[r.ch], &clip.channels[ch]) do return i
	}
	return -1
}

// The key times across the channels `chans`, sorted. Times within half a
// frame of the first time of a run count as one, and that first time stands
// for the run. An Object row's summary keys come from this over the target's
// channels, a split row's over its lanes' channels.
sheet_keys_times :: proc(clip: ^anim.AnimationClip, chans: []int, allocator := context.allocator) -> []f32 {
	all := make([dynamic]f32, context.temp_allocator)
	for idx in chans do append(&all, ..clip.channels[idx].times[:])
	slice.sort(all[:])
	half := 0.5 / anim.animation_clip_frame_rate(clip)
	out := make([dynamic]f32, 0, len(all), allocator)
	for t in all {
		if len(out) > 0 && t - out[len(out) - 1] <= half do continue
		append(&out, t)
	}
	return out[:]
}

// The keys of the channels `chans` that summary time `times[i]` stands for:
// every key from that time up to the next summary time. `times` comes from
// sheet_keys_times over the same channels.
sheet_keys_at :: proc(clip: ^anim.AnimationClip, chans: []int, times: []f32, i: int, allocator := context.allocator) -> []Sheet_Key {
	assert(i >= 0 && i < len(times), "sheet_keys_at: summary index in range")
	keys := make([dynamic]Sheet_Key, allocator)
	for ci in chans {
		for kt, k in clip.channels[ci].times {
			if sheet_object_key_index(times, kt) == i do append(&keys, Sheet_Key{ci, k})
		}
	}
	return keys[:]
}

// sheet_keys_times over every channel of `target`.
sheet_object_key_times :: proc(clip: ^anim.AnimationClip, target: string, allocator := context.allocator) -> []f32 {
	return sheet_keys_times(clip, sheet_target_channels(clip, target, context.temp_allocator), allocator)
}

// sheet_keys_at over every channel of `target`.
sheet_object_keys_at :: proc(clip: ^anim.AnimationClip, target: string, times: []f32, i: int, allocator := context.allocator) -> []Sheet_Key {
	return sheet_keys_at(clip, sheet_target_channels(clip, target, context.temp_allocator), times, i, allocator)
}

// The summary time a key at `kt` falls under: the last index of `times`
// (sorted) at or before `kt`, -1 before the first.
sheet_object_key_index :: proc(times: []f32, kt: f32) -> int {
	lo, hi := 0, len(times)
	for lo < hi {
		mid := (lo + hi) / 2
		if times[mid] <= kt {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo - 1
}

// A target path split for its Object row: `parent` is the path before the
// last segment ("" for none), `name` the last segment, `depth` the number of
// segments. The animated object itself ("") has depth 0. Both strings are
// slices of `target`.
sheet_target_split :: proc(target: string) -> (parent, name: string, depth: int) {
	if target == "" do return "", "", 0
	depth = 1
	last := -1
	for i in 0 ..< len(target) {
		if target[i] != '/' do continue
		depth += 1
		last = i
	}
	if last < 0 do return "", target, depth
	return target[:last], target[last + 1:], depth
}

// The display name of a target: its last path segment, or `root_name` for the
// animated object itself.
sheet_target_name :: proc(target: string, root_name: string) -> string {
	if target == "" do return root_name
	_, name, _ := sheet_target_split(target)
	return name
}
