package inspector

import "core:c"
import "core:fmt"
import "core:mem"
import "core:reflect"
import "base:runtime"
import strings "core:strings"
import im "moonhug:external/odin-imgui"
import engine "../../engine"
import "../undo"

ICON_MD_DRAG_INDICATOR :: "\ue945" // drag_indicator (array row reorder grip)

// Row-reorder drag, identified by the array's field pointer. The data is NOT
// touched while dragging: rows keep their order, an insertion line (hierarchy
// style) marks the target slot, and the drop applies one move inside a
// comp_snapshot/comp_commit pair — a single undo step.
_reorder_array: rawptr
_reorder_index: int  // source row
_reorder_target: int // insertion slot 0..count, recomputed every drawn frame
_reorder_row_left: f32

REORDER_LINE_COLOR :: im.Vec4{1, 0.8, 0, 1} // hierarchy's drop indicator

// Applies the pending move when the mouse is released. Runs at the top of the
// array's draw, so the slot shown by last frame's line is what lands.
_reorder_apply_if_released :: proc(array_ptr: rawptr, data: rawptr, elem_size: int, count: int) {
	if _reorder_array != array_ptr || im.IsMouseDown(.Left) do return
	from := _reorder_index
	slot := _reorder_target
	_reorder_array = nil
	_reorder_index = -1

	to := slot > from ? slot - 1 : slot
	if from == to || from < 0 || from >= count || to < 0 || to >= count do return
	sess := structural_edit_begin("Reorder Element")
	move_array_element(data, elem_size, from, to)
	structural_edit_end(&sess)
}

// Insertion slot past the last row. Runs right after the row loop, so the
// cursor sits below everything the last element drew - expanded contents
// included - and the line lands after all of it, like the between-row lines.
_draw_reorder_tail :: proc(array_ptr: rawptr, count: int) {
	if _reorder_array != array_ptr || _reorder_target != count do return
	dl := im.GetWindowDrawList()
	x1 := im.GetWindowPos().x + im.GetWindowWidth() - im.GetStyle().WindowPadding.x
	y := im.GetCursorScreenPos().y - im.GetStyle().ItemSpacing.y * 0.5
	im.DrawList_AddLine(dl, im.Vec2{_reorder_row_left, y}, im.Vec2{x1, y},
		im.GetColorU32ImVec4(REORDER_LINE_COLOR), 3.0)
}

// One grip per array row, shared by dynamic and fixed arrays. Transparent at
// rest, tinted on the source row while a drag is live. Rows draw top to bottom,
// so the target slot is the first row whose grip center is below the mouse.
_draw_reorder_grip :: proc(array_ptr: rawptr, i: int, count: int) {
	style := im.GetStyle()
	held := _reorder_array == array_ptr && _reorder_index == i
	im.PushStyleColorImVec4(.Button,
		held ? style.Colors[im.Col.ButtonActive] : im.Vec4{0, 0, 0, 0})
	im.Button(ICON_MD_DRAG_INDICATOR + "###drag")
	im.PopStyleColor(1)

	if im.IsItemActivated() {
		_reorder_array = array_ptr
		_reorder_index = i
		_reorder_target = i
	}
	if _reorder_array == array_ptr {
		rect_min := im.GetItemRectMin()
		rect_max := im.GetItemRectMax()
		if i == 0 {
			_reorder_target = count // sentinel: below the last row
			_reorder_row_left = rect_min.x
		}
		if _reorder_target == count && im.GetMousePos().y < (rect_min.y + rect_max.y) * 0.5 {
			_reorder_target = i
			dl := im.GetWindowDrawList()
			x1 := im.GetWindowPos().x + im.GetWindowWidth() - im.GetStyle().WindowPadding.x
			y := rect_min.y - style.ItemSpacing.y * 0.5
			im.DrawList_AddLine(dl, im.Vec2{rect_min.x, y}, im.Vec2{x1, y},
				im.GetColorU32ImVec4(REORDER_LINE_COLOR), 3.0)
		}
	}
	im.SameLine()
}

// draw_inspector_array draws a dynamic or fixed array field. Called from the inspector when a field type is an array.
draw_inspector_array :: proc(field_ptr: rawptr, field_tid: typeid, label: cstring) {
	draw_inspector_array_multi(field_ptr, field_tid, label, 0)
}

// The array field, multi-selection aware.
//
// `array_offset` locates this array field on a peer object. Element storage is
// somewhere else entirely for a dynamic array (its own allocation), so the peer
// list is rebased onto each peer's storage before the rows draw — after that,
// element i is at i*elem_size on every object and the rows multi-edit like any
// other field.
//
// Unity's model, which this follows: the array is NOT hidden under a
// multi-selection. Rows are drawn up to the SHORTEST length across the
// selection, each row showing its own mixed-value dash. Rows past that length
// have no counterpart to edit, so they are not shown.
draw_inspector_array_multi :: proc(field_ptr: rawptr, field_tid: typeid, label: cstring, array_offset: uintptr) {
	ti := runtime.type_info_base(type_info_of(field_tid))

	if info, ok := ti.variant.(runtime.Type_Info_Dynamic_Array); ok {
		da := (^runtime.Raw_Dynamic_Array)(field_ptr)
		draw_dynamic_array(da, info.elem, field_ptr, field_tid, label, array_offset)
	} else if info, ok := ti.variant.(runtime.Type_Info_Array); ok {
		draw_fixed_array(field_ptr, info.count, info.elem, field_tid, label, array_offset)
	} else {
		im.TextColored(im.Vec4{1, 0, 0, 1}, "Not an array type")
	}
}

// is_array_type returns true if the typeid is a dynamic or fixed array.
is_array_type :: proc(tid: typeid) -> bool {
	ti := runtime.type_info_base(type_info_of(tid))
	_, is_dyn := ti.variant.(runtime.Type_Info_Dynamic_Array)
	_, is_fixed := ti.variant.(runtime.Type_Info_Array)
	return is_dyn || is_fixed
}

draw_fixed_array :: proc(ptr: rawptr, count: int, elem_ti: ^runtime.Type_Info, field_tid: typeid, label: cstring, array_offset: uintptr = 0) {
	tree_open := im.TreeNode(label)
	draw_field_context_menu(ptr, field_tid)
	if !tree_open do return
	defer im.TreePop()
	im.TextDisabled("Fixed size: %d", count)

	readonly := engine.inspector_is_readonly()
	_reorder_apply_if_released(ptr, ptr, elem_ti.size, count)

	// The storage IS the field, and the length is fixed by the type, so every
	// peer has the same count — only the base moves.
	multi_prev := multi_rebase_to_fixed_array(array_offset)
	defer multi_rebase_end(multi_prev)

	for i in 0 ..< count {
		im.PushIDInt(c.int(i))
		if !readonly do _draw_reorder_grip(ptr, i, count)
		elem_ptr := rawptr(uintptr(ptr) + uintptr(i * elem_ti.size))
		sub_label := fmt.tprintf("[%d]", i)
		draw_array_element(elem_ptr, elem_ti.id, strings.clone_to_cstring(sub_label, context.temp_allocator), uintptr(i * elem_ti.size))
		im.PopID()
	}
	_draw_reorder_tail(ptr, count)
}

// What the "+ Add" and "x" buttons DO, separated from the buttons so they can be
// driven without a UI.
//
// `peers` is the PRE-REBASE list, whose bases are component bases: the op finds
// each peer's array at `base + array_offset`. The rebased list the rows use
// points at element storage instead, and also drops peers whose array is empty —
// which are exactly the peers an Add must still reach.
//
// Every selected object grows or shrinks too, so a new row is immediately
// editable across the whole selection rather than being hidden by truncation,
// and the whole thing is ONE undo step rather than one per object.
array_add_element :: proc(da: ^runtime.Raw_Dynamic_Array, array_offset: uintptr, elem_ti: ^runtime.Type_Info, peers: []Multi_Peer) {
	multi_array_structural(.Append, da, array_offset, elem_ti, 0, peers, "Add Element")
}

array_remove_element :: proc(da: ^runtime.Raw_Dynamic_Array, array_offset: uintptr, elem_ti: ^runtime.Type_Info, index: int, peers: []Multi_Peer) {
	multi_array_structural(.Remove, da, array_offset, elem_ti, index, peers, "Remove Element")
}

draw_dynamic_array :: proc(da: ^runtime.Raw_Dynamic_Array, elem_ti: ^runtime.Type_Info, field_ptr: rawptr, field_tid: typeid, label: cstring, array_offset: uintptr = 0) {
	tree_open := im.TreeNode(label)
	draw_field_context_menu(field_ptr, field_tid)
	if !tree_open do return
	defer im.TreePop()

	// Rows are drawn up to the SHORTEST length across the selection: past that
	// there is no counterpart on some object, so there is nothing to edit. The
	// size row says so rather than silently showing a short list.
	// Both questions are asked BEFORE the rebase: they are about the array fields
	// on the peer OBJECTS, and the rebase replaces those with element storage.
	// It can also empty the peer list (a peer whose array is empty has no rows
	// to pair with), so "is this a multi-selection" has to be captured here too.
	is_multi := multi_active()
	len_mixed := is_multi && multi_array_len_mixed(array_offset, da.len)
	multi_prev, common_len := multi_rebase_to_dynamic_array(array_offset, da.len, elem_ti.size)
	defer multi_rebase_end(multi_prev)

	if len_mixed {
		// The dash is the mixed marker every other field uses. The counts spell
		// out what it means for a list, since "mixed length" alone does not say
		// why some rows are missing.
		im.TextDisabled("Size: %s - this object %d, showing %d common",
			MIXED_VALUE_TEXT, da.len, common_len)
	} else {
		im.TextDisabled("Size: %d", da.len)
	}

	readonly := engine.inspector_is_readonly()

	// Reorder stays single-object: it permutes rows, and a permutation of one
	// array means nothing on a peer whose contents differ. Unity suppresses drag
	// reordering under a multi-selection for the same reason.
	reorder_readonly := readonly || is_multi

	_reorder_apply_if_released(field_ptr, da.data, elem_ti.size, da.len)

	draw_count := common_len if is_multi else da.len

	to_remove := -1
	for i in 0 ..< draw_count {
		im.PushIDInt(c.int(i))
		if !reorder_readonly do _draw_reorder_grip(field_ptr, i, da.len)
		im.AlignTextToFramePadding()
		im.Text("%d:", i)
		im.SameLine()
		elem_ptr := rawptr(uintptr(da.data) + uintptr(i * elem_ti.size))
		im.SetNextItemWidth(im.GetContentRegionAvail().x - 30)
		draw_array_element(elem_ptr, elem_ti.id, "##val", uintptr(i * elem_ti.size))
		im.SameLine()
		if readonly {
			im.BeginDisabled(true)
		}
		if im.Button("x") {
			to_remove = i
		}
		if readonly {
			im.EndDisabled()
		}
		im.PopID()
	}
	_draw_reorder_tail(field_ptr, draw_count)

	if readonly {
		im.BeginDisabled(true)
	}
	if im.Button("+ Add") && !readonly {
		array_add_element(da, array_offset, elem_ti, multi_prev.peers)
	}
	if readonly {
		im.EndDisabled()
	}

	if to_remove >= 0 && !readonly {
		array_remove_element(da, array_offset, elem_ti, to_remove, multi_prev.peers)
	}
}

// draw_array_element draws one element using the same rules as the inspector: property drawer, struct recursion, or text.
//
// `elem_offset` is the element's byte offset within the array's element storage.
// The peer list has already been rebased onto each peer's storage, so this
// addresses the same element on every selected object.
draw_array_element :: proc(ptr: rawptr, elem_tid: typeid, label: cstring, elem_offset: uintptr = 0) {
	if drawer, ok := mapPropertyDrawer[elem_tid]; ok {
		prev_changed := inspector_changed
		inspector_changed = false
		multi_probe_field(ptr, elem_tid, elem_offset)

		// One shared transaction path for every value row — see field_edit_row.
		// Duplicating it here is what let the array copy keep a picker handling
		// that wrote to peers on every draw.
		field_edit_row(ptr, elem_tid, elem_offset, "Element", drawer, label)

		if prev_changed || inspector_changed do inspector_changed = true
		draw_field_context_menu(ptr, elem_tid)
		return
	}
	elem_ti := type_info_of(elem_tid)
	if is_union_type(elem_tid) {
		mprev := multi_suspend()
		draw_inspector_union(ptr, elem_tid, label)
		multi_resume(mprev)
		return
	}
	if reflect.is_struct(elem_ti) {
		elem_any := any{ptr, elem_tid}
		tree_open := im.TreeNode(label)
		draw_field_context_menu(ptr, elem_tid)
		if tree_open {
			prev_in_elem := _in_array_element
			_in_array_element = true
			// Fields inside the element are located from the element's start on
			// each peer, so the recursion carries its offset.
			prev_off := multi_push_offset(elem_offset)
			draw_inspector(elem_any)
			multi_pop_offset(prev_off)
			_in_array_element = prev_in_elem
			im.TreePop()
		}
		return
	}
	elem_any := any{ptr, elem_tid}
	c_str := strings.clone_to_cstring(fmt.tprintf("%s: %v", label, elem_any), context.temp_allocator)
	im.Text(c_str)
	draw_field_context_menu(ptr, elem_tid)
}

append_dynamic_array_element :: proc(da: ^runtime.Raw_Dynamic_Array, elem_ti: ^runtime.Type_Info) -> bool {
	elem_size := elem_ti.size
	if elem_size == 0 do return false

	// Use context allocator if the array's allocator was never set (e.g. after JSON load or default-init)
	if da.allocator.procedure == nil do da.allocator = context.allocator

	new_len := da.len + 1
	if new_len > da.cap {
		new_cap := max(da.cap * 2, 1)
		new_data, err := mem.alloc(new_cap * elem_size, mem.DEFAULT_ALIGNMENT, da.allocator)
		if err != .None do return false
		if da.len > 0 do mem.copy(new_data, da.data, da.len * elem_size)
		old_data := da.data
		da.data = new_data
		da.cap = new_cap
		mem.free(old_data, da.allocator)
	}
	if da.data == nil do return false

	slot := rawptr(uintptr(da.data) + uintptr(da.len * elem_size))
	mem.zero(slot, elem_size)
	da.len = new_len
	return true
}

// Removes the element at `from` and re-inserts it at `to`, shifting the range
// between them by one slot.
move_array_element :: proc(data: rawptr, elem_size: int, from, to: int) {
	if from == to || from < 0 || to < 0 || elem_size == 0 || data == nil do return
	tmp, err := mem.alloc_bytes(elem_size, mem.DEFAULT_ALIGNMENT, context.temp_allocator)
	if err != .None do return
	src := rawptr(uintptr(data) + uintptr(from * elem_size))
	dst := rawptr(uintptr(data) + uintptr(to * elem_size))
	mem.copy(raw_data(tmp), src, elem_size)
	if to < from {
		// shift [to, from) right by one
		mem.copy(rawptr(uintptr(data) + uintptr((to + 1) * elem_size)), dst, (from - to) * elem_size)
	} else {
		// shift (from, to] left by one
		mem.copy(src, rawptr(uintptr(data) + uintptr((from + 1) * elem_size)), (to - from) * elem_size)
	}
	mem.copy(dst, raw_data(tmp), elem_size)
}

remove_dynamic_array_element :: proc(da: ^runtime.Raw_Dynamic_Array, elem_ti: ^runtime.Type_Info, index: int) {
	if index < 0 || index >= da.len do return
	elem_size := elem_ti.size
	src := rawptr(uintptr(da.data) + uintptr((index + 1) * elem_size))
	dst := rawptr(uintptr(da.data) + uintptr(index * elem_size))
	n_bytes := (da.len - 1 - index) * elem_size
	if n_bytes > 0 {
		mem.copy(dst, src, n_bytes)
	}
	last_slot := rawptr(uintptr(da.data) + uintptr((da.len - 1) * elem_size))
	mem.zero(last_slot, elem_size)
	da.len -= 1
}
