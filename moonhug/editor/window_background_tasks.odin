package editor

// The Background Tasks panel: every running task (editor/tasks) with what it
// does, how far it is and its own Cancel. It is a popup over the status bar,
// opening upward from the tasks button with its right edge on the button's.
// The button shows and hides it, a click elsewhere hides it, and Window ▸
// General ▸ Background Tasks shows it.

import "core:fmt"
import im "moonhug:external/odin-imgui"
import "moonhug:editor/tasks"

BACKGROUND_TASKS_PANEL_WIDTH :: f32(380)
BACKGROUND_TASKS_PANEL_MAX_HEIGHT :: f32(420)

@(private = "file")
_PANEL_ID :: "##background_tasks_panel"

// Shows the panel. Call inside the status bar window, where the panel is drawn.
background_tasks_panel_open :: proc() {
	im.OpenPopup(_PANEL_ID)
}

// The panel, when shown, with its bottom right corner at `anchor`. Call inside
// the status bar window, after the tasks button.
draw_background_tasks_panel :: proc(anchor: im.Vec2) {
	im.SetNextWindowPos(anchor, .Always, {1, 1})
	im.SetNextWindowSizeConstraints({BACKGROUND_TASKS_PANEL_WIDTH, 0}, {BACKGROUND_TASKS_PANEL_WIDTH, BACKGROUND_TASKS_PANEL_MAX_HEIGHT})
	if !im.BeginPopup(_PANEL_ID) do return
	defer im.EndPopup()

	im.SeparatorText("Background Tasks")
	running := tasks.collect()
	if len(running) == 0 {
		im.TextDisabled("No background tasks")
		return
	}
	style := im.GetStyle()
	for t, i in running {
		im.PushIDInt(i32(i))
		defer im.PopID()
		if i > 0 do im.Separator()
		im.TextUnformatted(fmt.ctprintf("%s", t.title))
		im.TextDisabled("%s", fmt.ctprintf("%s", t.detail))
		button_w := im.CalcTextSize("Cancel").x + style.FramePadding.x * 2 if t.cancel != nil else 0
		fraction := t.fraction if t.fraction >= 0 else -1 * f32(im.GetTime())
		im.ProgressBar(fraction, im.Vec2{im.GetContentRegionAvail().x - button_w - (style.ItemSpacing.x if t.cancel != nil else 0), 0}, "" if t.fraction < 0 else nil)
		if t.cancel != nil {
			im.SameLine()
			if im.Button("Cancel") do t.cancel(t.data)
		}
	}
}
