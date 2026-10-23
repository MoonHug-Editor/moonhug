package inspector

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:encoding/uuid"
import im "moonhug:external/odin-imgui"
import "moonhug:editor/widgets"
import assets "moonhug:libs/assets"
import core "moonhug:libs/core"

@(property_drawer={type = core.Asset_GUID, priority = 0})
draw_asset_guid_property :: proc(ptr: rawptr, tid: typeid, label: cstring) {
    guid_ptr := cast(^core.Asset_GUID)ptr
    guid_val := uuid.Identifier(guid_ptr^)
    has_value := guid_val != (uuid.Identifier{})

    // Mixed multi-selections are substituted inside picker_field_row, so every
    // reference drawer gets the dash without repeating the check.
    display: string
    if !has_value {
        display = "None"
    } else if path, ok := assets.asset_db_get_path(guid_val); ok {
        display = filepath_base(path)
    } else {
        display = fmt.tprintf("%v", guid_val)
    }

    popup_id := strings.clone_to_cstring(
        fmt.tprintf("asset_guid_picker##%s", label), context.temp_allocator,
    )

    value_clicked, value_double, cleared: bool
    dropped: string
    dropped_pptr: core.PPtr
    dropped_pptr_ok: bool
    if picker_field_row(label, display, has_value, &value_clicked, &cleared, &value_double, &dropped, &dropped_pptr, &dropped_pptr_ok) {
        im.OpenPopup(popup_id)
    }
    // Single click: ping (project view navigates to + selects the asset).
    // Double click: OPEN it (scene loads, .asset goes to the inspector).
    if value_double && has_value {
        core.inspector_request_open_asset(guid_ptr^)
    } else if value_clicked && has_value {
        core.inspector_request_ping_asset(guid_ptr^)
    }
    if cleared {
        guid_ptr^ = {}
        mark_inspector_changed()
    }
    if dropped != "" && _ext_filter_matches(dropped) {
        if new_guid, ok := assets.asset_db_get_guid(dropped); ok && _ref_admits(core.Asset_GUID(new_guid)) {
            guid_ptr^ = core.Asset_GUID(new_guid)
            mark_inspector_changed()
        }
    }

    if im.BeginPopup(popup_id) {
        search := picker_search_bar()
        // Single Project tab: a plain guid can only name an asset (core.Ref
        // fields are the ones with both sources).
        if im.BeginTabBar("##picker_tabs") {
            if im.BeginTabItem("Project") {
                if im.Selectable("None") {
                    guid_ptr^ = {}
                    mark_inspector_changed()
                }
                im.Separator()

                // With a `ref:` tag: only the assets the AssetDB type index
                // lists under one of the admitted types, scene assets whose
                // root carries the component or typed asset files of the
                // asset type. Untagged: every asset.
                keys := ref_target_keys(current_field_ref_target)
                picked: core.PPtr
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
_picker_asset_rows_of_types :: proc(keys: []core.TypeKey, search: []string, picked: ^core.PPtr) -> bool {
    if len(keys) == 0 do return _picker_asset_rows(core.INVALID_TYPE_KEY, search, picked)
    clicked := false
    for k in keys {
        if _picker_asset_rows(k, search, picked) do clicked = true
    }
    return clicked
}

// Rows of the assets the type index lists under `key`: scene assets whose
// root carries the component, typed asset files of the asset type
// (INVALID_TYPE_KEY: every asset, pptr local_id 0), name-filtered by `search`. Returns true and writes
// `picked` when a row is clicked (picked may be nil for display-only lists).
_picker_asset_rows :: proc(key: core.TypeKey, search: []string, picked: ^core.PPtr) -> bool {
    Candidate :: struct {
        path:  string, // sort key
        label: string, // row text: the file name
        kind:  string, // what the ext filter tests: the file's extension
        entry: core.PPtr,
    }
    candidates := make([dynamic]Candidate, context.temp_allocator)
    if key != core.INVALID_TYPE_KEY {
        for entry in assets.asset_db_assets_with_root_type(key) {
            if path, pok := assets.asset_db_get_path(uuid.Identifier(entry.guid)); pok {
                append(&candidates, Candidate{path = path, label = filepath_base(path), kind = _path_ext(path), entry = entry})
            }
        }
    } else {
        for path, guid in assets.asset_db.path_to_guid {
            append(&candidates, Candidate{path = path, label = filepath_base(path), kind = _path_ext(path), entry = {guid = core.Asset_GUID(guid)}})
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
        im.TextDisabled("(no assets of this type)" if key != core.INVALID_TYPE_KEY else "(no matches)")
    }
    return result
}

// Whether the field's `ref:` tag admits the asset: the type index lists it
// under one of the tag's types. No tag, or a tag naming no type, admits every
// asset, as the picker lists every asset then.
_ref_admits :: proc(guid: core.Asset_GUID) -> bool {
    keys := ref_target_keys(current_field_ref_target)
    if len(keys) == 0 do return true
    for k in keys {
        for entry in assets.asset_db_assets_with_root_type(k) {
            if entry.guid == guid do return true
        }
    }
    return false
}

// True when `path`'s extension is in the field's `ext:"glb,gltf"` tag (comma
// separated, no dots). No tag = no filtering. Applies to picker rows AND the
// drag-drop assign path so a sprite can't be dropped on a mesh field.
_ext_filter_matches :: proc(path: string) -> bool {
    return _ext_allowed(_path_ext(path))
}

// The lowercase extension without the dot, "" when there is none.
_path_ext :: proc(path: string) -> string {
    dot := strings.last_index(path, ".")
    if dot < 0 || dot + 1 >= len(path) do return ""
    return strings.to_lower(path[dot + 1:], context.temp_allocator)
}

// Whether `ext` (a file's extension, or a sub-asset's kind, spelled the same
// way) passes the field's `ext:` tag. No tag = everything.
_ext_allowed :: proc(ext: string) -> bool {
    if current_field_ext_filter == "" do return true
    if ext == "" do return false
    remaining := current_field_ext_filter
    for allowed in strings.split_iterator(&remaining, ",") {
        if ext == strings.trim_space(allowed) do return true
    }
    return false
}

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
