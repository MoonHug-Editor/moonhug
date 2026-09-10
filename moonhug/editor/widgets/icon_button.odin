package widgets

// Icon buttons, in the shared package so every view gets the same look and
// the same centering.
//
// A glyph is NOT centered by passing it as the button's label: imgui centers
// a label by its advance width, and these glyphs carry side bearing, so the
// icon sits visibly off-center in a square box. Every icon button here takes
// an EMPTY label and draws the glyph centered on the button's own rect. That
// mistake has been made twice in this codebase, so it is fixed in one place.

import im "moonhug:external/odin-imgui"

// Draws `glyph` centered inside [rmin, rmax] on the current draw list, in the
// current text color. For a caller that owns its own button or frame.
icon_draw_centered :: proc(glyph: cstring, rmin, rmax: im.Vec2) {
	sz := im.CalcTextSize(glyph, nil, false, -1)
	pos := im.Vec2{
		rmin.x + (rmax.x - rmin.x - sz.x) * 0.5,
		rmin.y + (rmax.y - rmin.y - sz.y) * 0.5,
	}
	im.DrawList_AddText(im.GetWindowDrawList(), pos, im.GetColorU32(.Text), glyph)
}

// A square icon button. `id` must start with "##" — it is the button's imgui
// id and never shows. `size` 0 takes one frame height, so a row of them lines
// up with the fields beside it.
//
// `active` lights the button the way a held toggle reads, and `tooltip` is
// shown on hover (also while disabled, so a disabled control can say why).
icon_button :: proc(
	glyph: cstring,
	id: cstring,
	tooltip: cstring = "",
	active := false,
	size: f32 = 0,
) -> (clicked: bool) {
	h := size > 0 ? size : im.GetFrameHeight()
	if active do im.PushStyleColorImVec4(.Button, im.GetStyleColorVec4(.ButtonActive)^)
	clicked = im.Button(id, im.Vec2{h, h})
	if active do im.PopStyleColor()
	icon_draw_centered(glyph, im.GetItemRectMin(), im.GetItemRectMax())
	if tooltip != "" && im.IsItemHovered(im.HoveredFlags_AllowWhenDisabled) {
		im.SetTooltip(tooltip)
	}
	return
}
