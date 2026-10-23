package editor

// The Background Tasks window: every running task (editor/tasks) with what
// it does, how far it is and its own Cancel. Window ▸ General ▸ Background
// Tasks opens it, and so does a click on the task in the status bar.

import "core:fmt"
import im "moonhug:external/odin-imgui"
import "menu"
import "moonhug:editor/icons"
import "moonhug:editor/tasks"

draw_background_tasks_view :: proc() {
	defer im.End()
	if !im.Begin(icons.TITLE_BACKGROUND_TASKS, &menu.show_background_tasks, {.NoCollapse}) do return

	running := tasks.collect()
	if len(running) == 0 {
		im.TextDisabled("No background tasks")
		return
	}
	style := im.GetStyle()
	for t, i in running {
		im.PushIDInt(i32(i))
		defer im.PopID()
		im.TextUnformatted(fmt.ctprintf("%s", t.title))
		im.TextDisabled("%s", fmt.ctprintf("%s", t.detail))
		button_w := im.CalcTextSize("Cancel").x + style.FramePadding.x * 2 if t.cancel != nil else 0
		fraction := t.fraction if t.fraction >= 0 else -1 * f32(im.GetTime())
		im.ProgressBar(fraction, im.Vec2{im.GetContentRegionAvail().x - button_w - (style.ItemSpacing.x if t.cancel != nil else 0), 0}, "" if t.fraction < 0 else nil)
		if t.cancel != nil {
			im.SameLine()
			if im.Button("Cancel") do t.cancel(t.data)
		}
		im.Separator()
	}
}
