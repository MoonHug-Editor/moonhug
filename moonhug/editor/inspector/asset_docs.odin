package inspector

// Asset document registry: the in-memory copy of every serialized asset
// (.mat/.asset) the project inspector has opened this session, keyed by
// asset GUID. Docs OUTLIVE the inspector's current selection — that is what
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
import engine "../../engine"
import anim "moonhug:packages/animation"
import ser "../../engine/serialization"
import "../../engine/log"
import "../undo"

Asset_Doc :: struct {
    guid:  engine.Asset_GUID,
    path:  string, // owned
    data:  any,
    dirty: bool,   // edited (or undone/redone) since last save
}

@(private="file")
_docs: map[engine.Asset_GUID]^Asset_Doc

// The open document for a path — reused if already loaded (unsaved edits
// survive clicking away and back), loaded from disk otherwise. nil on load
// failure or when the file isn't in the asset db.
asset_doc_get :: proc(path: string) -> ^Asset_Doc {
    context.allocator = runtime.default_allocator()
    raw_guid, ok := engine.asset_db_get_guid(path)
    if !ok do return nil
    guid := engine.Asset_GUID(raw_guid)

    if doc, found := _docs[guid]; found {
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
    if _docs == nil do _docs = make(map[engine.Asset_GUID]^Asset_Doc)
    _docs[guid] = doc
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
    path, known := engine.asset_db_get_path(uuid.Identifier(doc.guid))
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
// what File/Save does, so one shortcut saves all pending asset edits.
asset_docs_save_dirty :: proc() -> (saved, failed: int) {
    for _, doc in _docs {
        if !doc.dirty do continue
        if asset_doc_save(doc) {
            saved += 1
        } else {
            failed += 1
        }
    }
    return
}

// Undo hook: replace the document's payload with the given JSON (a full
// capture_json of the document struct). A fresh zeroed instance is
// unmarshalled so dynamic arrays never merge with stale contents. The old
// instance is intentionally leaked — there is no generic deep-destroy for
// asset types (parity with the pre-registry reload-on-click behavior).
asset_doc_apply_json :: proc(guid: engine.Asset_GUID, json_bytes: []byte) -> bool {
    context.allocator = runtime.default_allocator()
    doc, found := _docs[guid]
    if !found {
        path, path_ok := engine.asset_db_get_path(uuid.Identifier(guid))
        if !path_ok do return false
        doc = asset_doc_get(path)
        if doc == nil do return false
    }

    tid := doc.data.id
    type_guid := engine.get_guid_by_typeid(tid)
    fresh := engine.create_instance_by_guid(type_guid)
    ptr_tid, ptr_ok := engine.get_pointer_typeid_by_typeid(tid)
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

    doc.data = fresh
    doc.dirty = true
    // The inspector may be showing this doc — repoint its view.
    if inspectorData.doc == doc {
        inspectorData.fileData = doc.data
    }
    // Live preview only syncs the DISPLAYED doc each frame; a material undone
    // while another asset is shown must still reach the engine cache.
    if tid == typeid_of(engine.Material) {
        mat := cast(^engine.Material)doc.data.data
        _ = engine.material_sync_properties(mat)
        engine.material_preview(doc.guid, mat^)
    }
    // Same live-preview contract for clips: an undone/redone clip document
    // must reach the clip cache the scrub preview and runtime sample from.
    if tid == typeid_of(anim.AnimationClip) {
        clip := cast(^anim.AnimationClip)doc.data.data
        anim.animation_clip_preview(doc.guid, clip^)
    }
    return true
}

// The asset left the project (engine asset-gone hook, fired by a refresh
// after a delete, never for a rename). Its undo steps go first, then the
// document. The inspector lets go of the file if it shows it.
@(private="file")
_asset_doc_gone :: proc(guid: engine.Asset_GUID, path: string) {
    // Before the pin: undo entries free with the allocator that made them, the
    // caller's, like every purge.
    undo.purge_asset(undo.get(), guid)
    context.allocator = runtime.default_allocator()
    doc, found := _docs[guid]
    if (found && inspectorData.doc == doc) || inspectorData.filePath == path do unload()
    if !found do return
    delete_key(&_docs, guid)
    delete(doc.path)
    free(doc.data.data) // shallow, same as shutdown
    free(doc)
}

@(init)
_asset_docs_register :: proc "contextless" () {
    context = runtime.default_context()
    engine.asset_db_add_asset_gone_hook(_asset_doc_gone)
}

asset_docs_shutdown :: proc() {
    context.allocator = runtime.default_allocator()
    for _, doc in _docs {
        delete(doc.path)
        free(doc.data.data) // shallow; nested allocations lifetime = session
        free(doc)
    }
    delete(_docs)
    _docs = nil
}

// The live document payload for a guid, for undo's asset targets. The undo
// package cannot import this one, so it is installed as a hook at init.
asset_doc_payload_ptr :: proc(guid: engine.Asset_GUID) -> rawptr {
    doc, found := _docs[guid]
    if !found || doc == nil do return nil
    return doc.data.data
}
