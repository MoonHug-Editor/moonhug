package blackboard_editor

// Editor-only half of the blackboard plugin: an entry of a Blackboard drawn
// on one line, its name, its type and the one value its type names.
//
// Each of the three goes through the inspector's row machinery
// (field_edit_row), so it has its own undo step, reaches every selected
// object and records its prefab override, as a row of the generic field loop
// does.
//
// Slots connect to an entry's id, so a rename is only an edit of the name.
// An entry made in the list starts without an id and gets one the first time
// it draws (_entry_id_ensure). The component's own step adds Override Entry
// under the list: an entry that stands in for one of a Blackboard above, with
// its id.

import "core:fmt"
import "core:strings"
import im "moonhug:external/odin-imgui"
import "moonhug:editor/inspector"
import "moonhug:editor/undo"
import "moonhug:editor/widgets"
import engine "moonhug:packages/engine"
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

	_entry_id_ensure(e)
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
_cell :: proc(ctx: ^inspector.Ctx, ptr: rawptr, tid: typeid, field_offset: uintptr, name: string, width: f32, drawer: proc(ptr: rawptr, tid: typeid, label: cstring) = nil) -> (finished: bool) {
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
	finished = inspector.field_edit_row(ptr, tid, offset, name, drawer, "##cell")
	inspector.record_nested_override(ptr, tid, path, finished)
	return
}

// The Blackboard the inspector is drawing and its handle, nil when it draws
// something else.
@(private = "file")
_board :: proc() -> (b: ^blackboard.Blackboard, handle: engine.Handle) {
	o, ok := undo.current_owner()
	if !ok || o.kind != .Pooled || o.base_ptr == nil do return
	if engine.get_typeid_by_type_key(o.handle.type_key) != typeid_of(blackboard.Blackboard) do return
	return cast(^blackboard.Blackboard)o.base_ptr, o.handle
}

// Gives entry `e` its id: an entry the list just added has none, and a
// duplicate made in the list has its source's. Recorded into the step that
// made the entry, so the id is saved with it and an undo takes both.
@(private = "file")
_entry_id_ensure :: proc(e: ^blackboard.Blackboard_Entry) {
	b, handle := _board()
	if b == nil do return
	// Only an entry of the live list: a copy drawn for a mixed selection or
	// a driven value is not where the id is kept.
	index := -1
	for &other, i in b.entries do if &other == e do index = i
	if index < 0 do return
	needs := e.id == 0
	for &other in b.entries[:index] do if other.id == e.id do needs = true
	if !needs do return
	g := undo.amend_begin("Entry Id")
	edit := undo.edit_begin(handle, typeid_of(blackboard.Blackboard), "Entry Id")
	e.id = blackboard.entry_id_new()
	undo.edit_end(&edit)
	undo.group_commit(&g)
	undo.group_end(&g)
}

// Under the Blackboard's fields: Override Entry, which lists the entries of
// the Blackboards above that this one has none for. Picking one adds an
// entry with its id, name, type and value, so the slots under this object
// that were connected to it take this one.
@(property_drawer={type=blackboard.Blackboard, order="middle"})
property_drawer_Blackboard_override :: proc(ctx: ^inspector.Ctx) {
	inspector.draw(ctx)
	b, handle := _board()
	if b == nil || rawptr(b) != ctx.ptr do return
	above := blackboard.entries_above(b)
	if len(above) == 0 do return
	if im.Button("Override Entry") do im.OpenPopup("##bb_override")
	widgets.tooltip("Adds an entry that stands in for one of a Blackboard above, for the objects under this one")
	if !im.BeginPopup("##bb_override") do return
	defer im.EndPopup()
	for from in above {
		if !im.MenuItem(strings.clone_to_cstring(from.name, context.temp_allocator)) do continue
		edit := undo.edit_begin(handle, typeid_of(blackboard.Blackboard), "Override Entry")
		blackboard.entry_override(b, from)
		undo.edit_end(&edit)
		break
	}
}

@(private = "file")
_color_drawer :: proc(ptr: rawptr, tid: typeid, label: cstring) {
	if im.ColorEdit4(label, cast(^[4]f32)ptr, {.AlphaBar}) do inspector.mark_inspector_changed()
}
