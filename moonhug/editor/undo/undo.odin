package undo

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"
import "base:builtin"
import core "moonhug:host/core"
import "moonhug:host/log"

MAX_ENTRIES :: 128

Owner_Kind :: enum {
	None,
	Pooled,
	Raw,
	Asset, // serialized asset document (.mat/.asset), identified by asset guid
}

// The scene identity an undo entry records (core.Scene_Ref: the session id).
Scene_Ref :: core.Scene_Ref

// Which document of an asset an .Asset target edits: the asset's own file
// (.mat, .asset) or its import settings (the .meta, committed by Apply).
Doc_Kind :: enum u8 {
	File,
	Import_Settings,
}

Property_Target :: struct {
	kind:       Owner_Kind,
	scene:      Scene_Ref,
	local_id:   core.Local_ID,
	handle:     core.Handle,
	offset:     u32,
	type_id:    typeid,
	raw_ptr:    rawptr,
	asset_guid: core.Asset_GUID, // .Asset only
	asset_doc:  Doc_Kind,          // .Asset only
}

@(undo_command)
Value_Command :: struct {
	target:   Property_Target,
	old_json: []byte,
	new_json: []byte,
}

apply_Value_Command :: proc(v: ^Value_Command) {
	_value_apply(v^, v.new_json)
}

revert_Value_Command :: proc(v: ^Value_Command) {
	_value_apply(v^, v.old_json)
}

destroy_Value_Command :: proc(v: ^Value_Command) {
	delete(v.old_json)
	delete(v.new_json)
}

label_Value_Command :: proc(v: ^Value_Command) -> string {
	switch v.target.kind {
	case .None:   return "Edit Value"
	case .Pooled: return v.target.handle.type_key == core.transform_type_key ? "Edit Transform" : "Edit Component"
	case .Raw:    return "Edit"
	case .Asset:  return v.target.asset_doc == .Import_Settings ? "Edit Import Settings" : "Edit Asset"
	}
	return "Edit Value"
}

scenes_Value_Command :: proc(v: ^Value_Command, out: ^[dynamic]core.Scene_Ref) {
	if v.target.kind == .Pooled do append(out, v.target.scene)
}

assets_Value_Command :: proc(v: ^Value_Command, out: ^[dynamic]core.Asset_GUID) {
	if v.target.kind == .Asset do append(out, v.target.asset_guid)
}

describe_Value_Command :: proc(v: ^Value_Command, b: ^strings.Builder, depth: int) {
	indent := _indent(depth)
	fmt.sbprintf(b, "%sValue edit\n", indent)
	_append_target(b, v.target, depth + 1)
	fmt.sbprintf(b, "%s  old: %s\n", indent, _truncate(string(v.old_json), 512))
	fmt.sbprintf(b, "%s  new: %s\n", indent, _truncate(string(v.new_json), 512))
}

@(undo_command)
Group_Command :: struct {
	subs: [dynamic]Command,
}

// Sub-commands apply in order and revert in reverse.
apply_Group_Command :: proc(v: ^Group_Command) {
	for i in 0 ..< len(v.subs) {
		_apply_command(&v.subs[i])
	}
}

revert_Group_Command :: proc(v: ^Group_Command) {
	for i := len(v.subs) - 1; i >= 0; i -= 1 {
		_revert_command(&v.subs[i])
	}
}

destroy_Group_Command :: proc(v: ^Group_Command) {
	_group_destroy(v)
}

label_Group_Command :: proc(v: ^Group_Command) -> string {
	return "Group"
}

scenes_Group_Command :: proc(v: ^Group_Command, out: ^[dynamic]core.Scene_Ref) {
	for i in 0 ..< len(v.subs) do _command_scenes(&v.subs[i], out)
}

assets_Group_Command :: proc(v: ^Group_Command, out: ^[dynamic]core.Asset_GUID) {
	for i in 0 ..< len(v.subs) do _command_assets(&v.subs[i], out)
}

describe_Group_Command :: proc(v: ^Group_Command, b: ^strings.Builder, depth: int) {
	fmt.sbprintf(b, "%sGroup (%d sub-commands)\n", _indent(depth), len(v.subs))
	for i in 0 ..< len(v.subs) do describe(&v.subs[i], b, depth + 1)
}

Selection_Scene_Item :: struct {
	scene:    Scene_Ref,
	local_id: core.Local_ID,
}

// Snapshot of the editor selection (both domains, ordered, last = active).
// Slices are owned by the command. Project items are full sub-asset refs —
// guid survives renames, local_id 0 = the asset itself, nonzero = a
// sub-asset (a sprite slice).
Selection_State :: struct {
	scene: []Selection_Scene_Item,
	proj:  []core.PPtr,
	// While the project holds the selection, the objects the Inspector keeps
	// showing (the editor's two-inspector layout). Restored with the rest, so
	// an undo brings back what both panels showed. Not part of equality: it
	// only changes when the selection itself moves.
	kept:  []Selection_Scene_Item,
}

// A selection change as its own undo step (Unity model): undo applies
// `before`, redo applies `after`. Restoration goes through the editor-side
// hook installed with set_selection_hooks.
@(undo_command)
Selection_Command :: struct {
	before: Selection_State,
	after:  Selection_State,
}

apply_Selection_Command :: proc(v: ^Selection_Command) {
	_selection_apply(v.after)
}

revert_Selection_Command :: proc(v: ^Selection_Command) {
	_selection_apply(v.before)
}

destroy_Selection_Command :: proc(v: ^Selection_Command) {
	selection_state_destroy(&v.before)
	selection_state_destroy(&v.after)
}

label_Selection_Command :: proc(v: ^Selection_Command) -> string {
	return "Select"
}

// The scenes the selection names. A selection step is purged with them, but
// never dirties them (_mark_scenes_dirty skips selection steps).
scenes_Selection_Command :: proc(v: ^Selection_Command, out: ^[dynamic]core.Scene_Ref) {
	for it in v.before.scene do append(out, it.scene)
	for it in v.after.scene do append(out, it.scene)
}

describe_Selection_Command :: proc(v: ^Selection_Command, b: ^strings.Builder, depth: int) {
	fmt.sbprintf(b, "%sSelection change\n", _indent(depth))
	_append_selection_state(b, "before", v.before, depth + 1)
	_append_selection_state(b, "after", v.after, depth + 1)
}

// Marks a type as an undo command: a struct with apply_<Name>, revert_<Name>,
// destroy_<Name> and label_<Name> procs in its file, and optional
// scenes_<Name>, assets_<Name> and describe_<Name>. The prebuild joins every
// marked type into Command and writes the dispatch
// (undo_command_generated.odin). A command's package works on its own world
// and must not import undo, the stack drives it.
@(extension_point={attribute="undo_command", target="type", fields=""})
Entry :: struct {
	label:   string,
	cmd:     Command,
	in_play: bool, // recorded during the current Play run (play_begin/play_end)
}

Undo_Stack :: struct {
	items:      [dynamic]Entry,
	top:        int,
	txn_stack:  [dynamic]Group_Command,
	recording:  bool,
	applying:   bool,
	// Set by every stack mutation (push, undo/redo, clear, purge); consumed
	// once per frame by the editor's selection tracker so selection changes
	// caused by data operations don't also record as selection steps.
	activity:   bool,
	// A new top-level entry landed (a push outside any group, or a group
	// closing). `disturbed` is any other mutation: undo, redo, clear, purge.
	// A frame that only landed is one where a selection change belongs to the
	// operation that just ran (a create that selects what it made), and the
	// tracker attaches it to that entry (amend_top_selection) instead of
	// dropping it.
	landed:     bool,
	disturbed:  bool,
	// Between play_begin and play_end: undo and redo move only through
	// entries recorded in this run (Entry.in_play).
	playing:    bool,
}

init :: proc(s: ^Undo_Stack) {
	s.items = make([dynamic]Entry)
	s.txn_stack = make([dynamic]Group_Command)
	s.recording = true
}

clear :: proc(s: ^Undo_Stack) {
	if s == nil do return
	for &e in s.items {
		_entry_destroy(&e)
	}
	builtin.clear(&s.items)
	for &g in s.txn_stack {
		_group_destroy(&g)
	}
	builtin.clear(&s.txn_stack)
	s.top = 0
	s.activity = true
	s.disturbed = true
}

destroy :: proc(s: ^Undo_Stack) {
	if s == nil do return
	clear(s)
	delete(s.items)
	delete(s.txn_stack)
	s.items = {}
	s.txn_stack = {}
	inspector_shutdown()
}

set_recording :: proc(s: ^Undo_Stack, on: bool) {
	s.recording = on
}

is_applying :: proc(s: ^Undo_Stack) -> bool {
	return s != nil && s.applying
}

// Where the current stack is kept. The owner of the user context installs it
// (scene_undo keeps one stack per engine user context). Without it there is
// no current stack: get returns nil and install does nothing.
@(private) _stack_slot: proc() -> ^rawptr

set_stack_slot :: proc(fn: proc() -> ^rawptr) {
	_stack_slot = fn
}

get :: proc() -> ^Undo_Stack {
	if _stack_slot == nil do return nil
	slot := _stack_slot()
	if slot == nil do return nil
	return (^Undo_Stack)(slot^)
}

install :: proc(s: ^Undo_Stack) {
	if _stack_slot == nil do return
	slot := _stack_slot()
	if slot == nil do return
	slot^ = rawptr(s)
}

push :: proc(s: ^Undo_Stack, cmd: Command, label := "") {
	if s == nil do return
	if !s.recording || s.applying do return
	s.activity = true

	if len(s.txn_stack) > 0 {
		top_txn := &s.txn_stack[len(s.txn_stack) - 1]
		append(&top_txn.subs, cmd)
		return
	}
	s.landed = true

	for i := len(s.items) - 1; i >= s.top; i -= 1 {
		e := &s.items[i]
		_entry_destroy(e)
		ordered_remove(&s.items, i)
	}

	for len(s.items) >= MAX_ENTRIES {
		e := &s.items[0]
		_entry_destroy(e)
		ordered_remove(&s.items, 0)
		if s.top > 0 do s.top -= 1
	}

	effective_label := label
	if effective_label == "" {
		c := cmd
		effective_label = default_label(&c)
	}
	append(&s.items, Entry{label = strings.clone(effective_label), cmd = cmd, in_play = s.playing})
	s.top = len(s.items)
	_mark_scenes_dirty(&s.items[len(s.items) - 1].cmd)
}

// Every scene a command touches is edited by it, whether the command is
// being recorded, undone or redone. Selection commands touch none, and asset
// value commands mark their document instead (asset_docs). A scene that has
// been unloaded since is skipped by the validity check.
@(private)
_mark_scenes_dirty :: proc(cmd: ^Command) {
	// A selection step names scenes but edits none. A group walks its subs so
	// that a selection inside it is skipped the same way.
	#partial switch &v in cmd {
	case Selection_Command:
		return
	case Group_Command:
		for i in 0 ..< len(v.subs) do _mark_scenes_dirty(&v.subs[i])
		return
	}
	refs := make([dynamic]core.Scene_Ref, context.temp_allocator)
	_command_scenes(cmd, &refs)
	for r in refs do scene_mark_dirty(r)
}

jump_to :: proc(s: ^Undo_Stack, target_top: int) -> bool {
	if s == nil do return false
	if target_top < 0 || target_top > len(s.items) do return false
	// While playing only this run's steps move, so a jump past them does
	// nothing rather than stopping halfway.
	if s.playing {
		for i in min(target_top, s.top) ..< max(target_top, s.top) {
			if !s.items[i].in_play do return false
		}
	}
	for s.top > target_top {
		if !apply_undo(s) do return false
	}
	for s.top < target_top {
		if !apply_redo(s) do return false
	}
	return true
}

begin_group_command :: proc(s: ^Undo_Stack, label := "") {
	if s == nil do return
	if !s.recording || s.applying do return
	append(&s.txn_stack, Group_Command{subs = make([dynamic]Command)})
}

abort_group_command :: proc(s: ^Undo_Stack) {
	if s == nil do return
	if len(s.txn_stack) == 0 do return
	grp := s.txn_stack[len(s.txn_stack) - 1]
	pop(&s.txn_stack)
	_group_destroy(&grp)
}

end_group_command :: proc(s: ^Undo_Stack, label := "") {
	if s == nil do return
	if len(s.txn_stack) == 0 do return
	grp := s.txn_stack[len(s.txn_stack) - 1]
	pop(&s.txn_stack)

	if len(grp.subs) == 0 {
		delete(grp.subs)
		return
	}

	if len(s.txn_stack) > 0 {
		outer := &s.txn_stack[len(s.txn_stack) - 1]
		append(&outer.subs, Command(grp))
		return
	}

	for i := len(s.items) - 1; i >= s.top; i -= 1 {
		e := &s.items[i]
		_entry_destroy(e)
		ordered_remove(&s.items, i)
	}
	for len(s.items) >= MAX_ENTRIES {
		e := &s.items[0]
		_entry_destroy(e)
		ordered_remove(&s.items, 0)
		if s.top > 0 do s.top -= 1
	}
	// Clone like push() does — _entry_destroy deletes the label, and group
	// labels are usually string literals.
	append(&s.items, Entry{label = strings.clone(label), cmd = Command(grp), in_play = s.playing})
	s.top = len(s.items)
	s.activity = true
	s.landed = true
	// Lands outside push(), so the dirty mark is made here as well.
	_mark_scenes_dirty(&s.items[len(s.items) - 1].cmd)
}

can_undo :: proc(s: ^Undo_Stack) -> bool {
	if s == nil || s.top == 0 do return false
	return !s.playing || s.items[s.top - 1].in_play
}

entries :: proc(s: ^Undo_Stack) -> []Entry {
	if s == nil do return nil
	return s.items[:]
}

top_index :: proc(s: ^Undo_Stack) -> int {
	if s == nil do return 0
	return s.top
}

can_redo :: proc(s: ^Undo_Stack) -> bool {
	if s == nil || s.top >= len(s.items) do return false
	return !s.playing || s.items[s.top].in_play
}

// Play starts. From here until play_end, undo and redo only move through what
// this run records. An entry from before Play targets the edit-time scene,
// which Stop restores from its snapshot: undoing it on the running scene
// would change a scene Stop then replaces, and the stack would no longer
// match the scene it describes.
play_begin :: proc(s: ^Undo_Stack) {
	if s == nil do return
	s.playing = true
}

// Play ends, before Stop restores the scene. The run's scene edits go: they
// describe objects and values Stop replaces. The run's asset edits stay,
// since assets are not rolled back. Entries from before Play stay too: their
// targets find the restored scene by guid and their objects by local_id.
play_end :: proc(s: ^Undo_Stack) {
	if s == nil do return
	s.playing = false
	for i := len(s.items) - 1; i >= 0; i -= 1 {
		e := &s.items[i]
		if !e.in_play do continue
		e.in_play = false
		if !_command_refs_scene(&e.cmd, {}, true) do continue
		_entry_destroy(e)
		ordered_remove(&s.items, i)
		if i < s.top do s.top -= 1
	}
	s.activity = true
	s.disturbed = true
}

apply_undo :: proc(s: ^Undo_Stack) -> bool {
	if !can_undo(s) do return false
	s.activity = true
	s.disturbed = true
	s.applying = true
	defer s.applying = false
	s.top -= 1
	cmd := &s.items[s.top].cmd
	_revert_command(cmd)
	return true
}

apply_redo :: proc(s: ^Undo_Stack) -> bool {
	if !can_redo(s) do return false
	s.activity = true
	s.disturbed = true
	s.applying = true
	defer s.applying = false
	cmd := &s.items[s.top].cmd
	_apply_command(cmd)
	s.top += 1
	return true
}

@(private)
_entry_destroy :: proc(e: ^Entry) {
	delete(e.label)
	_command_destroy(&e.cmd)
}

@(private)
_group_destroy :: proc(g: ^Group_Command) {
	for i in 0 ..< len(g.subs) {
		_command_destroy(&g.subs[i])
	}
	delete(g.subs)
}

resolve_target_ptr :: proc(t: Property_Target) -> rawptr {
	switch t.kind {
	case .None:
		return nil
	case .Raw:
		if t.raw_ptr == nil do return nil
		return rawptr(uintptr(t.raw_ptr) + uintptr(t.offset))
	case .Pooled:
		base, _, ok := resolve_pooled_base(t)
		if !ok do return nil
		return rawptr(uintptr(base) + uintptr(t.offset))
	case .Asset:
		return nil // applied through the asset hook, never via pointer
	}
	return nil
}

// The live base pointer of a pooled target, through the installed resolver
// (target_resolver.odin).
resolve_pooled_base :: proc(t: Property_Target) -> (rawptr, core.Handle, bool) {
	if t.kind != .Pooled || _resolver.pooled_base == nil do return nil, {}, false
	return _resolver.pooled_base(t)
}

resolve_component_base :: proc(t: Property_Target) -> (rawptr, core.Handle, bool) {
	if t.kind != .Pooled || t.handle.type_key == core.transform_type_key do return nil, {}, false
	return resolve_pooled_base(t)
}

make_pooled_target :: proc(h: core.Handle, offset: uintptr, tid: typeid) -> Property_Target {
	scene: core.Scene_Ref
	lid: core.Local_ID
	if _resolver.pooled_identity != nil {
		if sc, l, ok := _resolver.pooled_identity(h); ok {
			scene = sc
			lid = l
		}
	}
	return Property_Target{
		kind = .Pooled,
		scene = scene,
		local_id = lid,
		handle = h,
		offset = u32(offset),
		type_id = tid,
	}
}

make_transform_target :: proc(tH: core.Transform_Handle, offset: uintptr, tid: typeid) -> Property_Target {
	return make_pooled_target(core.Handle(tH), offset, tid)
}

make_component_target :: proc(comp_handle: core.Handle, offset: uintptr, tid: typeid) -> Property_Target {
	return make_pooled_target(comp_handle, offset, tid)
}

make_raw_target :: proc(ptr: rawptr, offset: uintptr, tid: typeid) -> Property_Target {
	return Property_Target{
		kind = .Raw,
		raw_ptr = ptr,
		offset = u32(offset),
		type_id = tid,
	}
}

capture_json :: proc(ptr: rawptr, tid: typeid) -> []byte {
	if ptr == nil || tid == nil do return nil
	opts := json.Marshal_Options{spec = .JSON, pretty = false}
	data, err := json.marshal(any{ptr, tid}, opts)
	if err != nil {
		log.error(fmt.tprintf("undo: marshal failed for %v: %v", tid, err))
		return nil
	}
	return data
}

push_value :: proc(s: ^Undo_Stack, t: Property_Target, old_json, new_json: []byte, label := "") {
	if s == nil do return
	if !s.recording || s.applying {
		if old_json != nil do delete(old_json)
		if new_json != nil do delete(new_json)
		return
	}
	if old_json == nil || new_json == nil {
		if old_json != nil do delete(old_json)
		if new_json != nil do delete(new_json)
		return
	}
	if slice.equal(old_json, new_json) {
		delete(old_json)
		delete(new_json)
		return
	}
	cmd: Value_Command = {target = t, old_json = old_json, new_json = new_json}
	push(s, Command(cmd), label)
}

@(private)
_value_apply :: proc(vc: Value_Command, json_bytes: []byte) {
	if vc.target.kind == .Asset {
		if _asset_apply_hook == nil {
			log.error("undo: no asset apply hook installed (inspector init missing?)")
			return
		}
		if !_asset_apply_hook(vc.target.asset_guid, vc.target.asset_doc, json_bytes) {
			log.error(fmt.tprintf("undo: asset apply failed (guid=%v)", vc.target.asset_guid))
		}
		return
	}
	ptr := resolve_target_ptr(vc.target)
	if ptr == nil {
		log.error(fmt.tprintf("undo: failed to resolve target for value command (tid=%v)", vc.target.type_id))
		return
	}
	if !write_json_value(ptr, vc.target.type_id, json_bytes, vc.target.scene) {
		return
	}

	if vc.target.kind == .Pooled && vc.target.handle.type_key != core.transform_type_key {
		if base, h, ok := resolve_pooled_base(vc.target); ok {
			core.type_on_validate(h.type_key, base)
		}
	}
}

// Writes a captured value (capture_json output) into a live field, replacing
// whatever it holds. THE way to assign a field of arbitrary type: it releases
// the old value's heap memory, unmarshals a FRESH copy of the payload — so the
// destination shares no backing storage with the source — and rebinds any
// reference handles inside it.
//
// `scene` is the scene the field lives in, for that rebinding, done by the
// installed resolver. A zero scene skips it, which is right for values that
// hold no references.
//
// Used by undo to apply a Value_Command, and by multi-edit to copy one committed
// field onto the rest of a selection. Both need identical semantics, and having
// one implementation is what stops them drifting.
//
// A decode failure is logged as an error: for those callers the payload was
// captured from a live field, so it cannot legitimately fail to decode. A
// caller whose bytes come from outside (an MCP property write) passes `quiet`
// and reports the refusal itself — a bad value there is input, not a fault.
write_json_value :: proc(ptr: rawptr, tid: typeid, json_bytes: []byte, scene: core.Scene_Ref, quiet := false) -> bool {
	if ptr == nil || tid == nil || json_bytes == nil do return false
	ptr_tid, ok := core.get_pointer_typeid_by_typeid(tid)
	if !ok {
		log.error(fmt.tprintf("undo: no pointer typeid registered for %v — call engine.register_pointer_type during init", tid))
		return false
	}

	_cleanup_before_unmarshal(ptr, tid)

	target_ptr := ptr
	target_any := any{data = &target_ptr, id = ptr_tid}
	if err := json.unmarshal_any(json_bytes, target_any, json.DEFAULT_SPECIFICATION, context.allocator); err != nil {
		if !quiet do log.error(fmt.tprintf("undo: unmarshal failed (tid=%v): %v", tid, err))
		return false
	}

	// The payload carries only PPtr data — Handle fields are json:"-", so
	// unmarshal leaves whatever handle the pre-apply value had (zero after a
	// load, RESOLVED after a prior undo). Authoritative mode derives handles
	// entirely from the payload: bound when the lid resolves, cleared when
	// the payload says none.
	if scene.id != 0 && _resolver.fixup_refs != nil {
		_resolver.fixup_refs(ptr, tid, scene)
	}
	return true
}

@(private)
_cleanup_before_unmarshal :: proc(ptr: rawptr, tid: typeid) {
	if ptr == nil do return
	if tid == typeid_of(string) {
		s := cast(^string)ptr
		if len(s^) > 0 do delete(s^)
		s^ = ""
		return
	}
	if key, ok := core.get_type_key_by_typeid(tid); ok {
		core.type_cleanup(key, ptr)
	}
}

// --- Editor hooks -------------------------------------------------------------
// The undo package sits below the editor (it may not import selection or the
// inspector), so restoration of editor-level state goes through hooks
// installed at startup. Unset hooks degrade to no-ops (tests, headless).

@(private) _selection_capture_hook: proc() -> Selection_State
@(private) _selection_apply_hook:   proc(state: Selection_State)
@(private) _asset_apply_hook:       proc(guid: core.Asset_GUID, doc: Doc_Kind, json_bytes: []byte) -> bool

set_selection_hooks :: proc(capture: proc() -> Selection_State, apply: proc(state: Selection_State)) {
	_selection_capture_hook = capture
	_selection_apply_hook = apply
}

// cb replaces the whole asset document identified by guid with the given
// JSON payload (installed by the project inspector's doc registry).
set_asset_apply :: proc(cb: proc(guid: core.Asset_GUID, doc: Doc_Kind, json_bytes: []byte) -> bool) {
	_asset_apply_hook = cb
}

@(private)
_selection_apply :: proc(state: Selection_State) {
	if _selection_apply_hook != nil do _selection_apply_hook(state)
}

make_asset_target :: proc(guid: core.Asset_GUID, tid: typeid, doc := Doc_Kind.File) -> Property_Target {
	return Property_Target{kind = .Asset, asset_guid = guid, asset_doc = doc, type_id = tid}
}

// --- Selection state helpers ----------------------------------------------------

selection_state_destroy :: proc(st: ^Selection_State) {
	if st.scene != nil do delete(st.scene)
	if st.proj != nil do delete(st.proj)
	if st.kept != nil do delete(st.kept)
	st^ = {}
}

selection_state_equal :: proc(a, b: Selection_State) -> bool {
	if len(a.scene) != len(b.scene) || len(a.proj) != len(b.proj) do return false
	for it, i in a.scene {
		if it != b.scene[i] do return false
	}
	for p, i in a.proj {
		if p != b.proj[i] do return false
	}
	return true
}

// Pushes one selection step. Takes OWNERSHIP of both states on every path
// (pushed, skipped as equal, or dropped because recording is off).
push_selection :: proc(s: ^Undo_Stack, before, after: Selection_State, label := "") {
	b := before
	a := after
	if s == nil || !s.recording || s.applying || selection_state_equal(b, a) {
		selection_state_destroy(&b)
		selection_state_destroy(&a)
		return
	}
	push(s, Command(Selection_Command{before = b, after = a}), label)
}

// For structural groups that consume the selection (delete/duplicate): push a
// selection step whose `before` is the current selection and `after` is empty.
// Push it FIRST inside the group, so group revert (which walks subs in
// reverse) restores the selection only after the objects are back.
record_selection_snapshot :: proc() {
	s := get()
	if s == nil || !s.recording || s.applying do return
	if _selection_capture_hook == nil do return
	before := _selection_capture_hook()
	if len(before.scene) == 0 && len(before.proj) == 0 {
		selection_state_destroy(&before)
		return
	}
	push(s, Command(Selection_Command{before = before}))
}

// True once after any stack mutation since the last call. The editor's
// per-frame selection tracker uses this to re-baseline instead of recording.
activity_consume :: proc(s: ^Undo_Stack) -> bool {
	if s == nil do return false
	res := s.activity
	s.activity = false
	s.landed = false
	s.disturbed = false
	return res
}

// The tracker's once-per-frame read: whether anything mutated the stack, and
// whether the only thing that happened is new entries landing. Clears all.
activity_take :: proc(s: ^Undo_Stack) -> (activity: bool, only_landed: bool) {
	if s == nil do return false, false
	activity = s.activity
	only_landed = s.landed && !s.disturbed
	s.activity = false
	s.landed = false
	s.disturbed = false
	return
}

// Attaches a selection change to the entry that just landed, so one undo
// takes back both: the operation and what it selected. A create that selects
// what it made, a paste that selects what it pasted. The selection goes LAST
// in the group: revert walks subs in reverse, so the old selection comes back
// while the objects it names still exist, and redo re-applies the selection
// after the operation has recreated what it names. Takes ownership of both
// states. Does nothing (frees them) when there is no fresh top entry.
amend_top_selection :: proc(s: ^Undo_Stack, before, after: Selection_State) {
	b, a := before, after
	if s == nil || !s.recording || s.applying || len(s.items) == 0 || s.top != len(s.items) || selection_state_equal(b, a) {
		selection_state_destroy(&b)
		selection_state_destroy(&a)
		return
	}
	e := &s.items[len(s.items) - 1]
	sel := Command(Selection_Command{before = b, after = a})
	if g, is_group := &e.cmd.(Group_Command); is_group {
		append(&g.subs, sel)
		return
	}
	grp := Group_Command{subs = make([dynamic]Command, 0, 2)}
	append(&grp.subs, e.cmd, sel)
	e.cmd = Command(grp)
}

// --- History view details ------------------------------------------------------

@(private)
_append_selection_state :: proc(b: ^strings.Builder, name: string, st: Selection_State, depth: int) {
	indent := _indent(depth)
	fmt.sbprintf(b, "%s%s: %d scene, %d project\n", indent, name, len(st.scene), len(st.proj))
	for it in st.scene {
		resolved := "unresolved"
		if n, ok := object_name(it.scene, it.local_id); ok do resolved = n
		fmt.sbprintf(b, "%s  local_id=%d  %s\n", indent, i64(it.local_id), resolved)
	}
	for r in st.proj {
		path := "(deleted)"
		if p, ok := asset_path(r.guid); ok do path = p
		if r.local_id != 0 {
			fmt.sbprintf(b, "%s  %s : sub %d\n", indent, path, i64(r.local_id))
		} else {
			fmt.sbprintf(b, "%s  %s\n", indent, path)
		}
	}
}

@(private)
_append_target :: proc(b: ^strings.Builder, t: Property_Target, depth: int) {
	indent := _indent(depth)
	kind_str: string
	switch t.kind {
	case .None:   kind_str = "None"
	case .Pooled: kind_str = t.handle.type_key == core.transform_type_key ? "Transform" : "Component"
	case .Raw:    kind_str = "Raw"
	case .Asset:  kind_str = "Asset"
	}
	fmt.sbprintf(b, "%starget: kind=%s local_id=%d handle=%d:%d:%d offset=%d type=%v\n",
		indent, kind_str, i64(t.local_id),
		t.handle.index, t.handle.generation, t.handle.type_key,
		t.offset, t.type_id)

	resolved := "unresolved"
	switch t.kind {
	case .None:
	case .Raw:
		if t.raw_ptr != nil do resolved = "raw"
	case .Asset:
		if path, ok := asset_path(t.asset_guid); ok do resolved = path
	case .Pooled:
		// The resolver re-finds the object by scene and local id, so entries
		// stay resolvable after undo/redo recreated it under a fresh handle.
		if n, ok := target_name(t); ok do resolved = n
	}
	fmt.sbprintf(b, "%s  resolved: %s\n", indent, resolved)
}

@(private)
_indent :: proc(depth: int) -> string {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	for _ in 0 ..< depth {
		strings.write_string(&b, "  ")
	}
	return strings.to_string(b)
}

@(private)
_truncate :: proc(s: string, max: int) -> string {
	if len(s) <= max do return s
	return fmt.tprintf("%s ...(%d bytes)", s[:max], len(s))
}

// --- Purge ----------------------------------------------------------------------
// Scene load/unload no longer wipes the whole history: only entries that
// reference the affected scene(s) are dropped. Asset edits and pure project
// selection steps survive scene navigation.

// Whether the command touches the scene `r` (any scene at all with
// `any_scene`).
@(private)
_command_refs_scene :: proc(cmd: ^Command, r: core.Scene_Ref, any_scene: bool) -> bool {
	refs := make([dynamic]core.Scene_Ref, context.temp_allocator)
	_command_scenes(cmd, &refs)
	for ref in refs {
		if ref.id == 0 do continue
		if any_scene || ref.id == r.id do return true
	}
	return false
}

@(private)
_purge :: proc(s: ^Undo_Stack, r: core.Scene_Ref, any_scene: bool) {
	if s == nil do return
	for i := len(s.items) - 1; i >= 0; i -= 1 {
		if !_command_refs_scene(&s.items[i].cmd, r, any_scene) do continue
		e := &s.items[i]
		_entry_destroy(e)
		ordered_remove(&s.items, i)
		if i < s.top do s.top -= 1
	}
	s.activity = true
	s.disturbed = true
}

// Drop entries that reference this scene. Call BEFORE unloading.
purge_scene :: proc(s: ^Undo_Stack, r: core.Scene_Ref) {
	if r.id == 0 do return
	_purge(s, r, false)
}

// Drop entries that reference ANY scene (single-scene loads unload everything);
// asset edits and project-only selection steps survive.
purge_scenes :: proc(s: ^Undo_Stack) {
	_purge(s, {}, true)
}

@(private)
_command_refs_asset :: proc(cmd: ^Command, guid: core.Asset_GUID) -> bool {
	guids := make([dynamic]core.Asset_GUID, context.temp_allocator)
	_command_assets(cmd, &guids)
	for g in guids do if g == guid do return true
	return false
}

// Drop entries that edit this asset's document. Call when the asset left the
// project: undoing one would bring back a document for a missing file. A
// group goes whole if any sub-command edits the asset, like purge_scene.
purge_asset :: proc(s: ^Undo_Stack, guid: core.Asset_GUID) {
	if s == nil || core.asset_guid_is_empty(guid) do return
	removed := false
	for i := len(s.items) - 1; i >= 0; i -= 1 {
		if !_command_refs_asset(&s.items[i].cmd, guid) do continue
		_entry_destroy(&s.items[i])
		ordered_remove(&s.items, i)
		if i < s.top do s.top -= 1
		removed = true
	}
	if removed {
		s.activity = true
		s.disturbed = true
	}
}
