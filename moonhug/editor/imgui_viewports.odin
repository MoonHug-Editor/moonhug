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

import im "moonhug:external/odin-imgui"

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
