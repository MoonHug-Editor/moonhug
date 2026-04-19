package inspector

import "core:fmt"
import "core:strings"
import im "../../../external/odin-imgui"
import engine "../../engine"

Min_Value :: union { int, f64 }

decorator_min :: proc(ctx: ^DrawContext, min_value: Min_Value) {
	if !ctx.is_visible || ctx.is_pre do return
	if ctx.field_ptr == nil do return
	switch ctx.field_type {
	case typeid_of(int):
		v, ok := min_value.(int)
		if !ok do return
		ptr := cast(^int)ctx.field_ptr
		if ptr^ < v do ptr^ = v
	case typeid_of(f32):
		val: f32
		switch v in min_value {
		case int:  val = f32(v)
		case f64:  val = f32(v)
		}
		ptr := cast(^f32)ctx.field_ptr
		if ptr^ < val do ptr^ = val
	case typeid_of(f64):
		val: f64
		switch v in min_value {
		case int:  val = f64(v)
		case f64:  val = v
		}
		ptr := cast(^f64)ctx.field_ptr
		if ptr^ < val do ptr^ = val
	case:
	}
}

decorator_header :: proc(ctx: ^DrawContext, text:cstring = "") {
	if !ctx.is_visible || !ctx.is_pre do return

	im.Spacing()
    im.TextColored({0.7, 0.7, 1.0, 1.0}, text) // Light blue tint for visibility
    im.Separator()
}

decorator_tooltip :: proc(ctx: ^DrawContext, desc:cstring) {
	if !ctx.is_visible || ctx.is_pre do return

	if im.IsItemHovered() {
		im.BeginTooltip()
		im.TextUnformatted(desc)
		im.EndTooltip()
	}
}

decorator_separator :: proc(ctx: ^DrawContext) {
	if ctx == nil do return
	if ctx.is_visible && ctx.is_pre do im.Separator()
}

decorator_hide :: proc(ctx: ^DrawContext)
{
	if(ctx.is_pre)
	{
		ctx.is_visible = false
	}
}

decorator_readonly :: proc(ctx: ^DrawContext) {
	if ctx.is_pre {
		im.BeginDisabled()
	}
    else {
		im.EndDisabled()
    }
}

decorator_color :: proc(ctx: ^DrawContext) {
	if !ctx.is_pre do return
	if ctx.field_ptr == nil do return
	label := ctx.field_label
	switch ctx.field_type {
	case typeid_of([4]f32):
		if im.ColorEdit4(label, cast(^[4]f32)ctx.field_ptr) {
			mark_inspector_changed()
		}
		ctx.is_visible = false
		ctx.handled_draw = true
	case typeid_of([3]f32):
		if im.ColorEdit3(label, cast(^[3]f32)ctx.field_ptr) {
			mark_inspector_changed()
		}
		ctx.is_visible = false
		ctx.handled_draw = true
	case:
	}
}

decorator_euler :: proc(ctx: ^DrawContext) {
	if !ctx.is_pre do return
	if ctx.field_ptr == nil do return
	if ctx.field_type != typeid_of([4]f32) do return

	quat_ptr := cast(^[4]f32)ctx.field_ptr
	euler := engine.quat_to_euler_xyz(quat_ptr^)
	label := ctx.field_label
	avail := im.GetContentRegionAvail().x
	label_w: f32 = 70
	field_w := avail - label_w
	im.AlignTextToFramePadding()
	im.Text(label)
	im.SameLine(label_w)
	im.SetNextItemWidth(field_w)
	id := fmt.tprintf("##euler_%s", label)
	if im.DragFloat3(strings.clone_to_cstring(id, context.temp_allocator), &euler, 0.1) {
		quat_ptr^ = engine.quat_from_euler_xyz(euler.x, euler.y, euler.z)
		mark_inspector_changed()
	}

	ctx.is_visible = false
	ctx.handled_draw = true
}

decorator_color_picker :: proc(ctx: ^DrawContext) {
	if !ctx.is_pre do return
	if ctx.field_ptr == nil do return
	label := ctx.field_label
	switch ctx.field_type {
	case typeid_of([4]f32):
		if im.ColorPicker4(label, cast(^[4]f32)ctx.field_ptr) {
			mark_inspector_changed()
		}
		ctx.is_visible = false
		ctx.handled_draw = true
	case typeid_of([3]f32):
		if im.ColorPicker3(label, cast(^[3]f32)ctx.field_ptr) {
			mark_inspector_changed()
		}
		ctx.is_visible = false
		ctx.handled_draw = true
	case:
	}
}
