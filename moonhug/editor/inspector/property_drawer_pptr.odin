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
import "moonhug:editor/undo"
import assets "moonhug:libs/assets"
import core "moonhug:libs/core"

@(property_drawer={type = core.PPtr})
property_drawer_PPtr :: proc(ctx: ^Ctx) {
    ptr, label := ctx.ptr, ctx.label
    ref_ptr := cast(^core.PPtr)ptr
    // A sub-asset of a file never saved has a local id and no guid.
    has_value := ref_ptr.guid != {}
    if !has_value && ref_ptr.local_id != 0 do _, has_value = subassets.get(ref_ptr^)

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
    if dropped_pptr_ok && dropped_pptr.local_id != 0 && sub_asset_in_scope(dropped_pptr) {
        if s, ok := subassets.get(dropped_pptr); ok && _ext_allowed(s.kind) {
            _pptr_set(ref_ptr, dropped_pptr)
        }
    }
    if value_double && has_value && ref_ptr.guid != {} {
        core.inspector_request_open_asset(ref_ptr.guid, ref_ptr.local_id)
    } else if value_clicked && has_value && ref_ptr.guid != {} {
        core.inspector_request_ping_asset(ref_ptr.guid, ref_ptr.local_id)
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
        _pptr_picker_new_rows(ctx, ref_ptr)
        im.Separator()
        if picked, ok := _pptr_picker_rows(search, ref_ptr^); ok do _pptr_set(ref_ptr, picked)
        im.EndPopup()
    }
}

// The rows of the picker that add a sub-asset to the file in scope
// (sub_asset_scope), where that file takes one (subassets.Provider.create),
// and put it in the field, as one undo step:
//   - "New <Type>" for each asset type the field's `ext:` tag names. A field
//     without the tag has none: it would list every type
//   - "Make Unique" when the field holds an asset the inspector edits as a
//     document, a file or a sub-asset: a copy of it, unsaved edits included.
//     The field then has an asset of its own to change
@(private = "file")
_pptr_picker_new_rows :: proc(ctx: ^Ctx, ref_ptr: ^core.PPtr) {
    if !sub_asset_scope.set do return
    owner := sub_asset_scope.owner
    p, _, has := subassets.of(owner)
    if !has || p.create == nil do return
    if current_field_ext_filter != "" {
        for c in subassets.creatables() {
            if !_ext_allowed(c.kind) do continue
            label := fmt.tprintf("New %s", c.title)
            if !im.Selectable(strings.clone_to_cstring(label, context.temp_allocator)) do continue
            instance := core.create_instance_by_type_key(c.type_key)
            defer {
                core.type_cleanup(c.type_key, instance.data)
                free(instance.data)
            }
            _pptr_put_new(ctx, ref_ptr, p, c.kind, c.title, instance, label)
        }
    }
    if kind, name, ok := _pptr_copy_source(ref_ptr^); ok && im.Selectable("Make Unique") {
        // Asked for again: the rows above may have changed the field.
        if doc := asset_doc_get_ref(ref_ptr^); doc != nil {
            _pptr_put_new(ctx, ref_ptr, p, kind, name, doc.data, "Make Unique")
        }
    }
}

// What a copy of the asset `ref` names would be: its kind and its name.
// False when the field takes no such kind or the asset is not a document.
@(private = "file")
_pptr_copy_source :: proc(ref: core.PPtr) -> (kind, name: string, ok: bool) {
    if ref == {} do return
    if ref.local_id != 0 {
        s := subassets.get(ref) or_return
        kind, name = s.kind, s.name
    } else {
        path := assets.asset_db_get_path(uuid.Identifier(ref.guid)) or_return
        kind, name = _path_ext(path), _stem(path)
    }
    if kind == "" || !_ext_allowed(kind) do return
    doc := asset_doc_get_ref(ref)
    return kind, name, doc != nil && doc.data.data != nil
}

// Adds a sub-asset with a copy of `data` to the file in scope and puts it
// in the field. The sub-asset's own undo step lands inside the row, which
// drops the row's edit (field_edit.odin): the field's change is recorded
// here, in one group with it.
@(private = "file")
_pptr_put_new :: proc(ctx: ^Ctx, ref_ptr: ^core.PPtr, p: subassets.Provider, kind, name: string, data: any, label: string) {
    before := undo.capture_json(ref_ptr, typeid_of(core.PPtr))
    defer delete(before)
    g := undo.group_begin(label)
    defer undo.group_end(&g)
    created, made := p.create(sub_asset_scope.owner, kind, subassets.unique_name(sub_asset_scope.owner, name), data)
    if !made do return
    _pptr_set(ref_ptr, created)
    field_edit_begin(ref_ptr, typeid_of(core.PPtr), ctx.offset, string(ctx.label), before)
    field_edit_apply_to_peers(ref_ptr, typeid_of(core.PPtr), ctx.offset)
    field_edit_end()
    undo.group_commit(&g)
    if ctx.path != "" do record_nested_override(ref_ptr, typeid_of(core.PPtr), ctx.path, true)
    mark_inspector_changed()
}

// What stands for the name of a file that has no path yet
// (subassets.NO_FILE): a scene never saved.
@(private = "file")
_UNSAVED_FILE :: "This scene"

@(private = "file")
_pptr_set :: proc(ref_ptr: ^core.PPtr, value: core.PPtr) {
    if ref_ptr^ == value do return
    ref_ptr^ = value
}

// The file name, or "Model / Clip" for a sub-asset.
@(private = "file")
_pptr_display :: proc(ref: core.PPtr) -> (string, bool) {
    path, ok := assets.asset_db_get_path(uuid.Identifier(ref.guid))
    if !ok {
        // A sub-asset of a file never saved: the file has no path.
        if s, found := subassets.get(ref); found do return fmt.tprintf("%s / %s", _UNSAVED_FILE, s.name), true
        return "", false
    }
    if ref.local_id == 0 do return filepath_base(path), true
    s, found := subassets.get(ref)
    if !found do return fmt.tprintf("%s / (missing)", _stem(path)), true
    return fmt.tprintf("%s / %s", _stem(path), s.name), true
}

// One row of the picker: what it shows and the reference it sets.
Pptr_Candidate :: struct {
    path:  string, // what the rows sort by
    label: string,
    entry: core.PPtr,
    own:   bool, // a sub-asset of the file in scope: listed first
}

// What the picker of the field drawn now offers, sorted by path (temp):
//   - the files the field's tags admit
//   - the sub-assets, of every asset with a provider, whose kind the `ext:`
//     tag admits: a model's clips
//   - the sub-assets of the file in scope (sub_asset_scope) come first:
//     what the field's own file holds is what it most often wants
//   - the sub-assets of the file in scope when it was never saved: it is
//     not among the project's files
pptr_picker_candidates :: proc() -> []Pptr_Candidate {
    candidates := make([dynamic]Pptr_Candidate, context.temp_allocator)
    for path, guid in assets.asset_db.path_to_guid {
        owner := core.Asset_GUID(guid)
        if _ext_allowed(_path_ext(path)) && _ref_admits(owner) {
            append(&candidates, Pptr_Candidate{path = path, label = filepath_base(path), entry = {guid = owner}})
        }
        provider, has := subassets.find(strings.concatenate({".", _path_ext(path)}, context.temp_allocator))
        if !has || provider.list == nil do continue
        own := sub_asset_scope.set && sub_asset_scope.owner == owner
        for s in provider.list(path, context.temp_allocator) {
            if s.kind == "" || !_ext_allowed(s.kind) do continue
            append(&candidates, Pptr_Candidate{
                path  = fmt.tprintf("%s/%s", path, s.name),
                label = fmt.tprintf("%s / %s", _stem(path), s.name),
                entry = {guid = owner, local_id = s.id},
                own   = own,
            })
        }
    }
    if provider, path, has := subassets.of(sub_asset_scope.owner); sub_asset_scope.set && has && path == "" && provider.list != nil {
        for s in provider.list(path, context.temp_allocator) {
            if s.kind == "" || !_ext_allowed(s.kind) do continue
            append(&candidates, Pptr_Candidate{
                path  = fmt.tprintf("%s/%s", path, s.name),
                label = fmt.tprintf("%s / %s", _UNSAVED_FILE, s.name),
                own   = true,
                entry = {guid = sub_asset_scope.owner, local_id = s.id},
            })
        }
    }
    slice.sort_by(candidates[:], proc(a, b: Pptr_Candidate) -> bool {
        if a.own != b.own do return a.own
        return a.path < b.path
    })
    return candidates[:]
}

@(private = "file")
_pptr_picker_rows :: proc(search: []string, current: core.PPtr) -> (picked: core.PPtr, ok: bool) {
    shown := 0
    for cand in pptr_picker_candidates() {
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
