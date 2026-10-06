package inspector

// Asset document registry: the in-memory copy of every serialized asset
// (.mat/.asset) the project inspector has opened this session, keyed by
// asset GUID and document kind. The second kind, an asset's import settings,
// has its own procs in import_settings_docs.odin. Docs OUTLIVE the inspector's current selection — that is what
// lets asset edits participate in undo: a Value_Command with an .Asset
// target re-finds its document by GUID no matter what the inspector shows,
// and clicking around the project no longer invalidates (or clears) history.
//
// Undo/redo applies to the document, not the disk — same model as material
// live preview: Save persists, unsaved values revert next editor run.
//
// A document lives as long as its asset. Save writes to the asset's CURRENT
// path (looked up by guid), and deleting the asset drops the document and its
// undo steps (_asset_doc_gone), so no save or undo writes a deleted file back.
// Documents outlive frames, so every proc here pins the default allocator.

import "base:runtime"
import "core:encoding/json"
import "core:encoding/uuid"
import "core:fmt"
import "core:os"
import strings "core:strings"
import assets "moonhug:host/assets"
import core "moonhug:host/core"
import ser "moonhug:host/serialization"
import "moonhug:host/log"
import gfx "moonhug:host/gfx"
import "../undo"

Asset_Doc :: struct {
    guid:  core.Asset_GUID,
    kind:  undo.Doc_Kind,
    path:  string, // owned
    data:  any,
    dirty: bool,   // .File: edited since last save. .Import_Settings: differs from the .meta

    // .Import_Settings only (import_settings_docs.odin), default allocator.
    baseline: []byte, // JSON as of the last undo step
    applied:  []byte, // JSON as of the last load or Apply (the .meta)
    touched:  bool,   // shown or edited this frame
}

Doc_Key :: struct {
    guid: core.Asset_GUID,
    kind: undo.Doc_Kind,
}

@(private)
_docs: map[Doc_Key]^Asset_Doc

// Pushes an asset document's values into the runtime cache its asset is
// sampled from (the engine's material cache for materials), so an undone or
// redone document shows before it is saved. The engine and packages register
// one for their asset types at EditorInit. `doc` is the document's typed
// value, the registered typeid.
Doc_Preview :: proc(guid: core.Asset_GUID, doc: any)

@(private)
_doc_previews: map[typeid]Doc_Preview

// Process-global registry: never borrows the caller's allocator.
doc_preview_register :: proc(tid: typeid, p: Doc_Preview) {
    context.allocator = runtime.default_allocator()
    if _doc_previews == nil do _doc_previews = make(map[typeid]Doc_Preview)
    _doc_previews[tid] = p
}

// The open document for a path — reused if already loaded (unsaved edits
// survive clicking away and back), loaded from disk otherwise. nil on load
// failure or when the file isn't in the asset db.
asset_doc_get :: proc(path: string) -> ^Asset_Doc {
    context.allocator = runtime.default_allocator()
    raw_guid, ok := assets.asset_db_get_guid(path)
    if !ok do return nil
    guid := core.Asset_GUID(raw_guid)

    if doc, found := _docs[Doc_Key{guid, .File}]; found {
        // Follow renames: guid is stable, path may have changed.
        if doc.path != path {
            delete(doc.path)
            doc.path = strings.clone(path)
        }
        return doc
    }

    file_data, load_ok := ser.load_from_file(path)
    if !load_ok do return nil

    doc := new(Asset_Doc)
    doc.guid = guid
    doc.path = strings.clone(path)
    doc.data = file_data
    if _docs == nil do _docs = make(map[Doc_Key]^Asset_Doc)
    _docs[Doc_Key{guid, .File}] = doc
    return doc
}

// Writes the document to its file and clears the dirty flag. The one save
// path, whether the Project Inspector's Save button or an expanded row's.
// The path comes from the guid at write time, so a renamed or moved asset
// saves where it is now. An asset whose file is gone is not written: that
// would bring it back without its .meta, as a different asset.
asset_doc_save :: proc(doc: ^Asset_Doc) -> bool {
    context.allocator = runtime.default_allocator()
    if doc == nil || doc.data.data == nil do return false
    // An import settings document written here would land on the asset file
    // itself: those commit through import_settings_apply.
    assert(doc.kind == .File, "asset_doc_save: import settings commit through import_settings_apply")
    path, known := assets.asset_db_get_path(uuid.Identifier(doc.guid))
    if !known || !os.exists(path) {
        log.error(fmt.tprintf("asset_docs: %s is no longer in the project, not saved", doc.path))
        return false
    }
    if path != doc.path {
        delete(doc.path)
        doc.path = strings.clone(path)
    }
    if !ser.save_to_file(doc.path, doc.data) do return false
    doc.dirty = false
    return true
}

// Writes every document edited since its last save, wherever it was edited:
// the Project Inspector or an `expand` foldout under a component. This is
// what File/Save does, so one shortcut saves all pending asset edits. Import
// settings are not among them: those commit through Apply.
asset_docs_save_dirty :: proc() -> (saved, failed: int) {
    for _, doc in _docs {
        if !doc.dirty || doc.kind != .File do continue
        if asset_doc_save(doc) {
            saved += 1
        } else {
            failed += 1
        }
    }
    return
}

// Undo hook: replace the document's payload with the given JSON (a full
// capture_json of the document struct). Zero → JSON → on_validate into a
// fresh instance, so dynamic arrays never merge with stale contents. The old
// instance is retired (doc_data_retire): a wrapper may still draw it this frame.
asset_doc_apply_json :: proc(guid: core.Asset_GUID, kind: undo.Doc_Kind, json_bytes: []byte) -> bool {
    if kind == .Import_Settings do return _import_settings_apply_json(guid, json_bytes)
    context.allocator = runtime.default_allocator()
    doc, found := _docs[Doc_Key{guid, .File}]
    if !found {
        path, path_ok := assets.asset_db_get_path(uuid.Identifier(guid))
        if !path_ok do return false
        doc = asset_doc_get(path)
        if doc == nil do return false
    }

    tid := doc.data.id
    type_guid := core.get_guid_by_typeid(tid)
    fresh := core.create_zero_instance_by_guid(type_guid)
    ptr_tid, ptr_ok := core.get_pointer_typeid_by_typeid(tid)
    if !ptr_ok {
        log.error(fmt.tprintf("asset_docs: no pointer typeid for %v", tid))
        return false
    }
    tmp := fresh.data
    if err := json.unmarshal_any(json_bytes, any{&tmp, ptr_tid}, json.DEFAULT_SPECIFICATION, context.allocator); err != nil {
        log.error(fmt.tprintf("asset_docs: unmarshal failed for %s: %v", doc.path, err))
        return false
    }
    ser.Run_After_Deserialize(fresh.data, tid)
    core.type_on_validate_by_typeid(tid, fresh.data)

    _doc_replace(doc, fresh, dirty = true)
    return true
}

// Revert: the document back to its file, as one undo step. Nothing to do
// when it is not dirty.
asset_doc_revert :: proc(doc: ^Asset_Doc) {
    if doc == nil || !doc.dirty do return
    // The document lives on the default allocator, the undo entry on the
    // caller's: undo frees an entry with the allocator that made it.
    fresh: any
    ok: bool
    {
        context.allocator = runtime.default_allocator()
        fresh, ok = ser.load_from_file(doc.path)
    }
    if !ok {
        log.error(fmt.tprintf("asset_docs: revert could not load %s", doc.path))
        return
    }
    tid := doc.data.id
    before := undo.capture_json(doc.data.data, tid)
    after := undo.capture_json(fresh.data, tid)
    _doc_replace(doc, fresh, dirty = false)
    undo.push_value(undo.get(), undo.make_asset_target(doc.guid, tid, .File), before, after, fmt.tprintf("Revert %s", filepath_base(doc.path)))
}

// A document's new instance takes over: the old one retires, the inspector
// and the live previews follow. Document state is on the default allocator.
@(private = "file")
_doc_replace :: proc(doc: ^Asset_Doc, fresh: any, dirty: bool) {
    context.allocator = runtime.default_allocator()
    tid := fresh.id
    doc_data_retire(doc.data)
    doc.data = fresh
    doc.dirty = dirty
    // The inspector may be showing this doc — repoint its view.
    if inspectorData.doc == doc {
        inspectorData.fileData = doc.data
    }
    // Live preview only syncs the DISPLAYED doc each frame. A document undone
    // while another asset is shown must still reach its runtime cache (the
    // material cache, the clip cache the scrub preview samples from).
    if preview, has := _doc_previews[tid]; has do preview(doc.guid, doc.data)
}

// The asset left the project (engine asset-gone hook, fired by a refresh
// after a delete, never for a rename). Its undo steps go first, then the
// document. The inspector lets go of the file if it shows it.
@(private="file")
_asset_doc_gone :: proc(guid: core.Asset_GUID, path: string) {
    // Before the pin: undo entries free with the allocator that made them, the
    // caller's, like every purge.
    undo.purge_asset(undo.get(), guid)
    context.allocator = runtime.default_allocator()
    if inspectorData.filePath == path do unload()
    for kind in undo.Doc_Kind {
        doc, found := _docs[Doc_Key{guid, kind}]
        if !found do continue
        if inspectorData.doc == doc || inspectorData.settingsDoc == doc do unload()
        delete_key(&_docs, Doc_Key{guid, kind})
        _asset_doc_free(doc)
    }
}

// A document's typed instance: what it owns through its cleanup_T, then
// the instance. Documents live on the default allocator.
doc_data_release :: proc(data: any) {
    if data.data == nil do return
    context.allocator = runtime.default_allocator()
    core.type_cleanup_by_typeid(data.id, data.data)
    free(data.data)
}

// A replaced instance waits a frame before doc_data_release: the replacement
// happens mid-frame (a Revert button, an undo from the history view, a
// reimport) while a funnel wrapper above the button still holds the old
// pointer in its Asset_Ctx for the rest of the draw.
@(private = "file")
_Retired :: struct {
    data:  any,
    frame: u64,
}

@(private = "file")
_retired: [dynamic]_Retired

doc_data_retire :: proc(data: any) {
    if data.data == nil do return
    context.allocator = runtime.default_allocator()
    _doc_retired_drain(false)
    append(&_retired, _Retired{data = data, frame = gfx.frame_index})
}

// Frees what was retired in an earlier frame, or everything (shutdown).
@(private = "file")
_doc_retired_drain :: proc(all: bool) {
    context.allocator = runtime.default_allocator()
    for i := 0; i < len(_retired); {
        if !all && _retired[i].frame == gfx.frame_index {
            i += 1
            continue
        }
        doc_data_release(_retired[i].data)
        unordered_remove(&_retired, i)
    }
    if all {
        delete(_retired)
        _retired = nil
    }
}

@(private="file")
_asset_doc_free :: proc(doc: ^Asset_Doc) {
    context.allocator = runtime.default_allocator()
    delete(doc.path)
    delete(doc.baseline)
    delete(doc.applied)
    doc_data_release(doc.data)
    free(doc)
}

@(init)
_asset_docs_register :: proc "contextless" () {
    context = runtime.default_context()
    assets.asset_db_add_asset_gone_hook(_asset_doc_gone)
}

asset_docs_shutdown :: proc() {
    context.allocator = runtime.default_allocator()
    _doc_retired_drain(true)
    for _, doc in _docs do _asset_doc_free(doc)
    delete(_docs)
    _docs = nil
}

// The live document payload for a guid, for undo's asset targets. The undo
// package cannot import this one, so it is installed as a hook at init.
asset_doc_payload_ptr :: proc(guid: core.Asset_GUID, kind: undo.Doc_Kind) -> rawptr {
    doc, found := _docs[Doc_Key{guid, kind}]
    if !found || doc == nil do return nil
    return doc.data.data
}
