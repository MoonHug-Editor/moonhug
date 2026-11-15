package blackboard_editor

// Editor-only half of the blackboard plugin: an entry of a Blackboard drawn
// on one line, its name, its type and its value.
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
import "core:reflect"
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
	value_tid := typeid_of(blackboard.Blackboard_Value)

	_entry_id_ensure(e)
	_cell(ctx, &e.name, typeid_of(string), offset_of(e.name), "name", name_w)
	im.SameLine(0, gap)
	// The type and the value are two rows over the one union field: picking a
	// type is an edit of the value.
	_cell(ctx, &e.value, value_tid, offset_of(e.value), "type", _TYPE_W, _type_drawer, lands_later = true)
	im.SameLine(0, gap)
	_cell(ctx, &e.value, value_tid, offset_of(e.value), "value", value_w, _value_drawer, lands_later = inspector.is_enum_type(blackboard.value_typeid(e)))
}

// One field of the entry, `width` wide, as a row of its own for undo, the
// other selected objects and the prefab override. `name` is the field's.
// `lands_later`: the drawer changes the value from a popup, a frame after the
// click, so the row brackets the change after the fact.
@(private = "file")
_cell :: proc(ctx: ^inspector.Ctx, ptr: rawptr, tid: typeid, field_offset: uintptr, id: string, width: f32, drawer: proc(ptr: rawptr, tid: typeid, label: cstring) = nil, lands_later := false) -> (finished: bool) {
	im.PushIDStr(fmt.ctprintf("%s", id), nil)
	defer im.PopID()
	field := id == "type" ? "value" : id
	path := ctx.path_prefix == "" ? field : fmt.tprintf("%s.%s", ctx.path_prefix, field)
	offset := ctx.offset + field_offset
	drawer := drawer
	if drawer == nil do drawer = inspector.resolve_property_drawer(tid)
	if lands_later do inspector.multi_probe_field(ptr, tid, offset)
	im.SetNextItemWidth(width)
	finished = inspector.field_edit_row(ptr, tid, offset, field, drawer, "##cell")
	inspector.record_nested_override(ptr, tid, path, finished)
	return
}

// The entry's type: a list of every value type. Picking one gives the entry a
// new value of that type.
@(private = "file")
_type_drawer :: proc(ptr: rawptr, tid: typeid, label: cstring) {
	v := cast(^blackboard.Blackboard_Value)ptr
	current := reflect.union_variant_typeid(v^)
	vt, _ := blackboard.value_type_of(current)
	if !im.BeginCombo(label, strings.clone_to_cstring(vt.name, context.temp_allocator), {.HeightLarge}) do return
	defer im.EndCombo()
	for t, i in blackboard.value_types {
		if !im.Selectable(fmt.ctprintf("%s##%d", t.name, i), t.type == current) || t.type == current do continue
		v^ = blackboard.value_new(t.type)
		inspector.mark_inspector_changed()
	}
}

// The entry's value, with the drawer of the type it holds.
@(private = "file")
_value_drawer :: proc(ptr: rawptr, tid: typeid, label: cstring) {
	T := reflect.union_variant_typeid(any{ptr, tid})
	switch {
	case T == typeid_of([4]f32):
		_color_drawer(ptr, T, label)
	case T == typeid_of(core.Ref):
		// The tag says what the picker offers, as the field loop would set it.
		prev := inspector.field_tags_set(`ref:"Transform"`)
		defer inspector.field_tags_restore(prev)
		inspector.resolve_property_drawer(T)(ptr, T, label)
	case inspector.is_enum_type(T):
		inspector.draw_inspector_enum(ptr, T, label)
	case:
		inspector.resolve_property_drawer(T)(ptr, T, label)
	}
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
// entry with its id, name and value, so the slots under this object
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
