package widgets

// A box of explanatory text across the panel: an info, warning or error icon
// on the left and the text wrapped beside it. Inspector fields get one with
// `decor:help(text="...")`, panels and importers call help_box directly.

import "core:strings"
import im "moonhug:external/odin-imgui"
import "moonhug:editor/icons"

Message_Kind :: enum {
	Info,
	Warning,
	Error,
}

// The Console's level colors, shared so a box and a log line of the same kind
// match: info nudged bluer and darker so it reads against the background,
// warning toned down a touch.
message_color :: proc(kind: Message_Kind) -> im.Vec4 {
	switch kind {
	case .Info:    return im.Vec4{0.62, 0.68, 0.78, 1}
	case .Warning: return im.Vec4{0.83, 0.64, 0.02, 1}
	case .Error:   return im.Vec4{0.827, 0.133, 0.133, 1}
	}
	return im.Vec4{1, 1, 1, 1}
}

message_icon :: proc(kind: Message_Kind) -> string {
	switch kind {
	case .Info:    return icons.ICON_MD_INFO
	case .Warning: return icons.ICON_MD_WARNING
	case .Error:   return icons.ICON_MD_ERROR
	}
	return icons.ICON_MD_INFO
}

// Draws `text` in a box as wide as the available space, tinted with the
// kind's color, with its icon on the left and the text wrapped beside it.
help_box :: proc(kind: Message_Kind, text: string) {
	style := im.GetStyle()
	pad := style.FramePadding
	gap := style.ItemInnerSpacing.x
	width := im.GetContentRegionAvail().x
	color := message_color(kind)

	icon := strings.clone_to_cstring(message_icon(kind), context.temp_allocator)
	body := strings.clone_to_cstring(text, context.temp_allocator)
	icon_size := im.CalcTextSize(icon)
	text_x := pad.x + icon_size.x + gap
	wrap := max(width - text_x - pad.x, 1)
	text_size := im.CalcTextSize(body, nil, false, wrap)
	height := max(text_size.y, icon_size.y) + pad.y * 2

	pos := im.GetCursorScreenPos()
	end := pos + im.Vec2{width, height}
	dl := im.GetWindowDrawList()
	im.DrawList_AddRectFilled(dl, pos, end, im.GetColorU32ImVec4({color.r, color.g, color.b, 0.12}), style.FrameRounding)
	im.DrawList_AddRect(dl, pos, end, im.GetColorU32ImVec4({color.r, color.g, color.b, 0.45}), style.FrameRounding)
	im.DrawList_AddText(dl, pos + pad, im.GetColorU32ImVec4(color), icon)

	im.SetCursorScreenPos(pos + im.Vec2{text_x, pad.y})
	im.PushTextWrapPos(im.GetCursorPosX() + wrap)
	im.TextUnformatted(body)
	im.PopTextWrapPos()
	// One item for the whole box, so the layout moves past it.
	im.SetCursorScreenPos(pos)
	im.Dummy({width, height})
}
