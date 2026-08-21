package editor

// The editor's progress sink: draws a pumped frame per report while
// blocking work runs on the main thread (startup init, import passes).
// Installed after imgui init and before EditorInit fires, so the window
// shows progress instead of a black square.
//
// Each pump is a complete minimal frame through the SAME begin/end path as
// the main loop — swapchain state stays consistent. Throttled so per-item
// reports cost nothing.

import "core:time"
import sdl "vendor:sdl3"
import gfx "../engine/gfx"
import im "moonhug:external/odin-imgui"
import im_sdl "moonhug:external/odin-imgui/imgui_impl_sdl3"
import im_sdlgpu "moonhug:external/odin-imgui/imgui_impl_sdlgpu3"
import "../engine"
import "core:fmt"

@(private = "file")
_progress_last_pump: time.Tick

// True while the main loop has a frame in flight — a report from inside a
// frame must NOT pump (nested frame_begin corrupts the swapchain). The
// work still runs, only the redraw is skipped.
@(private = "file")
_in_main_frame: bool

progress_overlay_install :: proc() {
	engine.progress_set_sink(_progress_pump)
}

progress_overlay_frame_scope :: proc(active: bool) {
	_in_main_frame = active
}

@(private = "file")
_progress_pump :: proc(title, info: string, fraction: f32) {
	if _in_main_frame do return
	now := time.tick_now()
	if time.tick_diff(_progress_last_pump, now) < 33 * time.Millisecond do return
	_progress_last_pump = now

	// Keep the OS responsive (no beachball) — the backend consumes the
	// events, input snapshots resume with the real loop.
	gfx.poll_events(proc(e: ^sdl.Event) { im_sdl.ProcessEvent(e) })

	if !gfx.frame_begin() do return
	im_sdlgpu.NewFrame()
	im_sdl.NewFrame()
	im.NewFrame()

	vp := im.GetMainViewport()
	im.SetNextWindowPos(
		im.Vec2{vp.Pos.x + vp.Size.x * 0.5, vp.Pos.y + vp.Size.y * 0.5},
		.Always, im.Vec2{0.5, 0.5},
	)
	im.SetNextWindowSize(im.Vec2{420, 0}, .Always)
	if im.Begin("##progress_overlay", nil,
		{.NoTitleBar, .NoResize, .NoMove, .NoCollapse, .NoSavedSettings, .NoDocking}) {
		im.TextUnformatted(fmt.ctprintf("%s", title))
		if fraction >= 0 {
			im.ProgressBar(clamp(fraction, 0, 1), im.Vec2{-1, 0})
		} else {
			// Indeterminate: imgui's moving-bar idiom for unknown totals.
			im.ProgressBar(-1 * f32(im.GetTime()), im.Vec2{-1, 0}, "")
		}
		im.TextDisabled("%s", fmt.ctprintf("%s", info))
	}
	im.End()

	im.Render()
	dd := im.GetDrawData()
	im_sdlgpu.PrepareDrawData(dd, gfx.command_buffer())
	if gfx.pass_begin_swapchain([4]f32{0.96, 0.96, 0.96, 1}, depth = false) {
		gfx.pass_end(proc(cmd: ^sdl.GPUCommandBuffer, rp: ^sdl.GPURenderPass) {
			im_sdlgpu.RenderDrawData(im.GetDrawData(), cmd, rp)
		})
	}
	gfx.frame_end()
}
