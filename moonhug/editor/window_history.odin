package editor

import "core:fmt"
import "core:strings"
import im "moonhug:external/odin-imgui"
import "undo"
import "moonhug:editor/widgets"
import wnd "moonhug:editor/window"
import "moonhug:editor/keymap"

// One History copy's own state.
@(private = "file")
_History_Window :: struct {
	selected:      int `json:"-"`, // the entry shown in the details pane: 0 the initial state, -1 none
	last_count:    int `json:"-"`, // entries last frame: more means a new step to scroll to
	split_ratio:   f32, // the list's share of the list/details split
	scroll_to_sel: bool `json:"-"`, // scroll the selected row into view next frame
}

@(private = "file")
_hv: ^_History_Window

@(editor_window={id="History", title="History", icon="HISTORY"})
history_window_draw :: proc(w: ^wnd.Window) {
	_hv = wnd.state(w, _History_Window{selected = -1, split_ratio = 0.6}, saved = true)
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
		_hv.selected = -1
	}

	items := undo.entries(s)
	top := undo.top_index(s)

	im.SameLine()
	im.Text("top=%d  entries=%d", i32(top), i32(len(items)))

	avail := im.GetContentRegionAvail()
	split_total := avail.y - widgets.SPLITTER_SIZE
	MIN_PANE :: f32(60)
	list_h := split_total * _hv.split_ratio
	if list_h < MIN_PANE do list_h = MIN_PANE
	if list_h > split_total - MIN_PANE do list_h = split_total - MIN_PANE
	details_h := split_total - list_h

	im.BeginChild("HistoryList", im.Vec2{0, list_h}, {.Borders})
	{
		// The keys are the "History" keymap's commands (the end of this file).

		if im.Selectable("<initial>", _hv.selected == 0, {.SpanAllColumns}) {
			_hv.selected = 0
		}
		if _hv.selected == 0 && _hv.scroll_to_sel {
			im.SetScrollHereY()
			_hv.scroll_to_sel = false
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

			if im.Selectable(crow, _hv.selected == step_index, {.SpanAllColumns}) {
				_hv.selected = step_index
			}
			im.PopStyleColor()
			if _hv.selected == step_index && _hv.scroll_to_sel {
				im.SetScrollHereY()
				_hv.scroll_to_sel = false
			}

			if im.IsItemHovered() && im.IsMouseDoubleClicked(.Left) {
				undo.jump_to(s, step_index)
			}
		}

		if len(items) > _hv.last_count {
			im.SetScrollHereY(1)
		}
		_hv.last_count = len(items)
	}
	im.EndChild()

	if widgets.splitter("##hsplit", false, &list_h, &details_h, MIN_PANE, MIN_PANE) {
		_hv.split_ratio = list_h / split_total
	}

	im.BeginChild("HistoryDetails", im.Vec2{0, 0}, {.Borders})
	defer im.EndChild()

	if _hv.selected < 0 {
		im.TextDisabled("Select an entry to see details")
		return
	}
	if _hv.selected == 0 {
		im.Text("Initial state")
		im.TextDisabled("Double-click any row to jump to that step.")
		return
	}
	if _hv.selected > len(items) {
		_hv.selected = -1
		return
	}

	entry := items[_hv.selected - 1]
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

// --- Commands and keymap -------------------------------------------------------
//
// The keymap resolver runs these before the windows draw (editor/keymap). They
// act on the last clicked History copy, which is the focused one while its
// keymap resolves.

// The last clicked copy's state, nil before its first draw.
@(private = "file")
_history_keys_window :: proc() -> ^_History_Window {
	w := wnd.last("History")
	if w == nil do return nil
	return (^_History_Window)(w.data)
}

// Up and Down select the previous or next step. Row 0 is the initial state.
@(private = "file")
_history_nav_step :: proc(step: int) {
	hv := _history_keys_window()
	s := undo.get()
	if hv == nil || s == nil do return
	hv.selected = clamp(hv.selected + step, 0, len(undo.entries(s)))
	hv.scroll_to_sel = true
}

@(command={name="History/Select Down", palette=false, help="Selects the next undo step"})
history_select_down :: proc() { _history_nav_step(1) }

@(command={name="History/Select Up", palette=false, help="Selects the previous undo step"})
history_select_up :: proc() { _history_nav_step(-1) }

@(command={name="History/Jump To Selected", enabled=history_can_jump, help="Undoes or redoes up to the selected step"})
history_jump_to_selected :: proc() { undo.jump_to(undo.get(), _history_keys_window().selected) }

history_can_jump :: proc() -> bool {
	hv := _history_keys_window()
	if hv == nil do return keymap.disabled("The History window is not open")
	if hv.selected < 0 do return keymap.disabled("No step is selected")
	if undo.get() == nil do return keymap.disabled("There is no undo history")
	return true
}

@(keymap={name="History", window="History"})
history_keymap :: proc(km: ^keymap.Keymap) {
	keymap.bind(km, "Down", "History/Select Down", repeat = true)
	keymap.bind(km, "Up", "History/Select Up", repeat = true)
	keymap.bind(km, "Enter", "History/Jump To Selected")
}
