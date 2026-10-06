package engine

// The asset database's indexer for scene files: per scene asset, its root
// transform and the components on it, which the object picker reads through
// asset_db_get_root_info and asset_db_assets_with_root_type.

import "base:runtime"
import "core:encoding/json"
import assets "moonhug:host/assets"

@(init)
_scene_asset_index_register :: proc "contextless" () {
    context = runtime.default_context()
    assets.asset_db_add_indexer(".scene", _index_scene_asset)
}

_index_scene_asset :: proc(guid: Asset_GUID, path: string, data: []byte) {
    // Externally changed bytes (git checkout, other tools): refresh the
    // scene_lib cache and re-propagate to loaded scenes, exactly like an
    // editor save would. The save path itself already committed identical
    // bytes, so the equality check keeps it from re-propagating twice.
    if cached, has := scene_lib[guid]; has {
        if string(cached) != string(data) {
            _prefab_bytes_committed(guid, data)
        }
    }

    sf: SceneFile
    if scene_file_unmarshal(data, &sf) != nil do return

    is_variant := false
    base_prefab := Asset_GUID{}
    for &ns in sf.nested_scenes {
        if ns.transform_parent == 0 {
            is_variant = true
            base_prefab = ns.source_prefab
            break
        }
    }
    if is_variant {
        // A variant file has no root transform record of its own (sf.root
        // names the BASE root, only added content is stored). Index the
        // FLATTENED form instead, so variants get root info and inherited
        // root components like any other scene asset.
        scene_file_destroy(&sf)
        flat, flat_owned := _prefab_resolved_bytes(guid)
        if flat == nil do return
        cpy := make([]byte, len(flat), context.temp_allocator)
        copy(cpy, flat)
        if flat_owned do delete(flat)
        sf = {}
        if scene_file_unmarshal(cpy, &sf) != nil do return
    }
    defer scene_file_destroy(&sf)

    root: ^Transform
    for &t in sf.transforms {
        if t.local_id == sf.root {
            root = &t
            break
        }
    }
    if root == nil do return

    info := Asset_Root_Info{
        root_local_id = sf.root,
        root_name     = root.name,
        is_variant    = is_variant,
        base_prefab   = base_prefab,
    }
    // Every scene asset's root IS a transform.
    entries := make([dynamic]Asset_Index_Entry, context.temp_allocator)
    append(&entries, Asset_Index_Entry{key = .Transform, local_id = sf.root})
    root_lids := make(map[Local_ID]bool, context.temp_allocator)
    for c in root.components {
        root_lids[c.local_id] = true
    }
    _index_root_components(&sf, root_lids, &entries)
    // Before the deferred scene_file_destroy: root_name is a view into sf.
    assets.asset_db_index_set(guid, info, ..entries[:])
}

// Appends an entry per component on the root, in SceneFile field order, then
// the external components.
@(private = "file")
_index_root_components :: proc(sf: ^SceneFile, root_lids: map[Local_ID]bool, entries: ^[dynamic]Asset_Index_Entry) {
    if len(root_lids) == 0 do return

    // Typed component arrays, found by reflecting over SceneFile (component
    // structs start with CompData, non-component record arrays are skipped
    // explicitly). Keeps working when the generator adds component types.
    ti := runtime.type_info_base(type_info_of(SceneFile)).variant.(runtime.Type_Info_Struct)
    for i in 0 ..< ti.field_count {
        ftype := runtime.type_info_base(ti.types[i])
        dyn, is_dyn := ftype.variant.(runtime.Type_Info_Dynamic_Array)
        if !is_dyn do continue
        elem_id := dyn.elem.id
        if elem_id == typeid_of(Transform) || elem_id == typeid_of(NestedScene) || elem_id == typeid_of(Breadcrumb) do continue
        key, kok := get_type_key_by_typeid(elem_id)
        if !kok do continue // e.g. json.Value (ext components, handled below)
        arr := cast(^runtime.Raw_Dynamic_Array)(rawptr(uintptr(sf) + ti.offsets[i]))
        for j in 0 ..< arr.len {
            base := cast(^CompData)(uintptr(arr.data) + uintptr(j) * uintptr(dyn.elem.size))
            if root_lids[base.local_id] {
                append(entries, Asset_Index_Entry{key = key, local_id = base.local_id})
                break
            }
        }
    }

    // External (app-package) components: type from the "__type" guid record.
    for &v in sf.components {
        desc, dok := _ext_desc_for_value(v)
        if !dok do continue
        obj := v.(json.Object)
        bobj, has_base := obj["base"].(json.Object)
        if !has_base do continue
        lid: Local_ID
        #partial switch n in bobj["local_id"] {
        case json.Integer: lid = Local_ID(n)
        case json.Float:   lid = Local_ID(n)
        }
        if root_lids[lid] {
            append(entries, Asset_Index_Entry{key = desc.type_key, local_id = lid})
        }
    }
}
