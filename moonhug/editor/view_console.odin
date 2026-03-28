package editor

import "core:strings"
import im "../../external/odin-imgui"
import "../engine/log"

_console_last_count: int
_console_show_info:    bool = true
_console_show_warning: bool = true
_console_show_error:   bool = true
_console_filter: [256]u8

@(private="file")
label_info :: "i"

@(private="file")
label_warning :: "w"

@(private="file")
label_error :: "e"

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
	cmsg := strings.clone_to_cstring(last.message, context.temp_allocator)

	switch last.level {
	case .Info:
		im.Text(cmsg)
	case .Warning:
		im.TextColored(im.Vec4{0.6, 0.6, 0.1, 1}, cmsg)
	case .Error:
		im.TextColored(im.Vec4{1, 0.3, 0.3, 1}, cmsg)
	}
}

draw_console_view :: proc() {
	if im.Begin("Console", nil, {.NoCollapse}) {
		if im.Button("Clear") {
			log.clear()
			_console_last_count = 0
		}

		style := im.GetStyle()
		btn_labels := [3]cstring{label_info, label_warning, label_error}
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

		im.PushStyleColorImVec4(.Button, im.Vec4{0.4, 0.4, 0.4, 1} if _console_show_info else im.Vec4{0.2, 0.2, 0.2, 1})
		if im.Button(label_info) do _console_show_info = !_console_show_info
		im.PopStyleColor()

		im.SameLine()
		im.PushStyleColorImVec4(.Button, im.Vec4{0.6, 0.6, 0.1, 1} if _console_show_warning else im.Vec4{0.2, 0.2, 0.2, 1})
		if im.Button(label_warning) do _console_show_warning = !_console_show_warning
		im.PopStyleColor()

		im.SameLine()
		im.PushStyleColorImVec4(.Button, im.Vec4{0.7, 0.2, 0.2, 1} if _console_show_error else im.Vec4{0.2, 0.2, 0.2, 1})
		if im.Button(label_error) do _console_show_error = !_console_show_error
		im.PopStyleColor()

		im.Separator()
		im.BeginChild("ConsoleScroll", im.Vec2{0, 0}, {.Borders})

		filter_str := string(cstring(raw_data(_console_filter[:])))
		filter_terms := strings.fields(filter_str, context.temp_allocator)
		filter_terms_lower := make([]string, len(filter_terms), context.temp_allocator)
		for term, i in filter_terms {
			filter_terms_lower[i] = strings.to_lower(term, context.temp_allocator)
		}

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

			cmsg := strings.clone_to_cstring(entry.message)
			defer delete(cmsg)

			switch entry.level {
			case .Info:
				im.Text(cmsg)
			case .Warning:
				im.TextColored(im.Vec4{0.6, 0.6, 0.1, 1}, cmsg)
			case .Error:
				im.TextColored(im.Vec4{1, 0.3, 0.3, 1}, cmsg)
			}
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
