package inspector

// Import settings as documents: one per asset, the typed settings from its
// .meta, shared by every editor that shows or edits them (the import settings
// inspector, the model clip rows, the Sprite Editor). They live in the asset
// document registry (asset_docs.odin) under Doc_Kind.Import_Settings.
//
// - Nothing reaches the disk until Apply (import_settings_apply), which writes
//   the .meta and reimports. Revert (import_settings_revert) reloads the .meta
//   as one undo step. File/Save leaves them alone.
// - Undo needs no code in the editors: import_settings_track compares every
//   document shown or edited since the last compare with its baseline, and
//   turns a change into one undo step. The main loop calls it with check=true
//   only on frames where an edit may have just finished (a widget let go, a
//   mouse button up, a key press), so a drag, a typed name or a Slice button
//   press is one step and idle frames cost nothing.
// - Dirty means "differs from the .meta", so undoing back to the applied
//   state clears it.
// - A reimport may rewrite the .meta itself (the model importer adds entries
//   for new clips). A document with no unapplied edits then reloads
//   (_import_settings_reimported), so the next Apply does not write the old
//   version back.
// - The document outlives frames, so its fields use the default allocator.
//   Bytes handed to undo use the caller's allocator, like every undo entry.

import "base:runtime"
import "core:encoding/json"
import "core:encoding/uuid"
import "core:fmt"
import "core:slice"
import "core:strings"
import engine "../../engine"
import "../../engine/log"
import "moonhug:engine_editor/asset_pipeline"
import "../undo"

// The import settings document for an asset, loaded from its .meta on first
// use. nil when the asset has no import settings. Marks the document as shown
// this frame, which is what import_settings_track looks at.
import_settings_doc_get :: proc(path: string) -> ^Asset_Doc {
	context.allocator = runtime.default_allocator()
	raw, ok := engine.asset_db_get_guid(path)
	if !ok do return nil
	key := Doc_Key{engine.Asset_GUID(raw), .Import_Settings}
	if doc, found := _docs[key]; found {
		if doc.path != path {
			delete(doc.path)
			doc.path = strings.clone(path)
		}
		doc.touched = true
		return doc
	}
	settings, sok := engine.asset_pipeline_get_settings(path)
	if !sok do return nil
	doc := new(Asset_Doc)
	doc^ = Asset_Doc{
		guid    = key.guid,
		kind    = .Import_Settings,
		path    = strings.clone(path),
		data    = settings,
		touched = true,
	}
	doc.applied = _settings_json(settings)
	doc.baseline = slice.clone(doc.applied)
	if _docs == nil do _docs = make(map[Doc_Key]^Asset_Doc)
	_docs[key] = doc
	return doc
}

// Apply: writes the document into the .meta and reimports. The document
// stays, now equal to the .meta.
import_settings_apply :: proc(doc: ^Asset_Doc) -> bool {
	context.allocator = runtime.default_allocator()
	if doc == nil || doc.data.data == nil do return false
	path, known := engine.asset_db_get_path(uuid.Identifier(doc.guid))
	if !known do return false
	if path != doc.path {
		delete(doc.path)
		doc.path = strings.clone(path)
	}
	if !asset_pipeline.asset_pipeline_save_settings(path, doc.data) do return false
	delete(doc.applied)
	doc.applied = _settings_json(doc.data)
	doc.dirty = false
	// Clean before the reimport: the importer may refine the .meta, and the
	// reimport hook then reloads this document. The hooks also evict every
	// guid-keyed cache (textures, package asset caches), so the new settings
	// apply without a restart.
	asset_pipeline.asset_pipeline_reimport(path)
	return true
}

// Revert: back to the .meta, as one undo step. The replaced instance is not
// freed: the caller may be drawing it this frame (a Revert button inside the
// drawer), the same reason undo leaves the old instance of an asset document.
import_settings_revert :: proc(doc: ^Asset_Doc) {
	if doc == nil do return
	settings, ok := engine.asset_pipeline_get_settings(doc.path, runtime.default_allocator())
	if !ok do return
	before := _settings_json(doc.data, context.allocator)
	doc_data_release(doc.data)
	doc.data = settings
	after := _settings_json(doc.data, context.allocator)
	undo.push_value(undo.get(), undo.make_asset_target(doc.guid, doc.data.id, .Import_Settings), before, after, "Revert Import Settings")
	_import_settings_rebaseline(doc)
}

// After any reimport of the asset. The replaced instance is not freed, for the
// same reason as in Revert.
@(private = "file")
_import_settings_reimported :: proc(guid: engine.Asset_GUID) {
	context.allocator = runtime.default_allocator()
	doc, found := _docs[Doc_Key{guid, .Import_Settings}]
	if !found || doc.dirty do return
	settings, ok := engine.asset_pipeline_get_settings(doc.path)
	if !ok do return
	doc_data_release(doc.data)
	doc.data = settings
	delete(doc.applied)
	doc.applied = _settings_json(doc.data)
	_import_settings_rebaseline(doc)
}

@(init)
_import_settings_register :: proc "contextless" () {
	context = runtime.default_context()
	engine.asset_pipeline_add_reimport_hook(_import_settings_reimported)
}

// Once per frame, after every view drew. With `check` set (the main loop's
// "an edit may have just finished", true in tests), a document shown or edited
// since the last compare whose JSON differs from its baseline becomes one undo
// step. Without it nothing is compared, and the shown documents wait for the
// next compare.
import_settings_track :: proc(check: bool) {
	if !check do return
	for _, doc in _docs {
		if doc.kind != .Import_Settings || !doc.touched do continue
		doc.touched = false
		cur := _settings_json(doc.data, runtime.default_allocator())
		defer delete(cur, runtime.default_allocator())
		if string(cur) != string(doc.baseline) {
			undo.push_value(
				undo.get(), undo.make_asset_target(doc.guid, doc.data.id, .Import_Settings),
				slice.clone(doc.baseline), slice.clone(cur), "Edit Import Settings",
			)
			_import_settings_rebaseline(doc)
		}
	}
}

// Undo/redo of an import settings step: a fresh instance from the step's JSON
// (so dynamic arrays never merge with stale contents), then a new baseline, so
// the tracker does not record the restore itself.
@(private)
_import_settings_apply_json :: proc(guid: engine.Asset_GUID, json_bytes: []byte) -> bool {
	context.allocator = runtime.default_allocator()
	doc, found := _docs[Doc_Key{guid, .Import_Settings}]
	if !found {
		path, path_ok := engine.asset_db_get_path(uuid.Identifier(guid))
		if !path_ok do return false
		doc = import_settings_doc_get(path)
		if doc == nil do return false
	}
	tid := doc.data.id
	fresh := engine.create_zero_instance_by_guid(engine.get_guid_by_typeid(tid))
	ptr_tid, ptr_ok := engine.get_pointer_typeid_by_typeid(tid)
	if fresh.data == nil || !ptr_ok {
		log.error(fmt.tprintf("import settings: cannot rebuild %v", tid))
		return false
	}
	pp := fresh.data
	if err := json.unmarshal_any(json_bytes, any{&pp, ptr_tid}); err != nil {
		log.error(fmt.tprintf("import settings: unmarshal failed for %s: %v", doc.path, err))
		return false
	}
	engine.type_on_validate_by_typeid(tid, fresh.data)
	doc_data_release(doc.data)
	doc.data = fresh
	_import_settings_rebaseline(doc)
	return true
}

@(private = "file")
_import_settings_rebaseline :: proc(doc: ^Asset_Doc) {
	context.allocator = runtime.default_allocator()
	delete(doc.baseline)
	doc.baseline = _settings_json(doc.data)
	doc.dirty = string(doc.baseline) != string(doc.applied)
}

// Sorted map keys: a clip's settings are a JSON object, and without sorting the
// same value could marshal in a different order and read as a change.
@(private = "file")
_settings_json :: proc(settings: any, allocator := context.allocator) -> []byte {
	data, err := json.marshal(settings, {spec = .JSON, sort_maps_by_key = true}, allocator)
	if err != nil {
		log.error(fmt.tprintf("import settings: marshal failed for %v: %v", settings.id, err))
		return nil
	}
	return data
}
