package editor

// The status bar under every view: the last log line on the left, the
// background tasks (editor/tasks) and their panel on the right. It draws every
// frame, the console window may be hidden, so it is also where the play
// pipe's log entries are published and the tasks are polled.

import "core:fmt"
import im "moonhug:external/odin-imgui"
import "moonhug:editor/icons"
import "menu"
import "moonhug:editor/tasks"
import "moonhug:editor/widgets"
import "moonhug:libs/log"

draw_status_bar :: proc() {
	// Publish app-process log entries queued by the play pipe reader.
	log.drain()

	style := im.GetStyle()
	height := im.GetFrameHeight() + style.WindowPadding.y
	if !im.BeginViewportSideBar("##StatusBar", im.GetMainViewport(), .Down, height, {.NoScrollbar, .NoSavedSettings, .NoScrollWithMouse}) {
		im.End()
		return
	}
	defer im.End()

	tasks_x := _draw_status_bar_tasks()

	n := len(log.entries)
	if n == 0 do return
	last := log.entries[n - 1]
	cmsg := fmt.ctprintf("%s %s  %s", _console_level_icon(last.level), _console_time_str(last.time), last.message)
	im.PushClipRect(im.GetCursorScreenPos(), im.Vec2{im.GetWindowPos().x + tasks_x - style.ItemSpacing.x, im.GetWindowPos().y + im.GetWindowHeight()}, true)
	im.TextColored(_console_level_color(last.level), cmsg)
	im.PopClipRect()
}

// Right-aligned: while a task runs, the first one (an indeterminate or
// filled bar, its title and detail, and a cancel button when it can be
// cancelled), then the tasks button, always there at the bar's right end,
// which shows and hides the Background Tasks panel above it. A click on the
// bar or the text shows the panel too. Returns the window-local x where the
// tasks start, the right end of the log line's room, and leaves the cursor at
// the row's start.
@(private = "file")
_draw_status_bar_tasks :: proc() -> f32 {
	style := im.GetStyle()
	running := tasks.collect()
	right := im.GetCursorPosX() + im.GetContentRegionAvail().x
	row_y := im.GetCursorPosY()

	label: cstring
	bar_w := f32(90)
	cancel_w := im.GetFrameHeight()
	width := im.CalcTextSize(icons.ICON_MD_HOURGLASS_EMPTY).x + style.FramePadding.x * 2
	if len(running) > 0 {
		t := running[0]
		label = fmt.ctprintf("%s: %s", t.title, t.detail)
		if len(running) > 1 do label = fmt.ctprintf("%s: %s  (+%d more)", t.title, t.detail, len(running) - 1)
		width += bar_w + style.ItemSpacing.x + im.CalcTextSize(label).x + style.ItemSpacing.x + (cancel_w + style.ItemSpacing.x if t.cancel != nil else 0)
	}
	x := max(im.GetCursorPosX(), right - width)
	im.SetCursorPos(im.Vec2{x, row_y})

	if len(running) > 0 {
		t := running[0]
		im.SetCursorPosY(row_y + (im.GetFrameHeight() - im.GetTextLineHeight()) * 0.5)
		fraction := t.fraction if t.fraction >= 0 else -1 * f32(im.GetTime())
		im.ProgressBar(fraction, im.Vec2{bar_w, im.GetTextLineHeight()}, "")
		if im.IsItemClicked() do background_tasks_panel_open()
		widgets.tooltip("Show every background task")
		im.SameLine()
		im.TextUnformatted(label)
		if im.IsItemClicked() do background_tasks_panel_open()
		widgets.tooltip("Show every background task")
		if t.cancel != nil {
			im.SameLine()
			im.SetCursorPosY(row_y)
			if im.SmallButton(icons.ICON_MD_CLOSE + "##cancel_task") do t.cancel(t.data)
			widgets.tooltip("Cancel")
		}
		im.SameLine()
	}
	im.SetCursorPosY(row_y)
	if im.SmallButton(icons.ICON_MD_HOURGLASS_EMPTY + "##background_tasks") do background_tasks_panel_open()
	anchor := im.Vec2{im.GetItemRectMax().x, im.GetWindowPos().y}
	widgets.tooltip("Background Tasks")
	if menu.background_tasks_requested {
		menu.background_tasks_requested = false
		background_tasks_panel_open()
	}
	draw_background_tasks_panel(anchor)

	im.SetCursorPos(im.Vec2{style.WindowPadding.x, row_y})
	return x
}
