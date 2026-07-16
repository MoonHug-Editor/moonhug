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

import "core:encoding/json"
import "core:encoding/uuid"
import "core:fmt"
import strings "core:strings"
import engine "../../engine"
import ser "../../engine/serialization"
import "../../engine/log"

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

// Undo hook: replace the document's payload with the given JSON (a full
// capture_json of the document struct). A fresh zeroed instance is
// unmarshalled so dynamic arrays never merge with stale contents. The old
// instance is intentionally leaked — there is no generic deep-destroy for
// asset types (parity with the pre-registry reload-on-click behavior).
asset_doc_apply_json :: proc(guid: engine.Asset_GUID, json_bytes: []byte) -> bool {
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
    return true
}

asset_docs_shutdown :: proc() {
    for _, doc in _docs {
        delete(doc.path)
        free(doc.data.data) // shallow; nested allocations lifetime = session
        free(doc)
    }
    delete(_docs)
    _docs = nil
}
