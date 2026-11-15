package inspector

// A slot's row (moonhug/libs/slots): a slot field and its inline field,
// `_name`, drawn as one row under the slot's name.
//
// - Not connected: the row is the inline field's, with its own drawer and
//   decorators, its undo and its prefab override.
// - Connected: the row names the entry (property_drawer_Slot).
// - Either way a link button sits at the end of the label column. It opens
//   the list of what the slot can take its value from: the inline value, and
//   every declared entry of the inline field's type (slots.declare). Picking
//   one is an edit of the slot field, recorded as any row's.
//
// The struct field loop (draw_inspector_default) pairs the two fields and
// calls in here.

import "core:fmt"
import "core:reflect"
import "core:strings"
import im "moonhug:external/odin-imgui"
import "moonhug:editor/icons"
import "moonhug:editor/widgets"
import "moonhug:libs/slots"

// What the field loop knows about a slot's row.
Slot_Row :: struct {
	ptr:          ^slots.Slot,
	name:         string, // the slot field's name
	path:         string, // its property path, for the override record
	inline_index: int,    // the inline field's index in the struct, -1 when the struct has none
	value_tid:    typeid, // the inline field's type: what an entry must hold
	// Where the row starts and where its value column does, taken before the
	// row draws.
	row_y:    f32,
	column_x: f32,
}

// The slot field at index `fi` of the struct at `ptr`, and its inline field.
slot_row_of :: proc(ptr: rawptr, tid: typeid, fi: int, path_prefix: string) -> (row: Slot_Row) {
	names := reflect.struct_field_names(tid)
	types := reflect.struct_field_types(tid)
	row.ptr = cast(^slots.Slot)(uintptr(ptr) + reflect.struct_field_at(tid, fi).offset)
	row.name = names[fi]
	row.path = path_prefix == "" ? row.name : strings.concatenate({path_prefix, ".", row.name}, context.temp_allocator)
	row.inline_index = -1
	for n, i in names {
		if len(n) == len(row.name) + 1 && n[0] == '_' && n[1:] == row.name {
			row.inline_index = i
			row.value_tid = types[i].id
			break
		}
	}
	return
}

// Before the row draws.
slot_row_begin :: proc(row: ^Slot_Row) {
	row.row_y = im.GetCursorScreenPos().y
	row.column_x = field_column_screen_x()
}

// What the link's popup offers, for the drawer field_edit_row calls.
@(private = "file")
_link: ^Slot_Row
@(private = "file")
_link_size: f32

// After the row drew: the link button over the end of the label column, and
// its popup. `offset` is the slot field's multi-edit offset.
slot_row_link :: proc(row: ^Slot_Row, offset: uintptr) {
	after := im.GetCursorScreenPos()
	defer im.SetCursorScreenPos(after)
	// Centred on the row when the row is one line, which the row's group, the
	// last item, tells. A row that unfolded keeps the button on its first line.
	size := im.GetFrameHeight()
	y := row.row_y
	if h := im.GetItemRectMax().y - im.GetItemRectMin().y; h <= size * 1.5 {
		size = min(size, h)
		y = im.GetItemRectMin().y + (h - size) * 0.5
	}
	_link_size = size
	im.SetCursorScreenPos({row.column_x - size - im.GetStyle().ItemInnerSpacing.x, y})

	_link = row
	defer _link = nil
	prev_path := field_edit_set_path(row.path)
	finished := field_edit_row(row.ptr, typeid_of(slots.Slot), offset, row.name, _draw_link, "##slot_link")
	field_edit_set_path(prev_path)
	record_nested_override(row.ptr, typeid_of(slots.Slot), row.path, finished)
}

@(private = "file")
_draw_link :: proc(ptr: rawptr, tid: typeid, label: cstring) {
	slot := cast(^slots.Slot)ptr
	row := _link
	connected := slot^ != slots.INLINE
	tip := connected ? fmt.ctprintf("Takes its value from the entry %q. Click to change", slots.name(slot^)) : cstring("Takes the value set here. Click to take it from an entry the game fills")
	if widgets.icon_button(icons.ICON_MD_LINK, "##slot_link", tip, active = connected, size = _link_size) do im.OpenPopup("##slot_sources")
	if !im.BeginPopup("##slot_sources") do return
	defer im.EndPopup()
	if row.inline_index < 0 {
		im.TextDisabled(fmt.ctprintf("%s has no inline field _%s", row.name, row.name))
		return
	}
	if im.MenuItem("Inline value", nil, !connected) do slot^ = slots.INLINE
	im.Separator()
	entries := slots.declared_of(row.value_tid)
	if len(entries) == 0 {
		im.TextDisabled(fmt.ctprintf("No entry of type %v is declared", row.value_tid))
	}
	for e in entries {
		s := slots.entry(e.name)
		if im.MenuItem(strings.clone_to_cstring(e.name, context.temp_allocator), nil, slot^ == s) do slot^ = s
		if e.doc != "" do widgets.tooltip(strings.clone_to_cstring(e.doc, context.temp_allocator))
	}
	// A connection to an entry nothing declares now, such as one of a plugin
	// that is not installed: shown, so it can be seen and replaced.
	if connected {
		listed := false
		for e in entries do if slots.entry(e.name) == slot^ do listed = true
		if !listed do im.MenuItem(fmt.ctprintf("%s (not declared)", slots.name(slot^)), nil, true)
	}
}

// A connected slot's row: the entry it takes its value from. The link button
// changes it (slot_row_link).
@(property_drawer={type = slots.Slot})
property_drawer_Slot :: proc(ctx: ^Ctx) {
	slot := (cast(^slots.Slot)ctx.ptr)^
	field_row(ctx.label)
	im.AlignTextToFramePadding()
	if slot == slots.INLINE {
		// A slot whose struct has no inline field: the prebuild reports it.
		im.TextDisabled("no inline value")
		return
	}
	im.TextDisabled(fmt.ctprintf("from %s", slots.name(slot)))
}
