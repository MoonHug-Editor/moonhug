package inspector

import "core:fmt"
import "core:reflect"
import "core:slice"
import "core:strings"
import "core:encoding/uuid"
import im "../../../external/odin-imgui"
import "../../engine"

@(property_drawer={type = engine.Asset_GUID, priority = 0})
draw_asset_guid_property :: proc(ptr: rawptr, tid: typeid, label: cstring) {
    guid_ptr := cast(^engine.Asset_GUID)ptr
    guid_val := uuid.Identifier(guid_ptr^)
    has_value := guid_val != (uuid.Identifier{})

    display: string
    if !has_value {
        display = "None"
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
    if _picker_field_row(label, display, has_value, &value_clicked, &cleared, &value_double, &dropped) {
        im.OpenPopup(popup_id)
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
    if dropped != "" {
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

                // With a `ref:"Type"` tag: only scene assets whose ROOT carries
                // that component (AssetDB inverted index). Untagged: every asset.
                key := engine.INVALID_TYPE_KEY
                if current_field_ref_target != "" {
                    if v, ok := reflect.enum_from_name(engine.TypeKey, current_field_ref_target); ok {
                        key = v
                    }
                }
                picked: engine.PPtr
                if _picker_asset_rows(key, search, &picked) {
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

// Rows of scene assets whose root carries `key` (INVALID_TYPE_KEY: every
// asset, pptr local_id 0), name-filtered by `search`. Returns true and writes
// `picked` when a row is clicked (picked may be nil for display-only lists).
_picker_asset_rows :: proc(key: engine.TypeKey, search: string, picked: ^engine.PPtr) -> bool {
    Candidate :: struct {
        path:  string,
        entry: engine.PPtr,
    }
    candidates := make([dynamic]Candidate, context.temp_allocator)
    if key != engine.INVALID_TYPE_KEY {
        for entry in engine.asset_db_assets_with_root_type(key) {
            if path, pok := engine.asset_db_get_path(uuid.Identifier(entry.guid)); pok {
                append(&candidates, Candidate{path = path, entry = entry})
            }
        }
    } else {
        for path, guid in engine.asset_db.path_to_guid {
            append(&candidates, Candidate{path = path, entry = {guid = engine.Asset_GUID(guid)}})
        }
    }
    slice.sort_by(candidates[:], proc(a, b: Candidate) -> bool { return a.path < b.path })

    result := false
    shown := 0
    for cand in candidates {
        name := filepath_base(cand.path)
        if search != "" && !strings.contains(strings.to_lower(name, context.temp_allocator), search) {
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

// filepath.base without importing core:path/filepath (returns a slice into path).
filepath_base :: proc(path: string) -> string {
    last_slash := strings.last_index(path, "/")
    if last_slash >= 0 && last_slash + 1 < len(path) {
        return path[last_slash + 1:]
    }
    return path
}
