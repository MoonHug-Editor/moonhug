package inspector

import "core:c"
import "core:fmt"
import "core:mem"
import "base:runtime"
import strings "core:strings"
import im "moonhug:external/odin-imgui"
import engine "../../engine"
import "../undo"

// `record_undo=false` is for callers whose OWN transaction wraps this draw -- a
// custom drawer under field_edit_row already records the whole owner on any
// change, and the variant switch recording its own step there would produce two
// undo entries for one click.
draw_inspector_union :: proc(field_ptr: rawptr, field_tid: typeid, label: cstring, record_undo := true) {
	ti := runtime.type_info_base(type_info_of(field_tid))

	if info, ok := ti.variant.(runtime.Type_Info_Union); ok {
		draw_union_field(field_ptr, info, label, field_tid, record_undo)
	} else {
		im.TextColored(im.Vec4{1, 0, 0, 1}, "Not a union type")
	}
}

is_union_type :: proc(tid: typeid) -> bool {
	ti := runtime.type_info_base(type_info_of(tid))
	_, is_union := ti.variant.(runtime.Type_Info_Union)
	return is_union
}

// Odin's union tag encoding, in one place because the two forms differ by one
// and getting it wrong silently selects the neighbouring variant.
//
//   nilable  (`union {A, B}`):         tag 0 = nil, tag N = variants[N-1]
//   #no_nil  (`union #no_nil {A, B}`): tag N = variants[N]
//
// `variant_index` is an index into info.variants, or -1 for nil.
@(private)
_union_tag_for_index :: proc(info: runtime.Type_Info_Union, variant_index: int) -> i64 {
	if variant_index < 0 || variant_index >= len(info.variants) {
		return 0 // nil; a #no_nil union has no such state, so callers never ask
	}
	return i64(variant_index) if info.no_nil else i64(variant_index + 1)
}

@(private)
_union_index_for_tag :: proc(info: runtime.Type_Info_Union, tag: i64) -> int {
	idx := int(tag) if info.no_nil else int(tag) - 1
	if idx < 0 || idx >= len(info.variants) do return -1
	return idx
}

// What picking a variant from the dropdown DOES, separated from the dropdown so
// it can be driven without a UI.
//
// The payload is zeroed on every switch: the old variant's bytes mean something
// different under the new tag, and reading them as the new type is garbage.
//
// The session covers the ACTIVE object only. Unions are not multi-edited (see
// docs/Multiselection.md) — the same bytes mean different things when peers hold
// different variants — so there is no peer write to record.
union_set_variant :: proc(ptr: rawptr, tag_ptr: rawptr, info: runtime.Type_Info_Union, variant_index: int, record_undo := true) {
	if ptr == nil || tag_ptr == nil do return

	prev := multi_set_peers(nil)
	defer multi_set_peers(prev)

	sess: undo.Edit_Session
	if record_undo do sess = structural_edit_begin("Change Variant")
	mem.zero(ptr, int(info.tag_offset))
	(^i64)(tag_ptr)^ = _union_tag_for_index(info, variant_index)
	if record_undo {
		structural_edit_end(&sess)
	} else {
		mark_inspector_changed()
	}
}

draw_union_field :: proc(ptr: rawptr, info: runtime.Type_Info_Union, label: cstring, field_tid: typeid, record_undo := true) {
	tag_ptr := rawptr(uintptr(ptr) + uintptr(info.tag_offset))
	current_tag := (^i64)(tag_ptr)^

	is_no_nil := info.no_nil

	variant_names := make([dynamic]cstring, context.temp_allocator)
	if !is_no_nil {
		append(&variant_names, "None")
	}
	for variant in info.variants {
		name := fmt.tprintf("%v", variant)
		append(&variant_names, strings.clone_to_cstring(name, context.temp_allocator))
	}

	current_index := _union_index_for_tag(info, current_tag)
	has_content := current_index >= 0

	tree_open := false
	if has_content {
		tree_open = im.TreeNodeEx(label, {.DefaultOpen})
	} else {
		im.AlignTextToFramePadding()
		im.Text(label)
	}
	draw_field_context_menu(ptr, field_tid)

	// The label is a foldout, so it is already drawn — this only claims the value
	// column for the type dropdown.
	type_id := field_row_value("type")

	// The combo list carries a leading "None" row for a nilable union, so its
	// index is the variant index shifted by one.
	combo_base := 0 if is_no_nil else 1
	selected := c.int(current_index + combo_base)

	readonly := engine.inspector_is_readonly()
	if readonly {
		im.BeginDisabled(true)
	}
	if im.ComboChar(type_id, &selected, ([^]cstring)(raw_data(variant_names[:])), c.int(len(variant_names))) && !readonly {
		union_set_variant(ptr, tag_ptr, info, int(selected) - combo_base, record_undo)
	}
	if readonly {
		im.EndDisabled()
	}

	if has_content && tree_open {
		variant_ti := info.variants[current_index]
		variant_any := any{ptr, variant_ti.id}
		draw_inspector(variant_any)
		im.TreePop()
	}
}
