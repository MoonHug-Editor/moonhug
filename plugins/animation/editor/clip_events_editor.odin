package animation_editor

// An event of a clip's settings (Animation_Clip_Settings.events) on one line:
// its time, then its name. Each is a row of its own for the inspector's row
// machinery (field_edit_row), so it is one undo step and reaches every
// selected object, as a row of the generic field loop does.

import "core:fmt"
import im "moonhug:external/odin-imgui"
import "moonhug:editor/inspector"
import anim "moonhug:packages/animation"

@(private = "file") _TIME_W :: f32(70)

@(property_drawer={type=anim.Animation_Clip_Event})
property_drawer_Animation_Clip_Event :: proc(ctx: ^inspector.Ctx) {
	e := cast(^anim.Animation_Clip_Event)ctx.ptr
	gap := im.GetStyle().ItemInnerSpacing.x
	// The list keeps room at the row's end for its own button.
	avail := im.GetContentRegionAvail().x - inspector.current_field_trailing_w
	_cell(ctx, &e.time, typeid_of(f32), offset_of(e.time), "time", _TIME_W)
	im.SameLine(0, gap)
	_cell(ctx, &e.name, typeid_of(string), offset_of(e.name), "name", max(avail - _TIME_W - gap, 40))
}

// One field of the event, `width` wide, as a row of its own.
@(private = "file")
_cell :: proc(ctx: ^inspector.Ctx, ptr: rawptr, tid: typeid, field_offset: uintptr, name: string, width: f32) {
	im.PushIDStr(fmt.ctprintf("%s", name), nil)
	defer im.PopID()
	path := ctx.path_prefix == "" ? name : fmt.tprintf("%s.%s", ctx.path_prefix, name)
	im.SetNextItemWidth(width)
	finished := inspector.field_edit_row(ptr, tid, ctx.offset + field_offset, name, inspector.resolve_property_drawer(tid), "##cell")
	inspector.record_nested_override(ptr, tid, path, finished)
}
