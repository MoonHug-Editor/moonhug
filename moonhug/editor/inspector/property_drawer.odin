package inspector

import "core:strings"
import im "moonhug:external/odin-imgui"

@(property_drawer={type = int})
property_drawer_int :: proc(ctx: ^Ctx) {
    ptr, label := ctx.ptr, ctx.label
    int_ptr := cast(^int)(ptr)
    value := cast(i32)(int_ptr^)
    if drag_int(field_row(label), &value) {
        int_ptr^ = int(value)
        mark_inspector_changed()
    }
}

@(property_drawer={type = i32})
property_drawer_i32 :: proc(ctx: ^Ctx) {
    ptr, label := ctx.ptr, ctx.label
    i32_ptr := cast(^i32)(ptr)
    value := i32_ptr^
    if drag_int(field_row(label), &value) {
        i32_ptr^ = value
        mark_inspector_changed()
    }
}

@(property_drawer={type = u32})
property_drawer_u32 :: proc(ctx: ^Ctx) {
    ptr, label := ctx.ptr, ctx.label
    u32_ptr := cast(^u32)(ptr)
    value := i32(min(u32_ptr^, u32(max(i32))))
    if drag_int(field_row(label), &value, 1, 0, max(i32)) {
        u32_ptr^ = u32(max(value, 0))
        mark_inspector_changed()
    }
}

@(property_drawer={type = string})
property_drawer_string :: proc(ctx: ^Ctx) {
    ptr, label := ctx.ptr, ctx.label
    str_ptr := cast(^string)(ptr)
    value := str_ptr^
    buf: [256]u8
    // A mixed multi-selection starts empty rather than showing one object's
    // string as if it were shared. Typing then assigns to the whole selection,
    // and leaving it alone changes nothing.
    if !current_field_mixed {
        copy(buf[:], value)
    }
    if im.InputText(field_row(label), cstring(raw_data(buf[:])), len(buf), {}) {
        str_len := 0
        for str_len < len(buf) && buf[str_len] != 0 {
            str_len += 1
        }
        // Component strings live on context.allocator — scene load
        // (_ext_value_into), the union unmarshaler and undo's apply all
        // allocate with it, so the replacement does too. The old value is
        // freed, or every keystroke leaks its predecessor.
        if !current_field_mixed {
            delete(str_ptr^)
        }
        str_ptr^ = strings.clone(string(buf[:str_len]))
        mark_inspector_changed()
    }
}

@(property_drawer={type = bool})
property_drawer_bool :: proc(ctx: ^Ctx) {
    ptr, label := ctx.ptr, ctx.label
    bool_ptr := cast(^bool)(ptr)
    value := bool_ptr^
    mixed := current_field_mixed
    // A mixed selection draws neither checked nor unchecked. This binding has no
    // MixedValue item flag (upstream keeps it internal), so the box is drawn
    // unchecked and the dash is painted over it — the same substitute-the-glyph
    // approach drag_left uses for numbers. One click resolves the whole
    // selection to checked, as in Unity.
    checkbox_value := value if !mixed else false
    id := field_row(label)
    changed := im.Checkbox(id, &checkbox_value)
    if mixed && !changed {
        draw_mixed_check_mark()
    }
    if changed {
        bool_ptr^ = checkbox_value if !mixed else true
        mark_inspector_changed()
    }
}

// The dash inside the checkbox frame just drawn. Exported because the component
// enable toggle draws its own checkbox outside the drawer path and needs the
// same mark.
draw_mixed_check_mark :: proc() {
    lo := im.GetItemRectMin()
    hi := im.GetItemRectMax()
    // Square the rect to the box itself: Checkbox's item rect includes the
    // trailing label, and the mark belongs in the box on the left.
    side := hi.y - lo.y
    pad := side * 0.25
    dl := im.GetWindowDrawList()
    col := im.GetColorU32ImVec4(im.GetStyle().Colors[im.Col.CheckMark])
    y := (lo.y + hi.y) * 0.5
    im.DrawList_AddLine(dl, im.Vec2{lo.x + pad, y}, im.Vec2{lo.x + side - pad, y}, col, 2)
}

@(private)
draw_float_property :: proc(ptr: rawptr, tid: typeid, label: cstring) {
    if tid == typeid_of(f32) {
        float_ptr := cast(^f32)(ptr)
        value := float_ptr^
        if drag_float(field_row(label), &value, 0.01, format="%g") {
            float_ptr^ = value
            mark_inspector_changed()
        }
    } else if tid == typeid_of(f64) {
        float_ptr := cast(^f64)(ptr)
        value := float_ptr^
        if im.InputDouble(field_row(label), &value, 0.01, 0.1, "%g") {
            float_ptr^ = value
            mark_inspector_changed()
        }
    }
}

@(property_drawer={type = f32})
property_drawer_f32 :: proc(ctx: ^Ctx) {
    ptr, tid, label := ctx.ptr, ctx.tid, ctx.label
    draw_float_property(ptr, tid, label)
}

@(property_drawer={type = f64})
property_drawer_f64 :: proc(ctx: ^Ctx) {
    ptr, tid, label := ctx.ptr, ctx.tid, ctx.label
    draw_float_property(ptr, tid, label)
}

@(property_drawer={type = ^[3]f32})
property_drawer_vec3_ptr :: proc(ctx: ^Ctx) {
    // A container drawn as one widget: one row, one undo step.
    row_edit := edit_as_one_begin(ctx)
    defer edit_as_one_end(ctx, &row_edit)
    ptr, label := ctx.ptr, ctx.label
    v := cast(^[3]f32)(ptr)
    im.BeginGroup()
    if drag_float3(field_row(label), v, 0.1) {
        mark_inspector_changed()
    }
    im.EndGroup()
}

@(property_drawer={type=[3]f32})
property_drawer_vec3 :: proc(ctx: ^Ctx) {
    ptr, label := ctx.ptr, ctx.label
    v := cast(^[3]f32)(ptr)
    if drag_float3(field_row(label), v, 0.1) {
        mark_inspector_changed()
    }
}

@(property_drawer={type=[2]f32})
property_drawer_vec2 :: proc(ctx: ^Ctx) {
    ptr, label := ctx.ptr, ctx.label
    v := cast(^[2]f32)(ptr)
    if drag_float2(field_row(label), v, 0.1) {
        mark_inspector_changed()
    }
}

@(property_drawer={type=[4]f32})
property_drawer_vec4 :: proc(ctx: ^Ctx) {
    ptr, label := ctx.ptr, ctx.label
    v := cast(^[4]f32)(ptr)
    if drag_float4(field_row(label), v, 0.1) {
        mark_inspector_changed()
    }
}
