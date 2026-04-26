package inspector

import "core:fmt"
import "core:strings"
import im "../../../external/odin-imgui"

@(private, property_drawer={type = int, priority = 0})
draw_int_property :: proc(ptr: rawptr, tid: typeid, label: cstring) {
    int_ptr := cast(^int)(ptr)
    value := cast(i32)(int_ptr^)
    if im.DragInt(label, &value) {
        int_ptr^ = int(value)
        mark_inspector_changed()
    }
}

@(private, property_drawer={type = string, priority = 0})
draw_string_property :: proc(ptr: rawptr, tid: typeid, label: cstring) {
    str_ptr := cast(^string)(ptr)
    value := str_ptr^
    buf: [256]u8
    copy(buf[:], value)
    if im.InputText(label, cstring(raw_data(buf[:])), len(buf), {}) {
        str_len := 0
        for str_len < len(buf) && buf[str_len] != 0 {
            str_len += 1
        }
        str_ptr^ = strings.clone(string(buf[:str_len]))
        mark_inspector_changed()
    }
}

@(private, property_drawer={type = bool, priority = 0})
draw_bool_property :: proc(ptr: rawptr, tid: typeid, label: cstring) {
    bool_ptr := cast(^bool)(ptr)
    value := bool_ptr^
    if im.Checkbox(label, &value) {
        bool_ptr^ = value
        mark_inspector_changed()
    }
}

@(private)
draw_float_property :: proc(ptr: rawptr, tid: typeid, label: cstring) {
    if tid == typeid_of(f32) {
        float_ptr := cast(^f32)(ptr)
        value := float_ptr^
        if im.DragFloat(label, &value, 0.01, format="%g") {
            float_ptr^ = value
            mark_inspector_changed()
        }
    } else if tid == typeid_of(f64) {
        float_ptr := cast(^f64)(ptr)
        value := float_ptr^
        if im.InputDouble(label, &value, 0.01, 0.1, "%g") {
            float_ptr^ = value
            mark_inspector_changed()
        }
    }
}

@(private, property_drawer={type = f32, priority = 0})
draw_f32_property :: proc(ptr: rawptr, tid: typeid, label: cstring) {
    draw_float_property(ptr, tid, label)
}

@(private, property_drawer={type = f64, priority = 0})
draw_f64_property :: proc(ptr: rawptr, tid: typeid, label: cstring) {
    draw_float_property(ptr, tid, label)
}

@(private, property_drawer={type = ^[3]f32, priority = 0})
draw_vec3_row :: proc(ptr: rawptr, tid: typeid, label: cstring) {
    v := cast(^[3]f32)(ptr)
    im.AlignTextToFramePadding()
    im.BeginGroup()
    im.Text(label)
    avail := im.GetContentRegionAvail().x
    label_w: f32 = 70
    field_w := avail - label_w
    im.SameLine(label_w)
    im.SetNextItemWidth(field_w)
    id := fmt.tprintf("##%s", label)
    if im.DragFloat3(strings.clone_to_cstring(id, context.temp_allocator), v, 0.1) {
        mark_inspector_changed()
    }
    im.EndGroup()
}

@(property_drawer={type=[3]f32, priority = 0})
draw_vec3_property :: proc(ptr: rawptr, tid: typeid, label: cstring) {
    v := cast(^[3]f32)(ptr)
    if im.DragFloat3(label, v, 0.1) {
        mark_inspector_changed()
    }
}

@(property_drawer={type=[4]f32, priority = 0})
draw_vec4_property :: proc(ptr: rawptr, tid: typeid, label: cstring) {
    v := cast(^[4]f32)(ptr)
    if im.DragFloat4(label, v, 0.1) {
        mark_inspector_changed()
    }
}
