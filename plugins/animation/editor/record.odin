package animation_editor

// Record (plugins/animation/docs/windows/AnimationWindow.md "Record"): while the
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
import "core:slice"
import "core:strings"
import im "moonhug:external/odin-imgui"
import gfx "moonhug:libs/gfx"
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
	assert(inspector.driven_delete_key == nil || inspector.driven_delete_key == _record_delete_key, "inspector.driven_delete_key is installed by another package")
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

@(private = "file")
_record_commit :: proc(edits: []undo.Edit_Commit, consumed: []bool) {
	// A state preview from the States tree poses from an authored state, not
	// from the shown clip, so nothing is keyed while it runs.
	if !_pv.recording || _pv.entry != 0 do return
	doc, clip := _pv_doc()
	if doc == nil || clip == nil do return

	// Every keyed entry goes into one session on the clip document. The
	// session's payloads use the caller's allocator, as every undo record does.
	// The clip session's own end does not call this listener again
	// (undo.edit_session_end runs one listener call at a time).
	keyed := false
	for e, i in edits {
		k, ok := _record_key_of(e)
		if !ok do continue
		if !keyed {
			_pv_edit_begin(doc)
			_pv_edit_hold()
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
		_pv_edit_release()
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
		anim.animation_channel_set_value(ch, 0, _record_row_value(ch, k, old, _record_euler_near(clip, chans, k)))
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

// Keys `edited` (the field's own type, k.leaf) on the playhead's frame in the
// rows of `k`, which exist (_record_key_on_frame places the key):
//   - a joined row (one channel) takes the whole value, and every lane
//     animates. A lane the row had disabled holds values that were never
//     shown, so every other key of the row takes the live value in it: `ref`
//     when given, else `edited`. The row holds that lane flat at what the
//     object showed
//   - a split row (one channel per lane) keys lane by lane: with `ref`, the
//     value the edit started from in the field's type, only the lanes that
//     differ from it (_record_lane_differs), without it every lane
// A quaternion keyed into an Euler row unwinds toward the angles the rows
// give at the playhead (_record_euler_near).
@(private = "file")
_record_key_rows :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, chans: []int, k: _Record_Key, edited: anim.Channel_Value, ref: Maybe(anim.Channel_Value)) {
	near := _record_euler_near(clip, chans, k)
	if len(chans) == 1 {
		idx := chans[0]
		off := anim.animation_channel_lanes_off(&clip.channels[idx], k.kind)
		at := _record_key_on_frame(doc, clip, idx, _record_row_value(&clip.channels[idx], k, edited, near))
		ch := &clip.channels[idx]
		if off != {} {
			src, has_ref := ref.?
			if !has_ref do src = edited
			fill, fok := _record_row_value(ch, k, src, near).([4]f32)
			vals, vok := ch.values.([dynamic][4]f32)
			if fok && vok {
				for &v, i in vals do if i != at do for l in off do v[l] = fill[l]
			}
		}
		ch.lanes_off = {}
		return
	}
	for idx in chans {
		ch := &clip.channels[idx]
		v := _record_row_value(ch, k, edited, near)
		if r, has_ref := ref.?; has_ref {
			f, fok := v.([4]f32)
			rf, rok := _record_row_value(ch, k, r, near).([4]f32)
			if fok && rok {
				changed := false
				off := anim.animation_channel_lanes_off(ch, k.kind)
				for l in 0 ..< anim.animation_channel_lane_count(ch, k.kind) {
					if l in off do continue
					if _record_lane_differs(f[l], rf[l]) {
						changed = true
						break
					}
				}
				if !changed do continue
			}
		}
		_record_key_on_frame(doc, clip, idx, v)
	}
}

// Whether two lane values differ by more than float noise: 1e-5 relative to
// the larger magnitude, or absolute below a magnitude of 1. A quaternion
// decomposed to euler angles twice gives lanes that differ in the last bits.
@(private = "file")
_record_lane_differs :: proc(a, b: f32) -> bool {
	return abs(a - b) > 1e-5 * max(f32(1), abs(a), abs(b))
}

// Keys `v` in row `idx` on the playhead's frame, the one rule for where a
// recorded key goes:
//   - the key goes at the playhead snapped to the clip's frame grid, so a
//     playhead paused between frames still keys on a frame
//   - a key within half a frame of that time is the key on the playhead: it
//     takes `v` and keeps its own time
// Runs inside the caller's open session. Returns the key's index.
@(private = "file")
_record_key_on_frame :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, idx: int, v: anim.Channel_Value) -> int {
	if at := _record_key_at_playhead(clip, idx); at >= 0 {
		anim.animation_channel_set_value(&clip.channels[idx], at, v)
		_pv_sel_set(idx, at)
		return at
	}
	_pv_add_key(doc, clip, idx, _record_playhead_frame(clip), v)
	at := _record_key_at_playhead(clip, idx)
	assert(at >= 0, "record: the added key is on the playhead's frame")
	return at
}

// The angles the rows `chans` of `k` give at the playhead over the object's
// own rotation, by the one combining rule (anim.Clip_TRS): the angles a
// recorded quaternion unwinds toward. Zero for a key that is not a rotation.
@(private = "file")
_record_euler_near :: proc(clip: ^anim.AnimationClip, chans: []int, k: _Record_Key) -> [3]f32 {
	if k.property || k.path != .Rotation do return {}
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(k.owner))
	if t == nil do return {}
	trs: anim.Clip_TRS
	for idx in chans do anim.animation_trs_add(&trs, &clip.channels[idx], _pv.time)
	return anim.animation_trs_euler(trs, t.rotation)
}

// `v`, a value of the field (its type is k.leaf), in the form row `ch`
// holds: euler angles for an Euler row given a quaternion, unwound toward
// `near` (anim.animation_euler_nearest), a normalized quaternion for a Rotation
// row, else `v` itself.
@(private = "file")
_record_row_value :: proc(ch: ^anim.Animation_Channel, k: _Record_Key, v: anim.Channel_Value, near: [3]f32) -> anim.Channel_Value {
	if k.property do return v
	f, is_f := v.([4]f32)
	if !is_f do return v
	switch {
	case ch.path == .Euler && k.leaf == typeid_of([4]f32):
		e := anim.animation_euler_nearest(_record_normalized(f), near)
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
	// The property as a channel, so the package's identity rule decides.
	like := anim.Animation_Channel{target = k.target, path = k.path}
	if k.property {
		like.component = k.guid_str
		like.field = k.field
	}
	first := -1
	quat := -1
	for &c, i in clip.channels {
		if anim.animation_channel_same_property(&like, &c) {
			if !k.property && k.path == .Rotation {
				if quat < 0 do quat = i
				continue
			}
			first = i
			break
		}
		if !k.property && k.path == .Rotation && !anim.animation_channel_is_property(&c) && c.target == k.target && c.path == .Euler && first < 0 do first = i
	}
	if first < 0 do first = quat
	if first < 0 do return {}
	return anim.animation_clip_property_channels(clip, first, context.temp_allocator)
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

// The fields the inspector asks about, resolved once per frame: the inspector
// asks _record_driven and _record_row_state for every field it draws, and
// resolving walks the parents, formats the component guid and scans the
// channels. Keyed by (owner, field offset, field type), holding the field's
// _Record_Key and its rows, or that it does not resolve. Cleared when the
// frame, the world, the shown clip, the animated object or the clip's
// document changes. Owned by runtime.default_allocator.
@(private = "file")
_Record_Memo_Key :: struct {
	owner:  engine.Handle,
	offset: uintptr,
	tid:    typeid,
}

@(private = "file")
_Record_Memo :: struct {
	k:     _Record_Key,
	chans: []int,
	ok:    bool,
}

@(private = "file")
_Record_Memo_Stamp :: struct {
	frame:    u64,
	world:    rawptr,
	doc:      rawptr,
	edits:    u64,
	clip:     rawptr,
	channels: int,
	owner:    engine.Transform_Handle,
	pptr:     engine.PPtr,
}

@(private = "file")
_record_memo: map[_Record_Memo_Key]_Record_Memo

@(private = "file")
_record_memo_stamp: _Record_Memo_Stamp

@(private = "file")
_record_memo_clear :: proc() {
	alloc := runtime.default_allocator()
	for _, m in _record_memo {
		delete(m.k.target, alloc)
		delete(m.k.guid_str, alloc)
		delete(m.k.field, alloc)
		delete(m.chans, alloc)
	}
	clear(&_record_memo)
	_record_memo_stamp = {}
}

// The field's key and rows in `clip`, `ok` false when the field does not
// resolve (_record_field_key). The results stay valid until the memo clears.
@(private = "file")
_record_memo_lookup :: proc(owner: engine.Handle, field_offset: uintptr, field_tid: typeid, doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip) -> (k: _Record_Key, chans: []int, ok: bool) {
	stamp := _Record_Memo_Stamp{
		frame    = gfx.frame_index,
		world    = engine.ctx_world(),
		doc      = doc,
		edits    = doc != nil ? doc.edits : 0,
		clip     = clip,
		channels = len(clip.channels),
		owner    = _pv.owner,
		pptr     = _pv.clip,
	}
	if stamp != _record_memo_stamp {
		_record_memo_clear()
		_record_memo_stamp = stamp
	}
	key := _Record_Memo_Key{owner, field_offset, field_tid}
	if m, found := _record_memo[key]; found do return m.k, m.chans, m.ok

	alloc := runtime.default_allocator()
	m: _Record_Memo
	m.k, m.ok = _record_field_key(owner, field_offset, field_tid)
	if m.ok {
		m.k.target = strings.clone(m.k.target, alloc)
		m.k.guid_str = strings.clone(m.k.guid_str, alloc)
		m.k.field = strings.clone(m.k.field, alloc)
		m.chans = slice.clone(_record_channels(clip, m.k), alloc)
	}
	if _record_memo == nil do _record_memo = make(map[_Record_Memo_Key]_Record_Memo, alloc)
	_record_memo[key] = m
	return m.k, m.chans, m.ok
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
_record_driven :: proc(owner: engine.Handle, field_offset: uintptr, field_tid: typeid, out: rawptr) -> (driven: bool, editable: bool, own: inspector.Driven_Lanes) {
	// State preview poses from an authored state, not from the shown clip.
	if !_pv.active || _pv.entry != 0 || _pv.clip == {} do return
	kind, kok := anim._prop_kind_of(field_tid)
	if !kok || kind == .Text do return
	doc, clip := _pv_doc()
	if clip == nil || len(clip.channels) == 0 do return

	k, chans, ok := _record_memo_lookup(owner, field_offset, field_tid, doc, clip)
	if !ok || len(chans) == 0 do return
	editable = _pv.recording && doc != nil
	if k.property {
		ch0 := &clip.channels[chans[0]]
		if !anim.animation_channel_is_float(ch0) {
			anim._prop_write_value(out, k.kind, field_tid, anim._animation_channel_sample_value(ch0, _pv.time))
			return true, editable, {}
		}
		cur: [4]f32
		if live, _, _, lok := anim._prop_locate(k.owner, k.guid_str, k.field); lok do cur = anim._prop_read(live, k.kind, field_tid)
		anim._prop_write_value(out, k.kind, field_tid, _record_sample_lanes(clip, chans, k.kind, cur))
		// The lanes no row animates show and edit the object's own value.
		n := anim.prop_kind_lanes(k.kind)
		if n >= 2 {
			animated: anim.Lane_Set
			for idx in chans {
				ch := &clip.channels[idx]
				off := anim.animation_channel_lanes_off(ch, k.kind)
				for l in 0 ..< anim.animation_channel_lane_count(ch, k.kind) do if l not_in off do animated += {l}
			}
			for l in 0 ..< n do if l not_in animated do own += {l}
		}
		return true, editable, own
	}
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(k.owner))
	if t == nil do return
	// The field's rows over the object's own values, by the one combining
	// rule (anim.Clip_TRS). The rotation reads as a quaternion or as euler
	// angles, by the type asked for. The lanes no row sets are the object's
	// own: a quaternion is driven whole, euler angles per angle.
	trs: anim.Clip_TRS
	for idx in chans do anim.animation_trs_add(&trs, &clip.channels[idx], _pv.time)
	switch k.path {
	case .Position:
		(cast(^[3]f32)out)^ = anim.animation_trs_lanes_over(trs.pos, trs.pos_lanes, t.position)
		own = _record_own_xyz(trs.pos_lanes)
	case .Scale:
		(cast(^[3]f32)out)^ = anim.animation_trs_lanes_over(trs.scl, trs.scl_lanes, t.scale)
		own = _record_own_xyz(trs.scl_lanes)
	case .Rotation:
		if k.leaf == typeid_of([3]f32) {
			(cast(^[3]f32)out)^ = anim.animation_trs_euler(trs, t.rotation)
			if !trs.has_rot do own = _record_own_xyz(trs.eul_lanes)
		} else {
			(cast(^[4]f32)out)^ = anim.animation_trs_rotation(trs, t.rotation)
		}
	case .Euler:
		unreachable() // a field key names the rotation field, never a row form
	}
	return true, editable, own
}

// The lanes of x, y, z outside `animated`.
@(private = "file")
_record_own_xyz :: proc(animated: anim.Lane_Set) -> (own: inspector.Driven_Lanes) {
	for l in 0 ..< 3 do if l not_in animated do own += {l}
	return
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
	return _record_test_shown || wnd.is_open(ANIMATION_WINDOW)
}

// `has_row`: the shown clip has a row for the field. `keyable`: the clip has
// a document (a clip inside a model has none), the field is animatable on
// the animated object or under it, and only while recording and no state of
// the States tree is previewed. Per field per frame: the field resolves once
// per frame (_record_memo_lookup).
@(private = "file")
_record_row_state :: proc(owner: engine.Handle, field_offset: uintptr, field_tid: typeid) -> (has_row, keyable, keyed: bool) {
	if !_record_clip_shown() do return false, false, false
	if _, kok := anim._prop_kind_of(field_tid); !kok do return false, false, false
	doc, clip := _pv_doc()
	if clip == nil do return false, false, false
	_, chans, ok := _record_memo_lookup(owner, field_offset, field_tid, doc, clip)
	if !ok do return false, false, false
	// Keyable only while recording: "Add Key" is a recording tool. A state
	// preview poses from an authored state, not from the shown clip.
	keyable = doc != nil && _pv.recording && _pv.entry == 0
	if len(chans) == 0 do return false, keyable, false
	// Keyed when any of the rows has a key on the playhead's frame.
	for idx in chans do if _record_key_at_playhead(clip, idx) >= 0 {
		keyed = true
		break
	}
	return true, keyable, keyed
}

// The playhead in the clip, snapped to the clip's frame grid: where a
// recorded key goes.
@(private = "file")
_record_playhead_frame :: proc(clip: ^anim.AnimationClip) -> f32 {
	return clamp(anim.animation_snap_to_frame(clip, clamp(_pv.time, 0, clip.length)), 0, clip.length)
}

// The key of row `idx` on the playhead's frame, -1 for none: the key nearest
// the snapped playhead (_record_playhead_frame) within half a frame of it.
// Recording, the keyed mark and Delete Key all use this rule.
@(private = "file")
_record_key_at_playhead :: proc(clip: ^anim.AnimationClip, idx: int) -> int {
	t := _record_playhead_frame(clip)
	best := -1
	best_d := 0.5 / anim.animation_clip_frame_rate(clip)
	for kt, i in clip.channels[idx].times {
		if d := abs(kt - t); d <= best_d {
			best = i
			best_d = d
		}
	}
	return best
}

// Deletes the row's key on the playhead's frame. A row left with no keys goes
// too, as the window's Delete does. One undo step. False when there is no
// such key.
@(private = "file")
_record_delete_key :: proc(owner: engine.Handle, field_offset: uintptr, field_tid: typeid) -> bool {
	if !_record_clip_shown() || _pv.entry != 0 do return false
	doc, clip := _pv_doc()
	if doc == nil || clip == nil do return false
	k, ok := _record_field_key(owner, field_offset, field_tid)
	if !ok do return false
	chans := _record_channels(clip, k)
	any_key := false
	for idx in chans do if _record_key_at_playhead(clip, idx) >= 0 do any_key = true
	if !any_key do return false

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

// Keys `value` (the field's own type) at the playhead. A missing row is
// created first (its key at the clip start holds the object's own value, as
// Add Property does). One undo step on the clip document. False when the
// field cannot be keyed.
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
	if !_record_clip_shown() || _pv.entry != 0 do return false
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
		if driven, _, _ := _record_driven(owner, field_offset, field_tid, &scratch); driven {
			ref = anim._prop_read_value(&scratch, k.kind, k.leaf)
		}
	}

	_pv_edit_begin(doc)
	_pv_edit_hold()
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
	_pv_edit_release()
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
// `entry` nonzero stands in for a state of the States tree being previewed.
animation_record_arm :: proc(owner: engine.Transform_Handle, clip: engine.PPtr, time: f32, armed := true, entry: i32 = 0) {
	_pv.owner = owner
	_pv.clip = clip
	_pv.time = time
	_pv.active = true
	_pv.recording = armed
	_pv.entry = entry
	_record_test_shown = true
	_record_memo_clear()
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
	_record_note_clear()
	_record_memo_clear()
}

// Test-only: the rows of the shown clip for a field, as the inspector's
// questions see them (through the per-frame memo). Valid until the memo
// clears.
animation_record_field_channels :: proc(owner: engine.Handle, field_offset: uintptr, field_tid: typeid) -> []int {
	doc, clip := _pv_doc()
	if clip == nil do return nil
	_, chans, _ := _record_memo_lookup(owner, field_offset, field_tid, doc, clip)
	return chans
}

// The note the window shows under the toolbar, "" for none.
animation_record_note :: proc() -> string {
	return _record_note
}
