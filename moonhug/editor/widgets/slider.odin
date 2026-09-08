package widgets

// slider: a thin track, a round handle, and a number field beside it.
// imgui's own SliderFloat draws a filled box with the value centered inside
// it, which reads as a progress bar rather than a slider.
//
// The track is drawn, not an imgui frame, so the widget carries no theme
// frame background. Colors come from the theme's slider and frame colors, so
// it follows every theme like the built-in one.

import "core:math"
import im "moonhug:external/odin-imgui"

// Track thickness and handle radius, in pixels at the default font size.
SLIDER_TRACK_H :: f32(3)
SLIDER_GRAB_R :: f32(6)

// Width of the number field beside the track.
SLIDER_INPUT_W :: f32(56)

// A slider over [min, max] with a number field. `format` is the field's
// printf format (e.g. "%.2f"). `width` is the whole widget including the
// field; 0 takes the remaining content width.
//
// Returns true on any frame the value changed, from either half.
slider_float :: proc(id: cstring, v: ^f32, min, max: f32, format: cstring = "%.2f", width: f32 = 0) -> (changed: bool) {
	if v == nil || max <= min do return false

	im.PushID(id)
	defer im.PopID()

	style := im.GetStyle()
	total := width > 0 ? width : im.GetContentRegionAvail().x
	track_w := max_f32(total - SLIDER_INPUT_W - style.ItemSpacing.x, SLIDER_GRAB_R * 4)

	// The track's own item: full height so the row lines up with the field,
	// with the line drawn centered inside it.
	h := im.GetFrameHeight()
	origin := im.GetCursorScreenPos()
	im.InvisibleButton("##track", im.Vec2{track_w, h})
	track_id := im.GetItemID()
	active := im.IsItemActive()
	hovered := im.IsItemHovered({})

	// Drag anywhere on the track, including the first click: the handle
	// jumps to the pointer, which is how Unity's slider behaves.
	if active {
		mx := im.GetMousePos().x
		t := (mx - (origin.x + SLIDER_GRAB_R)) / max_f32(track_w - SLIDER_GRAB_R * 2, 1)
		nv := min + clamp_f32(t, 0, 1) * (max - min)
		if nv != v^ {
			v^ = nv
			changed = true
			// An InvisibleButton never marks itself edited, so without this a
			// release would not read as IsItemDeactivatedAfterEdit and an undo
			// bracket around the row would never close.
			im.MarkItemEdited(track_id)
		}
	}

	frac := clamp_f32((v^ - min) / (max - min), 0, 1)
	cy := origin.y + h * 0.5
	x0 := origin.x + SLIDER_GRAB_R
	x1 := origin.x + track_w - SLIDER_GRAB_R
	gx := x0 + frac * (x1 - x0)

	dl := im.GetWindowDrawList()
	// Track: the unfilled part in the frame color, the filled part in the
	// slider color, so the value reads at a glance.
	im.DrawList_AddRectFilled(dl,
		im.Vec2{x0, cy - SLIDER_TRACK_H * 0.5}, im.Vec2{x1, cy + SLIDER_TRACK_H * 0.5},
		im.GetColorU32(.FrameBg), SLIDER_TRACK_H * 0.5)
	if gx > x0 {
		im.DrawList_AddRectFilled(dl,
			im.Vec2{x0, cy - SLIDER_TRACK_H * 0.5}, im.Vec2{gx, cy + SLIDER_TRACK_H * 0.5},
			im.GetColorU32(.SliderGrab), SLIDER_TRACK_H * 0.5)
	}
	// Handle: a filled circle with a darker edge, so it reads on any track.
	grab_col: im.Col = active ? .SliderGrabActive : .SliderGrab
	im.DrawList_AddCircleFilled(dl, im.Vec2{gx, cy}, SLIDER_GRAB_R, im.GetColorU32(grab_col))
	if hovered || active {
		im.DrawList_AddCircle(dl, im.Vec2{gx, cy}, SLIDER_GRAB_R, im.GetColorU32(.Text), 0, 1)
	} else {
		im.DrawList_AddCircle(dl, im.Vec2{gx, cy}, SLIDER_GRAB_R, im.GetColorU32(.Border), 0, 1)
	}

	// The number field: types an exact value, and clamps to the range.
	im.SameLine(0, style.ItemSpacing.x)
	im.SetNextItemWidth(SLIDER_INPUT_W)
	typed := v^
	if im.InputFloat("##value", &typed, 0, 0, format, {.EnterReturnsTrue}) {
		nv := clamp_f32(typed, min, max)
		if nv != v^ {
			v^ = nv
			changed = true
		}
	}
	return
}

@(private = "file")
clamp_f32 :: proc(v, lo, hi: f32) -> f32 {
	return math.min(math.max(v, lo), hi)
}

@(private = "file")
max_f32 :: proc(a, b: f32) -> f32 {
	return math.max(a, b)
}

// The width a slider_float occupies for a given track width.
slider_width_for_track :: proc(track_w: f32) -> f32 {
	return track_w + im.GetStyle().ItemSpacing.x + SLIDER_INPUT_W
}
