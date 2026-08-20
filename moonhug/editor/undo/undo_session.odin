package undo

// Edit sessions: one bracketed transaction covering any number of targets.
//
// An edit in the editor is a GESTURE. It begins, runs for some number of frames,
// and ends, and undo needs the value from before it and the value after. The
// older entry points each re-derive "has this started / ended" from per-frame
// widget state, and they disagree with each other — that is the bug class this
// replaces:
//
//   - comp_snapshot DISCARDS an already-open pending edit and replaces it, so
//     two objects edited in one gesture lose the first one's record.
//   - edit_pooled_begin stores a field as (field_ptr - component_base). For a
//     dynamic-array element that spans two unrelated allocations, and applying
//     it later writes far outside the component.
//   - comp_snapshot only opens on IsItemActivated, which a picker popup never
//     triggers — so a picker edit records nothing at all.
//
// A session fixes all three by representing the gesture directly: before-state
// is captured ONCE for every target at the same instant, and held until the
// session closes. Nothing infers anything per frame.
//
// SESSIONS ARE NOT GROUPS. A group (group_begin/group_end) bundles several
// FINISHED operations into one Ctrl+Z — "Create Empty Parent" is one create plus
// two reparents. A session brackets one UNFINISHED edit. A session emits exactly
// one grouped action when it closes, so an N-target session is already one undo
// step and needs no group around it.

import "core:slice"
import engine "../../engine"

// One thing being edited. The three kinds cover every call site in the editor:
// pooled components and transforms, plain editor-owned structs, and asset
// documents.
Edit_Target :: struct {
	kind: Owner_Kind,

	// .Pooled — a component or transform in a world pool.
	handle: engine.Handle,

	// .Raw — a struct the editor owns (import settings, project settings).
	raw_ptr: rawptr,
	raw_tid: typeid,

	// .Asset — a document in the asset registry.
	asset_guid: engine.Asset_GUID,
	asset_tid:  typeid,

	// The field inside it. A nil field_ptr means the WHOLE target, which is what
	// a structural change (array add/remove) needs.
	field_ptr: rawptr,
	field_tid: typeid,
}

// Convenience constructors — the shapes call sites actually have.
edit_target_pooled :: proc(h: engine.Handle, field_ptr: rawptr, field_tid: typeid) -> Edit_Target {
	return Edit_Target{kind = .Pooled, handle = h, field_ptr = field_ptr, field_tid = field_tid}
}

edit_target_transform :: proc(tH: engine.Transform_Handle, field_ptr: rawptr, field_tid: typeid) -> Edit_Target {
	return edit_target_pooled(engine.Handle(tH), field_ptr, field_tid)
}

// The whole component/transform, for structural edits that no offset can name.
edit_target_whole :: proc(h: engine.Handle) -> Edit_Target {
	return Edit_Target{kind = .Pooled, handle = h}
}

edit_target_asset :: proc(guid: engine.Asset_GUID, tid: typeid) -> Edit_Target {
	return Edit_Target{kind = .Asset, asset_guid = guid, asset_tid = tid}
}

@(private)
_Edit_Entry :: struct {
	target:   Property_Target, // resolved once at begin
	old_json: []byte,
	// The pointer the after-state is read from. Re-resolved at end for .Pooled,
	// since a pool slot can be reallocated by an intervening operation.
	ptr:      rawptr,
}

Edit_Session :: struct {
	active:  bool,
	label:   string,
	entries: [dynamic]_Edit_Entry,
}

// Opens a transaction and captures every target's before-state at one instant.
//
// Granularity is decided HERE, per target, not by the caller:
//   - the field lies inside the target's own storage -> record that field
//     (~17 bytes for a [3]f32)
//   - the field is outside it, or nil -> record the whole target (~149 bytes for
//     a median component). Required for dynamic-array elements, whose storage is
//     a separate allocation that no offset from the component base can address.
//
// Deciding it in one place is the point: two call sites choosing differently for
// the same field is what produced the "undo reverts only one of two objects"
// and the out-of-bounds-write crash.
//
// Returns an inactive session when recording is off or nothing resolved, and
// every proc here tolerates that — callers need no special case.
// `restore_before` is for edits that can only be bracketed AFTER they happened —
// a picker writes from inside a popup, so by the time the caller notices, the
// live value is already the new one and capturing it would record new->new.
//
// The caller supplies a proc that puts the field back to its previous value for
// the duration of the capture. Doing it that way rather than accepting a raw
// payload is what makes it correct at any granularity: an entry may record a
// FIELD or a WHOLE COMPONENT (see _entry_begin), and a payload captured at one
// granularity written into an entry expecting the other corrupts the record —
// undoing a material assignment wrote the active object's whole component onto
// its peer, emptying that peer's materials.
edit_session_begin :: proc(
	targets: []Edit_Target,
	label := "",
	allocator := context.allocator,
	restore_before: proc(user: rawptr) = nil,
	restore_user: rawptr = nil,
	restore_after: proc(user: rawptr) = nil,
) -> Edit_Session {
	s := get()
	if s == nil || !s.recording || s.applying || len(targets) == 0 {
		return {}
	}

	sess := Edit_Session{label = label}
	sess.entries = make([dynamic]_Edit_Entry, 0, len(targets), allocator)

	// Roll the edit back, capture every target at its OWN granularity, roll it
	// forward again. Each entry then holds a payload of the shape it will be
	// applied with.
	if restore_before != nil do restore_before(restore_user)
	for t in targets {
		entry, ok := _entry_begin(t)
		if !ok do continue
		append(&sess.entries, entry)
	}
	if restore_after != nil do restore_after(restore_user)

	if len(sess.entries) == 0 {
		delete(sess.entries)
		return {}
	}
	sess.active = true
	return sess
}

// Captures after-state and records ONE grouped action for every target that
// actually changed. Targets whose value is unchanged contribute nothing, so a
// gesture that ends where it started records nothing at all.
edit_session_end :: proc(sess: ^Edit_Session) {
	if sess == nil || !sess.active do return
	defer _session_reset(sess)

	s := get()
	if s == nil {
		_session_free_payloads(sess)
		return
	}

	// One group for the whole session: an N-target edit is one Ctrl+Z.
	begin_group_command(s)
	wrote := false

	for &e in sess.entries {
		ptr := e.ptr
		if e.target.kind == .Pooled {
			// Re-resolve: a pool slot can move if something else ran mid-gesture.
			ptr = resolve_target_ptr(e.target)
		}
		if ptr == nil {
			delete(e.old_json)
			e.old_json = nil
			continue
		}
		new_json := capture_json(ptr, e.target.type_id)
		if new_json == nil {
			delete(e.old_json)
			e.old_json = nil
			continue
		}
		if slice.equal(e.old_json, new_json) {
			delete(e.old_json)
			delete(new_json)
			e.old_json = nil
			continue
		}
		// push_value takes ownership of both payloads.
		push_value(s, e.target, e.old_json, new_json, sess.label)
		e.old_json = nil
		wrote = true
	}

	if wrote {
		end_group_command(s, sess.label)
	} else {
		abort_group_command(s)
	}
}

// Abandons the transaction without recording. Values the caller already wrote
// stay written — this only drops the pending record, for a gesture that should
// not appear in the undo history.
edit_session_abort :: proc(sess: ^Edit_Session) {
	if sess == nil || !sess.active do return
	_session_free_payloads(sess)
	_session_reset(sess)
}

edit_session_active :: proc(sess: ^Edit_Session) -> bool {
	return sess != nil && sess.active
}

@(private = "file")
_session_free_payloads :: proc(sess: ^Edit_Session) {
	for &e in sess.entries {
		if e.old_json != nil {
			delete(e.old_json)
			e.old_json = nil
		}
	}
}

@(private = "file")
_session_reset :: proc(sess: ^Edit_Session) {
	if sess.entries != nil do delete(sess.entries)
	sess^ = {}
}

// Resolves one target and captures its before-state. Where the field-vs-whole
// decision is made.
@(private = "file")
_entry_begin :: proc(t: Edit_Target) -> (_Edit_Entry, bool) {
	switch t.kind {
	case .None:
		return {}, false

	case .Asset:
		// Asset documents are applied through the asset hook, which replaces the
		// whole document — there is no field-level form.
		if t.asset_tid == nil do return {}, false
		doc_ptr := _asset_doc_ptr(t.asset_guid)
		if doc_ptr == nil do return {}, false
		old := capture_json(doc_ptr, t.asset_tid)
		if old == nil do return {}, false
		return _Edit_Entry{
			target = make_asset_target(t.asset_guid, t.asset_tid),
			old_json = old,
			ptr = doc_ptr,
		}, true

	case .Raw:
		if t.raw_ptr == nil || t.raw_tid == nil do return {}, false
		base := t.raw_ptr
		field_ptr := t.field_ptr
		field_tid := t.field_tid
		offset := uintptr(0)
		if field_ptr == nil || !_ptr_within(base, t.raw_tid, field_ptr, field_tid) {
			field_ptr = base
			field_tid = t.raw_tid
		} else {
			offset = uintptr(field_ptr) - uintptr(base)
		}
		old := capture_json(field_ptr, field_tid)
		if old == nil do return {}, false
		return _Edit_Entry{
			target = make_raw_target(base, offset, field_tid),
			old_json = old,
			ptr = field_ptr,
		}, true

	case .Pooled:
		w := engine.ctx_world()
		if w == nil do return {}, false
		base := engine.world_pool_get(w, t.handle)
		if base == nil do return {}, false
		owner_tid := engine.get_typeid_by_type_key(t.handle.type_key)
		if owner_tid == nil do return {}, false

		field_ptr := t.field_ptr
		field_tid := t.field_tid
		offset := uintptr(0)

		// THE granularity rule. A field outside the component's own storage —
		// an element of a dynamic array, which lives in its own allocation —
		// cannot be named by an offset from the base, so the whole component is
		// recorded instead. Doing this here rather than at the call site is what
		// stops two callers disagreeing about the same field.
		if field_ptr == nil || !_ptr_within(base, owner_tid, field_ptr, field_tid) {
			field_ptr = base
			field_tid = owner_tid
		} else {
			offset = uintptr(field_ptr) - uintptr(base)
		}

		old := capture_json(field_ptr, field_tid)
		if old == nil do return {}, false
		return _Edit_Entry{
			target = make_pooled_target(t.handle, offset, field_tid),
			old_json = old,
			ptr = field_ptr,
		}, true
	}
	return {}, false
}

// Whether `field` (of size field_tid) lies entirely inside `base` (of size
// base_tid). A field-level undo target is an offset from the base, so this is
// exactly the condition under which such a target is meaningful.
@(private = "file")
_ptr_within :: proc(base: rawptr, base_tid: typeid, field: rawptr, field_tid: typeid) -> bool {
	if base == nil || field == nil || base_tid == nil || field_tid == nil do return false
	bti := type_info_of(base_tid)
	fti := type_info_of(field_tid)
	if bti == nil || fti == nil do return false
	lo := uintptr(base)
	hi := lo + uintptr(bti.size)
	p := uintptr(field)
	return p >= lo && p + uintptr(fti.size) <= hi
}

// The live document pointer for an asset guid, via the same hook the asset
// apply path uses. nil when the inspector has no document open for it.
@(private = "file")
_asset_doc_ptr :: proc(guid: engine.Asset_GUID) -> rawptr {
	if _asset_doc_lookup == nil do return nil
	return _asset_doc_lookup(guid)
}

// Installed by the inspector at init, like set_asset_apply — the undo package
// cannot import the inspector.
@(private)
_asset_doc_lookup: proc(guid: engine.Asset_GUID) -> rawptr

set_asset_doc_lookup :: proc(fn: proc(guid: engine.Asset_GUID) -> rawptr) {
	_asset_doc_lookup = fn
}
