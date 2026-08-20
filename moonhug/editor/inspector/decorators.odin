package inspector

import "base:intrinsics"
import "core:fmt"
import "core:strings"
import im "moonhug:external/odin-imgui"
import engine "../../engine"
import "../../engine/log"
import "../undo"

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
		if im.ColorEdit4(field_row(label), cast(^[4]f32)ctx.field_ptr) {
			mark_inspector_changed()
		}
		ctx.is_visible = false
		ctx.handled_draw = true
	case typeid_of([3]f32):
		if im.ColorEdit3(field_row(label), cast(^[3]f32)ctx.field_ptr) {
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
	if drag_float3(field_row(label), &euler, 0.1) {
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
		if im.ColorPicker4(field_row(label), cast(^[4]f32)ctx.field_ptr) {
			mark_inspector_changed()
		}
		ctx.is_visible = false
		ctx.handled_draw = true
	case typeid_of([3]f32):
		if im.ColorPicker3(field_row(label), cast(^[3]f32)ctx.field_ptr) {
			mark_inspector_changed()
		}
		ctx.is_visible = false
		ctx.handled_draw = true
	case:
	}
}

// Field-anchored action buttons: `decor:button(proc_name, label="", row=0, weight=1)`.
// decorator_gen qualifies proc_name with its package and emits the reference
// into decorators_generated.odin, so a renamed proc is a COMPILE error there —
// the tag itself travels with the field, so field renames cost nothing.
//
// Arity picks the payload: proc(), proc(^Component) or proc(^Component,
// ^Field) — the two-arg form receives a pointer to the field the tag sits on
// (the field always anchors PLACEMENT, whatever the proc needs). HIGHER row
// renders HIGHER on screen: rows >= 0 stack above the field (2 over 1 over
// 0), rows < 0 below it (-1 over -2) — decorator_gen position-sorts the
// emitted calls and routes negative rows to the post pass. Buttons sharing a
// `row` value render on one line, widths split by `weight` (row totals settle
// after one frame, the usual imgui deferred-layout pattern). The invocation
// is wrapped in the inspector's component snapshot/commit, so a button that
// mutates the component lands as ONE undo step.

@(private = "file")
_Button_Row_State :: struct {
	frame:     i32, // frame the accumulators belong to
	accum_w:   f32,
	accum_n:   int,
	total_w:   f32, // last completed frame's totals — sizing source
	total_n:   int,
	row_avail: f32, // content width at the row's first button
}

@(private = "file")
_Button_Row_Key :: struct {
	field: rawptr,
	row:   int,
}

@(private = "file")
_button_rows: map[_Button_Row_Key]_Button_Row_State

// One warning per action proc when a button is drawn on a struct its proc
// doesn't take — the polymorphic call compiles for any first-param type, so
// this mismatch (e.g. ^Component proc on a NESTED struct's field) is only
// detectable at draw time and would otherwise hide the button silently.
@(private = "file")
_button_owner_warned: map[rawptr]bool

decorators_shutdown :: proc() {
	delete(_button_rows)
	_button_rows = {}
	delete(_button_owner_warned)
	_button_owner_warned = {}
}

decorator_button :: proc(ctx: ^DrawContext, action: $P, label := cstring(""), row := 0, weight := f32(1))
	where intrinsics.type_is_proc(P) {
	if !ctx.is_visible do return
	// Above-field rows draw in the pre pass, below-field rows in post.
	if ctx.is_pre != (row >= 0) do return
	if ctx.owner_ptr == nil do return

	when intrinsics.type_proc_parameter_count(P) > 0 {
		if ctx.owner_type != typeid_of(intrinsics.type_elem_type(intrinsics.type_proc_parameter_type(P, 0))) {
			akey := transmute(rawptr)action
			if !_button_owner_warned[akey] {
				_button_owner_warned[akey] = true
				log.warningf("decor:button \"%s\": field belongs to %v but the proc takes ^%v — button hidden (use the owning struct's type, or proc())",
					label, ctx.owner_type, typeid_of(intrinsics.type_elem_type(intrinsics.type_proc_parameter_type(P, 0))))
			}
			return
		}
	}

	key := _Button_Row_Key{field = ctx.field_ptr, row = row}
	st := _button_rows[key]
	frame := i32(im.GetFrameCount())
	if st.frame != frame {
		st.total_w = st.accum_w
		st.total_n = st.accum_n
		st.accum_w = 0
		st.accum_n = 0
		st.frame = frame
	}
	first_in_row := st.accum_n == 0
	if first_in_row {
		st.row_avail = im.GetContentRegionAvail().x
	} else {
		im.SameLine()
	}
	st.accum_w += weight
	st.accum_n += 1
	_button_rows[key] = st

	total_w := max(st.total_w, weight)
	total_n := max(st.total_n, 1)
	spacing := im.GetStyle().ItemSpacing.x
	width := (st.row_avail - spacing * f32(total_n - 1)) * weight / total_w

	id := fmt.ctprintf("%s##btn_%d_%d", label, row, st.accum_n)
	if im.Button(id, im.Vec2{width, 0}) {
		sess := structural_edit_begin(string(label))
		when intrinsics.type_proc_parameter_count(P) == 2 {
			CompPtr :: intrinsics.type_proc_parameter_type(P, 0)
			FieldPtr :: intrinsics.type_proc_parameter_type(P, 1)
			if ctx.field_type == typeid_of(intrinsics.type_elem_type(FieldPtr)) && ctx.field_ptr != nil {
				action(cast(CompPtr)ctx.owner_ptr, cast(FieldPtr)ctx.field_ptr)
			}
		} else when intrinsics.type_proc_parameter_count(P) == 1 {
			CompPtr :: intrinsics.type_proc_parameter_type(P, 0)
			action(cast(CompPtr)ctx.owner_ptr)
		} else {
			action()
		}
		structural_edit_end(&sess)
	}
}
