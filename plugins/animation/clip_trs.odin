package animation

// What a clip's transform rows say about one transform at a time, before it
// meets the transform or the mixer: the lanes its Position and Scale rows
// set, its Rotation row's quaternion, and the angles its Euler rows set.
// One rule for combining rows, used by the direct apply
// (animation_clip_apply), the graph leaf (playable_graph.odin) and the
// editor's preview provider, so a clip poses the same everywhere:
//   - several rows of one property (split lanes) each set their own lanes,
//     a lane two rows both animate takes the later row's value
//   - the rotation is the Rotation row's quaternion when the clip has one,
//     else `base` (the transform's own rotation, or the rotation at bind
//     time in the graph), then the Euler rows' lanes replace their angles
//   - a lane no row sets keeps `base`

import "core:fmt"
import "moonhug:packages/engine"

Clip_TRS :: struct {
	pos, scl, eul: [4]f32,
	pos_lanes, scl_lanes, eul_lanes: Lane_Set,
	rot:     [4]f32,
	has_rot: bool,
}

// Adds transform row `ch` sampled at `t` to `trs`. A property row or a row
// with no keys adds nothing.
animation_trs_add :: proc(trs: ^Clip_TRS, ch: ^Animation_Channel, t: f32) {
	if animation_channel_is_property(ch) || len(ch.times) == 0 do return
	v := _animation_channel_sample(ch, t)
	off := animation_channel_lanes_off(ch, .Vec3)
	switch ch.path {
	case .Position: _trs_set_lanes(&trs.pos, &trs.pos_lanes, v, off)
	case .Scale:    _trs_set_lanes(&trs.scl, &trs.scl_lanes, v, off)
	case .Euler:    _trs_set_lanes(&trs.eul, &trs.eul_lanes, v, off)
	case .Rotation:
		trs.rot = v
		trs.has_rot = true
	}
}

@(private = "file")
_trs_set_lanes :: proc(dst: ^[4]f32, lanes: ^Lane_Set, v: [4]f32, off: Lane_Set) {
	for l in 0 ..< 3 do if l not_in off {
		dst[l] = v[l]
		lanes^ += {l}
	}
}

// Whether the rows say anything about the rotation.
animation_trs_has_rotation :: proc(trs: Clip_TRS) -> bool {
	return trs.has_rot || trs.eul_lanes != {}
}

// The rotation the rows give over `base`, as a quaternion.
animation_trs_rotation :: proc(trs: Clip_TRS, base: [4]f32) -> [4]f32 {
	q := trs.has_rot ? trs.rot : base
	if trs.eul_lanes == {} do return q
	return animation_quat_from_euler(animation_trs_euler(trs, base))
}

// The rotation the rows give over `base`, as euler angles in degrees: the
// Rotation row's angles or `base` decomposed, with the Euler rows' lanes
// replaced. The editor's rotation row reads this form.
animation_trs_euler :: proc(trs: Clip_TRS, base: [4]f32) -> [3]f32 {
	e := engine.quat_to_euler_xyz(trs.has_rot ? trs.rot : base)
	for l in trs.eul_lanes do e[l] = trs.eul[l]
	return e
}

// `v` with the lanes in `lanes` taken from `src`.
animation_trs_lanes_over :: proc(src: [4]f32, lanes: Lane_Set, v: [3]f32) -> [3]f32 {
	out := v
	for l in lanes do if l < 3 do out[l] = src[l]
	return out
}

// --- Property identity ----------------------------------------------------------------
//
// A property is what a channel animates on a target: Position, Rotation,
// Scale or Euler of a transform, or one field of one component. The channels
// of one property are its lanes (split lanes, editor/lane_split.odin). Every
// consumer that needs "the rows of this property" asks here.

// Whether two channels animate the same property of the same target.
// Rotation and Euler are two forms of the rotation and count as different
// properties here, the recording rule prefers the Euler rows.
animation_channel_same_property :: proc(a, b: ^Animation_Channel) -> bool {
	if a.target != b.target do return false
	if animation_channel_is_property(a) != animation_channel_is_property(b) do return false
	if animation_channel_is_property(a) do return a.component == b.component && a.field == b.field
	return a.path == b.path
}

// The channels of the property channel `ch` animates, in channel order, `ch`
// among them.
animation_clip_property_channels :: proc(clip: ^AnimationClip, ch: int, allocator := context.allocator) -> []int {
	out := make([dynamic]int, allocator)
	c := &clip.channels[ch]
	for &o, i in clip.channels do if animation_channel_same_property(c, &o) do append(&out, i)
	return out[:]
}

// The invariant a loaded clip holds: two channels of one property never
// animate the same lane, so every lane of every property has one row that
// says its value. Returns the first violation as a message, temp-allocated,
// or "" and true.
animation_clip_validate :: proc(clip: ^AnimationClip) -> (msg: string, ok: bool) {
	for &a, i in clip.channels {
		for &b in clip.channels[i + 1:] {
			if !animation_channel_same_property(&a, &b) do continue
			width := animation_channel_mask_width(&a)
			shared := Lane_Set(a.lanes_off) | Lane_Set(b.lanes_off)
			both: Lane_Set
			if width == 0 {
				both = {0} // a row with no mask animates its one value
			} else {
				for l in 0 ..< width do if l not_in shared do both += {l}
			}
			if both == {} do continue
			return _clip_dup_message(&a, both), false
		}
	}
	return "", true
}

@(private = "file")
_clip_dup_message :: proc(c: ^Animation_Channel, lanes: Lane_Set) -> string {
	names := [4]string{"x", "y", "z", "w"}
	ls := ""
	for l in lanes do ls = len(ls) == 0 ? names[l] : fmt.tprintf("%s %s", ls, names[l])
	target := c.target == "" ? "the animated object" : c.target
	if animation_channel_is_property(c) {
		return fmt.tprintf("two rows animate lane %s of %s on %s", ls, c.field, target)
	}
	return fmt.tprintf("two rows animate lane %s of %v on %s", ls, c.path, target)
}
