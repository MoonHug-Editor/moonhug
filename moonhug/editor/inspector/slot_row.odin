package inspector

// A slot's row (moonhug/libs/slots): a slot field and its inline field,
// `_name`, drawn as one row under the slot's name.
//
// - Not connected: the row is the inline field's, with its own drawer and
//   decorators, its undo and its prefab override.
// - Connected: the row names the entry (property_drawer_Slot).
// - Either way a link button sits at the end of the label column. It opens
//   the list of what the slot can take its value from: the inline value, the
//   entries of the inline field's type the installed scope offers the object
//   (slots.scope_entries: the Blackboards above it), and every declared one
//   (slots.declare). Picking one is an edit of the slot field, recorded as
//   any row's.
//
// The struct field loop (draw_inspector_default) pairs the two fields and
// calls in here.

import "core:fmt"
import "core:reflect"
import "core:strings"
import im "moonhug:external/odin-imgui"
import "moonhug:editor/icons"
import "moonhug:editor/undo"
import "moonhug:editor/widgets"
import core "moonhug:libs/core"
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
	_value_tid = row.value_tid
	_column_x = row.column_x
	_origin = {}
}

// Where the row's value column starts, for property_drawer_Slot.
@(private = "file")
_column_x: f32

// The inline field's type of the row being drawn, for property_drawer_Slot:
// the type a connected slot's value is shown as.
@(private = "file")
_value_tid: typeid

// Where the row's drawer put the origin text, drawn with its button by
// slot_row_link: a button inside the row's group would need an item after it.
@(private = "file")
_origin: struct {
	pos:    im.Vec2,
	right:  f32,
	text:   cstring,
	holder: core.Transform_Handle,
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
	if _origin.text != nil {
		_origin_link(_origin.pos, _origin.right, _origin.text, _origin.holder)
		_origin = {}
	}
	im.SetCursorScreenPos({row.column_x - size - im.GetStyle().ItemInnerSpacing.x, y})

	_value_tid = nil
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
	owner := _owner_object()
	tip := connected ? strings.clone_to_cstring(_origin_text(slots.origin(owner, slot^)), context.temp_allocator) : cstring("Takes the value set here. Click to take it from an entry")
	if widgets.icon_button(icons.ICON_MD_LINK, "##slot_link", tip, active = connected, size = _link_size) do im.OpenPopup("##slot_sources")
	if !im.BeginPopup("##slot_sources") do return
	defer im.EndPopup()
	if row.inline_index < 0 {
		im.TextDisabledUnformatted(fmt.ctprintf("%s has no inline field _%s", row.name, row.name))
		return
	}
	if im.MenuItem("Inline value", nil, !connected) do slot^ = slots.INLINE
	listed := false
	// What the installed scope offers the object the component is on, a
	// Blackboard above it for instance, nearest first.
	scoped := slots.scope_entries(owner, row.value_tid)
	if len(scoped) > 0 do im.Separator()
	for e, i in scoped {
		if e.slot == slot^ do listed = true
		// Two entries may share a name: the id keeps the items apart.
		if im.MenuItem(fmt.ctprintf("%s##scoped%d", e.name, i), strings.clone_to_cstring(e.from, context.temp_allocator), slot^ == e.slot) do slot^ = e.slot
	}
	// What code declares.
	entries := slots.declared_of(row.value_tid)
	if len(entries) > 0 do im.Separator()
	next: for e in entries {
		for have in scoped do if have.slot == slots.entry(e.name) do continue next
		s := slots.entry(e.name)
		if s == slot^ do listed = true
		if im.MenuItem(strings.clone_to_cstring(e.name, context.temp_allocator), nil, slot^ == s) do slot^ = s
		if e.doc != "" do widgets.tooltip(strings.clone_to_cstring(e.doc, context.temp_allocator))
	}
	if len(scoped) == 0 && len(entries) == 0 {
		im.Separator()
		im.TextDisabledUnformatted(fmt.ctprintf("Nothing offers an entry of type %v", row.value_tid))
	}
	// A connection to an entry nothing offers now, such as one of a
	// Blackboard that was removed: shown, so it can be seen and replaced.
	if connected && !listed {
		im.Separator()
		im.MenuItem(fmt.ctprintf("%s (not offered)", slots.label(owner, slot^)), nil, true)
	}
}

// The object whose component the inspector is drawing, {} when it draws
// something else: an asset, a settings struct.
@(private)
_owner_object :: proc() -> core.Transform_Handle {
	o, ok := undo.current_owner()
	if !ok || o.kind != .Pooled || o.base_ptr == nil || o.handle.type_key == .Transform do return {}
	return (cast(^core.CompData)o.base_ptr).owner
}

// What a connection is shown as: "Squad B: lift", the object whose
// Blackboard holds the entry and the entry's name as it is now, or the
// entry's name alone when nothing says where it is.
@(private = "file")
_origin_text :: proc(o: slots.Origin) -> string {
	if o.from == "" do return fmt.tprintf("%s (not set)", o.name)
	return fmt.tprintf("%s: %s", o.from, o.name)
}

// The origin in the label column of the row that starts at `start`:
// right-aligned against the link button, pushed right by a label that
// reaches it, and cut at the button.
@(private = "file")
_origin_in_label :: proc(start: im.Vec2, label: cstring, o: slots.Origin) {
	if _column_x <= 0 do return
	style := im.GetStyle()
	text := strings.clone_to_cstring(_origin_text(o), context.temp_allocator)
	right := _column_x - im.GetFrameHeight() - style.ItemInnerSpacing.x * 2
	label_end := start.x + im.CalcTextSize(label, nil, true).x + style.ItemInnerSpacing.x * 2
	x := max(label_end, right - im.CalcTextSize(text).x)
	if x >= right do return
	_origin = {{x, start.y}, right, text, o.holder}
}

// The origin text at `pos`, one frame high and cut at `right`. When an
// object holds the entry, the text is a button: a click pings that object in
// the Hierarchy, a double click selects it. A cut text shows in full in its tooltip.
// Moves the cursor: slot_row_link puts it back.
@(private = "file")
_origin_link :: proc(pos: im.Vec2, right: f32, text: cstring, holder: core.Transform_Handle) {
	h := im.GetFrameHeight()
	hovered := false
	if holder != {} {
		im.SetCursorScreenPos(pos)
		if im.InvisibleButton("##slot_origin", {right - pos.x, h}) do core.inspector_request_ping(holder)
		hovered = im.IsItemHovered()
		if hovered && im.IsMouseDoubleClicked(.Left) do core.inspector_request_select(holder)
		if hovered do im.SetMouseCursor(.Hand)
		if pos.x + im.CalcTextSize(text).x > right do widgets.tooltip(text)
	}
	y := pos.y + (h - im.GetTextLineHeight()) * 0.5
	dl := im.GetWindowDrawList()
	im.DrawList_PushClipRect(dl, pos, {right, pos.y + h}, true)
	im.DrawList_AddText(dl, {pos.x, y}, im.GetColorU32(hovered ? im.Col.Text : im.Col.TextDisabled), text)
	im.DrawList_PopClipRect(dl)
}

// A connected slot's row. When the entry's value can be read, the row shows
// it with the inline field's own widget, read-only: the value belongs to the
// entry, edited where the entry is. In the label column, where the value
// comes from.
// When it cannot be read, the row is where it would come from. The link
// button changes the connection (slot_row_link).
@(property_drawer={type = slots.Slot})
property_drawer_Slot :: proc(ctx: ^Ctx) {
	slot := (cast(^slots.Slot)ctx.ptr)^
	if slot == slots.INLINE {
		// A slot whose struct has no inline field: the prebuild reports it.
		field_row(ctx.label)
		im.AlignTextToFramePadding()
		im.TextDisabled("no inline value")
		return
	}
	owner := _owner_object()
	origin := slots.origin(owner, slot)
	if T := _value_tid; T != nil && type_info_of(T).size <= slots.MAX_VALUE_SIZE {
		value: [slots.MAX_VALUE_SIZE]u8
		if slots.lookup_raw(slot, T, slots.scope_of(owner), &value[0]) {
			// The label as any row's, the value read-only and dimmed.
			start := im.GetCursorScreenPos()
			field_row(ctx.label)
			im.BeginDisabled()
			draw_value(&value[0], T, "##slot_value")
			im.EndDisabled()
			_origin_in_label(start, ctx.label, origin)
			return
		}
	}
	// No value to show: the origin takes the value column.
	field_row(ctx.label)
	pos := im.GetCursorScreenPos()
	right := pos.x + max(im.GetContentRegionAvail().x, 1)
	im.Dummy({right - pos.x, im.GetFrameHeight()})
	_origin = {pos, right, strings.clone_to_cstring(_origin_text(origin), context.temp_allocator), origin.holder}
}
