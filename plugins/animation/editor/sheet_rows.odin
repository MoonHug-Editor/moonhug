package animation_editor

// The Animation window's sheet rows: the channels grouped by the transform
// they animate. Pure, no imgui, so the grouping is testable on its own.
//
// - One Object row per distinct channel target, in order of first appearance
//   among the channels. "" is the animated object itself.
// - A Channel row per channel of that target, in channel order, right after
//   its Object row, unless the target is collapsed.
// - An Object row is indented by its target's path depth (sheet_target_split),
//   its Channel rows one level further.
// - The view maps between sheet rows and channel indices only through
//   sheet_rows and sheet_row_of_channel. A channel index is never a row index.

import "core:slice"
import anim "moonhug:packages/animation"

Sheet_Row_Kind :: enum {
	Object,
	Channel,
}

Sheet_Row :: struct {
	kind:   Sheet_Row_Kind,
	target: string, // the channel target, borrowed from the clip
	ch:     int,    // channel index, -1 for an Object row
	depth:  int,    // indent level: an Object row's path depth, one more for its channels
}

// One key of a clip: channel index and key index in it.
Sheet_Key :: struct {
	ch:  int,
	key: int,
}

// The visible rows of `clip`. A target in `collapsed` (value true) shows its
// Object row only.
sheet_rows :: proc(clip: ^anim.AnimationClip, collapsed: map[string]bool, allocator := context.allocator) -> []Sheet_Row {
	rows := make([dynamic]Sheet_Row, 0, len(clip.channels) * 2, allocator)
	for &first, i in clip.channels {
		if _sheet_target_seen(clip, first.target, i) do continue
		_, _, depth := sheet_target_split(first.target)
		append(&rows, Sheet_Row{kind = .Object, target = first.target, ch = -1, depth = depth})
		if collapsed[first.target] do continue
		for &c, j in clip.channels[i:] {
			if c.target == first.target do append(&rows, Sheet_Row{kind = .Channel, target = c.target, ch = i + j, depth = depth + 1})
		}
	}
	return rows[:]
}

// Whether a channel before index `before` already has `target`.
@(private = "file")
_sheet_target_seen :: proc(clip: ^anim.AnimationClip, target: string, before: int) -> bool {
	for &c in clip.channels[:before] {
		if c.target == target do return true
	}
	return false
}

// The row showing channel `ch`, -1 when the channel is hidden or absent.
sheet_row_of_channel :: proc(rows: []Sheet_Row, ch: int) -> int {
	for r, i in rows {
		if r.kind == .Channel && r.ch == ch do return i
	}
	return -1
}

// The key times across every channel of `target`, sorted. Times within half a
// frame of the first time of a run count as one, and that first time stands
// for the run.
sheet_object_key_times :: proc(clip: ^anim.AnimationClip, target: string, allocator := context.allocator) -> []f32 {
	all := make([dynamic]f32, context.temp_allocator)
	for &c in clip.channels {
		if c.target == target do append(&all, ..c.times[:])
	}
	slice.sort(all[:])
	half := 0.5 / anim.animation_clip_frame_rate(clip)
	out := make([dynamic]f32, 0, len(all), allocator)
	for t in all {
		if len(out) > 0 && t - out[len(out) - 1] <= half do continue
		append(&out, t)
	}
	return out[:]
}

// The keys of `target`'s channels that summary time `times[i]` stands for:
// every key from that time up to the next summary time. `times` comes from
// sheet_object_key_times on the same clip.
sheet_object_keys_at :: proc(clip: ^anim.AnimationClip, target: string, times: []f32, i: int, allocator := context.allocator) -> []Sheet_Key {
	assert(i >= 0 && i < len(times), "sheet_object_keys_at: summary index in range")
	keys := make([dynamic]Sheet_Key, allocator)
	for &c, ci in clip.channels {
		if c.target != target do continue
		for kt, k in c.times {
			if sheet_object_key_index(times, kt) == i do append(&keys, Sheet_Key{ci, k})
		}
	}
	return keys[:]
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
