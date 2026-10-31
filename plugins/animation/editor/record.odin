package animation_editor

// Record (plugins/animation/docs/AnimationComponent.md "Record"): while the
// Animation window's Record is armed, an edit that records undo keys the clip
// instead of changing the object.
//
// The undo package hands every closing edit session's changed entries to
// undo.commit_listener before it records anything (docs/core/Undo.md). For
// each entry on the animated object or under it whose field is animatable,
// the listener keys the clip at the playhead, creating the row with the procs
// Add Property uses, and marks the entry consumed. The undo package then
// writes the entry's old value back and records no scene step. So:
//   - the clip document edit is the gesture's only undo step
//   - the object keeps its own value, and the preview shows the key through
//     the pose it applies at the playhead
//
// An inspector edit of a driven field does not reach the listener: the
// inspector hands it to inspector.driven_commit (_record_driven_commit below),
// which keys it the same way. The listener covers gizmo drags and multi-edit.
//
// "Add Key" in a field's context menu (inspector.driven_add_key,
// _record_add_key below) keys the value the field shows without Record armed.
//
// An entry that cannot be keyed stays an ordinary scene edit with its own undo:
//   - the field type is not animatable (an array, a plain struct, a Ref,
//     Ref_Local or Owned reference). The window shows a note under the
//     toolbar while Record is armed
//   - the object is neither the animated object nor under it
//   - the window has no clip document (a clip inside a model is read-only)

import "base:runtime"
import "core:encoding/uuid"
import "core:fmt"
import "core:math/linalg"
import "core:strings"
import im "moonhug:external/odin-imgui"
import wnd "moonhug:editor/window"
import engine "moonhug:packages/engine"
import anim "moonhug:packages/animation"
import "moonhug:editor/inspector"
import "moonhug:editor/undo"

@(phase={key=engine.Phase.EditorInit, order=1, mode=Editor})
animation_record_install :: proc() {
	assert(undo.commit_listener == nil || undo.commit_listener == _record_commit, "undo.commit_listener is installed by another package")
	undo.commit_listener = _record_commit
	assert(inspector.driven_provider == nil || inspector.driven_provider == _record_driven, "inspector.driven_provider is installed by another package")
	inspector.driven_provider = _record_driven
	assert(inspector.driven_commit == nil || inspector.driven_commit == _record_driven_commit, "inspector.driven_commit is installed by another package")
	inspector.driven_commit = _record_driven_commit
	assert(inspector.driven_row_state == nil || inspector.driven_row_state == _record_row_state, "inspector.driven_row_state is installed by another package")
	inspector.driven_row_state = _record_row_state
	assert(inspector.driven_add_key == nil || inspector.driven_add_key == _record_add_key, "inspector.driven_add_key is installed by another package")
	inspector.driven_add_key = _record_add_key
	inspector.driven_delete_key = _record_delete_key
	inspector.driven_tooltip_read_only = "Driven by the Animation preview. Arm Record to key this field"
	inspector.driven_tooltip_editable = "Recording: an edit keys this field at the playhead"
	inspector.driven_tooltip_add_key = "Keys the value shown here at the playhead, adding the row when it is missing. On a field the preview drives, that is the clip's value, so the key pins the current pose"
}

// What one committed edit keys: the row's identity and the field's value kind.
@(private = "file")
_Record_Key :: struct {
	owner:    engine.Transform_Handle, // the object the edited field belongs to
	target:   string,                  // name path from the animated object, "" for itself
	property: bool,                    // a component field, else a transform channel
	path:     anim.Animation_Path,     // transform channel
	guid_str: string,                  // component type guid
	field:    string,                  // dotted field path on the component
	kind:     anim.Prop_Kind,
	leaf:     typeid,
}

// Set while the listener runs: the clip document's own session ends inside it
// and calls the listener again.
@(private = "file")
_record_busy: bool

@(private = "file")
_record_commit :: proc(edits: []undo.Edit_Commit, consumed: []bool) {
	if _record_busy || !_pv.recording do return
	doc, clip := _pv_doc()
	if doc == nil || clip == nil do return
	_record_busy = true
	defer _record_busy = false

	// Every keyed entry goes into one session on the clip document. The
	// session's payloads use the caller's allocator, as every undo record does.
	keyed := false
	for e, i in edits {
		k, ok := _record_key_of(e)
		if !ok do continue
		if !keyed {
			_pv_edit_begin(doc)
			_pv_edit_held = true
			keyed = true
		}
		{
			// Channel strings and key arrays live in the document.
			context.allocator = inspector.doc_alloc()
			_record_key(doc, clip, k, e)
		}
		consumed[i] = true
	}
	if keyed {
		_pv_edit_held = false
		_pv_edit_commit(doc)
	}
}

// Which row a committed edit keys, or false when it stays a scene edit. Sets
// the window's note for a field under the animated object whose type cannot
// be animated.
@(private = "file")
_record_key_of :: proc(e: undo.Edit_Commit) -> (k: _Record_Key, ok: bool) {
	if e.target.kind != .Pooled || e.ptr == nil do return {}, false
	base, h, bok := undo.resolve_pooled_base(e.target)
	if !bok || base == nil do return {}, false

	comp_tid: typeid
	if h.type_key == .Transform {
		k.owner = engine.Transform_Handle(h)
		switch {
		case e.target.offset == u32(offset_of(engine.Transform, position)) && e.target.type_id == typeid_of([3]f32):
			k.path = .Position
		case e.target.offset == u32(offset_of(engine.Transform, rotation)) && e.target.type_id == typeid_of([4]f32):
			k.path = .Rotation
		case e.target.offset == u32(offset_of(engine.Transform, scale)) && e.target.type_id == typeid_of([3]f32):
			k.path = .Scale
		case:
			return {}, false
		}
	} else {
		comp_tid = engine.get_typeid_by_type_key(h.type_key)
		if comp_tid == nil do return {}, false
		k.owner = (^engine.CompData)(base).owner
		k.property = true
	}

	target, under := _record_target_path(k.owner)
	if !under do return {}, false
	k.target = target

	if k.property {
		field, leaf, animatable := anim._prop_path_of_offset(comp_tid, uintptr(e.target.offset), e.target.type_id)
		if !animatable {
			if leaf != nil {
				_record_note_set(fmt.tprintf("Cannot key %s: %s is not animatable", field, _record_type_name(leaf)))
			}
			return {}, false
		}
		k.field = field
		k.guid_str = uuid.to_string(engine.get_guid_by_type_key(h.type_key), context.temp_allocator)
	}
	kind, kok := anim._prop_kind_of(e.target.type_id)
	assert(kok, "record: a keyed field has an animatable type")
	k.kind = kind
	k.leaf = e.target.type_id
	return k, true
}

// Keys the edited value at the playhead. A missing row is created first, and
// its key at the clip start holds the value from before the edit, so the clip
// changes the object only from where the key was recorded. A split row keys
// only the lanes the edit changed (_record_key_rows).
@(private = "file")
_record_key :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, k: _Record_Key, e: undo.Edit_Commit) {
	// A string is borrowed from the live field: the row clones it.
	edited := anim._prop_read_value(e.ptr, k.kind, k.leaf)
	old := _record_old_value(e, k)
	// The decoded string is the scratch's, on context.allocator.
	defer if str, is_str := old.(string); is_str do delete(str)
	chans := _record_channels(clip, k)
	if len(chans) == 0 {
		_record_add_row(doc, clip, k)
		chans = _record_channels(clip, k)
		assert(len(chans) == 1, "record: the new row is in the clip")
		ch := &clip.channels[chans[0]]
		anim.animation_channel_set_value(ch, 0, _record_row_value(ch, k, old))
	}
	_record_key_rows(doc, clip, chans, k, edited, old)
}

// Adds the row of `k` to the clip, holding the object's own value at the
// clip start. A rotation row is an Euler row.
@(private = "file")
_record_add_row :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, k: _Record_Key) {
	if k.property {
		_pv_add_channel_property(doc, clip, k.target, k.guid_str, k.field, k.owner)
	} else {
		_pv_add_channel_transform(doc, clip, k.target, k.path == .Rotation ? .Euler : k.path, k.owner)
	}
}

// Keys `edited` (the field's own type, k.leaf) at the playhead in the rows
// of `k`, which exist:
//   - a joined row (one channel) takes the whole value, and every lane
//     animates
//   - a split row (one channel per lane) keys lane by lane: with `ref`, the
//     value the edit started from in the field's type, only the lanes that
//     differ from it, without it every lane
@(private = "file")
_record_key_rows :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, chans: []int, k: _Record_Key, edited: anim.Channel_Value, ref: Maybe(anim.Channel_Value)) {
	if len(chans) == 1 {
		idx := chans[0]
		_pv_add_key(doc, clip, idx, _pv.time, _record_row_value(&clip.channels[idx], k, edited))
		clip.channels[idx].lanes_off = {}
		return
	}
	for idx in chans {
		ch := &clip.channels[idx]
		v := _record_row_value(ch, k, edited)
		if r, has_ref := ref.?; has_ref {
			f, fok := v.([4]f32)
			rf, rok := _record_row_value(ch, k, r).([4]f32)
			if fok && rok {
				changed := false
				off := anim.animation_channel_lanes_off(ch, k.kind)
				for l in 0 ..< anim.animation_channel_lane_count(ch, k.kind) {
					if l in off do continue
					if f[l] != rf[l] {
						changed = true
						break
					}
				}
				if !changed do continue
			}
		}
		_pv_add_key(doc, clip, idx, _pv.time, v)
	}
}

// `v`, a value of the field (its type is k.leaf), in the form row `ch`
// holds: euler angles for an Euler row given a quaternion, a normalized
// quaternion for a Rotation row, else `v` itself.
@(private = "file")
_record_row_value :: proc(ch: ^anim.Animation_Channel, k: _Record_Key, v: anim.Channel_Value) -> anim.Channel_Value {
	if k.property do return v
	f, is_f := v.([4]f32)
	if !is_f do return v
	switch {
	case ch.path == .Euler && k.leaf == typeid_of([4]f32):
		e := engine.quat_to_euler_xyz(f)
		return [4]f32{e.x, e.y, e.z, 0}
	case ch.path == .Rotation && k.leaf == typeid_of([3]f32):
		return anim.animation_quat_from_euler(f.xyz)
	case ch.path == .Rotation:
		return _record_normalized(f)
	}
	return v
}

// The rows of `k` in `clip`, in channel order: one for a joined row, one per
// lane for a split row (editor/lane_split.odin). A rotation key lists the
// Euler rows when the clip has any, else its Rotation rows. Temp-allocated.
@(private = "file")
_record_channels :: proc(clip: ^anim.AnimationClip, k: _Record_Key) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	quat := make([dynamic]int, context.temp_allocator)
	for &c, i in clip.channels {
		if c.target != k.target do continue
		if k.property {
			if c.component == k.guid_str && c.field == k.field do append(&out, i)
			continue
		}
		if anim.animation_channel_is_property(&c) do continue
		switch {
		case k.path == .Rotation && c.path == .Euler: append(&out, i)
		case k.path == .Rotation && c.path == .Rotation: append(&quat, i)
		case c.path == k.path: append(&out, i)
		}
	}
	if len(out) == 0 do return quat[:]
	return out[:]
}

// The rows' value at the playhead over `cur`, the field's own value: each
// row sets the lanes it animates, the other lanes keep `cur`. Float rows only.
@(private = "file")
_record_sample_lanes :: proc(clip: ^anim.AnimationClip, chans: []int, kind: anim.Prop_Kind, cur: [4]f32) -> [4]f32 {
	v := cur
	for idx in chans {
		ch := &clip.channels[idx]
		s := anim._animation_channel_sample(ch, _pv.time)
		off := anim.animation_channel_lanes_off(ch, kind)
		for l in 0 ..< anim.animation_channel_lane_count(ch, kind) do if l not_in off do v[l] = s[l]
	}
	return v
}

// The field's value from before the edit, decoded from the session's payload
// into a scratch of the field's own type. A string is the decoded copy, on
// context.allocator, for the caller to free.
@(private = "file")
_record_old_value :: proc(e: undo.Edit_Commit, k: _Record_Key) -> anim.Channel_Value {
	scratch: [4]u64 // the largest animatable type is a PPtr (24 bytes), aligned for an i64
	assert(size_of(scratch) >= type_info_of(k.leaf).size, "record: an animatable field fits the scratch")
	ok := undo.write_json_value(&scratch, k.leaf, e.old_json, {})
	assert(ok, "record: the old value decodes")
	return anim._prop_read_value(&scratch, k.kind, k.leaf)
}

// The name path from the animated object down to `tH`, the shape Add Property
// builds: names joined with "/", "" for the animated object itself. False when
// `tH` is not under the animated object. Temp-allocated.
@(private = "file")
_record_target_path :: proc(tH: engine.Transform_Handle) -> (path: string, ok: bool) {
	w := engine.ctx_world()
	names := make([dynamic]string, context.temp_allocator)
	cur := tH
	for _ in 0 ..< 1024 {
		if cur.index == _pv.owner.index && cur.generation == _pv.owner.generation {
			b := strings.builder_make(context.temp_allocator)
			for i := len(names) - 1; i >= 0; i -= 1 {
				strings.write_string(&b, names[i])
				if i > 0 do strings.write_byte(&b, '/')
			}
			return strings.to_string(b), true
		}
		t := engine.pool_get(&w.transforms, engine.Handle(cur))
		if t == nil do return "", false
		append(&names, t.name)
		cur = engine.Transform_Handle(t.parent.handle)
	}
	return "", false
}

// A type's name without its package, as the row labels show component names.
@(private = "file")
_record_type_name :: proc(tid: typeid) -> string {
	name := fmt.tprintf("%v", tid)
	if dot := strings.last_index_byte(name, '.'); dot >= 0 do name = name[dot + 1:]
	return name
}

// --- Driven values ----------------------------------------------------------------------
//
// The inspector shows the preview's value for a field the shown clip animates
// (inspector.driven_provider, docs/core/Undo.md "Driven values"). The preview
// applies the pose only around the scene and game render, so the live field
// holds the object's own value while the inspector draws: this answers with
// the clip's value at the playhead instead.
//
// With Record off the field is read-only. An edit there would change the
// object's own value, which the preview pose hides at render and the
// inspector does not show, so the edit would look lost. With Record armed the
// inspector hands the edited value to inspector.driven_commit at the end of
// the gesture, which keys it. The inspector's scene edit session is not used
// for this: its "before" is the object's own value, so an edit back to that
// value would record nothing and key nothing. Gizmo drags and multi-edit
// still reach _record_commit through the session, where "before" is the
// posed value.

// Resolves a field the way _record_key_of resolves an undo target. Per field
// per frame: no allocations beyond temp, no
// logging.
@(private = "file")
_record_field_key :: proc(owner: engine.Handle, field_offset: uintptr, field_tid: typeid) -> (k: _Record_Key, ok: bool) {
	kind, kok := anim._prop_kind_of(field_tid)
	if !kok do return {}, false
	w := engine.ctx_world()
	if w == nil do return {}, false

	comp_tid: typeid
	if owner.type_key == .Transform {
		k.owner = engine.Transform_Handle(owner)
		switch {
		case field_offset == offset_of(engine.Transform, position) && field_tid == typeid_of([3]f32):
			k.path = .Position
		// The rotation field is keyed as a quaternion or as euler angles: the
		// inspector's rotation row works in euler angles (hierarchy inspector).
		case field_offset == offset_of(engine.Transform, rotation) && (field_tid == typeid_of([4]f32) || field_tid == typeid_of([3]f32)):
			k.path = .Rotation
		case field_offset == offset_of(engine.Transform, scale) && field_tid == typeid_of([3]f32):
			k.path = .Scale
		case:
			return {}, false
		}
	} else {
		base := engine.world_pool_get(w, owner)
		if base == nil do return {}, false
		comp_tid = engine.get_typeid_by_type_key(owner.type_key)
		if comp_tid == nil do return {}, false
		k.owner = (^engine.CompData)(base).owner
		k.property = true
	}

	target, under := _record_target_path(k.owner)
	if !under do return {}, false
	k.target = target
	if k.property {
		field, _, animatable := anim._prop_path_of_offset(comp_tid, field_offset, field_tid)
		if !animatable do return {}, false
		k.field = field
		k.guid_str = uuid.to_string(engine.get_guid_by_type_key(owner.type_key), context.temp_allocator)
	}
	k.kind = kind
	k.leaf = field_tid
	return k, true
}

// Samples the field's row at the playhead. A vector row with disabled lanes
// fills them from the live field, so the inspector shows the clip's lanes and
// the object's own lanes together.
//
// A string field is never driven: the inspector's string drawer frees the
// string in the buffer it draws on when it is edited, and a driven string
// would be the clip's own. The field shows its own value, and recording and
// Add Key still key it.
@(private = "file")
_record_driven :: proc(owner: engine.Handle, field_offset: uintptr, field_tid: typeid, out: rawptr) -> (driven: bool, editable: bool) {
	// State preview poses from an authored state, not from the shown clip.
	if !_pv.active || _pv.entry != 0 || _pv.clip == {} do return false, false
	kind, kok := anim._prop_kind_of(field_tid)
	if !kok || kind == .Text do return false, false
	doc, clip := _pv_doc()
	if clip == nil || len(clip.channels) == 0 do return false, false

	k, ok := _record_field_key(owner, field_offset, field_tid)
	if !ok do return false, false
	chans := _record_channels(clip, k)
	if len(chans) == 0 do return false, false
	editable = _pv.recording && doc != nil
	if k.property {
		ch0 := &clip.channels[chans[0]]
		if !anim.animation_channel_is_float(ch0) {
			anim._prop_write_value(out, k.kind, field_tid, anim._animation_channel_sample_value(ch0, _pv.time))
			return true, editable
		}
		cur: [4]f32
		if live, _, _, lok := anim._prop_locate(k.owner, k.guid_str, k.field); lok do cur = anim._prop_read(live, k.kind, field_tid)
		anim._prop_write_value(out, k.kind, field_tid, _record_sample_lanes(clip, chans, k.kind, cur))
		return true, editable
	}
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(k.owner))
	if t == nil do return false, false
	switch k.path {
	case .Position:
		(cast(^[3]f32)out)^ = _record_sample_lanes(clip, chans, .Vec3, {t.position.x, t.position.y, t.position.z, 0}).xyz
	case .Scale:
		(cast(^[3]f32)out)^ = _record_sample_lanes(clip, chans, .Vec3, {t.scale.x, t.scale.y, t.scale.z, 0}).xyz
	case .Rotation:
		// Rotation rows give the quaternion, Euler rows their angles over
		// the object's own. The field reads as a quaternion or as euler
		// angles, by the type asked for.
		q := t.rotation
		e: [3]f32
		if clip.channels[chans[0]].path == .Rotation {
			q = anim._animation_channel_sample(&clip.channels[chans[0]], _pv.time)
			e = engine.quat_to_euler_xyz(q)
		} else {
			e = engine.quat_to_euler_xyz(q)
			e = _record_sample_lanes(clip, chans, .Vec3, {e.x, e.y, e.z, 0}).xyz
			q = anim.animation_quat_from_euler(e)
		}
		if k.leaf == typeid_of([3]f32) {
			(cast(^[3]f32)out)^ = e
		} else {
			(cast(^[4]f32)out)^ = q
		}
	case .Euler:
		unreachable() // a field key names the rotation field, never a row form
	}
	return true, editable
}

// Keys an inspector edit of a driven field at the playhead: `value` holds the
// edited value in the field's own type, keyed as _record_add_key keys it.
// False when Record is off or the field cannot be keyed.
@(private = "file")
_record_driven_commit :: proc(owner: engine.Handle, field_offset: uintptr, field_tid: typeid, value: rawptr) -> bool {
	if !_pv.recording || !_pv.active || _pv.entry != 0 do return false
	return _record_key_value(owner, field_offset, field_tid, value, whole = false)
}

// --- Rows of the shown clip --------------------------------------------------------------
//
// While the Animation window shows a clip, preview on or off and Record armed
// or not, the inspector marks a field the clip has a row for
// (inspector.driven_row_state) and offers "Add Key" in the field's context
// menu (inspector.driven_add_key).

// Set by animation_record_arm: a test has no window, so arming stands in for
// an open Animation window.
@(private = "file")
_record_test_shown: bool

// Whether an Animation window shows a clip.
@(private = "file")
_record_clip_shown :: proc() -> bool {
	if _pv.clip == {} do return false
	return _record_test_shown || wnd.is_open(ANIMATION_VIEW)
}

// `has_row`: the shown clip has a row for the field. `keyable`: the clip has
// a document (a clip inside a model has none), and the field is animatable on
// the animated object or under it. Per field per frame: no allocations beyond
// temp.
@(private = "file")
_record_row_state :: proc(owner: engine.Handle, field_offset: uintptr, field_tid: typeid) -> (has_row, keyable, keyed: bool) {
	if !_record_clip_shown() do return false, false, false
	if _, kok := anim._prop_kind_of(field_tid); !kok do return false, false, false
	doc, clip := _pv_doc()
	if clip == nil do return false, false, false
	k, ok := _record_field_key(owner, field_offset, field_tid)
	if !ok do return false, false, false
	// Keyable only while recording: "Add Key" is a recording tool.
	keyable = doc != nil && _pv.recording
	chans := _record_channels(clip, k)
	if len(chans) == 0 do return false, keyable, false
	// Keyed when any of the rows has a key on the playhead's frame.
	for idx in chans do if _record_key_at_playhead(clip, idx) >= 0 {
		keyed = true
		break
	}
	return true, keyable, keyed
}

// The key of row `idx` on the playhead's frame, -1 for none.
@(private = "file")
_record_key_at_playhead :: proc(clip: ^anim.AnimationClip, idx: int) -> int {
	half := 0.5 / anim.animation_clip_frame_rate(clip)
	for t, i in clip.channels[idx].times do if abs(t - _pv.time) <= half do return i
	return -1
}

// Keys `value` (the field's own type) at the playhead. A missing row is
// created first (its key at the clip start holds the object's own value, as
// Add Property does). One undo step on the clip document. Record need not be
// armed. False when the field cannot be keyed.
// Deletes the row's key on the playhead's frame. A row left with no keys goes
// too, as the window's Delete does. One undo step. False when there is no
// such key.
@(private = "file")
_record_delete_key :: proc(owner: engine.Handle, field_offset: uintptr, field_tid: typeid) -> bool {
	if !_record_clip_shown() do return false
	doc, clip := _pv_doc()
	if doc == nil || clip == nil do return false
	k, ok := _record_field_key(owner, field_offset, field_tid)
	if !ok do return false
	chans := _record_channels(clip, k)
	any_key := false
	for idx in chans do if _record_key_at_playhead(clip, idx) >= 0 do any_key = true
	if !any_key do return false

	_record_busy = true
	defer _record_busy = false
	_pv_edit_begin(doc)
	{
		context.allocator = inspector.doc_alloc()
		// Last row first: removing an emptied row shifts the indices after it.
		for i := len(chans) - 1; i >= 0; i -= 1 {
			row := chans[i]
			key := _record_key_at_playhead(clip, row)
			if key < 0 do continue
			ch := &clip.channels[row]
			anim.animation_channel_remove_key(ch, key)
			if len(ch.times) == 0 {
				_pv_channel_remove(clip, row)
				_pv_deselect()
			}
		}
	}
	_pv_edit_commit(doc)
	return true
}

@(private = "file")
_record_add_key :: proc(owner: engine.Handle, field_offset: uintptr, field_tid: typeid, value: rawptr) -> bool {
	return _record_key_value(owner, field_offset, field_tid, value, whole = true)
}

// Keys `value` (the field's own type) at the playhead in the field's rows,
// adding the row when it is missing. `whole` keys every lane of a split row,
// as "Add Key" does, else only the lanes that differ from the value the
// rows show at the playhead, as a recorded edit does (_record_key_rows).
@(private = "file")
_record_key_value :: proc(owner: engine.Handle, field_offset: uintptr, field_tid: typeid, value: rawptr, whole: bool) -> bool {
	if !_record_clip_shown() do return false
	doc, clip := _pv_doc()
	if doc == nil || clip == nil do return false
	k, ok := _record_field_key(owner, field_offset, field_tid)
	if !ok do return false

	// A string is borrowed from `value`: the row clones it.
	edited := anim._prop_read_value(value, k.kind, k.leaf)

	// The value the edit started from, read before the rows change.
	ref: Maybe(anim.Channel_Value)
	if !whole {
		scratch: [4]u64
		if driven, _ := _record_driven(owner, field_offset, field_tid, &scratch); driven {
			ref = anim._prop_read_value(&scratch, k.kind, k.leaf)
		}
	}

	_record_busy = true
	defer _record_busy = false
	_pv_edit_begin(doc)
	_pv_edit_held = true
	{
		// Channel strings and key arrays live in the document.
		context.allocator = inspector.doc_alloc()
		chans := _record_channels(clip, k)
		if len(chans) == 0 {
			_record_add_row(doc, clip, k)
			chans = _record_channels(clip, k)
			assert(len(chans) == 1, "record: the new row is in the clip")
		}
		_record_key_rows(doc, clip, chans, k, edited, ref)
	}
	_pv_edit_held = false
	_pv_edit_commit(doc)
	return true
}

@(private = "file")
_record_normalized :: proc(q: [4]f32) -> [4]f32 {
	l := linalg.length(q)
	assert(l > 0.0001, "record: a rotation key is a nonzero quaternion")
	return (1.0 / l) * q
}

// --- Note ------------------------------------------------------------------------------
//
// Why the last edit under the animated object was not keyed. Shown under the
// toolbar while Record is armed, replaced by the next note, cleared when
// Record is disarmed.

@(private = "file")
_record_note: string

@(private = "file")
_record_note_set :: proc(text: string) {
	_record_note_clear()
	_record_note = strings.clone(text, runtime.default_allocator())
}

@(private)
_record_note_clear :: proc() {
	if _record_note == "" do return
	delete(_record_note, runtime.default_allocator())
	_record_note = ""
}

@(private)
_record_draw_note :: proc() {
	if !_pv.recording || _record_note == "" do return
	im.TextColored({0.95, 0.7, 0.3, 1}, fmt.ctprintf("%s", _record_note))
}

// --- Test access -----------------------------------------------------------------------

// Test-only: points the preview at `owner` and `clip` with the playhead at
// `time`, and arms Record when `armed`, as picking the clip and pressing
// Record in the window does, and stands in for an open Animation window.
// Nothing in the editor calls this.
animation_record_arm :: proc(owner: engine.Transform_Handle, clip: engine.PPtr, time: f32, armed := true) {
	_pv.owner = owner
	_pv.clip = clip
	_pv.time = time
	_pv.active = true
	_pv.recording = armed
	_record_test_shown = true
}

// Test-only: keys row `row` of the shown clip at the playhead with `value`,
// the way the row's value field in the Animation window does.
animation_record_key_row :: proc(row: int, value: [4]f32) {
	doc, clip := _pv_doc()
	if doc == nil || clip == nil do return
	_pv_row_key(doc, clip, row, value)
}

// Test-only: keys Rotation row `row` of the shown clip at the playhead with
// the euler angles `euler` (degrees), the way the row's euler fields do.
animation_record_key_row_euler :: proc(row: int, euler: [3]f32) {
	if doc, clip := _pv_doc(); clip != nil && row >= 0 && row < len(clip.channels) && clip.channels[row].path == .Euler {
		_pv_row_key(doc, clip, row, anim.Channel_Value([4]f32{euler.x, euler.y, euler.z, 0}))
		return
	}
	doc, clip := _pv_doc()
	if doc == nil || clip == nil do return
	_pv_row_key(doc, clip, row, _pv_rot_from_euler(euler))
}

// Test-only: disarms Record and lets go of the target.
animation_record_reset :: proc() {
	_pv_preview_off()
	_pv_teardown()
	_pv.owner = {}
	_pv.clip = {}
	_pv.time = 0
	_record_test_shown = false
}

// The note the window shows under the toolbar, "" for none.
animation_record_note :: proc() -> string {
	return _record_note
}
