package editor

// Floating windows: a view dragged outside the main window gets its own OS
// window (Dear ImGui multi-viewports, `io.ConfigFlags` .ViewportsEnable, set
// in main.odin). The SDL3 platform backend creates, moves and closes those
// windows and routes their input, and the SDLGPU3 renderer backend draws and
// presents each one with its own command buffer. A view dragged back over the
// main window merges into it again.
//
// The Odin binding does not declare the two calls that drive the windows each
// frame, so they are declared here against the same library.
//
// Each floating window draws through _render_floating_window instead of the
// backend's own handler. The backend takes the window's swapchain image with
// SDL_AcquireGPUSwapchainTexture, which never waits and skips the frame when
// SDL answers that the image is still in flight. SDL 3.4.14's Metal backend
// answers that question inverted (gfx.odin, fence_query_inverted), so after
// the first frame every frame is skipped and the window keeps its first image.
// The replacement waits for the image, as gfx does for the main window.

import "base:runtime"
import sdl "vendor:sdl3"
import im "moonhug:external/odin-imgui"
import im_sdlgpu "moonhug:external/odin-imgui/imgui_impl_sdlgpu3"
import gfx "moonhug:libs/gfx"

when ODIN_OS == .Windows {
	foreign import _imgui_viewports_lib {"../external/odin-imgui/" + im.IMGUI_LIB_NAME}
} else {
	foreign import _imgui_viewports_lib {"../external/odin-imgui/" + im.IMGUI_LIB_NAME, "system:c++"}
}

@(default_calling_convention = "c")
foreign _imgui_viewports_lib {
	@(link_name = "ImGui_UpdatePlatformWindows")
	_imgui_update_platform_windows :: proc() ---
	@(link_name = "ImGui_RenderPlatformWindowsDefault")
	_imgui_render_platform_windows_default :: proc(platform_render_arg, renderer_render_arg: rawptr) ---
}

// Installs the floating windows' draw handler. Call after the SDLGPU3 backend
// is initialized, which installs its own.
imgui_viewports_init :: proc() {
	if .ViewportsEnable not_in im.GetIO().ConfigFlags do return
	im.GetPlatformIO().Renderer_RenderWindow = _render_floating_window
}

// Draws one floating window's frame into its swapchain image, waiting for the
// image, and submits it.
@(private = "file")
_render_floating_window :: proc "c" (vp: ^im.Viewport, render_arg: rawptr) {
	context = runtime.default_context()
	window := sdl.GetWindowFromID(sdl.WindowID(uintptr(vp.PlatformHandle)))
	cmd := sdl.AcquireGPUCommandBuffer(gfx.device())
	if cmd == nil do return
	image: ^sdl.GPUTexture
	if sdl.WaitAndAcquireGPUSwapchainTexture(cmd, window, &image, nil, nil) && image != nil {
		im_sdlgpu.PrepareDrawData(vp.DrawData_, cmd)
		target := sdl.GPUColorTargetInfo{texture = image, clear_color = {0, 0, 0, 1}, load_op = .CLEAR, store_op = .STORE}
		pass := sdl.BeginGPURenderPass(cmd, &target, 1, nil)
		im_sdlgpu.RenderDrawData(vp.DrawData_, cmd, pass)
		sdl.EndGPURenderPass(pass)
	}
	_ = sdl.SubmitGPUCommandBuffer(cmd)
}

// Creates, moves, resizes and closes the OS windows of floating views, then
// draws and presents them. Called after every imgui frame is rendered and the
// main window presented: imgui asserts on the next frame when a frame skips it.
// The scene and game views' images, drawn into the main window's command
// buffer, are finished by then, since one GPU queue runs submissions in order.
imgui_platform_windows :: proc() {
	if .ViewportsEnable not_in im.GetIO().ConfigFlags do return
	_imgui_update_platform_windows()
	_imgui_render_platform_windows_default(nil, nil)
}
