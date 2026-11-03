package undo

// Driven lanes: a field some system drives now and takes no edit of, the
// Animation window's preview with Record off (inspector/driven.odin). A write
// to such a lane never lands, whoever makes it: the inspector's rows, the
// gizmo, the bridge's tools. Every edit session puts the driven lanes of its
// entries back to the value it opened on, at its end, and a drag does the
// same each frame after its writes, so the render shows the pose.
//
// A rotation is a quaternion in the field but driven per euler angle: the
// seam answers with `euler` set and the lanes name angles, and the keep works
// on the decomposed angles.

import "base:runtime"
import "core:math"
import core "moonhug:libs/core"

Driven_Lanes :: bit_set[0 ..< 4; u8]

Driven_Mask :: struct {
	lanes: Driven_Lanes, // the driven lanes, every lane of a field driven whole
	euler: bool,         // a [4]f32 rotation, the lanes are euler angles
}

// Installed by the inspector (inspector.init): the driven lanes of a pooled
// field, empty when nothing drives it or an edit of it goes somewhere
// (Record keys it).
driven_lanes: proc(owner: core.Handle, offset: uintptr, tid: typeid) -> Driven_Mask

// The seam through a proc, for packages that alias this one's procs.
driven_lanes_of :: proc(owner: core.Handle, offset: uintptr, tid: typeid) -> Driven_Mask {
	if driven_lanes == nil do return {}
	return driven_lanes(owner, offset, tid)
}

// Puts the driven lanes of every entry's live value back to the value the
// session opened on.
edit_session_keep_driven :: proc(sess: ^Edit_Session) {
	if sess == nil || !sess.active || driven_lanes == nil do return
	for &e in sess.entries {
		if e.target.kind != .Pooled || e.old_json == nil do continue
		m := driven_lanes(e.target.handle, uintptr(e.target.offset), e.target.type_id)
		if m.lanes == {} do continue
		ptr := resolve_target_ptr(e.target)
		if ptr == nil do continue
		_keep_lanes(ptr, e.target.type_id, e.old_json, m, e.target.scene)
	}
}

// Writes the driven lanes of the value at `ptr` from `old`: per lane for a
// vector of f32, per euler angle for a rotation, whole for any other type.
@(private = "file")
_keep_lanes :: proc(ptr: rawptr, tid: typeid, old: []byte, m: Driven_Mask, scene: core.Scene_Ref) {
	ti := runtime.type_info_base(type_info_of(tid))
	if arr, is_arr := ti.variant.(runtime.Type_Info_Array); is_arr && arr.count <= 4 {
		elem := runtime.type_info_base(arr.elem)
		if _, is_f := elem.variant.(runtime.Type_Info_Float); is_f && arr.elem.size == size_of(f32) {
			before: [4]f32
			if !write_json_value(&before, tid, old, scene, quiet = true) do return
			live := cast(^[4]f32)ptr
			if m.euler && arr.count == 4 {
				posed := core.quat_to_euler_xyz((cast(^[4]f32)&before)^)
				e := _euler_near(core.quat_to_euler_xyz(live^), posed)
				for l in 0 ..< 3 do if l in m.lanes do e[l] = posed[l]
				live^ = core.quat_from_euler_xyz(e.x, e.y, e.z)
				return
			}
			for l in 0 ..< arr.count do if l in m.lanes do live[l] = before[l]
			return
		}
	}
	write_json_value(ptr, tid, old, scene, quiet = true)
}

// A rotation has two euler spellings, (x, y, z) and (x + 180, 180 - y,
// z + 180): the one nearer `ref`, so angles replace like with like.
@(private = "file")
_euler_near :: proc(e, ref: [3]f32) -> [3]f32 {
	wrap :: proc(a: f32) -> f32 { return a - 360 * math.floor((a + 180) / 360) }
	dist :: proc(a, b: [3]f32) -> f32 {
		d: f32
		for i in 0 ..< 3 do d += abs(a[i] - b[i] - 360 * math.floor((a[i] - b[i] + 180) / 360))
		return d
	}
	twin := [3]f32{wrap(e.x + 180), wrap(180 - e.y), wrap(e.z + 180)}
	return twin if dist(twin, ref) < dist(e, ref) else e
}
