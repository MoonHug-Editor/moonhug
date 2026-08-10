package inspector

// Left-aligned drag widgets.
//
// imgui hardcodes the value text of DragFloat/DragInt to CENTER: DragScalar
// ends in RenderTextClipped(..., ImVec2(0.5f, 0.5f)) and there is no style var
// for it, unlike ButtonTextAlign. Inspector rows read as a column of values, so
// centered numbers make the column ragged. These procs are drop-in
// replacements for im.DragFloat / im.DragFloat2/3/4 / im.DragInt that align the
// value the way a text field does.
//
// HOW: hand imgui a display-suppressed "##" label and draw the real widget with
// Col.Text transparent, then redraw the value left-aligned over the frame and
// let normal layout place the label. The widget keeps imgui's exact behavior for
// free — drag speed, precision rounding, Ctrl+click to type, keyboard nav,
// min/max clamping, the color marker.
//
// Suppressing the label is what keeps this honest, for two reasons:
//   - imgui reports the item rect as frame + label. With the label hidden, the
//     item rect IS the frame rect, so GetItemRectMin/Max give us authoritative
//     geometry and nothing here recomputes imgui's layout math.
//   - Col.Text in this path is used for exactly two things, the value and the
//     label. With no label to draw, pushing it transparent hides precisely the
//     one string we intend to replace.
// Prefixing "##" preserves the widget's ID: ImHashStr resets its seed on "###",
// and hashes "##" like any other text, so "##" + label is stable and unique.
//
// WHY NOT transcribe DragScalar: the binding exports every internal proc such a
// copy needs, so it looks tempting, but the binding's INTERNAL STRUCT
// DEFINITIONS DO NOT MATCH THE COMPILED LIBRARY. Measured against the vendored
// imgui headers:
//     sizeof(ImGuiWindow)          C++ 1240  vs Odin 1256
//     offsetof(ImGuiWindow, DC)    C++  344  vs Odin  360   <- 16 bytes off
//     sizeof(ImGuiContext)         C++ 11560 vs Odin 11544
//     offsetof(Context, ActiveId)  C++ 5756  vs Odin  5724  <- 32 bytes off
//     sizeof(ImGuiIO)              C++ 3096  vs Odin 3064   <- 32 bytes off
// So window.DC.CursorPos, g.ActiveId and g.IO.* all read garbage, and a
// transcription of DragScalar laid its frames out at the window's top-left
// corner for exactly that reason. PASSING those pointers to imgui procs is
// fine, and ImGuiStyle happens to match (1356 both sides), so the rules here
// are: call any proc, read Style, never read a Window / Context / IO field.

import "core:fmt"
import im "moonhug:external/odin-imgui"

// Value alignment inside the frame. {0, 0.5} is left, vertically centered.
// The text rect is inset on both sides, so {0.5, 0.5} still centers and this
// constant alone decides the look.
DRAG_TEXT_ALIGN :: im.Vec2{0, 0.5}

// What a value reads as when the selected objects disagree on it (Unity's
// mixed-value dash). Drawn in place of the number — the underlying value is
// untouched, and typing or dragging still writes to the whole selection.
//
// ASCII on purpose. An em dash (U+2014) is the typographically right character
// and is what Unity uses, but the editor's font atlas is built from a limited
// glyph range and renders anything outside it as a "?" box — which reads as an
// error rather than as "these differ".
MIXED_VALUE_TEXT :: "-"

// Component index for the next _drag_scalar call, so a vector row can dash only
// the axes that actually differ. -1 means "not a component of a vector", and
// the whole-field flag decides.
@(private = "file")
_drag_component_index: int = -1

// Set when ANY component of a multi-component row just finished an edit.
// imgui's item state describes only the LAST component once the row returns, so
// a release on X or Y is otherwise invisible to the caller.
@(private = "file")
_drag_row_deactivated: bool

// The mirror of the above for the START of an edit: a drag begun on X or Y is
// equally invisible to a caller reading imgui's item state afterwards.
@(private = "file")
_drag_row_activated: bool

// Whether the row drawn by the last drag_floatN just ended an edit (drag
// released, or a typed value applied). Consumes the flag, so it answers once.
//
// Callers that close an undo entry on release must use this rather than
// im.IsItemDeactivatedAfterEdit, which reports the last component only —
// dragging any other axis would never close the entry, and the object being
// edited would get no undo record at all.
drag_row_deactivated :: proc() -> bool {
	v := _drag_row_deactivated
	_drag_row_deactivated = false
	return v
}

// Whether the row drawn by the last drag_floatN just BEGAN an edit, from
// whichever component was clicked. Consumes the flag. Callers that open an undo
// entry on activation must use this rather than im.IsItemActivated, for the
// same reason as drag_row_deactivated.
drag_row_activated :: proc() -> bool {
	v := _drag_row_activated
	_drag_row_activated = false
	return v
}

// Whether the value this call is about to draw should read as mixed.
@(private = "file")
_drag_is_mixed :: proc() -> bool {
	if !current_field_mixed do return false
	if _drag_component_index < 0 do return true
	if _drag_component_index >= len(current_field_mixed_comps) do return true
	// A vector whose per-component flags are all clear disagrees on something
	// the component pass could not attribute (a non-scalar element type), so the
	// whole row reads as mixed rather than none of it.
	any_comp := false
	for c in current_field_mixed_comps {
		if c {
			any_comp = true
			break
		}
	}
	if !any_comp do return true
	return current_field_mixed_comps[_drag_component_index]
}

// One scalar drag with a left-aligned value. `format` must be non-nil, which
// the wrappers guarantee by passing imgui's own defaults.
@(private = "file")
_drag_scalar :: proc(
	label: cstring,
	data_type: im.DataType,
	p_data: rawptr,
	v_speed: f32,
	p_min: rawptr,
	p_max: rawptr,
	format: cstring,
	flags: im.SliderFlags,
) -> bool {
	style := im.GetStyle()

	// Anything visible after "##" stripping is a label we must draw ourselves.
	// Inspector rows already pass "##id" labels and take this path unchanged.
	has_label := im.CalcTextSize(label, nil, true).x > 0
	drag_label := label
	if has_label do drag_label = fmt.ctprintf("##%s", label)

	id := im.GetID(drag_label)
	// While Ctrl+click editing, imgui swaps in an InputText that draws its own
	// already-left-aligned text. Leave that alone entirely.
	if im.TempInputIsActive(id) {
		return _drag_raw(drag_label, label, has_label, data_type, p_data, v_speed, p_min, p_max, format, flags)
	}

	if has_label do im.BeginGroup()

	im.PushStyleColorImVec4(.Text, im.Vec4{0, 0, 0, 0})
	changed := im.DragScalar(drag_label, data_type, p_data, v_speed, p_min, p_max, format, flags)
	im.PopStyleColor()

	// Authoritative frame rect: the label is hidden, so imgui's item rect is the
	// frame and nothing here reimplements its layout.
	frame_min := im.GetItemRectMin()
	frame_max := im.GetItemRectMax()

	// Redraw the value we just hid, inset by FramePadding.x on both sides — the
	// same inset InputText uses — so a left-aligned value clears the border.
	//
	// A mixed multi-selection draws the dash here instead. Substituting at the
	// TEXT is what keeps the widget itself honest: the drag still holds the
	// active object's real value, so a drag from a mixed field moves by the
	// gesture's delta rather than from some invented zero.
	buf: [64]byte
	text_begin, text_end: cstring
	if _drag_is_mixed() {
		text_begin = MIXED_VALUE_TEXT
		text_end = nil
	} else {
		n := im.DataTypeFormatString(cstring(raw_data(buf[:])), i32(len(buf)), data_type, p_data, format)
		text_begin = cstring(raw_data(buf[:]))
		text_end = cstring(rawptr(uintptr(raw_data(buf[:])) + uintptr(n)))
	}
	im.RenderTextClipped(
		im.Vec2{frame_min.x + style.FramePadding.x, frame_min.y},
		im.Vec2{frame_max.x - style.FramePadding.x, frame_max.y},
		text_begin,
		text_end,
		nil,
		DRAG_TEXT_ALIGN,
		nil,
	)

	if has_label {
		_draw_trailing_label(label)
		im.EndGroup()
	}
	return changed
}

// The drag with no text interference, for the Ctrl+click editing frames where
// imgui draws its own InputText. Grouped with the label so the item rect stays
// the same shape as the styled path above.
@(private = "file")
_drag_raw :: proc(
	drag_label: cstring,
	label: cstring,
	has_label: bool,
	data_type: im.DataType,
	p_data: rawptr,
	v_speed: f32,
	p_min: rawptr,
	p_max: rawptr,
	format: cstring,
	flags: im.SliderFlags,
) -> bool {
	if !has_label {
		return im.DragScalar(drag_label, data_type, p_data, v_speed, p_min, p_max, format, flags)
	}
	im.BeginGroup()
	changed := im.DragScalar(drag_label, data_type, p_data, v_speed, p_min, p_max, format, flags)
	_draw_trailing_label(label)
	im.EndGroup()
	return changed
}

// The label to the right of the frame, where imgui puts it. Uses real layout
// rather than a hand-placed RenderText so the cursor advances and the label
// lands inside the item/group rect, as it does upstream.
@(private = "file")
_draw_trailing_label :: proc(label: cstring) {
	im.SameLine(0, im.GetStyle().ItemInnerSpacing.x)
	im.TextEx(label, im.FindRenderedTextEnd(label), {})
}

// N components on one line, mirroring ImGui::DragScalarN's layout (grouped,
// PushMultiItemsWidths, label trailing the last component) but routing each
// component through _drag_scalar so every value is left-aligned.
@(private = "file")
_drag_scalar_n :: proc(
	label: cstring,
	data_type: im.DataType,
	p_data: rawptr,
	components: i32,
	type_size: uintptr,
	v_speed: f32,
	p_min: rawptr,
	p_max: rawptr,
	format: cstring,
	flags: im.SliderFlags,
) -> bool {
	style := im.GetStyle()
	changed := false
	im.BeginGroup()
	im.PushID(label)
	im.PushMultiItemsWidths(components, im.CalcItemWidth())
	p := p_data
	for i in 0 ..< components {
		im.PushIDInt(i)
		if i > 0 do im.SameLine(0, style.ItemInnerSpacing.x)
		// Each component reports its own mixed state, so a selection agreeing on
		// X and Y but not Z dashes Z alone.
		_drag_component_index = int(i)
		if _drag_scalar("", data_type, p, v_speed, p_min, p_max, format, flags) do changed = true
		// Each component is its OWN imgui item, so the caller's post-drawer
		// IsItemActive() would only ever describe the last one (Z). Dragging Y
		// would then look inactive, the multi-edit pre-image would be recaptured
		// every frame, and the fieldwise diff would come back empty — writing
		// the whole vector and flattening X and Z across the selection. Asking
		// here, inside the loop, is the only place each component's own state is
		// the current item.
		// Latched per component: imgui's item state describes only the LAST
		// component once the row returns, so a gesture begun or ended on X or Y
		// is otherwise invisible to the caller. See drag_row_activated.
		if im.IsItemActivated() do _drag_row_activated = true
		// Same trap for the RELEASE. A caller asking IsItemDeactivatedAfterEdit
		// after this proc returns only ever describes the last component, so
		// releasing a drag on X or Y looks like no release at all — and a caller
		// that ends its undo entry there (the rotation row) never records the
		// object being edited. Latched here, where each component is the current
		// item, and read once via drag_row_deactivated.
		if im.IsItemDeactivatedAfterEdit() do _drag_row_deactivated = true
		_drag_component_index = -1
		im.PopID()
		im.PopItemWidth()
		p = rawptr(uintptr(p) + type_size)
	}
	im.PopID()

	if im.CalcTextSize(label, nil, true).x > 0 do _draw_trailing_label(label)
	im.EndGroup()
	return changed
}

// Drop-in replacements for the im.DragXxx procs, same defaults. Like upstream,
// v_min >= v_max means unbounded.

drag_float :: proc(
	label: cstring,
	v: ^f32,
	v_speed: f32 = 1.0,
	v_min: f32 = 0,
	v_max: f32 = 0,
	format: cstring = "%.3f",
	flags: im.SliderFlags = {},
) -> bool {
	v_min, v_max := v_min, v_max
	return _drag_scalar(label, .Float, v, v_speed, &v_min, &v_max, format, flags)
}

drag_float2 :: proc(
	label: cstring,
	v: ^[2]f32,
	v_speed: f32 = 1.0,
	v_min: f32 = 0,
	v_max: f32 = 0,
	format: cstring = "%.3f",
	flags: im.SliderFlags = {},
) -> bool {
	v_min, v_max := v_min, v_max
	return _drag_scalar_n(label, .Float, v, 2, size_of(f32), v_speed, &v_min, &v_max, format, flags)
}

drag_float3 :: proc(
	label: cstring,
	v: ^[3]f32,
	v_speed: f32 = 1.0,
	v_min: f32 = 0,
	v_max: f32 = 0,
	format: cstring = "%.3f",
	flags: im.SliderFlags = {},
) -> bool {
	v_min, v_max := v_min, v_max
	return _drag_scalar_n(label, .Float, v, 3, size_of(f32), v_speed, &v_min, &v_max, format, flags)
}

drag_float4 :: proc(
	label: cstring,
	v: ^[4]f32,
	v_speed: f32 = 1.0,
	v_min: f32 = 0,
	v_max: f32 = 0,
	format: cstring = "%.3f",
	flags: im.SliderFlags = {},
) -> bool {
	v_min, v_max := v_min, v_max
	return _drag_scalar_n(label, .Float, v, 4, size_of(f32), v_speed, &v_min, &v_max, format, flags)
}

drag_int :: proc(
	label: cstring,
	v: ^i32,
	v_speed: f32 = 1.0,
	v_min: i32 = 0,
	v_max: i32 = 0,
	format: cstring = "%d",
	flags: im.SliderFlags = {},
) -> bool {
	v_min, v_max := v_min, v_max
	return _drag_scalar(label, .S32, v, v_speed, &v_min, &v_max, format, flags)
}
