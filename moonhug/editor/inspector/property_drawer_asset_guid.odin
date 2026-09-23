package inspector

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:encoding/uuid"
import im "moonhug:external/odin-imgui"
import "../../engine"
import "moonhug:editor/widgets"

@(property_drawer={type = engine.Asset_GUID, priority = 0})
draw_asset_guid_property :: proc(ptr: rawptr, tid: typeid, label: cstring) {
    guid_ptr := cast(^engine.Asset_GUID)ptr
    guid_val := uuid.Identifier(guid_ptr^)
    has_value := guid_val != (uuid.Identifier{})

    // Mixed multi-selections are substituted inside _picker_field_row, so every
    // reference drawer gets the dash without repeating the check.
    display: string
    if !has_value {
        display = "None"
    } else if sub_label, is_sub := _sub_asset_label(guid_ptr^); is_sub {
        display = sub_label
    } else if path, ok := engine.asset_db_get_path(guid_val); ok {
        display = filepath_base(path)
    } else {
        display = fmt.tprintf("%v", guid_val)
    }

    popup_id := strings.clone_to_cstring(
        fmt.tprintf("asset_guid_picker##%s", label), context.temp_allocator,
    )

    value_clicked, value_double, cleared: bool
    dropped: string
    dropped_pptr: engine.PPtr
    dropped_pptr_ok: bool
    if _picker_field_row(label, display, has_value, &value_clicked, &cleared, &value_double, &dropped, &dropped_pptr, &dropped_pptr_ok) {
        im.OpenPopup(popup_id)
    }
    // A sub-asset row dragged from the project view carries (owner, id). The
    // clip's own guid is what the field stores.
    if dropped_pptr_ok && dropped_pptr.local_id != 0 {
        if sub_guid, sok := engine.asset_db_sub_guid(dropped_pptr.guid, dropped_pptr.local_id); sok {
            if ref, rok := engine.asset_db_get_sub(sub_guid); rok && _ext_allowed(ref.kind) {
                guid_ptr^ = sub_guid
                mark_inspector_changed()
            }
        }
    }
    // Single click: ping (project view navigates to + selects the asset).
    // Double click: OPEN it (scene loads, .asset goes to the inspector).
    if value_double && has_value {
        engine.inspector_request_open_asset(guid_ptr^)
    } else if value_clicked && has_value {
        engine.inspector_request_ping_asset(guid_ptr^)
    }
    if cleared {
        guid_ptr^ = {}
        mark_inspector_changed()
    }
    if dropped != "" && _ext_filter_matches(dropped) {
        if new_guid, ok := engine.asset_db_get_guid(dropped); ok {
            guid_ptr^ = engine.Asset_GUID(new_guid)
            mark_inspector_changed()
        }
    }

    if im.BeginPopup(popup_id) {
        search := _picker_search_bar()
        // Single Project tab: a plain guid can only name an asset (engine.Ref
        // fields are the ones with both sources).
        if im.BeginTabBar("##picker_tabs") {
            if im.BeginTabItem("Project") {
                if im.Selectable("None") {
                    guid_ptr^ = {}
                    mark_inspector_changed()
                }
                im.Separator()

                // With a `ref:` tag: only scene assets whose ROOT carries one of
                // the admitted components (AssetDB inverted index). Untagged:
                // every asset.
                keys := ref_target_keys(current_field_ref_target)
                picked: engine.PPtr
                if _picker_asset_rows_of_types(keys, search, &picked) {
                    guid_ptr^ = picked.guid
                    mark_inspector_changed()
                }
                im.EndTabItem()
            }
            im.EndTabBar()
        }
        im.EndPopup()
    }
}

// `_picker_asset_rows` over a set of keys: no keys means every asset, one key
// is the plain call, several are drawn one after another — an asset whose root
// carries two admitted components lists once per component, as the scene
// picker does.
_picker_asset_rows_of_types :: proc(keys: []engine.TypeKey, search: []string, picked: ^engine.PPtr) -> bool {
    if len(keys) == 0 do return _picker_asset_rows(engine.INVALID_TYPE_KEY, search, picked)
    clicked := false
    for k in keys {
        if _picker_asset_rows(k, search, picked) do clicked = true
    }
    return clicked
}

// Rows of scene assets whose root carries `key` (INVALID_TYPE_KEY: every
// asset, pptr local_id 0), name-filtered by `search`. Returns true and writes
// `picked` when a row is clicked (picked may be nil for display-only lists).
_picker_asset_rows :: proc(key: engine.TypeKey, search: []string, picked: ^engine.PPtr) -> bool {
    Candidate :: struct {
        path:  string, // sort key
        label: string, // row text: the file name, or "Model / Clip" for a sub-asset
        kind:  string, // what the ext filter tests: the file's extension, or the sub-asset's kind
        entry: engine.PPtr,
    }
    candidates := make([dynamic]Candidate, context.temp_allocator)
    if key != engine.INVALID_TYPE_KEY {
        for entry in engine.asset_db_assets_with_root_type(key) {
            if path, pok := engine.asset_db_get_path(uuid.Identifier(entry.guid)); pok {
                append(&candidates, Candidate{path = path, label = filepath_base(path), kind = _path_ext(path), entry = entry})
            }
        }
    } else {
        for path, guid in engine.asset_db.path_to_guid {
            append(&candidates, Candidate{path = path, label = filepath_base(path), kind = _path_ext(path), entry = {guid = engine.Asset_GUID(guid)}})
        }
        // Sub-assets with their own guid (a model's clips) are assignable
        // wherever their kind is. They sort under their owner's path.
        for guid, ref in engine.asset_db.subs {
            if owner_path, clip_name, ok := _sub_asset_parts(engine.Asset_GUID(guid)); ok {
                append(&candidates, Candidate{
                    path  = fmt.tprintf("%s/%s", owner_path, clip_name),
                    label = fmt.tprintf("%s / %s", _stem(owner_path), clip_name),
                    kind  = ref.kind,
                    entry = {guid = engine.Asset_GUID(guid)},
                })
            }
        }
    }
    slice.sort_by(candidates[:], proc(a, b: Candidate) -> bool { return a.path < b.path })

    result := false
    shown := 0
    for cand in candidates {
        if !_ext_allowed(cand.kind) do continue
        name := cand.label
        if !widgets.search_match(name, search) {
            continue
        }
        shown += 1
        row := strings.clone_to_cstring(
            fmt.tprintf("%s##%s", cand.path, cand.path), context.temp_allocator,
        )
        if im.Selectable(row) && picked != nil {
            picked^ = cand.entry
            result = true
        }
    }
    if shown == 0 {
        im.TextDisabled("(no assets with this root component)" if key != engine.INVALID_TYPE_KEY else "(no matches)")
    }
    return result
}

// True when `path`'s extension is in the field's `ext:"glb,gltf"` tag (comma
// separated, no dots). No tag = no filtering. Applies to picker rows AND the
// drag-drop assign path so a sprite can't be dropped on a mesh field.
_ext_filter_matches :: proc(path: string) -> bool {
    return _ext_allowed(_path_ext(path))
}

// The lowercase extension without the dot, "" when there is none.
@(private = "file")
_path_ext :: proc(path: string) -> string {
    dot := strings.last_index(path, ".")
    if dot < 0 || dot + 1 >= len(path) do return ""
    return strings.to_lower(path[dot + 1:], context.temp_allocator)
}

// Whether `ext` (a file's extension, or a sub-asset's kind, spelled the same
// way) passes the field's `ext:` tag. No tag = everything.
@(private = "file")
_ext_allowed :: proc(ext: string) -> bool {
    if current_field_ext_filter == "" do return true
    if ext == "" do return false
    remaining := current_field_ext_filter
    for allowed in strings.split_iterator(&remaining, ",") {
        if ext == strings.trim_space(allowed) do return true
    }
    return false
}

// The owner's path and the clip's name for a guid that names a sub-asset.
@(private = "file")
_sub_asset_parts :: proc(guid: engine.Asset_GUID) -> (owner_path, name: string, ok: bool) {
    ref, is_sub := engine.asset_db_get_sub(guid)
    if !is_sub do return
    owner_path, ok = engine.asset_db_get_path(uuid.Identifier(ref.owner))
    if !ok do return
    for c in engine.mesh_clips(ref.owner) {
        if c.id == ref.id do return owner_path, c.name, true
    }
    return owner_path, fmt.tprintf("#%d", i64(ref.id)), true
}

// "Model / Clip", so a clip field never reads as the model file it lives in.
@(private = "file")
_sub_asset_label :: proc(guid: engine.Asset_GUID) -> (string, bool) {
    owner_path, name, ok := _sub_asset_parts(guid)
    if !ok do return "", false
    return fmt.tprintf("%s / %s", _stem(owner_path), name), true
}

@(private = "file")
_stem :: proc(path: string) -> string {
    stem := filepath_base(path)
    if dot := strings.last_index(stem, "."); dot > 0 do stem = stem[:dot]
    return stem
}

// filepath.base without importing core:path/filepath (returns a slice into path).
filepath_base :: proc(path: string) -> string {
    last_slash := strings.last_index(path, "/")
    if last_slash >= 0 && last_slash + 1 < len(path) {
        return path[last_slash + 1:]
    }
    return path
}
