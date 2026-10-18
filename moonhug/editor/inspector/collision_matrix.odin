package inspector

// The collision matrix: a [32]u32 of layer rows drawn as a triangle of
// checkboxes, one per pair of named layers (plugins/engine/docs/Layers.md
// "Collision matrix inspector"). Bit j of row i set means layers i and j
// collide. A checkbox sets both bits, so the matrix stays symmetric.
//
// `decor:collision_matrix(names="names")` puts it on a field. The layer names
// come from the named [32]string field of the same struct, so the labels are
// always the asset's own, saved or not. The field loop runs it through
// field_edit_row, so each click is one undo step.

import "core:fmt"
import "core:reflect"
import im "moonhug:external/odin-imgui"
import core "moonhug:libs/core"
import "moonhug:editor/widgets"

decorator_collision_matrix :: proc(ctx: ^DrawContext, names: string) {
	if !ctx.is_pre do return
	if ctx.field_ptr == nil do return
	if ctx.field_type != typeid_of([core.LAYER_COUNT]u32) {
		fmt.panicf("decor:collision_matrix sits on a %v field, it is for [%d]u32 rows", ctx.field_type, core.LAYER_COUNT)
	}
	f := reflect.struct_field_by_name(ctx.owner_type, names)
	if f.type == nil || f.type.id != typeid_of([core.LAYER_COUNT]string) {
		fmt.panicf("decor:collision_matrix names %q, which is no [%d]string field of %v", names, core.LAYER_COUNT, ctx.owner_type)
	}
	list := cast(^[core.LAYER_COUNT]string)(uintptr(ctx.owner_ptr) + f.offset)
	multi_probe_field(ctx.field_ptr, ctx.field_type, multi_offset_of(ctx.field_ptr, ctx.owner_ptr))
	collision_matrix_field(cast(^[core.LAYER_COUNT]u32)ctx.field_ptr, list)
	ctx.is_visible = false
	ctx.handled_draw = true
}

// Draws the matrix of `rows` over the named layers of `names` and returns
// whether a pair changed. Unnamed layers have no row or column. Rows run top
// to bottom and columns right to left, so the checkboxes form a triangle with
// each pair once.
collision_matrix_field :: proc(rows: ^[core.LAYER_COUNT]u32, names: ^[core.LAYER_COUNT]string) -> (changed: bool) {
	listed := make([dynamic]int, 0, core.LAYER_COUNT, context.temp_allocator)
	for name, i in names {
		if name != "" do append(&listed, i)
	}
	if len(listed) == 0 {
		im.TextDisabled("No named layers: name them above")
		return false
	}
	if current_field_mixed do im.TextDisabled("The selected matrices differ: an edit sets the pair on all of them")

	n := len(listed)
	flags := im.TableFlags_SizingFixedFit | im.TableFlags_BordersInnerV | im.TableFlags_HighlightHoveredColumn
	if !im.BeginTable("##collision_matrix", i32(n + 1), flags) do return false
	defer im.EndTable()

	im.TableSetupColumn("", {.NoHide, .NoReorder}, 0, 0)
	for c in 0 ..< n {
		layer := listed[n - 1 - c]
		im.TableSetupColumn(fmt.ctprintf("%s##col%d", names[layer], layer), {.AngledHeader, .WidthFixed}, 0, 0)
	}
	im.TableAngledHeadersRow()

	for r in 0 ..< n {
		a := listed[r]
		im.TableNextRow()
		im.TableSetColumnIndex(0)
		im.TextUnformatted(fmt.ctprintf("%s", names[a]))
		// Column c shows layer listed[n-1-c]: the pair (a, b) appears once,
		// in the row of the layer listed first.
		for c in 0 ..< n - r {
			b := listed[n - 1 - c]
			im.TableSetColumnIndex(i32(c + 1))
			on := rows[a] & (u32(1) << u32(b)) != 0
			if im.Checkbox(fmt.ctprintf("##pair%d_%d", a, b), &on) {
				bit_b, bit_a := u32(1) << u32(b), u32(1) << u32(a)
				rows[a] = on ? rows[a] | bit_b : rows[a] &~ bit_b
				rows[b] = on ? rows[b] | bit_a : rows[b] &~ bit_a
				changed = true
			}
			widgets.tooltip(fmt.ctprintf("%s / %s", names[a], names[b]))
		}
	}
	if changed do mark_inspector_changed()
	return
}
