package inspector

// The layer picker: a u32 mask drawn as a dropdown with one checkbox per named
// layer of a domain (core/layers.odin, plugins/engine/docs/Layers.md).
//
// `decor:layers(domain="render")` puts it on a field. A custom row calls
// layer_mask_field from a drawer it runs through field_edit_row, so the edit
// records undo like any other row.

import "core:fmt"
import "core:strings"
import im "moonhug:external/odin-imgui"
import core "moonhug:libs/core"

// A preview lists the names when this many layers or fewer are on, and says
// "Mixed" past that.
LAYER_PREVIEW_MAX_NAMES :: 3

LAYER_MASK_NOTHING    :: u32(0)
LAYER_MASK_EVERYTHING :: ~u32(0)

// Draws a u32 field as the layer picker of `domain`. The domain names a list
// some owner registered (layer_domain_register), "render" for the engine's
// render layers.
decorator_layers :: proc(ctx: ^DrawContext, domain: string) {
	if !ctx.is_pre do return
	if ctx.field_ptr == nil do return
	if ctx.field_type != typeid_of(u32) {
		fmt.panicf("decor:layers sits on a %v field, it is for u32 masks", ctx.field_type)
	}
	// The field loop probes the selection only for rows it draws itself.
	multi_probe_field(ctx.field_ptr, ctx.field_type, multi_offset_of(ctx.field_ptr, ctx.owner_ptr))
	layer_mask_field(ctx.field_label, cast(^u32)ctx.field_ptr, domain)
	ctx.is_visible = false
	ctx.handled_draw = true
}

// Draws a labelled layer picker for `mask` and returns whether it changed.
//
// The value lands from inside the dropdown, so while the dropdown is open the
// row is held (field_edit_row_hold): the caller's field_edit_row then records
// each change as one undo step.
layer_mask_field :: proc(label: cstring, mask: ^u32, domain: string) -> (changed: bool) {
	names := core.layer_names(domain)
	if names == nil do fmt.panicf("decor:layers names the domain %q, which no owner registered (layer_domain_register)", domain)
	hidden := core.layer_hidden_mask(domain)

	preview := current_field_mixed ? MIXED_VALUE_TEXT : layer_mask_preview(mask^, names, hidden)
	id := field_row(label)
	if !im.BeginCombo(id, strings.clone_to_cstring(preview, context.temp_allocator)) do return false
	defer im.EndCombo()
	field_edit_row_hold()

	if im.Selectable("Nothing", layer_mask_is_nothing(mask^, hidden)) {
		mask^ = LAYER_MASK_NOTHING
		changed = true
	}
	if im.Selectable("Everything", layer_mask_is_everything(mask^, hidden)) {
		mask^ = LAYER_MASK_EVERYTHING
		changed = true
	}
	im.Separator()
	for name, i in names {
		bit := u32(1) << u32(i)
		if name == "" || hidden & bit != 0 do continue
		on := mask^ & bit != 0
		if im.Checkbox(fmt.ctprintf("%s##layer%d", name, i), &on) {
			mask^ = on ? mask^ | bit : mask^ &~ bit
			changed = true
		}
	}
	if changed do mark_inspector_changed()
	return
}

// Hidden layers do not count: a mask is "Nothing" when no listed bit is on,
// "Everything" when every bit but the hidden ones is on.
layer_mask_is_nothing :: proc(mask, hidden: u32) -> bool {
	return mask &~ hidden == 0
}

layer_mask_is_everything :: proc(mask, hidden: u32) -> bool {
	return mask | hidden == LAYER_MASK_EVERYTHING
}

// The picker's closed text for `mask`: "Nothing", "Everything", the names of
// the layers that are on (comma separated, up to LAYER_PREVIEW_MAX_NAMES), or
// "Mixed" for more, or for an unnamed bit. Temp-allocated.
layer_mask_preview :: proc(mask: u32, names: ^[core.LAYER_COUNT]string, hidden: u32) -> string {
	if layer_mask_is_nothing(mask, hidden) do return "Nothing"
	if layer_mask_is_everything(mask, hidden) do return "Everything"
	listed := make([dynamic]string, 0, LAYER_PREVIEW_MAX_NAMES, context.temp_allocator)
	for name, i in names {
		bit := u32(1) << u32(i)
		if mask & bit == 0 || hidden & bit != 0 do continue
		if name == "" do return "Mixed"
		append(&listed, name)
	}
	if len(listed) > LAYER_PREVIEW_MAX_NAMES do return "Mixed"
	return strings.join(listed[:], ", ", context.temp_allocator)
}
