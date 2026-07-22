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
    importSettings: engine.ImportSettings,
    packageName: string, // .Package mode (owned)
    packageAssetCount: int,
}

MapPropertyDrawer :: map[typeid]proc(ptr: rawptr, tid: typeid, label: cstring)

init :: proc() {
    mapPropertyDrawer = make(MapPropertyDrawer)
    decorator_registry = make(DecoratorsMap)
    init_property_drawer_map()
    // Manual registration: the prebuild attribute parser takes plain type
    // names, not container type expressions.
    mapPropertyDrawer[typeid_of([dynamic]engine.Material_Property)] = draw_material_properties
    mapPropertyDrawer[typeid_of([dynamic]engine.Material_Texture)] = draw_material_textures
    init_decorators()
    undo.set_asset_apply(asset_doc_apply_json)
}

shutdown_registries :: proc() {
    delete(mapPropertyDrawer)
    for _, v in decorator_registry {
        delete(v)
    }
    delete(decorator_registry)
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
    settings, ok := engine.asset_pipeline_get_settings(filepath)
    if ok {
        delete(inspectorData.filePath)
        inspectorData.filePath = strings.clone(filepath)
        inspectorData.fileData = {}
        inspectorData.doc = nil
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
    if ser.save_to_file(inspectorData.filePath, inspectorData.fileData)
    {
        if inspectorData.doc != nil do inspectorData.doc.dirty = false
        inspectorData.statusMessage = fmt.tprintf("Saved successfully to %s", inspectorData.filePath)
    } else {
        inspectorData.statusMessage = fmt.tprintf("Failed to save %s", inspectorData.filePath)
    }
}

view_inspector_draw :: proc() {
    if im.Begin("Project Inspector", nil, {.NoCollapse}) {
        switch inspectorData.mode {
        case .Asset:
            _draw_asset_inspector()
        case .ImportSettings:
            _draw_import_settings_inspector()
        case .Package:
            _draw_package_inspector()
        }
    }
    im.End()
}

// Package inspector (docs/Plugins.md): shown when a package row is selected
// in the project view's Packages section. Read-only summary for now — a
// manifest (name/version/description) can feed it later.
_draw_package_inspector :: proc() {
    im.Text(strings.clone_to_cstring(fmt.tprintf("Package: %s", inspectorData.packageName), context.temp_allocator))
    im.Separator()
    im.Text(strings.clone_to_cstring(fmt.tprintf("Content root: %s", inspectorData.filePath), context.temp_allocator))
    im.Text(strings.clone_to_cstring(fmt.tprintf("Assets: %d", inspectorData.packageAssetCount), context.temp_allocator))
    im.TextDisabled("Installed package (moonhug/packages) — remove the folder to uninstall.")
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
    if im.Button("Apply", im.Vec2{60, 0}) {
        if engine.asset_pipeline_save_settings(inspectorData.filePath, inspectorData.importSettings) {
            engine.asset_pipeline_reimport(inspectorData.filePath)
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

    settings_any := reflect.union_variant_typeid(inspectorData.importSettings)
    if settings_any != nil {
        ptr := &inspectorData.importSettings
        drawer := resolve_property_drawer(settings_any)
        drawer(rawptr(ptr), settings_any, "Import Settings")
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
_undo_finalize_widget :: proc() {
    if im.IsItemActivated() {
        undo.comp_snapshot()
    }
    if im.IsItemDeactivatedAfterEdit() {
        undo.comp_commit()
    } else if inspector_changed && !im.IsItemActive() {
        undo.comp_commit()
    }
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
    comp:  bool,
    field: bool,
    scope: undo.Edit_Scope,
}

@(private)
_field_menu_undo_begin :: proc(field_ptr: rawptr, field_tid: typeid, label: string) -> _FieldMenuUndo {
    o, ok := undo.current_owner()
    if ok && (o.kind == .Asset || (o.kind == .Pooled && o.handle.type_key != .Transform)) {
        if undo.pending_is_active() {
            undo.comp_commit()
        }
        undo.comp_snapshot()
        if undo.pending_is_active() {
            return _FieldMenuUndo{comp = true}
        }
    }
    e := undo.edit_inspector_field_begin(field_ptr, field_tid, label)
    return _FieldMenuUndo{field = e.active, scope = e}
}

@(private)
_field_menu_undo_end :: proc(u: _FieldMenuUndo) {
    if u.comp {
        undo.comp_commit()
        return
    }
    if u.field {
        s := u.scope
        undo.edit_end(&s)
    }
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
                // Per docs/NestedPrefabs.md, overrides live at the root scene
                // level only. Walk up to the root native NS and look for the
                // breadcrumb-keyed override that root holds for this field.
                root_ns, root_target, ok := engine.nested_scene_locate_root_override(ht.scene, host_tH, nested_lid)
                is_overridden := ok && engine.nested_scene_has_override(root_ns, root_target, property_path)
                if is_overridden {
	                if im.MenuItem("Revert", nil, false, is_overridden) {
	                    u := _field_menu_undo_begin(field_ptr, field_tid, "Revert")
	                    engine.nested_scene_revert_override(ht.scene, root_ns, root_target, property_path, field_ptr)
	                    _field_menu_undo_end(u)
	                    mark_inspector_changed()
	                }
	                // Apply bakes the override up into an ancestor prefab. Unity-
	                // style: flat menu items (not a submenu), one per applicable
	                // level, ordered shallowest -> deepest. The deepest level
	                // (lvl 1) is the prefab that actually owns the field — applying
	                // there bakes the value in ("Apply to Prefab X"); shallower
	                // levels record an override in an intermediate prefab
	                // ("Apply as Override in X").
	                levels := engine.nested_scene_apply_levels(ht.scene, root_ns, root_target)
	                for lvl := levels; lvl >= 1; lvl -= 1 {
	                    name := "scene"
	                    is_owner := false
	                    if g, owner, gok := engine.nested_scene_apply_target_guid(ht.scene, root_ns, root_target, lvl); gok {
	                        is_owner = owner
	                        if p, pok := engine.asset_db_get_path(uuid.Identifier(g)); pok {
	                            name = filepath.stem(p)
	                        }
	                    }
	                    text := is_owner \
	                        ? fmt.tprintf("Apply to Scene '%s'", name) \
	                        : fmt.tprintf("Apply as Override in '%s'", name)
	                    label := strings.clone_to_cstring(text, context.temp_allocator)
	                    if im.MenuItem(label, nil, false, true) {
	                        engine.nested_scene_apply_override(ht.scene, root_ns, root_target, property_path, lvl)
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

    if drawer, ok := mapPropertyDrawer[tid]; ok {
        drawer(ptr, tid, label)
        return
    }

    names := reflect.struct_field_names(tid)
    types := reflect.struct_field_types(tid)
    count := len(names)

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

		ctx := DrawContext{is_visible = true, is_pre = true, field_ptr = field_ptr, field_type = field_type.id, field_label = c_field_name}

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
                // Group the drawer's widgets so the field context menu below
                // binds to the WHOLE row. A drawer can emit several items (e.g.
                // Ref_Local: picker button + "X" clear) and OpenPopupOnItemClick
                // only tests the last one — right-click would then work only on
                // the tiny X (or only when no value meant no X).
                im.BeginGroup()
                drawer(field_ptr, field_type.id, c_field_name)
                im.EndGroup()
                _undo_finalize_widget()
            } else if is_array_type(field_type.id) {
                draw_inspector_array(field_ptr, field_type.id, c_field_name)
                row_popup_done = true
            } else if is_union_type(field_type.id) {
                draw_inspector_union(field_ptr, field_type.id, c_field_name)
                row_popup_done = true
            } else if is_enum_type(field_type.id) {
                draw_inspector_enum(field_ptr, field_type.id, c_field_name)
                _undo_finalize_widget()
                row_popup_done = true
            } else if reflect.is_struct(field_type) || reflect.is_union(field_type) {
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
            _undo_finalize_widget()
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
}
