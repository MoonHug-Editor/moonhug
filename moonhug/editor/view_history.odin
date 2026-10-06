package editor

import "core:fmt"
import "core:strings"
import im "moonhug:external/odin-imgui"
import "menu"
import "undo"
import "moonhug:editor/widgets"
import "moonhug:editor/icons"

@(private="file")
_history_selected: int = -1

@(private="file")
_history_last_count: int

@(private="file")
_history_split_ratio: f32 = 0.6

draw_history_view :: proc() {
	if !im.Begin(icons.TITLE_HISTORY, &menu.show_history, {.NoCollapse}) {
		im.End()
		return
	}
	defer im.End()

	s := undo.get()
	if s == nil {
		im.TextDisabled("Undo stack unavailable")
		return
	}

	if im.Button("Undo") {
		undo.apply_undo(s)
	}
	im.SameLine()
	if im.Button("Redo") {
		undo.apply_redo(s)
	}
	im.SameLine()
	if im.Button("Clear") {
		undo.clear(s)
		_history_selected = -1
	}

	items := undo.entries(s)
	top := undo.top_index(s)

	im.SameLine()
	im.Text("top=%d  entries=%d", i32(top), i32(len(items)))

	avail := im.GetContentRegionAvail()
	split_total := avail.y - widgets.SPLITTER_SIZE
	MIN_PANE :: f32(60)
	list_h := split_total * _history_split_ratio
	if list_h < MIN_PANE do list_h = MIN_PANE
	if list_h > split_total - MIN_PANE do list_h = split_total - MIN_PANE
	details_h := split_total - list_h

	im.BeginChild("HistoryList", im.Vec2{0, list_h}, {.Borders})
	{
		max_index := len(items)

		if im.IsWindowFocused() {
			if im.IsKeyPressed(.UpArrow) {
				if _history_selected > 0 do _history_selected -= 1
				im.SetScrollHereY(0)
			}
			if im.IsKeyPressed(.DownArrow) {
				if _history_selected < max_index do _history_selected += 1
				im.SetScrollHereY(1)
			}
			if im.IsKeyPressed(.Enter) {
				undo.jump_to(s, _history_selected)
			}
		}

		if im.Selectable("<initial>", _history_selected == 0, {.SpanAllColumns}) {
			_history_selected = 0
		}
		if im.IsItemHovered() && im.IsMouseDoubleClicked(.Left) {
			undo.jump_to(s, 0)
		}

		for entry, i in items {
			step_index := i + 1
			status: string
			// While playing, steps from before Play don't move (undo.play_begin).
			locked := s.playing && !entry.in_play
			if locked {
				status = "before Play"
			} else if step_index <= top {
				status = "done"
			} else {
				status = "redo"
			}
			is_current := step_index == top
			label := entry.label
			if label == "" do label = "(unlabeled)"
			row := fmt.tprintf("%s %2d. %s  [%s]", is_current ? ">" : " ", step_index, label, status)
			crow := strings.clone_to_cstring(row, context.temp_allocator)

			text_col := im.GetStyleColorVec4(.Text)^
			if is_current {
				text_col = im.Vec4{0.9, 0.8, 0.3, 1}
			} else if step_index > top || locked {
				text_col = im.GetStyleColorVec4(.TextDisabled)^
			}
			im.PushStyleColorImVec4(.Text, text_col)

			if im.Selectable(crow, _history_selected == step_index, {.SpanAllColumns}) {
				_history_selected = step_index
			}
			im.PopStyleColor()

			if im.IsItemHovered() && im.IsMouseDoubleClicked(.Left) {
				undo.jump_to(s, step_index)
			}
		}

		if len(items) > _history_last_count {
			im.SetScrollHereY(1)
		}
		_history_last_count = len(items)
	}
	im.EndChild()

	if widgets.splitter("##hsplit", false, &list_h, &details_h, MIN_PANE, MIN_PANE) {
		_history_split_ratio = list_h / split_total
	}

	im.BeginChild("HistoryDetails", im.Vec2{0, 0}, {.Borders})
	defer im.EndChild()

	if _history_selected < 0 {
		im.TextDisabled("Select an entry to see details")
		return
	}
	if _history_selected == 0 {
		im.Text("Initial state")
		im.TextDisabled("Double-click any row to jump to that step.")
		return
	}
	if _history_selected > len(items) {
		_history_selected = -1
		return
	}

	entry := items[_history_selected - 1]
	_draw_history_entry_details(&entry)
}

@(private="file")
// The details pane, as ONE read-only text field so it can be selected and
// copied — the same treatment the console's detail pane gets, and for the same
// reason: these are values you want to paste into a bug report or diff against
// what you expected.
_draw_history_entry_details :: proc(entry: ^undo.Entry) {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "Label: %s\n", entry.label)
	undo.describe(&entry.cmd, &b, 0)

	text := strings.to_string(b)
	buf := strings.clone_to_cstring(text, context.temp_allocator)
	im.InputTextMultiline("##history_detail_text", buf, uint(len(text) + 1),
		im.Vec2{-1, -1}, {.ReadOnly, .WordWrap})
}

@(private="file")
cstr :: proc(s: string) -> cstring {
	return strings.clone_to_cstring(s, context.temp_allocator)
}
