package blackboard_editor

// Editor-only half of the blackboard plugin: an entry of a Blackboard drawn
// on one line, its name, its type and the one value its type names.
//
// Each of the three goes through the inspector's row machinery
// (field_edit_row), so it has its own undo step, reaches every selected
// object and records its prefab override, as a row of the generic field loop
// does.

import "core:fmt"
import im "moonhug:external/odin-imgui"
import "moonhug:editor/inspector"
import core "moonhug:libs/core"
import blackboard "moonhug:packages/blackboard"

@(private = "file") _TYPE_W :: f32(92)
@(private = "file") _MIN_NAME_W :: f32(60)

@(property_drawer={type=blackboard.Blackboard_Entry})
property_drawer_Blackboard_Entry :: proc(ctx: ^inspector.Ctx) {
	e := cast(^blackboard.Blackboard_Entry)ctx.ptr
	gap := im.GetStyle().ItemInnerSpacing.x
	// The list keeps room at the row's end for its own button.
	avail := im.GetContentRegionAvail().x - inspector.current_field_trailing_w
	name_w := max((avail - _TYPE_W - gap * 2) * 0.4, _MIN_NAME_W)
	value_w := max(avail - name_w - _TYPE_W - gap * 2, _MIN_NAME_W)

	_cell(ctx, &e.name, typeid_of(string), offset_of(e.name), "name", name_w)
	im.SameLine(0, gap)
	_cell(ctx, &e.type, typeid_of(blackboard.Value_Type), offset_of(e.type), "type", _TYPE_W)
	im.SameLine(0, gap)
	switch e.type {
	case .Number:  _cell(ctx, &e.number, typeid_of(f32), offset_of(e.number), "number", value_w)
	case .Integer: _cell(ctx, &e.integer, typeid_of(i32), offset_of(e.integer), "integer", value_w)
	case .Flag:    _cell(ctx, &e.flag, typeid_of(bool), offset_of(e.flag), "flag", value_w)
	case .Vector2: _cell(ctx, &e.vector2, typeid_of([2]f32), offset_of(e.vector2), "vector2", value_w)
	case .Vector3: _cell(ctx, &e.vector3, typeid_of([3]f32), offset_of(e.vector3), "vector3", value_w)
	case .Color:   _cell(ctx, &e.color, typeid_of([4]f32), offset_of(e.color), "color", value_w, _color_drawer)
	case .Object:
		// The field's tag says what the picker offers, as the field loop
		// would have set it.
		prev := inspector.field_tags_set(`ref:"Transform"`)
		_cell(ctx, &e.object, typeid_of(core.Ref), offset_of(e.object), "object", value_w)
		inspector.field_tags_restore(prev)
	case .Asset:   _cell(ctx, &e.asset, typeid_of(core.PPtr), offset_of(e.asset), "asset", value_w)
	}
}

// One field of the entry, `width` wide, as a row of its own for undo, the
// other selected objects and the prefab override.
@(private = "file")
_cell :: proc(ctx: ^inspector.Ctx, ptr: rawptr, tid: typeid, field_offset: uintptr, name: string, width: f32, drawer: proc(ptr: rawptr, tid: typeid, label: cstring) = nil) {
	im.PushIDStr(fmt.ctprintf("%s", name), nil)
	defer im.PopID()
	path := ctx.path_prefix == "" ? name : fmt.tprintf("%s.%s", ctx.path_prefix, name)
	offset := ctx.offset + field_offset
	drawer := drawer
	if drawer == nil {
		if inspector.is_enum_type(tid) {
			// An enum lands from a combo popup: the row brackets the change
			// after the fact.
			inspector.multi_probe_field(ptr, tid, offset)
			drawer = inspector.draw_inspector_enum
		} else {
			drawer = inspector.resolve_property_drawer(tid)
		}
	}
	im.SetNextItemWidth(width)
	finished := inspector.field_edit_row(ptr, tid, offset, name, drawer, "##cell")
	inspector.record_nested_override(ptr, tid, path, finished)
}

@(private = "file")
_color_drawer :: proc(ptr: rawptr, tid: typeid, label: cstring) {
	if im.ColorEdit4(label, cast(^[4]f32)ptr, {.AlphaBar}) do inspector.mark_inspector_changed()
}
