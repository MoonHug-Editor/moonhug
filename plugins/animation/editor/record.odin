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
// An entry that cannot be keyed stays an ordinary scene edit with its own undo:
//   - the field type is not animatable (a string, a reference, an array). The
//     window shows a note under the toolbar while Record is armed
//   - the object is neither the animated object nor under it
//   - the window has no clip document (a clip inside a model is read-only)

import "base:runtime"
import "core:encoding/uuid"
import "core:fmt"
import "core:strings"
import im "moonhug:external/odin-imgui"
import engine "moonhug:packages/engine"
import anim "moonhug:packages/animation"
import "moonhug:editor/inspector"
import "moonhug:editor/undo"

@(phase={key=engine.Phase.EditorInit, order=1, mode=Editor})
animation_record_install :: proc() {
	assert(undo.commit_listener == nil || undo.commit_listener == _record_commit, "undo.commit_listener is installed by another package")
	undo.commit_listener = _record_commit
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
// changes the object only from where the key was recorded.
@(private = "file")
_record_key :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, k: _Record_Key, e: undo.Edit_Commit) {
	edited := anim._prop_read(e.ptr, k.kind, k.leaf)
	idx := _record_find_channel(clip, k)
	if idx < 0 {
		if k.property {
			_pv_add_channel_property(doc, clip, k.target, k.guid_str, k.field, k.owner)
		} else {
			_pv_add_channel_transform(doc, clip, k.target, k.path, k.owner)
		}
		idx = _record_find_channel(clip, k)
		assert(idx >= 0, "record: the new row is in the clip")
		clip.channels[idx].values[0] = _record_old_value(e, k)
	}
	_pv_add_key(doc, clip, idx, _pv.time, edited)
}

@(private = "file")
_record_find_channel :: proc(clip: ^anim.AnimationClip, k: _Record_Key) -> int {
	for &c, i in clip.channels {
		if c.target != k.target do continue
		if k.property {
			if c.component == k.guid_str && c.field == k.field do return i
		} else if !anim.animation_channel_is_property(&c) && c.path == k.path {
			return i
		}
	}
	return -1
}

// The field's value from before the edit, decoded from the session's payload
// into a scratch of the field's own type.
@(private = "file")
_record_old_value :: proc(e: undo.Edit_Commit, k: _Record_Key) -> [4]f32 {
	scratch: [2]u64 // the largest animatable type is [4]f32, aligned for an i64
	assert(size_of(scratch) >= type_info_of(k.leaf).size, "record: an animatable field fits the scratch")
	ok := undo.write_json_value(&scratch, k.leaf, e.old_json, {})
	assert(ok, "record: the old value decodes")
	return anim._prop_read(&scratch, k.kind, k.leaf)
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
// Record in the window does. Nothing in the editor calls this.
animation_record_arm :: proc(owner: engine.Transform_Handle, clip: engine.PPtr, time: f32, armed := true) {
	_pv.owner = owner
	_pv.clip = clip
	_pv.time = time
	_pv.active = true
	_pv.recording = armed
}

// Test-only: disarms Record and lets go of the target.
animation_record_reset :: proc() {
	_pv_preview_off()
	_pv_teardown()
	_pv.owner = {}
	_pv.clip = {}
	_pv.time = 0
}

// The note the window shows under the toolbar, "" for none.
animation_record_note :: proc() -> string {
	return _record_note
}
