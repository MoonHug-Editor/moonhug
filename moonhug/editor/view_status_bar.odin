package editor

// The status bar under every view: the last log line on the left, or the
// quick help of the tool whose keymap is on top while one runs, the
// background tasks (editor/tasks) and their panel on the right. It draws every
// frame, the console window may be hidden, so it is also where the play
// pipe's log entries are published and the tasks are polled.

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"
import im "moonhug:external/odin-imgui"
import "moonhug:editor/icons"
import "moonhug:editor/keymap"
import "menu"
import "moonhug:editor/tasks"
import "moonhug:editor/widgets"
import core "moonhug:libs/core"
import "moonhug:libs/log"

// Which tools' quick help the status bar shows, for the person on this
// machine. Edited at the top of the Shortcuts section of the settings window.
Quick_Help_Settings :: struct {
	show:   bool,            // any tool's quick help, the log line stays when off
	hidden: [dynamic]string, // the names of the tool keymaps whose quick help stays hidden
}

@(system_settings={name="Quick Help"})
quick_help_settings := Quick_Help_Settings{show = true}

// Whether the status bar shows the quick help of the tool keymap `name`.
quick_help_shown :: proc(name: string) -> bool {
	return quick_help_settings.show && !slice.contains(quick_help_settings.hidden[:], name)
}

// Shows or hides the quick help of the tool keymap `name`, and saves.
quick_help_set_shown :: proc(name: string, shown: bool) {
	context.allocator = runtime.default_allocator()
	hidden := &quick_help_settings.hidden
	at, found := slice.linear_search(hidden[:], name)
	switch {
	case shown && found:
		delete(hidden[at])
		ordered_remove(hidden, at)
	case !shown && !found:
		append(hidden, strings.clone(name))
	}
	core.system_settings_save("Quick Help", &quick_help_settings, Quick_Help_Settings)
}

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

	// A tool's keymap on top of the modal stack: its keys take the log
	// line's place while it runs, unless the settings hide them. One without
	// any, the palette's, leaves it.
	if km := keymap.modal_top(); km != nil && quick_help_shown(km.name) {
		if help := keymap.quick_help(km); len(help) > 0 {
			_draw_status_bar_quick_help(km.name, help, tasks_x)
			return
		}
	}

	n := len(log.entries)
	if n == 0 do return
	last := log.entries[n - 1]
	cmsg := fmt.ctprintf("%s %s  %s", _console_level_icon(last.level), _console_time_str(last.time), last.message)
	im.PushClipRect(im.GetCursorScreenPos(), im.Vec2{im.GetWindowPos().x + tasks_x - style.ItemSpacing.x, im.GetWindowPos().y + im.GetWindowHeight()}, true)
	im.TextColored(_console_level_color(last.level), cmsg)
	im.PopClipRect()
}

// The tool's name, then each line of its quick help: the keys on a key cap,
// what they do dimmed after them. Clipped before the tasks at `right_x`,
// window-local.
@(private = "file")
_draw_status_bar_quick_help :: proc(name: string, help: []keymap.Quick_Help, right_x: f32) {
	style := im.GetStyle()
	win := im.GetWindowPos()
	im.PushClipRect(im.GetCursorScreenPos(), {win.x + right_x - style.ItemSpacing.x, win.y + im.GetWindowHeight()}, true)
	defer im.PopClipRect()
	im.TextUnformatted(strings.clone_to_cstring(name, context.temp_allocator))
	dl := im.GetWindowDrawList()
	pad := im.Vec2{style.FramePadding.x * 0.5, 1}
	for h in help {
		im.SameLine(0, style.ItemSpacing.x * 3)
		keys := strings.clone_to_cstring(h.keys, context.temp_allocator)
		size := im.CalcTextSize(keys)
		p := im.GetCursorScreenPos()
		// The button colour: the frame colour is the bar's own in some themes.
		im.DrawList_AddRectFilled(dl, p - {0, pad.y}, p + size + {pad.x * 2, pad.y}, im.GetColorU32(.Button), style.FrameRounding)
		im.DrawList_AddText(dl, p + {pad.x, 0}, im.GetColorU32(.Text), keys)
		im.Dummy(size + {pad.x * 2, 0})
		im.SameLine()
		im.TextDisabled("%s", strings.clone_to_cstring(h.text, context.temp_allocator))
	}
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
