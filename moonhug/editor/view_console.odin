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
_console_clear_on_play: bool = true
_console_filter: [256]u8
_console_selected_id: u64 // log.Entry.id of the row shown in the detail pane
_console_scroll_to_sel: bool // scroll the selected row into view next frame
_console_split_ratio: f32 = 0.72 // rows pane share of the rows/detail split

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
	// Publish app-process log entries queued by the play pipe reader. The
	// status bar draws every frame (the console window may be hidden), so
	// this is the reliable once-per-frame drain point.
	log.drain()

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
		im.SameLine()
		filter_toggle_button("Clear on Play", &_console_clear_on_play)

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
		// Resizable split between the log rows and the detail pane below (same
		// splitter pattern as the history view).
		avail := im.GetContentRegionAvail()
		splitter_h: f32 = 4
		scroll_h := (avail.y - splitter_h) * _console_split_ratio
		MIN_PANE :: f32(60)
		if scroll_h < MIN_PANE do scroll_h = MIN_PANE
		if scroll_h > avail.y - splitter_h - MIN_PANE do scroll_h = avail.y - splitter_h - MIN_PANE
		im.BeginChild("ConsoleScroll", im.Vec2{0, scroll_h}, {.Borders})
		im.PopStyleVar()

		filter_str := string(cstring(raw_data(_console_filter[:])))
		filter_terms := strings.fields(filter_str, context.temp_allocator)
		filter_terms_lower := make([]string, len(filter_terms), context.temp_allocator)
		for term, i in filter_terms {
			filter_terms_lower[i] = strings.to_lower(term, context.temp_allocator)
		}

		// Ids of rows drawn this frame, in draw order — the up/down keys walk
		// this list so navigation follows the active level/text filters.
		visible_ids := make([dynamic]u64, 0, len(log.entries), context.temp_allocator)

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
			is_row_selected := entry.id == _console_selected_id
			if is_row_selected {
				sel := im.GetStyleColorVec4(.Header)^
				p_max := im.Vec2{row_start.x + im.GetContentRegionAvail().x, row_start.y + row_h}
				im.DrawList_AddRectFilled(im.GetWindowDrawList(), row_start, p_max, im.GetColorU32ImVec4(sel))
			} else if visible_row % 2 == 1 {
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
			// via a real item — an invisible button, so the whole row is also the
			// click target selecting the entry for the detail pane.
			im.SetCursorScreenPos(row_start)
			if im.InvisibleButton(fmt.ctprintf("##crow_%d", entry.id), im.Vec2{max(row_w, 1), row_h}) {
				_console_selected_id = entry.id
			}
			if is_row_selected && _console_scroll_to_sel {
				im.SetScrollHereY()
				_console_scroll_to_sel = false
			}
			append(&visible_ids, entry.id)
			visible_row += 1
		}

		sel_visible := false
		for id in visible_ids {
			if id == _console_selected_id {
				sel_visible = true
				break
			}
		}

		// Follow new entries only while nothing is selected — otherwise the
		// auto-scroll fights keyboard navigation. Esc deselects to resume.
		n := len(log.entries)
		if n > _console_last_count && n > 0 && !sel_visible {
			im.SetScrollHereY(1)
		}
		_console_last_count = n

		im.EndChild()

		// Draggable splitter between rows and detail.
		splitter_pos := im.GetCursorScreenPos()
		im.InvisibleButton("##console_split", im.Vec2{-1, splitter_h})
		if im.IsItemActive() {
			delta := im.GetIO().MouseDelta.y
			total := avail.y - splitter_h
			_console_split_ratio = clamp((scroll_h + delta) / total, MIN_PANE / total, (total - MIN_PANE) / total)
		}
		if im.IsItemHovered() || im.IsItemActive() {
			im.SetMouseCursor(.ResizeNS)
		}
		dl := im.GetWindowDrawList()
		split_col := im.IsItemActive() ? im.GetColorU32ImVec4(im.Vec4{0.8, 0.8, 0.8, 0.9}) : im.GetColorU32ImVec4(im.Vec4{0.5, 0.5, 0.5, 0.5})
		im.DrawList_AddLine(dl, splitter_pos, im.Vec2{splitter_pos.x + avail.x, splitter_pos.y}, split_col, 1)

		// Up/Down select the previous/next visible row (nothing selected: both
		// start at the newest). Not while a text input owns the keyboard.
		if im.IsWindowFocused(im.FocusedFlags_RootAndChildWindows) && !im.IsAnyItemActive() && len(visible_ids) > 0 {
			if im.IsKeyPressed(im.Key.Escape) {
				_console_selected_id = 0
			}
			cur := -1
			for id, i in visible_ids {
				if id == _console_selected_id {
					cur = i
					break
				}
			}
			if im.IsKeyPressed(im.Key.DownArrow) {
				if cur == -1 {
					_console_selected_id = visible_ids[len(visible_ids) - 1]
				} else if cur + 1 < len(visible_ids) {
					_console_selected_id = visible_ids[cur + 1]
				}
				_console_scroll_to_sel = true
			}
			if im.IsKeyPressed(im.Key.UpArrow) {
				if cur == -1 {
					_console_selected_id = visible_ids[len(visible_ids) - 1]
				} else if cur - 1 >= 0 {
					_console_selected_id = visible_ids[cur - 1]
				}
				_console_scroll_to_sel = true
			}
		}

		// Bottom detail pane: full message + source + call stack of the
		// selected entry.
		im.BeginChild("ConsoleDetail", im.Vec2{0, 0}, {.Borders})
		_draw_console_detail()
		im.EndChild()
	}
	im.End()
}

_draw_console_detail :: proc() {
	sel: ^log.Entry
	for &e in log.entries {
		if e.id == _console_selected_id {
			sel = &e
			break
		}
	}
	if sel == nil {
		im.TextDisabled("Select a log entry to see details")
		return
	}

	// Plain im.Text can't be mouse-selected — render the details as a
	// read-only, frameless multiline input instead so they're copyable.
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, fmt.tprintf("%s  %s\n", _console_time_str(sel.time), sel.message))
	strings.write_string(&b, fmt.tprintf("%s\n\n", string(_console_loc_line(sel^))))
	if len(sel.stack) > 0 {
		for line in sel.stack {
			strings.write_string(&b, line)
			strings.write_byte(&b, '\n')
		}
	} else if sel.owns_loc {
		strings.write_string(&b, "Call stack: available in debug app builds only (run app with -debug).")
	} else if !ODIN_DEBUG {
		strings.write_string(&b, "Call stack: available in debug editor builds only (build with -debug).")
	} else {
		strings.write_string(&b, "No call stack captured.")
	}
	text := strings.to_string(b)
	buf := strings.clone_to_cstring(text, context.temp_allocator)

	im.PushStyleColorImVec4(.FrameBg, im.Vec4{0, 0, 0, 0})
	im.PushStyleColorImVec4(.Text, _console_level_color(sel.level))
	im.InputTextMultiline("##console_detail_text", buf, uint(len(text) + 1), im.Vec2{-1, -1}, {.ReadOnly, .WordWrap})
	im.PopStyleColor(2)
}

// A filter toggle. On: highlighted with on_color (or the theme's active-button
// color when none given). Off: the theme's NORMAL button with a dimmed label —
// a near-black button reads as disabled/broken rather than toggled off.
filter_toggle_button :: proc(label: cstring, on: ^bool, on_color := im.Vec4{}) {
	if on^ {
		col := on_color
		if col == {} {
			col = im.GetStyleColorVec4(im.Col.ButtonActive)^
		}
		im.PushStyleColorImVec4(.Button, col)
	} else {
		txt := im.GetStyleColorVec4(im.Col.Text)^
		im.PushStyleColorImVec4(.Text, im.Vec4{txt.x * 0.5, txt.y * 0.5, txt.z * 0.5, txt.w})
	}
	if im.Button(label) do on^ = !on^
	im.PopStyleColor()
}
