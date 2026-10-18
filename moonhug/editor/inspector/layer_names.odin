package inspector

// A layer names list: a [32]string drawn as 32 fixed rows, one per layer
// (plugins/engine/docs/Layers.md "The Render Layers asset"). A built-in layer
// reads "Builtin Layer N" with its name greyed out and fixed, a user layer
// reads "User Layer N" with a text field. An empty name is an unused layer.
//
// `decor:layer_names(builtin="0,31")` puts it on a field: the comma list names
// the built-in layers. The field loop runs it through field_edit_row, so each
// finished edit of a name is one undo step.

import "core:fmt"
import "core:strconv"
import "core:strings"
import im "moonhug:external/odin-imgui"
import core "moonhug:libs/core"
import "moonhug:editor/widgets"

decorator_layer_names :: proc(ctx: ^DrawContext, builtin: string) {
	if !ctx.is_pre do return
	if ctx.field_ptr == nil do return
	if ctx.field_type != typeid_of([core.LAYER_COUNT]string) {
		fmt.panicf("decor:layer_names sits on a %v field, it is for [%d]string names", ctx.field_type, core.LAYER_COUNT)
	}
	fixed: u32
	for part in strings.split(builtin, ",", context.temp_allocator) {
		p := strings.trim_space(part)
		if p == "" do continue
		n, ok := strconv.parse_int(p)
		if !ok || n < 0 || n >= core.LAYER_COUNT do fmt.panicf("decor:layer_names lists %q as a built-in layer, which is no layer number", p)
		fixed |= u32(1) << u32(n)
	}
	multi_probe_field(ctx.field_ptr, ctx.field_type, multi_offset_of(ctx.field_ptr, ctx.owner_ptr))
	layer_names_field(cast(^[core.LAYER_COUNT]string)ctx.field_ptr, fixed)
	ctx.is_visible = false
	ctx.handled_draw = true
}

// Draws the 32 rows of `names` and returns whether a name changed. The layers
// of `builtin` (a mask) show their names but do not edit them.
layer_names_field :: proc(names: ^[core.LAYER_COUNT]string, builtin: u32) -> (changed: bool) {
	if current_field_mixed do im.TextDisabled("The selected assets name their layers differently: an edit sets the name on all of them")
	for &name, i in names {
		im.PushIDInt(i32(i))
		defer im.PopID()
		fixed := builtin & (u32(1) << u32(i)) != 0
		label := fixed ? fmt.ctprintf("Builtin Layer %d", i) : fmt.ctprintf("User Layer %d", i)
		buf: [128]u8
		copy(buf[:len(buf) - 1], name)
		if fixed {
			im.BeginDisabled(true)
			im.InputText(field_row(label), cstring(raw_data(buf[:])), len(buf), {.ReadOnly})
			im.EndDisabled()
			widgets.tooltip("A built-in layer: its name is fixed", im.HoveredFlags_AllowWhenDisabled)
			continue
		}
		if im.InputText(field_row(label), cstring(raw_data(buf[:])), len(buf), {}) {
			// Asset strings live on context.allocator, as the string drawer's
			// do: the old name is freed, or every keystroke leaks one.
			delete(name)
			name = strings.clone(string(cstring(raw_data(buf[:]))))
			changed = true
		}
	}
	if changed do mark_inspector_changed()
	return
}
