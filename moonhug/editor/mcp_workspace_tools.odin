package editor

// The bridge's workspace tools (docs/core/McpBridge.md "Windows"): make a
// workspace and add a window to it, as the Workspace window's New button and
// a frame's Add do. Reading goes through window_state, which answers for a
// window in a frame too.

import "core:encoding/json"
import "core:fmt"
import mcp "moonhug:editor/mcp"
import wnd "moonhug:editor/window"
import "moonhug:editor/workspace"

@(private = "file")
_ws_param :: proc(params: json.Object, key: string, fallback := "") -> string {
	if v, ok := params[key]; ok {
		if str, is_str := v.(json.String); is_str do return string(str)
	}
	return fallback
}

@(mcp_tool={
	description="Makes a workspace in a source and shows it in an open Workspace window, as the window's New button does. Answers the workspace's id.",
	param_source="string!:The source that keeps it, by name: the Workspace window's New menu lists them (User, Project)",
	param_window="string:The Workspace window's instance key (default: workspace)",
	param_name="string:The workspace's name (default: Workspace <n>)",
})
mcp_tool_workspace_new :: proc(id: i64, params: json.Object) -> (string, Mcp_Error) {
	window := _ws_param(params, "window", WORKSPACE_WINDOW)
	if w := wnd.find(window); w == nil || w.id != WORKSPACE_WINDOW do return mcp.tool_fail("not_found", "no open Workspace window %q", window)
	source := _ws_param(params, "source")
	for p in workspace.providers() {
		if p.name != source || p.create == nil do continue
		ws := p.create(_ws_param(params, "name", fmt.tprintf("Workspace %d", len(workspace.all()) + 1)))
		if ws == nil do return mcp.tool_fail("failed", "source %q made no workspace", source)
		workspace_window_select(window, ws.id)
		return mcp.tool_ok(struct {
			id:   string,
			name: string,
		}{id = ws.id, name = ws.name})
	}
	return mcp.tool_fail("not_found", "no source %q makes workspaces", source)
}

@(mcp_tool={
	description="Adds a window to the workspace an open Workspace window shows, in a new frame: the window's first instance when it is not open anywhere, one more instance otherwise. Answers the instance's key.",
	param_id="string!:The id of the window to add",
	param_window="string:The Workspace window's instance key (default: workspace)",
})
mcp_tool_workspace_add :: proc(id: i64, params: json.Object) -> (string, Mcp_Error) {
	window := _ws_param(params, "window", WORKSPACE_WINDOW)
	wid := _ws_param(params, "id")
	if !wnd.is_registered(wid) do return mcp.tool_fail("not_found", "no window is declared under %q", wid)
	if workspace_window_selection(window) == "" do return mcp.tool_fail("bad_request", "Workspace window %q shows no workspace", window)
	key := _ws_new_key(wid)
	if key == "" || workspace_window_add(window, key) == nil do return mcp.tool_fail("failed", "window %q was not added to the workspace", wid)
	return mcp.tool_ok(struct {
		window: string,
	}{window = key})
}
