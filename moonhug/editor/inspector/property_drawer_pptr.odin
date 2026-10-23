package inspector

// The drawer of a `core.PPtr` field: an asset file ({guid, 0}) or a
// sub-asset of one ({owner guid, id}), such as a clip inside a model. The
// picker lists the files the field's `ext:` tag admits and every sub-asset
// whose kind the tag admits (subassets.Sub_Asset.kind, "anim" for a clip),
// the latter as "Model / Clip" under their owner. A drop takes a file, or a
// sub-asset row from the project window, which carries (owner, id).

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:encoding/uuid"
import im "moonhug:external/odin-imgui"
import "moonhug:editor/widgets"
import "moonhug:editor/subassets"
import assets "moonhug:libs/assets"
import core "moonhug:libs/core"

@(property_drawer={type = core.PPtr, priority = 0})
draw_pptr_property :: proc(ptr: rawptr, tid: typeid, label: cstring) {
    ref_ptr := cast(^core.PPtr)ptr
    has_value := ref_ptr.guid != {}

    display: string
    if !has_value {
        display = "None"
    } else if name, ok := _pptr_display(ref_ptr^); ok {
        display = name
    } else {
        display = fmt.tprintf("%v", uuid.Identifier(ref_ptr.guid))
    }

    popup_id := strings.clone_to_cstring(fmt.tprintf("pptr_picker##%s", label), context.temp_allocator)

    value_clicked, value_double, cleared: bool
    dropped: string
    dropped_pptr: core.PPtr
    dropped_pptr_ok: bool
    if picker_field_row(label, display, has_value, &value_clicked, &cleared, &value_double, &dropped, &dropped_pptr, &dropped_pptr_ok) {
        im.OpenPopup(popup_id)
    }
    if dropped_pptr_ok && dropped_pptr.local_id != 0 {
        if _, kind, ok := _sub_asset_name(dropped_pptr); ok && _ext_allowed(kind) {
            _pptr_set(ref_ptr, dropped_pptr)
        }
    }
    if value_double && has_value {
        core.inspector_request_open_asset(ref_ptr.guid)
    } else if value_clicked && has_value {
        core.inspector_request_ping_asset(ref_ptr.guid)
    }
    if cleared do _pptr_set(ref_ptr, {})
    if dropped != "" && _ext_filter_matches(dropped) {
        if guid, ok := assets.asset_db_get_guid(dropped); ok && _ref_admits(core.Asset_GUID(guid)) {
            _pptr_set(ref_ptr, {guid = core.Asset_GUID(guid)})
        }
    }

    if im.BeginPopup(popup_id) {
        search := picker_search_bar()
        if im.Selectable("None") do _pptr_set(ref_ptr, {})
        im.Separator()
        if picked, ok := _pptr_picker_rows(search, ref_ptr^); ok do _pptr_set(ref_ptr, picked)
        im.EndPopup()
    }
}

@(private = "file")
_pptr_set :: proc(ref_ptr: ^core.PPtr, value: core.PPtr) {
    if ref_ptr^ == value do return
    ref_ptr^ = value
    mark_inspector_changed()
}

// The file name, or "Model / Clip" for a sub-asset.
@(private = "file")
_pptr_display :: proc(ref: core.PPtr) -> (string, bool) {
    path, ok := assets.asset_db_get_path(uuid.Identifier(ref.guid))
    if !ok do return "", false
    if ref.local_id == 0 do return filepath_base(path), true
    name, _, nok := _sub_asset_name(ref)
    if !nok do return fmt.tprintf("%s / (missing)", _stem(path)), true
    return fmt.tprintf("%s / %s", _stem(path), name), true
}

// A sub-asset's name and kind, through its owner's provider.
@(private = "file")
_sub_asset_name :: proc(ref: core.PPtr) -> (name, kind: string, ok: bool) {
    path, pok := assets.asset_db_get_path(uuid.Identifier(ref.guid))
    if !pok do return
    provider, has := subassets.find(strings.concatenate({".", _path_ext(path)}, context.temp_allocator))
    if !has || provider.list == nil do return
    for s in provider.list(path, context.temp_allocator) {
        if s.id == ref.local_id do return s.name, s.kind, true
    }
    return
}

// The files the tag admits, and the sub-assets of every asset with a
// provider whose kind the tag admits, sorted by path.
@(private = "file")
_pptr_picker_rows :: proc(search: []string, current: core.PPtr) -> (picked: core.PPtr, ok: bool) {
    Candidate :: struct {
        path:  string,
        label: string,
        entry: core.PPtr,
    }
    candidates := make([dynamic]Candidate, context.temp_allocator)
    for path, guid in assets.asset_db.path_to_guid {
        owner := core.Asset_GUID(guid)
        if _ext_allowed(_path_ext(path)) && _ref_admits(owner) {
            append(&candidates, Candidate{path = path, label = filepath_base(path), entry = {guid = owner}})
        }
        provider, has := subassets.find(strings.concatenate({".", _path_ext(path)}, context.temp_allocator))
        if !has || provider.list == nil do continue
        for s in provider.list(path, context.temp_allocator) {
            if s.kind == "" || !_ext_allowed(s.kind) do continue
            append(&candidates, Candidate{
                path  = fmt.tprintf("%s/%s", path, s.name),
                label = fmt.tprintf("%s / %s", _stem(path), s.name),
                entry = {guid = owner, local_id = s.id},
            })
        }
    }
    slice.sort_by(candidates[:], proc(a, b: Candidate) -> bool { return a.path < b.path })

    shown := 0
    for cand in candidates {
        if !widgets.search_match(cand.label, search) do continue
        shown += 1
        row := strings.clone_to_cstring(fmt.tprintf("%s##%s", cand.label, cand.path), context.temp_allocator)
        if im.Selectable(row, cand.entry == current) {
            picked = cand.entry
            ok = true
        }
    }
    if shown == 0 do im.TextDisabled("(no matches)")
    return
}
