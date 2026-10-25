package inspector

// Working copies (docs/core/Views.md): an editor that applies its edits all
// at once loads a copy of what it edits, an asset's file or its import
// settings (the .meta), and works on it through a handle. Nothing else sees
// the copy until Apply writes it to the file, and the asset's shared document
// follows. The Sprite Editor keeps one of a texture's import settings.
//
// - The copy starts from the file on disk. Dirty means "differs from it".
// - Undo needs no code in the editors: asset_doc_copies_track compares every
//   copy shown or edited since the last compare with its baseline, and turns
//   a change into one step on the one undo queue, which names the copy by its
//   handle.
// - A copy is an open document of the view that holds it (session.Document
//   view, asset_doc_owner.odin): its tab carries the star, its menu, File/Save
//   and the quit prompt apply or discard it, and the view asks before it
//   closes with unapplied edits.
// - Close drops the copy and its undo steps. Handles are never reused, so a
//   closed one finds nothing.
// - Copies outlive frames, so their values use the doc allocator.

import "base:runtime"
import "core:encoding/json"
import "core:encoding/uuid"
import "core:slice"
import "core:strings"
import assets "moonhug:libs/assets"
import core "moonhug:libs/core"
import ser "moonhug:libs/serialization"
import asset_pipeline "moonhug:editor/assets"
import "../undo"

// A working copy's handle. 0 is none.
Doc_Copy :: distinct u64

Asset_Doc_Copy :: struct {
	id:       Doc_Copy,
	guid:     core.Asset_GUID,
	kind:     undo.Doc_Kind, // .File: the asset's file, .Import_Settings: its .meta
	path:     string, // owned
	view:     string, // owned, the view that holds the copy, "" for none
	data:     any,    // the copy's value. Undo replaces it, so fetch it each frame
	dirty:    bool,   // differs from the file on disk
	touched:  bool,   // shown or edited since the last compare
	baseline: []byte, // the value as last recorded on the undo queue
	disk:     []byte, // the file on disk, as of the last load or Apply
}

@(private = "file")
_copies: map[Doc_Copy]^Asset_Doc_Copy

@(private = "file")
_copy_count: u64

// Opens a working copy of the asset at `path`: of its file (.File) or of its
// import settings (.Import_Settings), loaded from disk. `view` is the key of
// the view that holds it, for its tab and its close prompt. 0 when the asset
// or its file cannot be read.
asset_doc_copy_open :: proc(path: string, kind: undo.Doc_Kind, view := "") -> Doc_Copy {
	context.allocator = doc_alloc()
	raw, ok := assets.asset_db_get_guid(path)
	if !ok do return 0
	data, loaded := _copy_load(path, kind)
	if !loaded do return 0
	_copy_count += 1
	c := new(Asset_Doc_Copy)
	c^ = Asset_Doc_Copy{
		id      = Doc_Copy(_copy_count),
		guid    = core.Asset_GUID(raw),
		kind    = kind,
		path    = strings.clone(path),
		view    = strings.clone(view),
		data    = data,
		touched = true,
	}
	c.disk = _copy_json(c.data)
	c.baseline = slice.clone(c.disk)
	if _copies == nil do _copies = make(map[Doc_Copy]^Asset_Doc_Copy)
	_copies[c.id] = c
	return c.id
}

// The copy behind a handle, nil for a closed one. Marks it shown this frame,
// which is what asset_doc_copies_track looks at.
asset_doc_copy :: proc(h: Doc_Copy) -> ^Asset_Doc_Copy {
	c := _copies[h] or_else nil
	if c != nil do c.touched = true
	return c
}

// Writes the copy to the asset's file, through the asset's shared document:
// import settings write the .meta and reimport (import_settings_apply), a
// file saves (asset_doc_save). The shared document takes the copy's value as
// no undo step of its own. The copy then reloads from the file, so it matches
// what the importer made of it.
asset_doc_copy_apply :: proc(h: Doc_Copy) -> bool {
	context.allocator = doc_alloc()
	c := _copies[h] or_else nil
	if c == nil do return false
	path, known := assets.asset_db_get_path(uuid.Identifier(c.guid))
	if !known do return false
	if path != c.path {
		delete(c.path)
		c.path = strings.clone(path)
	}
	bytes := _copy_json(c.data, context.temp_allocator)
	written := false
	switch c.kind {
	case .Import_Settings:
		if import_settings_doc_get(path) == nil || !_import_settings_apply_json(c.guid, bytes) do return false
		written = import_settings_apply(import_settings_doc_get(path))
	case .File:
		if asset_doc_get(path) == nil || !asset_doc_apply_json(c.guid, .File, bytes) do return false
		written = asset_doc_save(asset_doc_get(path))
	}
	if written do _copy_reload(c)
	return written
}

// Back to the file on disk, as one undo step on the copy.
asset_doc_copy_revert :: proc(h: Doc_Copy) {
	c := _copies[h] or_else nil
	if c == nil do return
	before := _copy_json(c.data, context.allocator)
	if !_copy_reload(c) {
		delete(before)
		return
	}
	after := _copy_json(c.data, context.allocator)
	undo.push_value(undo.get(), _copy_target(c), before, after, _copy_label(c))
}

// Drops the copy's unapplied edits and its undo steps: it is the file on
// disk again. The handle stays open.
asset_doc_copy_discard :: proc(h: Doc_Copy) {
	c := _copies[h] or_else nil
	if c == nil do return
	undo.purge_asset_copy(undo.get(), u64(c.id))
	_copy_reload(c)
}

// Frees the copy and drops its undo steps. Its edits are gone.
asset_doc_copy_close :: proc(h: Doc_Copy) {
	c := _copies[h] or_else nil
	if c == nil do return
	// Undo steps free with the caller's allocator, like every undo entry: the
	// purge runs before the copy's own allocator takes over.
	undo.purge_asset_copy(undo.get(), u64(c.id))
	context.allocator = doc_alloc()
	delete_key(&_copies, h)
	doc_data_retire(c.data)
	_copy_free_fields(c)
	free(c)
}

// Once per frame, after every view drew, with the same `check` as
// import_settings_track: a copy shown or edited since the last compare whose
// value differs from its baseline becomes one undo step.
asset_doc_copies_track :: proc(check: bool) {
	if !check do return
	for _, c in _copies {
		if !c.touched do continue
		c.touched = false
		cur := _copy_json(c.data, runtime.default_allocator())
		defer delete(cur, runtime.default_allocator())
		if string(cur) == string(c.baseline) do continue
		undo.push_value(undo.get(), _copy_target(c), slice.clone(c.baseline), slice.clone(cur), _copy_label(c))
		_copy_rebaseline(c)
	}
}

// Every open copy, for the open documents list (asset_doc_owner.odin).
@(private)
_doc_copies :: proc(allocator := context.temp_allocator) -> []^Asset_Doc_Copy {
	out := make([dynamic]^Asset_Doc_Copy, 0, len(_copies), allocator)
	for _, c in _copies do append(&out, c)
	return out[:]
}

@(private)
_doc_copies_shutdown :: proc() {
	context.allocator = doc_alloc()
	for _, c in _copies {
		doc_data_release(c.data)
		_copy_free_fields(c)
		free(c)
	}
	delete(_copies)
	_copies = nil
}

// Undo and redo of a copy's step: a fresh value from the step's JSON, then a
// new baseline, so the tracker does not record the restore itself.
@(private = "file")
_copy_apply_json :: proc(copy: u64, json_bytes: []byte) -> bool {
	context.allocator = doc_alloc()
	c := _copies[Doc_Copy(copy)] or_else nil
	if c == nil do return false
	data, ok := _copy_unmarshal(c.data.id, json_bytes)
	if !ok do return false
	doc_data_retire(c.data)
	c.data = data
	_copy_rebaseline(c)
	return true
}

// After a reimport of an asset, its import settings copies with no unapplied
// edits reload, so they match what the importer wrote.
@(private = "file")
_copies_reimported :: proc(guid: core.Asset_GUID) {
	for _, c in _copies {
		if c.guid == guid && c.kind == .Import_Settings && !c.dirty do _copy_reload(c)
	}
}

@(init, private = "file")
_copies_register :: proc "contextless" () {
	context = runtime.default_context()
	undo.set_asset_copy_apply(_copy_apply_json)
	assets.asset_pipeline_add_reimport_hook(_copies_reimported)
}

// Loads the copy from the file again, clean. The replaced value is retired,
// not freed: the editor may be drawing it this frame (a Revert button).
@(private = "file")
_copy_reload :: proc(c: ^Asset_Doc_Copy) -> bool {
	context.allocator = doc_alloc()
	data, ok := _copy_load(c.path, c.kind)
	if !ok do return false
	doc_data_retire(c.data)
	c.data = data
	delete(c.disk)
	c.disk = _copy_json(c.data)
	_copy_rebaseline(c)
	return true
}

@(private = "file")
_copy_load :: proc(path: string, kind: undo.Doc_Kind) -> (any, bool) {
	context.allocator = doc_alloc()
	switch kind {
	case .Import_Settings: return asset_pipeline.import_settings_or_default(path)
	case .File:            return ser.load_from_file(path)
	}
	return {}, false
}

@(private = "file")
_copy_unmarshal :: proc(tid: typeid, json_bytes: []byte) -> (any, bool) {
	context.allocator = doc_alloc()
	fresh := core.create_zero_instance_by_guid(core.get_guid_by_typeid(tid))
	if fresh.data == nil do return {}, false
	if err := core.unmarshal_over_reset(json_bytes, fresh.data, tid); err != nil {
		doc_data_release(fresh)
		return {}, false
	}
	core.type_on_validate_by_typeid(tid, fresh.data)
	return fresh, true
}

@(private = "file")
_copy_rebaseline :: proc(c: ^Asset_Doc_Copy) {
	context.allocator = doc_alloc()
	delete(c.baseline)
	c.baseline = _copy_json(c.data)
	c.dirty = string(c.baseline) != string(c.disk)
}

// Sorted map keys: the same value always marshals to the same bytes, so a
// compare never reads a reordering as a change.
@(private = "file")
_copy_json :: proc(data: any, allocator := context.allocator) -> []byte {
	bytes, err := json.marshal(data, {spec = .JSON, sort_maps_by_key = true}, allocator)
	if err != nil do return nil
	return bytes
}

@(private = "file")
_copy_target :: proc(c: ^Asset_Doc_Copy) -> undo.Property_Target {
	return undo.make_asset_target(c.guid, c.data.id, c.kind, u64(c.id))
}

@(private = "file")
_copy_label :: proc(c: ^Asset_Doc_Copy) -> string {
	return "Edit Import Settings" if c.kind == .Import_Settings else "Edit Asset"
}

@(private = "file")
_copy_free_fields :: proc(c: ^Asset_Doc_Copy) {
	context.allocator = doc_alloc()
	delete(c.path)
	delete(c.view)
	delete(c.baseline)
	delete(c.disk)
}
