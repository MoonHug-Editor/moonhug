package editor

import "core:fmt"
import "core:strings"
import "core:path/filepath"
import "core:time"
import im "../../external/odin-imgui"
import "../engine/log"

_console_last_count: int
_console_show_info:    bool = true
_console_show_warning: bool = true
_console_show_error:   bool = true
_console_filter: [256]u8

// Console text colors, based on Unity's dark palette (default #D2D2D2,
// warning #F4BC02, error #D32222) but with info nudged bluer/darker so it
// reads against the bg, and warning toned down a touch.
_console_level_color :: proc(level: log.Level) -> im.Vec4 {
	switch level {
	case .Info:    return im.Vec4{0.62, 0.68, 0.78, 1}
	case .Warning: return im.Vec4{0.83, 0.64, 0.02, 1}
	case .Error:   return im.Vec4{0.827, 0.133, 0.133, 1}
	}
	return im.Vec4{1, 1, 1, 1}
}

_console_level_icon :: proc(level: log.Level) -> string {
	switch level {
	case .Info:    return ICON_MD_INFO
	case .Warning: return ICON_MD_WARNING
	case .Error:   return ICON_MD_ERROR
	}
	return ICON_MD_INFO
}

// The raw codepoint of each level icon, for per-glyph metric lookups.
_console_level_codepoint :: proc(level: log.Level) -> rune {
	for r in _console_level_icon(level) do return r // single-rune icon strings
	return 0
}

// Unity-style source line: "procedure (at path/to/file.odin:42)".
_console_loc_line :: proc(entry: log.Entry) -> cstring {
	name := entry.loc.procedure
	if name == "" do name = filepath.base(entry.loc.file_path)
	return fmt.ctprintf("%s (at %s:%d)", name, entry.loc.file_path, entry.loc.line)
}

// Local wall-clock "[hh:mm:ss]" prefix for a log entry.
_console_time_str :: proc(t: time.Time) -> string {
	h, m, s := time.clock_from_time(t)
	return fmt.tprintf("[%02d:%02d:%02d]", h, m, s)
}

draw_status_bar :: proc() {
	style := im.GetStyle()
	height := im.GetFrameHeight() + style.WindowPadding.y
	if !im.BeginViewportSideBar("##StatusBar", im.GetMainViewport(), .Down, height, {.NoScrollbar, .NoSavedSettings, .NoScrollWithMouse}) {
		im.End()
		return
	}
	defer im.End()

	n := len(log.entries)
	if n == 0 do return

	last := log.entries[n - 1]
	cmsg := fmt.ctprintf("%s %s  %s", _console_level_icon(last.level), _console_time_str(last.time), last.message)
	im.TextColored(_console_level_color(last.level), cmsg)
}

draw_console_view :: proc() {
	if im.Begin("Console", nil, {.NoCollapse}) {
		if im.Button("Clear") {
			log.clear()
			_console_last_count = 0
		}

		style := im.GetStyle()
		btn_labels := [3]cstring{ICON_MD_INFO, ICON_MD_WARNING, ICON_MD_ERROR}
		btn_width: f32
		for lbl in btn_labels {
			btn_width += im.CalcTextSize(lbl).x + style.FramePadding.x * 2
		}
		btn_width += style.ItemSpacing.x * 2

		im.SameLine()
		im.Dummy(im.Vec2{style.ItemSpacing.x * 8, 0})
		im.SameLine()
		avail_x := im.GetContentRegionAvail().x
		cursor_x := im.GetCursorPosX()
		filter_width := avail_x - btn_width - style.ItemSpacing.x
		im.SetNextItemWidth(filter_width)
		im.InputText("##filter", cstring(raw_data(_console_filter[:])), len(_console_filter))
		im.SameLine()
		im.SetCursorPosX(cursor_x + avail_x - btn_width)

		filter_toggle_button(ICON_MD_INFO, &_console_show_info)
		im.SameLine()
		filter_toggle_button(ICON_MD_WARNING, &_console_show_warning, im.Vec4{0.957, 0.737, 0.008, 1})
		im.SameLine()
		filter_toggle_button(ICON_MD_ERROR, &_console_show_error, im.Vec4{0.827, 0.133, 0.133, 1})

		// Zero horizontal inner padding so rows sit flush against the left border
		// (keep the default vertical padding for top/bottom breathing room).
		child_pad := im.GetStyle().WindowPadding
		child_pad.x = 0
		im.PushStyleVarImVec2(.WindowPadding, child_pad)
		im.BeginChild("ConsoleScroll", im.Vec2{0, 0}, {.Borders})
		im.PopStyleVar()

		filter_str := string(cstring(raw_data(_console_filter[:])))
		filter_terms := strings.fields(filter_str, context.temp_allocator)
		filter_terms_lower := make([]string, len(filter_terms), context.temp_allocator)
		for term, i in filter_terms {
			filter_terms_lower[i] = strings.to_lower(term, context.temp_allocator)
		}

		visible_row := 0
		for entry in log.entries {
			switch entry.level {
			case .Info:
				if !_console_show_info do continue
			case .Warning:
				if !_console_show_warning do continue
			case .Error:
				if !_console_show_error do continue
			}

			if len(filter_terms_lower) > 0 {
				msg_lower := strings.to_lower(entry.message, context.temp_allocator)
				matched := true
				for term in filter_terms_lower {
					if !strings.contains(msg_lower, term) {
						matched = false
						break
					}
				}
				if !matched do continue
			}

			// Unity-style row: a large level icon spanning both text rows in a
			// left column, then "[hh:mm:ss] message" and a dimmed source line.
			// Alternate rows are the live window bg darkened by ALT_ROW_MUL,
			// keyed off the theme so it tracks whatever background is in use.
			row_h := im.GetTextLineHeightWithSpacing() * 2
			row_start := im.GetCursorScreenPos()
			if visible_row % 2 == 1 {
				ALT_ROW_MUL :: 0.98
				bg := im.GetStyleColorVec4(.WindowBg)^
				alt := im.Vec4{bg.x * ALT_ROW_MUL, bg.y * ALT_ROW_MUL, bg.z * ALT_ROW_MUL, 1}
				p_max := im.Vec2{row_start.x + im.GetContentRegionAvail().x, row_start.y + row_h}
				im.DrawList_AddRectFilled(im.GetWindowDrawList(), row_start, p_max, im.GetColorU32ImVec4(alt))
			}

			// Icon column: left pad, visible glyph, right pad. The glyph is placed
			// by its VISIBLE box (X0/X1, Y0/Y1 are visible offsets from the cursor)
			// so the font's side-bearing doesn't skew it, and vertically centered
			// against the two text rows.
			ICON_PAD_L :: f32(10) // gap left of the icon
			ICON_PAD_R :: f32(8)  // gap between icon and text
			icon_c := strings.clone_to_cstring(_console_level_icon(entry.level), context.temp_allocator)
			im.PushFontFloat(editor_icon_font_lg, ICON_FONT_SIZE_LG) // explicit 26px base
			g := im.FontBaked_FindGlyph(im.GetFontBaked(), im.Wchar(_console_level_codepoint(entry.level)))
			icon_col_w := ICON_PAD_L + (g.X1 - g.X0) + ICON_PAD_R
			icon_pos := im.Vec2{
				row_start.x + ICON_PAD_L - g.X0,
				row_start.y + (row_h - (g.Y0 + g.Y1)) * 0.5,
			}
			im.DrawList_AddText(im.GetWindowDrawList(), icon_pos, im.GetColorU32ImVec4(_console_level_color(entry.level)), icon_c)
			im.PopFont()

			row_w := im.GetContentRegionAvail().x

			// Text column to the right of the icon.
			im.SetCursorScreenPos(im.Vec2{row_start.x + icon_col_w, row_start.y})
			im.BeginGroup()
			cmsg := fmt.ctprintf("%s  %s", _console_time_str(entry.time), entry.message)
			im.TextColored(_console_level_color(entry.level), cmsg)
			im.TextColored(im.Vec4{0.55, 0.55, 0.55, 1}, _console_loc_line(entry))
			im.EndGroup()

			// Reserve exactly row_h of vertical space (regardless of text height)
			// via a real item, so imgui grows the scroll region correctly.
			im.SetCursorScreenPos(row_start)
			im.Dummy(im.Vec2{row_w, row_h})
			visible_row += 1
		}

		n := len(log.entries)
		if n > _console_last_count && n > 0 {
			im.SetScrollHereY(1)
		}
		_console_last_count = n

		im.EndChild()
	}
	im.End()
}

// A filter toggle. When on, uses on_color (or, if that's zero, the theme's
// default button color like the Clear button); when off, dimmed grey.
filter_toggle_button :: proc(label: cstring, on: ^bool, on_color := im.Vec4{}) {
	pushed := false
	if !on^ {
		im.PushStyleColorImVec4(.Button, im.Vec4{0.2, 0.2, 0.2, 1})
		pushed = true
	} else if on_color != {} {
		im.PushStyleColorImVec4(.Button, on_color)
		pushed = true
	}
	if im.Button(label) do on^ = !on^
	if pushed do im.PopStyleColor()
}
