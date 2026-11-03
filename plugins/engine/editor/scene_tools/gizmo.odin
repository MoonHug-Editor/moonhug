package scene_tools

// The scene view's transform tool (W E R): a caller of the move, rotate and
// scale handles (editor/handles/transform_handles.odin). The handles own the
// pointer, the drawing and the drag math. The tool owns what a drag does:
//
// - Drags apply to EVERY selected top-level object: move offsets them all,
//   rotate orbits positions around the gizmo and turns orientations, scale
//   scales offsets and local scales. Start states are captured at grab, and
//   every frame applies start + the drag since the grab.
// - One undo step per drag: an edit session opened at grab and closed at
//   release, or when the drag's handle goes away (a mode switch, the
//   selection emptied).
// - The gizmo sits on the active object's pivot or the centroid of the
//   selection (viewport.gizmo_pivot). Move and rotate follow viewport.gizmo_space, scale is
//   always on the object's own axes.
// - Its parts use handles.PRIO_TOOL: a component's own handle under the
//   pointer takes the click.

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "moonhug:editor/handles"
import "moonhug:editor/inspector"
import "moonhug:packages/engine"
import "moonhug:editor/viewport"
import "moonhug:editor/session"
import undo "moonhug:packages/engine/editor/undo"

gizmo_origin :: proc(tH: engine.Transform_Handle) -> [3]f32 {
	if viewport.gizmo_pivot == .Center {
		sum: [3]f32
		n := 0
		for h in session.top_level() {
			sum += engine.transform_world_position(h)
			n += 1
		}
		if n > 0 do return sum / f32(n)
	}
	return engine.transform_world_position(tH)
}

// Gizmo screen presence: fraction of the camera distance, so it stays a
// constant apparent size while zooming.
_GIZMO_SIZE_FACTOR :: f32(0.15)

// The tool's handle id: the composites salt their parts from it.
@(private = "file")
_TOOL_ID :: u64(0x7472_616e_7366_6f72)

_gizmo_dragging: bool
_gizmo_start_world: [3]f32 // gizmo origin (pivot point) at grab

// What the rotate and scale handles edit during a drag: the turn since the
// grab (from _gizmo_rot_start) and the per-axis scale factor.
@(private = "file")
_gizmo_rot: quaternion128 = 1
@(private = "file")
_gizmo_rot_start: quaternion128 = 1
@(private = "file")
_gizmo_factor: [3]f32 = {1, 1, 1}

// One drag applies to every selected top-level object. Start states are
// captured at grab, the per-frame apply is absolute (start + delta).
_Gizmo_Target :: struct {
	tH:          engine.Transform_Handle,
	start_pos:   [3]f32, // world
	start_rot:   [4]f32, // world
	start_scale: [3]f32, // local
	// Lanes of the local position, the scale and the euler angles the preview
	// drives with Record off: they keep the pose, the posed values are the
	// local ones at grab.
	pos_driven:  inspector.Driven_Lanes,
	posed:       [3]f32,
	scl_driven:  inspector.Driven_Lanes,
	posed_scl:   [3]f32,
	rot_driven:  inspector.Driven_Lanes,
	posed_eul:   [3]f32,
	grab_rot:    [4]f32, // local rotation at grab, for the override record
}
_gizmo_targets: [dynamic]_Gizmo_Target

// One transaction for the whole drag, however many objects it moves. Opened
// at grab, closed at release (docs/core/Undo.md): the session captures every
// target's before-state at one instant and emits a single grouped action.
@(private)
_gizmo_edit: undo.Edit_Session

// True while the gizmo or a handle owns the mouse (hot or dragging): the
// scene view then neither picks nor starts a box select, so grabs never
// select through.
scene_tools_consume_mouse :: proc() -> bool {
	return handles.consumes_mouse()
}

// True while a transform gizmo or handle drag is in progress.
scene_tools_dragging :: proc() -> bool {
	return handles.dragging()
}

// The transform tool's frame, from scene_tools_frame after the handle procs: the
// gizmo on the active object in W E R, and the end of a drag whose gizmo went
// away (Q or T pressed mid-drag, the selection emptied).
gizmo_tool_frame :: proc() {
	sel := session.active()
	if viewport.gizmo_mode != .Handles && sel != {} {
		gizmo_draw_and_handle(sel)
	} else {
		gizmo_end_drag_if_any()
	}
}

// The gizmo for tH in the handles frame (handles.frame: view, pointer,
// buttons, snap steps), and what its drag does to the selection.
gizmo_draw_and_handle :: proc(tH: engine.Transform_Handle) {
	origin := gizmo_origin(tH)
	size := linalg.length(handles.frame().view.cam_pos - origin) * _GIZMO_SIZE_FACTOR
	if size <= 0 do return

	d: handles.Drag
	switch viewport.gizmo_mode {
	case .Picker, .Handles:
		gizmo_end_drag_if_any()
		return
	case .Translate:
		rot := _gizmo_rotation(tH) if viewport.gizmo_space == .Local else quaternion128(1)
		pos := origin
		d = handles.position_handle(_TOOL_ID, &pos, rot, size, handles.PRIO_TOOL)
		if d.started do _gizmo_begin(origin)
		if _gizmo_dragging && (d.dragging || d.released) {
			delta := pos - _gizmo_start_world
			for &tgt in _gizmo_targets {
				_gizmo_move_to(&tgt, tgt.start_pos + delta)
			}
		}
	case .Rotate:
		local := viewport.gizmo_space == .Local
		if !_gizmo_dragging do _gizmo_rot = _gizmo_rotation(tH) if local else quaternion128(1)
		d = handles.rotation_handle(_TOOL_ID, &_gizmo_rot, origin, size, local, handles.PRIO_TOOL)
		if d.started {
			_gizmo_begin(origin)
			_gizmo_rot_start = _gizmo_rot
		}
		if _gizmo_dragging && (d.dragging || d.released) {
			turn := _gizmo_rot * conj(_gizmo_rot_start)
			for &tgt in _gizmo_targets {
				world := turn * engine.quat_to_native(tgt.start_rot)
				engine.transform_set_world_rotation(tgt.tH, engine.quat_from_native(world))
				_gizmo_keep_driven_angles(&tgt)
				// Orbit the position around the pivot (no-op for the object
				// AT the pivot: single-object Pivot mode keeps its place).
				off := tgt.start_pos - _gizmo_start_world
				if linalg.length(off) > 1e-6 {
					_gizmo_move_to(&tgt, _gizmo_start_world + linalg.quaternion128_mul_vector3(turn, off))
				}
			}
		}
	case .Scale:
		if !_gizmo_dragging do _gizmo_factor = {1, 1, 1}
		rot := _gizmo_rotation(tH)
		d = handles.scale_handle(_TOOL_ID, &_gizmo_factor, origin, rot, size, handles.PRIO_TOOL)
		if d.started do _gizmo_begin(origin)
		if _gizmo_dragging && (d.dragging || d.released) {
			w := engine.ctx_world()
			f := _gizmo_factor
			for &tgt in _gizmo_targets {
				t := engine.pool_get(&w.transforms, engine.Handle(tgt.tH))
				if t == nil do continue
				t.scale = tgt.start_scale * f
				for i in 0 ..< 3 do if i in tgt.scl_driven do t.scale[i] = tgt.posed_scl[i]
				// Each object's offset from the pivot scales along the
				// handle's axes by the same factors.
				off := tgt.start_pos - _gizmo_start_world
				if linalg.length(off) > 1e-6 {
					moved := _gizmo_start_world
					for i in 0 ..< 3 {
						e: [3]f32
						e[i] = 1
						axis := linalg.quaternion128_mul_vector3(rot, e)
						moved += axis * linalg.dot(off, axis) * f[i]
					}
					_gizmo_move_to(&tgt, moved)
				}
			}
		}
	}
	// A released drag is one step, and so is a drag whose handle went away
	// (another mode's handle holds no drag).
	if d.released || (_gizmo_dragging && !d.dragging) do gizmo_end_drag_if_any()
}

@(private = "file")
_gizmo_rotation :: proc(tH: engine.Transform_Handle) -> quaternion128 {
	return engine.quat_to_native(engine.transform_world_rotation(tH))
}

@(private = "file")
_gizmo_begin :: proc(origin: [3]f32) {
	gizmo_end_drag_if_any()
	if !_gizmo_collect_targets() do return
	_gizmo_dragging = true
	_gizmo_start_world = origin
}

@(private)
_gizmo_collect_targets :: proc() -> bool {
	// Cross-frame state: never borrows the caller's allocator.
	if _gizmo_targets == nil do _gizmo_targets = make([dynamic]_Gizmo_Target, runtime.default_allocator())
	clear(&_gizmo_targets)
	w := engine.ctx_world()

	// One target list for the session, built alongside the gizmo's own. Rotate
	// and scale each touch TWO fields per object (the field itself plus position,
	// which moves as things orbit or scale about the pivot), so those objects
	// contribute two entries.
	edits := make([dynamic]undo.Edit_Target, 0, len(_gizmo_targets) * 2, context.temp_allocator)

	for h in session.top_level() {
		t := engine.pool_get(&w.transforms, engine.Handle(h))
		if t == nil do continue
		// A field the preview drives with Record off stays where the pose puts
		// it: the inspector ignores an edit of such a field for the same
		// reason (inspector/driven.odin), and a session here would record the
		// posed value as "before". A lane the clip leaves to the object moves
		// as usual, as its inspector row does. With Record armed the session
		// keys the clip through its listener instead (animation's record.odin).
		// The rotation is asked for as euler angles, which is how a clip
		// drives it per lane. A quaternion row drives every angle.
		all := inspector.Driven_Lanes{0, 1, 2}
		pos_driven, scl_driven, rot_driven: inspector.Driven_Lanes
		switch viewport.gizmo_mode {
		case .Picker, .Handles:
		case .Translate:
			pos_driven = _gizmo_driven_lanes(h, offset_of(engine.Transform, position), typeid_of([3]f32))
		case .Rotate:
			rot_driven = _gizmo_driven_lanes(h, offset_of(engine.Transform, rotation), typeid_of([3]f32))
			pos_driven = _gizmo_driven_lanes(h, offset_of(engine.Transform, position), typeid_of([3]f32))
		case .Scale:
			scl_driven = _gizmo_driven_lanes(h, offset_of(engine.Transform, scale), typeid_of([3]f32))
			pos_driven = _gizmo_driven_lanes(h, offset_of(engine.Transform, position), typeid_of([3]f32))
		}
		// The mode's own field driven whole leaves the object out. A driven
		// position in Rotate or Scale mode only keeps its lanes (_gizmo_move_to).
		locked: bool
		#partial switch viewport.gizmo_mode {
		case .Translate: locked = pos_driven == all
		case .Rotate:    locked = rot_driven == all
		case .Scale:     locked = scl_driven == all
		}
		if locked do continue
		append(&_gizmo_targets, _Gizmo_Target{
			tH          = h,
			start_pos   = engine.transform_world_position(h),
			start_rot   = engine.transform_world_rotation(h),
			start_scale = t.scale,
			pos_driven  = pos_driven,
			posed       = t.position,
			scl_driven  = scl_driven,
			posed_scl   = t.scale,
			rot_driven  = rot_driven,
			posed_eul   = engine.quat_to_euler_xyz(t.rotation),
			grab_rot    = t.rotation,
		})
		switch viewport.gizmo_mode {
		case .Picker, .Handles:
		case .Translate:
			append(&edits, undo.edit_target_transform(h, &t.position, typeid_of([3]f32)))
			// A UI node moves through its RectTransform (transform_set_world_position
			// converts), so that is the field the drag must record.
			if owned, rt := engine.transform_get_comp(h, engine.RectTransform); rt != nil {
				append(&edits, undo.edit_target_pooled(owned.handle, &rt.anchored_position, typeid_of([3]f32)))
			}
		case .Rotate:
			append(&edits, undo.edit_target_transform(h, &t.rotation, typeid_of([4]f32)))
			append(&edits, undo.edit_target_transform(h, &t.position, typeid_of([3]f32)))
			if owned, rt := engine.transform_get_comp(h, engine.RectTransform); rt != nil {
				append(&edits, undo.edit_target_pooled(owned.handle, &rt.anchored_position, typeid_of([3]f32)))
			}
		case .Scale:
			append(&edits, undo.edit_target_transform(h, &t.scale, typeid_of([3]f32)))
			append(&edits, undo.edit_target_transform(h, &t.position, typeid_of([3]f32)))
			if owned, rt := engine.transform_get_comp(h, engine.RectTransform); rt != nil {
				append(&edits, undo.edit_target_pooled(owned.handle, &rt.anchored_position, typeid_of([3]f32)))
			}
		}
	}

	if len(_gizmo_targets) == 0 do return false
	if len(edits) > 0 {
		_gizmo_edit = undo.edit_session_begin(edits[:], _gizmo_label())
	}
	return true
}

// The lanes of the field the preview drives and takes no edit of now: every
// lane of a field driven whole, none of a field that is not driven.
@(private = "file")
_gizmo_driven_lanes :: proc(h: engine.Transform_Handle, field_offset: uintptr, field_tid: typeid) -> inspector.Driven_Lanes {
	if inspector.driven_provider == nil do return {}
	out: [4]f32 // the widest transform field
	driven, editable, own := inspector.driven_provider(engine.Handle(h), field_offset, field_tid, &out)
	if !driven || editable do return {}
	lanes: inspector.Driven_Lanes
	for i in 0 ..< type_info_of(field_tid).size / size_of(f32) do lanes += {i}
	return lanes - own
}

// After a rotation write on a rotation the clip drives per euler angle: the
// turn since grab, in the object's own frame, is one angle when it is about
// a local axis, the ring's. That angle alone changes, by the turn, from the
// posed angles. A turn about a driven angle, or about no single axis (a
// world ring on a turned object), changes nothing: the euler angles are
// coupled, so turning the quaternion and putting the driven angles back
// would leave the rest of the turn in the free ones.
@(private = "file")
_gizmo_keep_driven_angles :: proc(tgt: ^_Gizmo_Target) {
	if tgt.rot_driven == {} do return
	t := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(tgt.tH))
	if t == nil do return
	d := conj(engine.quat_to_native(tgt.grab_rot)) * engine.quat_to_native(t.rotation)
	w := clamp(d.w, -1, 1)
	angle := 2 * math.acos(w)
	s := math.sqrt(max(1 - w * w, 0))
	lane := -1
	if s > 1e-6 {
		axis := [3]f32{d.x, d.y, d.z} / s
		for i in 0 ..< 3 do if abs(axis[i]) > 0.999 do lane = i
		if lane >= 0 && axis[lane] < 0 do angle = -angle
	}
	if lane < 0 || lane in tgt.rot_driven {
		t.rotation = tgt.grab_rot
		return
	}
	e := tgt.posed_eul
	e[lane] += math.to_degrees(angle)
	t.rotation = engine.quat_from_euler_xyz(e.x, e.y, e.z)
}

// Moves the target to `world`, then puts the driven lanes of its local
// position back at the pose.
@(private = "file")
_gizmo_move_to :: proc(tgt: ^_Gizmo_Target, world: [3]f32) {
	engine.transform_set_world_position(tgt.tH, world)
	if tgt.pos_driven == {} do return
	t := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(tgt.tH))
	if t == nil do return
	for i in 0 ..< 3 do if i in tgt.pos_driven do t.position[i] = tgt.posed[i]
}

@(private)
_gizmo_label :: proc() -> string {
	switch viewport.gizmo_mode {
	case .Picker, .Handles: return "Gizmo"
	case .Translate: return "Gizmo Move"
	case .Rotate:    return "Gizmo Rotate"
	case .Scale:     return "Gizmo Scale"
	}
	return "Gizmo"
}

@(private)
_gizmo_end_drag :: proc() {
	// The session is the group: it records one action for every target that
	// moved, and nothing at all when the drag ended where it started.
	undo.edit_session_end(&_gizmo_edit)
	// On an object of a prefab instance, each field the drag changed is
	// recorded as an override, as the inspector's rows record theirs
	// (record_nested_override): the record folds into the step just pushed.
	w := engine.ctx_world()
	for &tgt in _gizmo_targets {
		t := engine.pool_get(&w.transforms, engine.Handle(tgt.tH))
		if t == nil do continue
		is_host := engine.scene_find_nested_scene_for_host(t.scene, tgt.tH) != nil
		if !t.nested_owned && !is_host do continue
		host := tgt.tH if is_host else engine.transform_immediate_nested_host(tgt.tH)
		if t.position != tgt.posed do inspector.override_record(host, t.local_id, "position", &t.position, typeid_of([3]f32))
		if t.rotation != tgt.grab_rot do inspector.override_record(host, t.local_id, "rotation", &t.rotation, typeid_of([4]f32))
		if t.scale != tgt.start_scale do inspector.override_record(host, t.local_id, "scale", &t.scale, typeid_of([3]f32))
	}
	clear(&_gizmo_targets)
}

// Finalize an in-flight drag (mode switch, selection loss) — commits what
// happened so far as the drag's undo group.
gizmo_end_drag_if_any :: proc() {
	if !_gizmo_dragging do return
	_gizmo_dragging = false
	_gizmo_end_drag()
	// The drag's handle is the tool's own (one drag at a time): it holds the
	// pointer no longer.
	handles.end_drag()
}

gizmo_shutdown :: proc() {
	delete(_gizmo_targets)
	_gizmo_targets = nil
}
