package editor

// The bridge's window registry tools (docs/core/McpBridge.md "Windows"): open
// and close a window instance by its key, lock it, and read what the registry
// holds for it. They act on the registry directly, without imgui, so they
// work for a window in a workspace frame too, which window_list leaves out.
// The editor scenarios drive windows through them (moonhug/scenarios).

import "core:encoding/json"
import mcp "moonhug:editor/mcp"
import wnd "moonhug:editor/window"

@(private = "file")
_param_str :: proc(params: json.Object, key: string) -> string {
	if v, ok := params[key]; ok {
		if str, is_str := v.(json.String); is_str do return string(str)
	}
	return ""
}

@(mcp_tool={
	description="What the window registry holds for a window instance: whether it is open, the window that hosts it (a workspace frame), its lock, the assets it shows, and its saved state as the window would save it now. The key is the instance key: the window's id for its first instance, `id/<n>` or `id/<asset guid>` for another.",
	param_window="string!:The window instance key",
})
mcp_tool_window_state :: proc(id: i64, params: json.Object) -> (string, Mcp_Error) {
	key := _param_str(params, "window")
	if key == "" do return mcp.tool_fail("bad_request", "window is required")
	Result :: struct {
		window:       string,
		open:         bool,
		host:         string,
		can_reopen:   bool,
		locked:       bool,
		lock_missing: bool,
		assets:       []string, // the paths it shows: its lock's, or the project selection
		state:        json.Value,
	}
	r := Result{window = key, can_reopen = wnd.can_reopen(key), locked = window_locked(key), lock_missing = window_lock_missing(key)}
	paths := make([dynamic]string, context.temp_allocator)
	for a in window_assets(key) do append(&paths, a.path)
	r.assets = paths[:]
	if w := wnd.find(key); w != nil {
		r.open = true
		r.host = w.host
	}
	if text := wnd.saved_text(key); text != "" {
		if v, err := json.parse_string(text, .JSON, true, context.temp_allocator); err == nil do r.state = v
	}
	return mcp.tool_ok(r)
}

@(mcp_tool={
	description="Opens a window by its id and answers the instance's key. With `another`, opens one more instance, as Add Tab does when the first one is open.",
	param_id="string!:The window's id (window_list, or the id in its @(editor_window))",
	param_another="boolean:Open one more instance (default false: show the first one)",
})
mcp_tool_window_open :: proc(id: i64, params: json.Object) -> (string, Mcp_Error) {
	wid := _param_str(params, "id")
	if !wnd.is_registered(wid) do return mcp.tool_fail("not_found", "no window is declared under %q", wid)
	another, _ := params["another"].(json.Boolean)
	w := wnd.open_another(wid) if another else wnd.open(wid)
	if w == nil do return mcp.tool_fail("failed", "window %q did not open", wid)
	return mcp.tool_ok(struct {
		window: string,
	}{window = w.key})
}

@(mcp_tool={
	description="Closes a window instance by its key, as its tab's close button does. It is gone the next frame, unless it holds unapplied edits and asks first.",
	param_window="string!:The window instance key",
})
mcp_tool_window_close :: proc(id: i64, params: json.Object) -> (string, Mcp_Error) {
	key := _param_str(params, "window")
	if wnd.find(key) == nil do return mcp.tool_fail("not_found", "no open window %q", key)
	wnd.close(key)
	return mcp.tool_ok(struct {
		window: string,
	}{window = key})
}

@(mcp_tool={
	description="Locks a window instance to the selection as it is now, or unlocks it, as its padlock does. With nothing selected the window stays unlocked.",
	param_window="string!:The window instance key",
	param_locked="boolean!:true to lock, false to unlock",
})
mcp_tool_window_lock :: proc(id: i64, params: json.Object) -> (string, Mcp_Error) {
	key := _param_str(params, "window")
	if wnd.find(key) == nil do return mcp.tool_fail("not_found", "no open window %q", key)
	v, _ := wnd.parse_key_id(key)
	if wnd.lock_mode(v) == .None do return mcp.tool_fail("bad_request", "window %q has no padlock", key)
	locked, _ := params["locked"].(json.Boolean)
	window_lock_set(key, locked)
	return mcp.tool_ok(struct {
		window: string,
		locked: bool,
	}{window = key, locked = window_locked(key)})
}
