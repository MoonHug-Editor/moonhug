package editor

// Input Debug window (Help/Input Debug) — for diagnosing the "keyboard dies
// until restart" bug. Everything here is drawable with the mouse alone. When
// keys stop working: open this, press keys, and read which layer went dark:
//
//   1. SDL counters not increasing  → the OS/SDL stopped delivering key
//      events to the window (app focus / key-window problem).
//   2. Counters increase but probes stay false → imgui io state stuck
//      (AppFocusLost, stuck modifier, backend event handling).
//   3. Probes work but views don't react → an editor-side gate is stuck
//      (rename state machines, window focus gating) — shown below.

import "core:fmt"
import "core:strings"
import im "moonhug:external/odin-imgui"
import gfx "../engine/gfx"
import input "../engine/input"
import "menu"

@(private="file")
_dbg_text :: proc(format: string, args: ..any) {
	im.Text(strings.clone_to_cstring(fmt.tprintf(format, ..args), context.temp_allocator))
}

draw_input_debug :: proc() {
	if !im.Begin("Input Debug", &menu.show_input_debug, {}) {
		im.End()
		return
	}
	defer im.End()

	im.SeparatorText("frame timing")
	io_fps := im.GetIO()
	_dbg_text("fps: %.1f   frame: %.2f ms", io_fps.Framerate, 1000.0 / max(io_fps.Framerate, 0.001))

	im.SeparatorText("SDL layer (before imgui)")
	kd, ku, fg, fl := input.debug_counters()
	_dbg_text("key events: %d down / %d up  (press keys — must increase)", kd, ku)
	_dbg_text("window focused: %v  (gained %d / lost %d)", input.focused(), fg, fl)

	im.SeparatorText("imgui io")
	io := im.GetIO()
	_dbg_text("WantCaptureKeyboard: %v   WantTextInput: %v", io.WantCaptureKeyboard, io.WantTextInput)
	_dbg_text("NavActive: %v   AppFocusLost: %v", io.NavActive, io.AppFocusLost)
	_dbg_text("mods: ctrl=%v shift=%v alt=%v super=%v (stuck true = lost KEY_UP)",
		io.KeyCtrl, io.KeyShift, io.KeyAlt, io.KeySuper)
	_dbg_text("live probes: W=%v A=%v S=%v D=%v space=%v",
		im.IsKeyDown(.W), im.IsKeyDown(.A), im.IsKeyDown(.S), im.IsKeyDown(.D), im.IsKeyDown(.Space))

	im.SeparatorText("editor gates")
	_dbg_text("any item active: %v (stuck true blocks every view's key handling)", im.IsAnyItemActive())
	_dbg_text("hierarchy rename active: %v", _hierarchy_rename_target != _HANDLE_NONE)
	_dbg_text("project rename active: %v", _project_rename_active)
	_dbg_text("scene view hovered: %v", scene_view_hovered)

	im.Separator()
	if im.Button("Reset editor input gates") {
		// Mouse-only rescue: clear every editor-side state machine that can
		// gate keyboard handling. If this revives the keyboard, the culprit
		// was one of the gates above; if not, the problem is SDL/imgui-side.
		_hierarchy_rename_target = _HANDLE_NONE
		_project_rename_active = false
		_project_rename_just_finished = false
		_hierarchy_rename_just_finished = false
	}
}
