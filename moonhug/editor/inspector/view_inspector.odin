package inspector

import "core:fmt"
import "core:reflect"
import strings "core:strings"
import im "../../../external/odin-imgui"
import ser "../../engine/serialization"
import engine "../../engine"

InspectorMode :: enum {
    Asset,
    ImportSettings,
}

mapPropertyDrawer: MapPropertyDrawer
inspectorData: InspectorData

InspectorData :: struct {
    mode: InspectorMode,
    filePath: string,
    fileData: any,
    statusMessage: string,
    importSettings: engine.ImportSettings,
}

MapPropertyDrawer :: map[typeid]proc(ptr: rawptr, tid: typeid, label: cstring)

init :: proc() {
    mapPropertyDrawer = make(MapPropertyDrawer)
    decorator_registry = make(DecoratorsMap)
    init_property_drawer_map()
    init_decorators()
}

load_from_file :: proc(filepath: string){
    file_data, ok := ser.load_from_file(filepath)
    if ok {
        delete(inspectorData.filePath)
        inspectorData.filePath = strings.clone(filepath)
        inspectorData.fileData = file_data
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
        inspectorData.importSettings = settings
        inspectorData.mode = .ImportSettings
        inspectorData.statusMessage = ""
    } else {
        inspectorData.statusMessage = fmt.tprintf("No import settings for %s", filepath)
    }
}

get_file_path :: proc() -> string {
    return inspectorData.filePath
}

save_to_file :: proc() {
    if ser.save_to_file(inspectorData.filePath, inspectorData.fileData)
    {
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
        }
    }
    im.End()
}

_draw_asset_inspector :: proc() {
    if im.Button("Save", im.Vec2{60, 0}) {
        if ser.save_to_file(inspectorData.filePath, inspectorData.fileData) {
            inspectorData.statusMessage = fmt.tprintf("Saved successfully to %s", inspectorData.filePath)
        } else {
            inspectorData.statusMessage = fmt.tprintf("Failed to save %s", inspectorData.filePath)
        }
    }
    im.SameLine()

    if inspectorData.statusMessage != "" {
        im.Text(strings.clone_to_cstring(inspectorData.statusMessage, context.temp_allocator))
    }

    im.Separator()

    if inspectorData.filePath != "" {
        im.Text(strings.clone_to_cstring(fmt.tprintf("File: %s", inspectorData.filePath), context.temp_allocator))
    } else {
        im.TextColored(im.Vec4{1, 0, 0, 1}, "No file loaded")
    }

    im.Separator()

    if inspectorData.fileData.data != nil {
        draw_inspector(inspectorData.fileData)
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

resolve_property_drawer :: proc(tid: typeid) -> proc(ptr: rawptr, tid: typeid, label: cstring) {
    if drawer, ok := mapPropertyDrawer[tid]; ok {
        return drawer
    }
    return draw_default_inspector
}

draw_default_inspector :: proc(ptr: rawptr, tid: typeid, label: cstring) {
    a := any{ptr, tid}
    draw_inspector(a, label)
}


draw_inspector :: proc(a: any, label: cstring = "") {
    xAny := a
    ptr, tid := reflect.any_data(xAny)
    tInfo := type_info_of(tid)

    isPointer := reflect.is_pointer(tInfo)
    if isPointer {
        im.Indent(20)
        draw_inspector(reflect.deref(xAny))
        im.Unindent(20)
        return
    }

    if drawer, ok := mapPropertyDrawer[tid]; ok {
        drawer(ptr, tid, label)
        return
    }

    // Draw type name
    //type_name := fmt.tprintf("%v", tInfo)
    //if label != "" {
    //    im.Text(strings.clone_to_cstring(fmt.tprintf("%s: %s", label, type_name), context.temp_allocator))
    //} else {
    //    im.Text(strings.clone_to_cstring(type_name, context.temp_allocator))
    //}

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

        // Get pointer to the field for write-back
        field_ptr := rawptr(uintptr(ptr) + field_info.offset)

		ctx := DrawContext{is_visible = true, is_pre = true, field_ptr = field_ptr, field_type = field_type.id, field_label = c_field_name}
        run_field_decorators(tid, i, &ctx)

        if ctx.is_visible
        {
            if drawer, ok := mapPropertyDrawer[field_type.id]; ok {
                drawer(field_ptr, field_type.id, c_field_name)
            } else if is_array_type(field_type.id) {
                draw_inspector_array(field_ptr, field_type.id, c_field_name)
            } else if is_union_type(field_type.id) {
                draw_inspector_union(field_ptr, field_type.id, c_field_name)
            } else if is_enum_type(field_type.id) {
                draw_inspector_enum(field_ptr, field_type.id, c_field_name)
            } else if reflect.is_struct(field_type) || reflect.is_union(field_type) {
                _, is_inline := reflect.struct_tag_lookup(field_info.tag, "inline")
                if is_inline {
                    draw_inspector(field_val)
                } else if im.TreeNode(c_field_name) {
                    draw_inspector(field_val)
                    im.TreePop()
                }
            } else if reflect.is_pointer(type_info_of(field_type.id)){
                draw_inspector(field_val)
            } else {
                // Draw non-editable value as text
                c_str := strings.clone_to_cstring(fmt.tprintf("%s: %v", field_name, field_val))
                defer delete(c_str)
                im.Text(c_str)
            }
        }

        ctx.is_pre = false
        run_field_decorators(tid, i, &ctx)
    }
}
