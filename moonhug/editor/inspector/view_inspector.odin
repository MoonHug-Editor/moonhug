package inspector

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:reflect"
import "core:path/filepath"
import "core:encoding/uuid"
import strings "core:strings"
import im "moonhug:external/odin-imgui"
import ser "../../engine/serialization"
import engine "../../engine"
import "moonhug:engine_editor/asset_pipeline"
import clip "../clipboard"
import "../undo"

InspectorMode :: enum {
    Asset,
    ImportSettings,
    Package,
}

mapPropertyDrawer: MapPropertyDrawer
inspectorData: InspectorData
inspector_changed: bool

// Set by the inspector loop before invoking a property drawer, so drawers can
// read field-level tags that aren't part of the (ptr, tid, label) signature.
// Currently used by the Ref_Local / Ref pickers to read `ref:"TypeName"`.
current_field_ref_target: string
// `pick:"scene"` / `pick:"project"` limits which picker tabs are assignable
// for engine.Ref fields (no tag = both).
current_field_pick_mode: string
// Comma-separated allowed extensions from the field's `ext:"..."` tag; limits
// the Asset_GUID picker + drag-drop to matching files ("" = everything).
current_field_ext_filter: string

InspectorData :: struct {
    mode: InspectorMode,
    filePath: string,
    fileData: any,
    doc: ^Asset_Doc, // .Asset mode: the registry document backing fileData
    statusMessage: string,
    importSettings: any, // typed settings instance, owned (default allocator)
    packageName: string, // .Package mode (owned)
    packageAssetCount: int,
}

MapPropertyDrawer :: map[typeid]proc(ptr: rawptr, tid: typeid, label: cstring)

// Asset preview pane: package editor subpackages register a drawer per
// source extension (lowercase, with dot). A matching drawer pins a Preview
// section to the BOTTOM of the Project Inspector, below whatever the mode
// draws (the audio Play/Stop buttons are the reference).
mapAssetPreview: map[string]proc(path: string)

init :: proc() {
    mapPropertyDrawer = make(MapPropertyDrawer)
    mapAssetPreview = make(map[string]proc(path: string))
    decorator_registry = make(DecoratorsMap)
    init_property_drawer_map()
    // Manual registration: the prebuild attribute parser takes plain type
    // names, not container type expressions.
    mapPropertyDrawer[typeid_of([dynamic]engine.Material_Property)] = draw_material_properties
    mapPropertyDrawer[typeid_of([dynamic]engine.Material_Texture)] = draw_material_textures
    init_decorators()
    inspector_buttons = make(map[typeid][]Inspector_Button)
    _register_inspector_buttons()
    undo.set_asset_apply(asset_doc_apply_json)
    undo.set_asset_doc_lookup(asset_doc_payload_ptr)
}

shutdown_registries :: proc() {
    multi_shutdown()
    delete(mapPropertyDrawer)
    delete(mapAssetPreview)
    for _, v in decorator_registry {
        delete(v)
    }
    delete(decorator_registry)
    for _, v in inspector_buttons {
        delete(v)
    }
    delete(inspector_buttons)
    decorators_shutdown()
    if inspectorData.filePath != "" {
        delete(inspectorData.filePath)
    }
    if inspectorData.packageName != "" {
        delete(inspectorData.packageName)
    }
    asset_docs_shutdown()
}

load_from_file :: proc(filepath: string){
    doc := asset_doc_get(filepath)
    if doc != nil {
        delete(inspectorData.filePath)
        inspectorData.filePath = strings.clone(filepath)
        inspectorData.fileData = doc.data
        inspectorData.doc = doc
        inspectorData.mode = .Asset
        inspectorData.statusMessage = fmt.tprintf("Loaded from %s", filepath)
    } else {
        inspectorData.statusMessage = fmt.tprintf("Failed to load %s", filepath)
    }
}

load_import_settings :: proc(filepath: string) {
    settings, ok := engine.asset_pipeline_get_settings(filepath, runtime.default_allocator())
    if ok {
        delete(inspectorData.filePath)
        inspectorData.filePath = strings.clone(filepath)
        inspectorData.fileData = {}
        inspectorData.doc = nil
        // The working copy survives frames — free the previous one.
        if inspectorData.importSettings.data != nil do free(inspectorData.importSettings.data, runtime.default_allocator())
        inspectorData.importSettings = settings
        inspectorData.mode = .ImportSettings
        inspectorData.statusMessage = ""
    } else {
        inspectorData.statusMessage = fmt.tprintf("No import settings for %s", filepath)
    }
}

// Package selected in the project view's Packages section (docs/Plugins.md):
// shows the package inspector instead of an asset document.
load_package :: proc(name: string, assets_path: string, asset_count: int) {
    delete(inspectorData.filePath)
    inspectorData.filePath = strings.clone(assets_path)
    delete(inspectorData.packageName)
    inspectorData.packageName = strings.clone(name)
    inspectorData.packageAssetCount = asset_count
    inspectorData.fileData = {}
    inspectorData.doc = nil
    inspectorData.mode = .Package
    inspectorData.statusMessage = ""
}

get_file_path :: proc() -> string {
    return inspectorData.filePath
}

save_to_file :: proc() {
    // Only an ASSET has a document to write. A package folder (or an import
    // settings view) leaves fileData as a nil `any`, and serializing that asks
    // for the GUID of a nil typeid — which panics rather than failing softly.
    if inspectorData.mode != .Asset || inspectorData.fileData.data == nil {
        return
    }
    if ser.save_to_file(inspectorData.filePath, inspectorData.fileData)
    {
        if inspectorData.doc != nil do inspectorData.doc.dirty = false
        inspectorData.statusMessage = fmt.tprintf("Saved successfully to %s", inspectorData.filePath)
    } else {
        inspectorData.statusMessage = fmt.tprintf("Failed to save %s", inspectorData.filePath)
    }
}

// p_open: the editor's show flag, so the dock tab's X can close the window
// (the menu package imports this one, so the flag is passed in).
// Preview pane's share of the window height, dragged via the splitter
// (the console/history splitter pattern).
_preview_split_ratio: f32 = 0.3

view_inspector_draw :: proc(p_open: ^bool) {
    if im.Begin("Project Inspector", p_open, {.NoCollapse}) {
        // A registered preview pins to the window's bottom — the mode content
        // scrolls in a child above it.
        preview := _asset_preview_drawer()
        avail := im.GetContentRegionAvail()
        splitter_h: f32 = 4
        MIN_PANE :: 60
        preview_h: f32
        if preview != nil {
            preview_h = (avail.y - splitter_h) * _preview_split_ratio
            if preview_h < MIN_PANE do preview_h = MIN_PANE
            if preview_h > avail.y - splitter_h - MIN_PANE do preview_h = avail.y - splitter_h - MIN_PANE
            im.BeginChild("##inspector_body", {0, avail.y - splitter_h - preview_h})
        }
        switch inspectorData.mode {
        case .Asset:
            _draw_asset_inspector()
        case .ImportSettings:
            _draw_import_settings_inspector()
        case .Package:
            _draw_package_inspector()
        }
        if preview != nil {
            im.EndChild()

            splitter_pos := im.GetCursorScreenPos()
            im.InvisibleButton("##preview_split", im.Vec2{-1, splitter_h})
            if im.IsItemActive() {
                delta := im.GetIO().MouseDelta.y
                total := avail.y - splitter_h
                _preview_split_ratio = clamp((preview_h - delta) / total, MIN_PANE / total, (total - MIN_PANE) / total)
            }
            if im.IsItemHovered() || im.IsItemActive() {
                im.SetMouseCursor(.ResizeNS)
            }
            dl := im.GetWindowDrawList()
            split_col := im.IsItemActive() ? im.GetColorU32ImVec4(im.Vec4{0.8, 0.8, 0.8, 0.9}) : im.GetColorU32ImVec4(im.Vec4{0.5, 0.5, 0.5, 0.5})
            im.DrawList_AddLine(dl, splitter_pos, im.Vec2{splitter_pos.x + avail.x, splitter_pos.y}, split_col, 1)

            im.SeparatorText("Preview")
            preview(inspectorData.filePath)
        }
    }
    im.End()
}

_asset_preview_drawer :: proc() -> proc(path: string) {
    if inspectorData.filePath == "" do return nil
    ext := strings.to_lower(filepath.ext(inspectorData.filePath), context.temp_allocator)
    return mapAssetPreview[ext] or_else nil
}

// Samples section hook, injected by the editor root at startup (the file ops
// and dir cache live there, and this package can't import the editor root).
package_samples_draw: proc(pkg_name: string)

// Package inspector (docs/Plugins.md): shown when a package is selected in
// the project view's Packages section (left-pane node or right-pane row).
_draw_package_inspector :: proc() {
    im.Text(strings.clone_to_cstring(fmt.tprintf("Package: %s", inspectorData.packageName), context.temp_allocator))
    im.Separator()
    im.Text(strings.clone_to_cstring(fmt.tprintf("Content root: %s", inspectorData.filePath), context.temp_allocator))
    im.Text(strings.clone_to_cstring(fmt.tprintf("Assets: %d", inspectorData.packageAssetCount), context.temp_allocator))
    im.TextDisabled("Installed package (moonhug/packages) - remove the folder to uninstall.")
    if package_samples_draw != nil {
        package_samples_draw(inspectorData.packageName)
    }
}

_draw_asset_inspector :: proc() {
    // Undo may have swapped the document payload since last frame.
    if inspectorData.doc != nil {
        inspectorData.fileData = inspectorData.doc.data
    }

    if im.Button("Save", im.Vec2{60, 0}) {
        save_to_file()
    }
    im.SameLine()

    if inspectorData.statusMessage != "" {
        im.Text(strings.clone_to_cstring(inspectorData.statusMessage, context.temp_allocator))
    }

    im.Separator()

    if inspectorData.filePath != "" {
        dirty := inspectorData.doc != nil && inspectorData.doc.dirty ? " *" : ""
        im.Text(strings.clone_to_cstring(fmt.tprintf("File: %s%s", inspectorData.filePath, dirty), context.temp_allocator))
    } else {
        im.TextColored(im.Vec4{1, 0, 0, 1}, "No file loaded")
    }

    im.Separator()

    if inspectorData.fileData.data != nil {
        if inspectorData.fileData.id == typeid_of(engine.Material) {
            current_material = cast(^engine.Material)inspectorData.fileData.data
        }
        // Whole-document undo: _undo_finalize_widget after each drawer snapshots
        // and commits against this owner, exactly like the component inspector.
        if inspectorData.doc != nil {
            undo.push_asset_owner(inspectorData.doc.guid, inspectorData.fileData.data, inspectorData.fileData.id)
        }
        prev_changed := inspector_changed
        inspector_changed = false
        draw_inspector(inspectorData.fileData)
        if inspector_changed && inspectorData.doc != nil {
            inspectorData.doc.dirty = true
        }
        inspector_changed |= prev_changed
        if inspectorData.doc != nil do undo.pop_owner()
        _material_live_preview()
        current_material = nil
    }
}

// Material edits render live (Unity-style): the open .mat's values are
// pushed into the engine material cache every frame, saved or not. Save
// persists them to disk; unsaved edits revert on the next editor run.
// Property rows for the assigned custom shader auto-populate from its
// reflected UBO members, so names never have to be typed by hand.
_material_live_preview :: proc() {
    if inspectorData.fileData.id != typeid_of(engine.Material) do return
    mat := cast(^engine.Material)inspectorData.fileData.data
    _ = engine.material_sync_properties(mat)
    if guid, ok := engine.asset_db_get_guid(inspectorData.filePath); ok {
        engine.material_preview(engine.Asset_GUID(guid), mat^)
    }
}

_draw_import_settings_inspector :: proc() {
    // Registered wrappers funnel the settings body (inspector_funnel.odin),
    // keyed by the importer owning this asset's extension.
    ext := strings.to_lower(filepath.ext(inspectorData.filePath), context.temp_allocator)
    if chain, has := _asset_chain(asset_pipeline.importer_for_extension(ext)); has {
        guid: engine.Asset_GUID
        if g, ok := engine.asset_db_get_guid(inspectorData.filePath); ok {
            guid = engine.Asset_GUID(g)
        }
        actx := Asset_Ctx{
            path     = inspectorData.filePath,
            guid     = guid,
            settings = inspectorData.importSettings,
            _chain   = chain,
        }
        _funnel_draw(&actx)
        return
    }
    draw_default_import_settings()
}

// The asset funnel's base: Apply + file row + the reflected settings.
draw_default_import_settings :: proc() {
    if im.Button("Apply", im.Vec2{60, 0}) {
        if asset_pipeline.asset_pipeline_save_settings(inspectorData.filePath, inspectorData.importSettings) {
            // Reimport hooks evict every guid-keyed cache (textures, package
            // asset caches) so the new settings apply without a restart.
            asset_pipeline.asset_pipeline_reimport(inspectorData.filePath)
            inspectorData.statusMessage = fmt.tprintf("Reimported %s", inspectorData.filePath)
        } else {
            inspectorData.statusMessage = fmt.tprintf("Failed to save settings for %s", inspectorData.filePath)
        }
    }
    im.SameLine()

    if inspectorData.statusMessage != "" {
        im.Text(strings.clone_to_cstring(inspectorData.statusMessage, context.temp_allocator))
    }

    im.Separator()

    if inspectorData.filePath != "" {
        im.Text(strings.clone_to_cstring(fmt.tprintf("File: %s", inspectorData.filePath), context.temp_allocator))
    }

    im.Separator()

    if inspectorData.importSettings.data != nil {
        drawer := resolve_property_drawer(inspectorData.importSettings.id)
        drawer(inspectorData.importSettings.data, inspectorData.importSettings.id, "Import Settings")
    }

}

mark_inspector_changed :: proc() {
    inspector_changed = true
}

consume_inspector_changed :: proc() -> bool {
    changed := inspector_changed
    inspector_changed = false
    return changed
}

is_changed_flag_set :: proc() -> bool {
    return inspector_changed
}


@(private)
_is_picker_type :: proc(tid: typeid) -> bool {
    return tid == typeid_of(engine.Asset_GUID) ||
           tid == typeid_of(engine.Ref) ||
           tid == typeid_of(engine.Ref_Local)
}

// Records a prefab-instance override for a field whose edit just committed, so
// the override marker / Revert / Apply light up immediately instead of after a
// save. No-op for non-nested content.
//
// `committed` is the caller's commit signal, from Field_Commit (see
// field_commit_state): the generic loop passes what _undo_finalize_widget
// detected, the transform wrappers what their own commit branch decided.
// Recording is a CONSEQUENCE of committing, never its own detection — that
// split is what let the transform fields miss overrides.
//
// When the edit CREATED the override (as opposed to updating an existing one),
// the undo step is told, so undo takes the record away with the value.
record_nested_override :: proc(field_ptr: rawptr, field_tid: typeid, property_path: string, committed: bool) {
    if !committed || property_path == "" || field_ptr == nil do return

    host_tH := engine.inspector_get_nested_host()
    nested_lid := engine.inspector_get_nested_local_id()
    if host_tH == {} || nested_lid == 0 do return

    w := engine.ctx_world()
    ht := engine.pool_get(&w.transforms, engine.Handle(host_tH))
    if ht == nil do return
    created, ok := engine.nested_scene_record_override_for_host(ht.scene, host_tH, nested_lid, property_path, field_ptr, field_tid)
    if ok && created {
        undo.record_override_created(ht.scene, host_tH, nested_lid, property_path)
    }
}

// THE commit predicate for an inspector field widget, in one place. Every
// field-edit boundary is one of these two events:
//
//   Field_Commit.Drag_Released — the widget owned the edit and gave it back
//     (imgui's IsItemDeactivatedAfterEdit: drag release, InputText Enter/blur).
//   Field_Commit.Value_Applied — the value changed without the widget holding
//     focus (typed digits applied inline, drawer wrote through immediately).
//
// The two are NOT interchangeable to callers: the rotation wrapper ends its
// euler cache on a released drag and not on an inline write. Returning WHICH
// event happened, rather than a bare bool, is what lets every wrapper share this
// detection while keeping its own commit strategy — the duplication that
// previously let one wrapper consume the changed flag another wrapper needed to
// read.
Field_Commit :: enum {
    None,
    Drag_Released,
    Value_Applied,
}

// `changed`: did the value change this frame. Pass the caller's OWN signal —
// a wrapper that consumed the package flag (the transform wrappers) has to,
// since the flag reads false by then. field_commit_state() uses the package
// flag and is what the generic field loop wants.
field_commit_state_of :: proc(changed: bool) -> Field_Commit {
    if im.IsItemDeactivatedAfterEdit() do return .Drag_Released
    if changed && !im.IsItemActive() do return .Value_Applied
    return .None
}

// Commit state from the package changed flag (generic field loop).
field_commit_state :: proc() -> Field_Commit {
    return field_commit_state_of(inspector_changed)
}

resolve_property_drawer :: proc(tid: typeid) -> proc(ptr: rawptr, tid: typeid, label: cstring) {
    if drawer, ok := mapPropertyDrawer[tid]; ok {
        return drawer
    }
    return draw_default_inspector
}

draw_default_inspector :: proc(ptr: rawptr, tid: typeid, label: cstring) {
    a := any{ptr, tid}
    draw_inspector(a, label, "")
}

@(private)
_FieldMenuUndo :: struct {
    active: bool,
    sess:   undo.Edit_Session,
}

// Reset / Paste from the field's context menu. These write from a popup rather
// than a drag, so the whole write is bracketed here in one call - the session
// picks field or whole-owner granularity from where field_ptr lands.
@(private)
_field_menu_undo_begin :: proc(field_ptr: rawptr, field_tid: typeid, label: string) -> _FieldMenuUndo {
    targets := make([dynamic]undo.Edit_Target, 0, multi_peer_count() + 1, context.temp_allocator)
    if o, ok := undo.current_owner(); ok {
        switch o.kind {
        case .None:
        case .Pooled:
            append(&targets, undo.edit_target_pooled(o.handle, field_ptr, field_tid))
        case .Asset:
            append(&targets, undo.Edit_Target{
                kind = .Asset, asset_guid = o.asset_guid, asset_tid = o.asset_tid,
                field_ptr = field_ptr, field_tid = field_tid,
            })
        case .Raw:
            append(&targets, undo.Edit_Target{
                kind = .Raw, raw_ptr = o.base_ptr, raw_tid = o.raw_tid,
                field_ptr = field_ptr, field_tid = field_tid,
            })
        }
    }
    if len(targets) == 0 do return {}
    return _FieldMenuUndo{active = true, sess = undo.edit_session_begin(targets[:], label)}
}

@(private)
_field_menu_undo_end :: proc(u: _FieldMenuUndo) {
    if !u.active do return
    s := u.sess
    undo.edit_session_end(&s)
}

@(private)
_draw_field_context_menu_reset :: proc(field_ptr: rawptr, field_tid: typeid, readonly: bool, property_path: string) -> bool {
    full_ti := type_info_of(field_tid)
    check_ti := runtime.type_info_base(full_ti)
    check_tid := field_tid
    if ptr_info, ok := check_ti.variant.(runtime.Type_Info_Pointer); ok {
        check_tid = ptr_info.elem.id
        full_ti = type_info_of(check_tid)
        check_ti = runtime.type_info_base(full_ti)
    }
    fixed_count := 0
    elem_size := 0
    is_fixed_array := false
    is_dyn_array := false
    if info, ok := check_ti.variant.(runtime.Type_Info_Array); ok {
        check_ti = runtime.type_info_base(info.elem)
        check_tid = info.elem.id
        fixed_count = info.count
        elem_size = int(info.elem.size)
        is_fixed_array = true
    } else if info, ok := check_ti.variant.(runtime.Type_Info_Dynamic_Array); ok {
        check_ti = runtime.type_info_base(info.elem)
        check_tid = info.elem.id
        elem_size = int(info.elem.size)
        is_dyn_array = true
    }
    if key, ok := engine.get_type_key_by_typeid(check_tid); ok && engine.type_reset_procs[key] != nil {
        if im.MenuItem("Reset", nil, false, !readonly) {
            u := _field_menu_undo_begin(field_ptr, field_tid, "Reset")
            if is_fixed_array {
                for i in 0 ..< fixed_count {
                    p := rawptr(uintptr(field_ptr) + uintptr(i * elem_size))
                    engine.type_reset(key, p)
                }
            } else if is_dyn_array {
                da := (^runtime.Raw_Dynamic_Array)(field_ptr)
                for i in 0 ..< da.len {
                    p := rawptr(uintptr(da.data) + uintptr(i * elem_size))
                    engine.type_reset(key, p)
                }
            } else {
                engine.type_reset(key, field_ptr)
            }
            _field_menu_undo_end(u)
            // Reset is an ordinary value edit: on prefab-instance content it
            // creates an override like typing a value would.
            record_nested_override(field_ptr, field_tid, property_path, true)
            mark_inspector_changed()
        }
        return true
    }
    if reflect.is_integer(check_ti) || reflect.is_float(check_ti) || reflect.is_boolean(check_ti) ||
       reflect.is_enum(check_ti) {
        if im.MenuItem("Reset", nil, false, !readonly) {
            u := _field_menu_undo_begin(field_ptr, field_tid, "Reset")
            if is_fixed_array {
                if property_path == "scale" && check_tid == typeid_of(f32) && fixed_count == 3 {
                    (cast(^[3]f32)(field_ptr))^ = {1, 1, 1}
                } else if property_path == "rotation" && check_tid == typeid_of(f32) && fixed_count == 4 {
                    (cast(^[4]f32)(field_ptr))^ = engine.QUAT_IDENTITY
                } else {
                    mem.zero(field_ptr, full_ti.size)
                }
            } else if is_dyn_array {
                da := (^runtime.Raw_Dynamic_Array)(field_ptr)
                if da.data != nil && da.len > 0 {
                    mem.zero(da.data, da.len * elem_size)
                }
            } else {
                mem.zero(field_ptr, full_ti.size)
            }
            _field_menu_undo_end(u)
            // Reset is an ordinary value edit: on prefab-instance content it
            // creates an override like typing a value would.
            record_nested_override(field_ptr, field_tid, property_path, true)
            mark_inspector_changed()
        }
        return true
    }
    return false
}

draw_field_context_menu :: proc(field_ptr: rawptr, field_tid: typeid, property_path: string = "") {
    popup_id := strings.clone_to_cstring(fmt.tprintf("##vcp_%x", uintptr(field_ptr)), context.temp_allocator)
    im.OpenPopupOnItemClick(popup_id, im.PopupFlags_MouseButtonRight)
    if im.BeginPopup(popup_id) {
        readonly := engine.inspector_is_readonly()
        if _draw_field_context_menu_reset(field_ptr, field_tid, readonly, property_path) {
            im.Separator()
        }

        host_tH := engine.inspector_get_nested_host()
        nested_lid := engine.inspector_get_nested_local_id()
        if host_tH != {} && nested_lid != 0 && property_path != "" {
            w := engine.ctx_world()
            ht := engine.pool_get(&w.transforms, engine.Handle(host_tH))
            if ht != nil {
                // Per docs/PrefabsSpec.md §3.2, overrides live at the root scene
                // level only. Walk up to the root native NS and look for the
                // breadcrumb-keyed override that root holds for this field.
                root_ns, root_target, ok := engine.nested_scene_locate_root_override(ht.scene, host_tH, nested_lid)
                is_overridden := ok && engine.nested_scene_has_override(root_ns, root_target, property_path)
                if is_overridden {
	                if im.MenuItem("Revert", nil, false, is_overridden) {
	                    // Snapshot the entries BEFORE the revert deletes them;
	                    // they are attached to the undo step after it commits,
	                    // so the record undoes together with the value.
	                    snap := undo.override_removal_snapshot(root_ns, root_target, property_path)
	                    u := _field_menu_undo_begin(field_ptr, field_tid, "Revert")
	                    engine.nested_scene_revert_override(ht.scene, root_ns, root_target, property_path, field_ptr)
	                    _field_menu_undo_end(u)
	                    undo.record_override_removed(ht.scene, host_tH, nested_lid, property_path, snap)
	                    mark_inspector_changed()
	                }
	                // Apply pushes the override into a prefab on the field's chain.
	                // Unity-style: flat menu items (not a submenu), one per target,
	                // ordered closest -> base. The last target is the file that
	                // owns the row — applying there bakes the value in ("Apply to
	                // Scene X"); every other target records an override in that
	                // prefab ("Apply as Override in X"), variants included.
	                targets := engine.nested_scene_apply_targets(ht.scene, root_ns, root_target)
	                for tgt in targets {
	                    name := "scene"
	                    if p, pok := engine.asset_db_get_path(uuid.Identifier(tgt.guid)); pok {
	                        name = filepath.stem(p)
	                    }
	                    text := tgt.is_owner \
	                        ? fmt.tprintf("Apply to Scene '%s'", name) \
	                        : fmt.tprintf("Apply as Override in '%s'", name)
	                    label := strings.clone_to_cstring(text, context.temp_allocator)
	                    if im.MenuItem(label, nil, false, true) {
	                        entry := engine.Override_Entry{
	                            kind          = .Modified_Property,
	                            target        = root_target,
	                            property_path = property_path,
	                        }
	                        root_host := engine.Transform_Handle(
	                            engine.nested_scene_resolve_host_handle(ht.scene, root_ns))
	                        engine.nested_scene_apply_entries(
	                            ht.scene, root_host, tgt.guid, {entry})
	                        mark_inspector_changed()
	                    }
	                }
	                im.Separator()
                }
            }
        }

        if im.MenuItem("Copy") {
            clip.copy(any{field_ptr, field_tid})
        }
        can := clip.can_paste(field_tid) && !readonly
        if im.MenuItem("Paste", nil, false, can) {
            clip.paste(any{field_ptr, field_tid})
        }
        im.EndPopup()
    }
}

draw_inspector :: proc(a: any, label: cstring = "", path_prefix: string = "") {
    xAny := a
    ptr, tid := reflect.any_data(xAny)
    tInfo := type_info_of(tid)

    isPointer := reflect.is_pointer(tInfo)
    if isPointer {
        im.Indent(20)
        draw_inspector(reflect.deref(xAny), "", path_prefix)
        im.Unindent(20)
        return
    }

    // Registered wrappers funnel this type's draw (inspector_funnel.odin).
    // No registration: straight to the default drawing.
    if chain, has := _component_chain(tid); has {
        cctx := Component_Ctx{ptr = ptr, tid = tid, label = label, path_prefix = path_prefix, _chain = chain}
        _funnel_draw(&cctx)
        return
    }
    draw_inspector_default(ptr, tid, label, path_prefix)
}

// The funnel's end of chain: the type's custom drawer, or the reflected
// field loop. Never re-enters the funnel — that is what makes wrapping
// non-recursive.
draw_inspector_default :: proc(ptr: rawptr, tid: typeid, label: cstring, path_prefix: string) {
    if drawer, ok := mapPropertyDrawer[tid]; ok {
        drawer(ptr, tid, label)
        return
    }

    xAny := any{ptr, tid}
    names := reflect.struct_field_names(tid)
    types := reflect.struct_field_types(tid)
    count := len(names)

    // @(inspector_button) rows >= 0 frame this struct's draw from the TOP —
    // wherever it appears (component, nested field, array element); buttons
    // with show_in_array=false skip array elements.
    draw_inspector_buttons(tid, ptr, above = true, element_ctx = _in_array_element)

    for i in 0..<count {
        field_info := reflect.struct_field_at(tid, i)
        inspect_val, has_inspect := reflect.struct_tag_lookup(field_info.tag, "inspect")
        if has_inspect && inspect_val == "-" {
            continue
        }
        json_val, has_json := reflect.struct_tag_lookup(field_info.tag, "json")
        if !has_inspect && has_json && json_val == "-" {
            continue
        }

        field_name := names[i]
        c_field_name := strings.clone_to_cstring(field_name)
        defer delete(c_field_name)
        field_type := types[i]
        field_val := reflect.struct_field_value(xAny, field_info)

        field_ptr := rawptr(uintptr(ptr) + field_info.offset)

        full_path := path_prefix == "" ? field_name : strings.concatenate({path_prefix, ".", field_name}, context.temp_allocator)

        nested_lid := engine.inspector_get_nested_local_id()
        host_tH := engine.inspector_get_nested_host()
        is_field_overridden := false
        if nested_lid != 0 && host_tH != {} {
            w := engine.ctx_world()
            ht := engine.pool_get(&w.transforms, engine.Handle(host_tH))
            if ht != nil {
                is_field_overridden = engine.nested_scene_has_root_override(ht.scene, host_tH, nested_lid, full_path)
            }
        }

		ctx := DrawContext{is_visible = true, is_pre = true, field_ptr = field_ptr, field_type = field_type.id, field_label = c_field_name, owner_ptr = ptr, owner_type = tid}

        im.PushID(c_field_name)
        prev_changed_outside := inspector_changed
        inspector_changed = false

        if is_field_overridden {
            im.PushStyleColorImVec4(im.Col.Text, im.Vec4{0.4, 0.8, 1.0, 1.0})
        }

        run_field_decorators(tid, i, &ctx)

        row_popup_done := false

        if ctx.is_visible {
            // Field-level picker tags apply through EVERY drawer path — a
            // [dynamic]Asset_GUID `ext:"mat"` field reaches the guid drawer
            // via draw_inspector_array, and the elements must still filter.
            ref_tag, _ := reflect.struct_tag_lookup(field_info.tag, "ref")
            current_field_ref_target = ref_tag
            pick_tag, _ := reflect.struct_tag_lookup(field_info.tag, "pick")
            current_field_pick_mode = pick_tag
            ext_tag, _ := reflect.struct_tag_lookup(field_info.tag, "ext")
            current_field_ext_filter = ext_tag
            defer {
                current_field_ref_target = ""
                current_field_pick_mode = ""
                current_field_ext_filter = ""
            }

            if drawer, ok := mapPropertyDrawer[field_type.id]; ok {
                // Mixed-value display for the selection. Read by the drawer.
                multi_offset := multi_offset_of(field_ptr, ptr)
                multi_probe_field(field_ptr, field_type.id, multi_offset)

                // Group the drawer's widgets so the field context menu below
                // binds to the WHOLE row. A drawer can emit several items (e.g.
                // Ref_Local: picker button + "X" clear) and OpenPopupOnItemClick
                // only tests the last one — right-click would then work only on
                // the tiny X (or only when no value meant no X).
                im.BeginGroup()
                // The whole transaction, shared with the array-element path so
                // the two cannot drift — see field_edit_row.
                // Peers record their overrides against their own instances, and
                // the path names which field — see field_edit.odin.
                prev_path := field_edit_set_path(full_path)
                finished := field_edit_row(field_ptr, field_type.id, multi_offset,
                                           field_name, drawer, c_field_name)
                field_edit_set_path(prev_path)
                im.EndGroup()
                record_nested_override(field_ptr, field_type.id, full_path, finished)
            } else if is_array_type(field_type.id) {
                // Elements multi-edit through their own rebased peer list —
                // draw_inspector_array does that itself, since only it knows
                // where the element storage is.
                draw_inspector_array_multi(field_ptr, field_type.id, c_field_name, multi_offset_of(field_ptr, ptr))
                row_popup_done = true
            } else if is_union_type(field_type.id) {
                // A union's payload type can differ per object, so the same
                // bytes would mean different things — see multi_suspend.
                mprev := multi_suspend()
                draw_inspector_union(field_ptr, field_type.id, c_field_name)
                multi_resume(mprev)
                row_popup_done = true
            } else if is_enum_type(field_type.id) {
                // An enum row is a combo: the value lands from a popup, so the
                // gesture opens before the draw like the pickers.
                multi_offset := multi_offset_of(field_ptr, ptr)
                multi_probe_field(field_ptr, field_type.id, multi_offset)
                field_edit_begin(field_ptr, field_type.id, multi_offset, field_name)
                draw_inspector_enum(field_ptr, field_type.id, c_field_name)
                multi_clear_mixed()
                changed := is_changed_flag_set()
                if changed {
                    field_edit_apply_to_peers(field_ptr, field_type.id, multi_offset)
                }
                record_nested_override(field_ptr, field_type.id, full_path, changed)
                if changed || !im.IsItemActive() {
                    field_edit_end()
                }
                row_popup_done = true
            } else if reflect.is_struct(field_type) || reflect.is_union(field_type) {
                // Descending into a nested struct: the peers' matching fields
                // sit at the same offset inside THEIR copy, so the recursion
                // carries the accumulated offset rather than the raw pointer.
                prev_off := multi_push_offset(uintptr(field_ptr) - uintptr(ptr))
                defer multi_pop_offset(prev_off)
                _, is_inline := reflect.struct_tag_lookup(field_info.tag, "inline")
                if is_inline {
                    draw_inspector(field_val, "", full_path)
                    row_popup_done = true
                } else {
                    tree_open := im.TreeNode(c_field_name)
                    draw_field_context_menu(field_ptr, field_type.id, full_path)
                    row_popup_done = true
                    if tree_open {
                        draw_inspector(field_val, "", full_path)
                        im.TreePop()
                    }
                }
            } else if reflect.is_pointer(type_info_of(field_type.id)) {
                draw_inspector(field_val, "", full_path)
                row_popup_done = true
            } else {
                c_str := strings.clone_to_cstring(fmt.tprintf("%s: %v", field_name, field_val))
                defer delete(c_str)
                im.Text(c_str)
            }
            if !row_popup_done {
                draw_field_context_menu(field_ptr, field_type.id, full_path)
            }
        } else if ctx.handled_draw {
            // A decorator drew this field itself. It is still a VALUE edit, so
            // it gets the same transaction every other row does — the drawer
            // already ran, so the row is driven with a nil drawer.
            multi_offset := multi_offset_of(field_ptr, ptr)
            prev_path := field_edit_set_path(full_path)
            finished := field_edit_row(field_ptr, field_type.id, multi_offset,
                                       field_name, nil, c_field_name)
            field_edit_set_path(prev_path)
            record_nested_override(field_ptr, field_type.id, full_path, finished)
            draw_field_context_menu(field_ptr, field_type.id, full_path)
        }

        if is_field_overridden {
            im.PopStyleColor(1)
        }

        if prev_changed_outside || inspector_changed do inspector_changed = true
        im.PopID()

        ctx.is_pre = false
        run_field_decorators(tid, i, &ctx)
    }

    // @(inspector_button) rows < 0 close this struct's draw from the BOTTOM.
    draw_inspector_buttons(tid, ptr, above = false, element_ctx = _in_array_element)
}
