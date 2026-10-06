package editor

// MCP bridge (docs/core/McpBridge.md): a loopback TCP endpoint inside the editor
// that the mcp_shim binary translates to MCP for agent clients. Threadless —
// mcp_bridge_tick polls a non-blocking socket once per frame, right after
// gfx.frame_begin, so tools run on the main thread with every editor and
// engine API available. Wire protocol lives in editor/mcp (length-prefixed
// JSON envelope, token auth from the bridge file).
//
// This file holds the transport and the shell's own tools (console, menus,
// dialogs, settings, screenshots, the project view). The tools that read or
// edit the world are the engine's, in plugins/engine/editor/mcp_tools.
//
// Screenshots complete across frames: the tick runs BEFORE views draw, so a
// view's render target still holds the PREVIOUS frame's submitted contents —
// downloadable immediately (gfx.rt_download_begin), fence polled per tick,
// response sent when the pixels land. Full-resolution PNG goes to
// library/screenshots, a ≤max_size thumbnail rides the wire as base64.

import "base:runtime"
import "core:c"
import "core:crypto"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import stbi "vendor:stb/image"
import mcp "moonhug:editor/mcp"
import assets "moonhug:host/assets"
import core "moonhug:host/core"
import gfx "moonhug:host/gfx"
import "moonhug:host/log"
import "menu"
import "moonhug:editor/viewport"
import "moonhug:editor/widgets"

_MCP_PORT_FIRST :: 6600
_MCP_PORT_COUNT :: 100
_MCP_SCREENSHOT_DIR :: "library/screenshots"
_MCP_DEFAULT_IMAGE_MAX :: 640

_Mcp_Shot :: struct {
	id:       i64,
	dl:       ^gfx.Texture_Download,
	view:     string,
	max_size: int,
}

// A pending full-window capture. Serviced at the END of the frame, because the
// swapchain only holds the finished UI after the imgui pass has drawn and the
// bridge tick runs before it.
_Mcp_Window_Shot :: struct {
	id:       i64,
	max_size: int,
	wanted:   bool,
}

@(private = "file") _mcp: struct {
	active:       bool,
	listener:     net.TCP_Socket,
	client:       net.TCP_Socket,
	has_client:   bool,
	authed:       bool,
	token:        string,
	fb:           mcp.Frame_Buffer,
	shots:        [dynamic]_Mcp_Shot,
	shot_counter: int,
	pending_window_shot: _Mcp_Window_Shot,
}

mcp_bridge_init :: proc() {
	core.project_settings_load("MCP", &mcp.mcp_settings)
	if !mcp.mcp_settings.enabled {
		// A file left by an earlier enabled run would send shims to a port
		// nobody is listening on — remove it so they report "not running".
		os.remove(mcp.BRIDGE_FILE_FROM_EDITOR)
		log.info("[MCP] Bridge disabled (Edit > Project Settings > MCP)")
		return
	}

	port := 0
	for candidate in _MCP_PORT_FIRST ..< _MCP_PORT_FIRST + _MCP_PORT_COUNT {
		listener, lerr := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = candidate})
		if lerr != nil do continue
		_mcp.listener = listener
		port = candidate
		break
	}
	if port == 0 {
		log.error("[MCP] No free port — bridge disabled")
		return
	}
	if net.set_blocking(_mcp.listener, false) != nil {
		net.close(_mcp.listener)
		log.error("[MCP] set_blocking failed — bridge disabled")
		return
	}

	raw: [16]u8
	crypto.rand_bytes(raw[:])
	_mcp.token = fmt.aprintf("%032x", transmute(u128be)raw)

	info := mcp.Bridge_Info{port = port, pid = os.get_pid(), token = _mcp.token, project = "moonhug"}
	data, merr := json.marshal(info, {pretty = true}, context.temp_allocator)
	if merr != nil {
		log.error("[MCP] Bridge file marshal failed — bridge disabled")
		net.close(_mcp.listener)
		return
	}
	os.make_directory("library")
	os.make_directory("library/state_cache")
	if os.write_entire_file(mcp.BRIDGE_FILE_FROM_EDITOR, data) != nil {
		log.error("[MCP] Bridge file write failed — bridge disabled")
		net.close(_mcp.listener)
		return
	}
	_mcp.active = true
	log.infof("[MCP] Bridge listening on 127.0.0.1:%d", port)
}

mcp_bridge_shutdown :: proc() {
	if _mcp.active {
		os.remove(mcp.BRIDGE_FILE_FROM_EDITOR)
		net.close(_mcp.listener)
	}
	_mcp_drop_client()
	for shot in _mcp.shots {
		gfx.texture_download_cancel(shot.dl)
	}
	delete(_mcp.shots)
	mcp.frame_buffer_destroy(&_mcp.fb)
	delete(_mcp.token)
	_mcp = {}
}

@(private = "file")
_mcp_drop_client :: proc() {
	if _mcp.has_client do net.close(_mcp.client)
	_mcp.has_client = false
	_mcp.authed = false
	clear(&_mcp.fb.data)
}

mcp_bridge_tick :: proc() {
	if !_mcp.active do return

	// One shim at a time — a new connection replaces a dead predecessor.
	if client, _, aerr := net.accept_tcp(_mcp.listener); aerr == nil {
		_mcp_drop_client()
		_mcp.client = client
		_mcp.has_client = true
		_ = net.set_blocking(client, true)
		if !mcp.send_all(client, transmute([]u8)string(mcp.HANDSHAKE)) {
			_mcp_drop_client()
		} else {
			_ = net.set_blocking(client, false)
		}
	}

	_mcp_poll_shots()

	if !_mcp.has_client do return
	buf: [65536]u8
	for {
		n, rerr := net.recv_tcp(_mcp.client, buf[:])
		if rerr != nil {
			if rerr == .Would_Block do break
			_mcp_drop_client()
			return
		}
		if n == 0 { // orderly shutdown from the peer
			_mcp_drop_client()
			return
		}
		mcp.frame_buffer_push(&_mcp.fb, buf[:n])
		if n < len(buf) do break
	}

	for {
		payload, ok, malformed := mcp.frame_buffer_next(&_mcp.fb)
		if malformed {
			_mcp_drop_client()
			return
		}
		if !ok do break
		keep := _mcp_handle(payload)
		mcp.frame_buffer_consume(&_mcp.fb)
		if !keep {
			_mcp_drop_client()
			return
		}
	}
}

// --- Envelope ------------------------------------------------------------------

@(private = "file")
_mcp_send :: proc(payload: string) {
	if !_mcp.has_client do return
	_ = net.set_blocking(_mcp.client, true)
	if !mcp.write_frame(_mcp.client, transmute([]u8)payload) {
		_mcp_drop_client()
		return
	}
	_ = net.set_blocking(_mcp.client, false)
}

// result_json must be valid JSON (object/array/scalar). NOTE: fmt treats
// {} as placeholders — JSON braces in format strings are escaped as {{ }}.
@(private = "file")
_mcp_respond :: proc(id: i64, result_json: string) {
	_mcp_send(fmt.tprintf(`{{"id":%d,"status":"ok","result":%s}}`, id, result_json))
}

@(private = "file")
_mcp_respond_error :: proc(id: i64, code: string, message: string) {
	e, _ := json.marshal(mcp.Wire_Error{code = code, message = message}, {}, context.temp_allocator)
	_mcp_send(fmt.tprintf(`{{"id":%d,"status":"error","error":%s}}`, id, string(e)))
}

// Returns false when the connection must close (auth failure, bad payload).
@(private = "file")
_mcp_handle :: proc(payload: []u8) -> bool {
	val, jerr := json.parse(payload, allocator = context.temp_allocator)
	if jerr != nil do return false
	obj, is_obj := val.(json.Object)
	if !is_obj do return false

	if !_mcp.authed {
		token, has := obj["token"].(json.String)
		if !has || token != _mcp.token do return false
		_mcp.authed = true
		_mcp_send(`{"ok":true}`)
		return true
	}

	id := mcp.json_int(obj, "id", 0)
	tool, t_ok := obj["tool"].(json.String)
	if !t_ok {
		_mcp_respond_error(id, "bad_request", "missing tool")
		return true
	}
	params, _ := obj["params"].(json.Object)
	_mcp_dispatch(id, tool, params)
	return true
}


// --- Tool table ------------------------------------------------------------------

// Tools are DECLARED, not registered: @(mcp_tool={description=...,
// param_x="type!:desc"}) on an `mcp_tool_<name>` proc, and mcp_tool_gen emits
// _mcp_tool_table (mcp_tools_generated.odin). The schema the agent reads comes
// from the same declaration as the handler, so the two cannot drift.
//
// A handler returns (result_json, error). Returning a zero Mcp_Error means the
// result is sent as-is; screenshot-style tools that finish frames later return
// MCP_DEFERRED and respond themselves. There is no read/write classification:
// the bridge is on or off (mcp.mcp_settings), so no tool needs to declare
// what it touches and none can be mislabeled. The handler vocabulary
// (mcp.Tool_Error, mcp.tool_ok, mcp.tool_fail) is in editor/mcp, so tools in
// the engine's editor half and in plugins return the same types.
Mcp_Error :: mcp.Tool_Error

// Exposes a proc as a tool of the editor's MCP bridge, so an agent can call it.
//
// `description` is what the agent reads. Each `param_<name>` field declares one
// parameter as "type:description". The proc takes the request id and the
// params object and returns the result as JSON, or an Mcp_Error.
@(extension_point={attribute="mcp_tool", target="proc", fields="description param_*"})
Mcp_Tool_Def :: struct {
	name:        string,
	description: string,
	schema:      string,
	handler:     proc(id: i64, params: json.Object) -> (string, Mcp_Error),
}

// A handler that answers on its own schedule (across frames).
MCP_DEFERRED :: mcp.DEFERRED

// Runs one tool and hands back its marshaled result, without answering the
// client. Dispatch answers; batch collects. Both go through here so a batched
// call cannot diverge from the same call made on its own.
@(private = "file")
_mcp_invoke :: proc(id: i64, tool: string, params: json.Object) -> (string, Mcp_Error) {
	for def in _mcp_tool_table() {
		if def.name != tool do continue
		return def.handler(id, params)
	}
	return "", Mcp_Error{"unknown_tool", fmt.tprintf("no tool named %q", tool)}
}

// Runs a tool by name the way a client call does, for tests. The handlers are
// where the behaviour is, and reaching them through the socket would need a
// live editor.
mcp_tool_for_test :: proc(tool: string, params: json.Object) -> (string, Mcp_Error) {
	return _mcp_invoke(0, tool, params)
}

@(private = "file")
_mcp_dispatch :: proc(id: i64, tool: string, params: json.Object) {
	if tool == "describe" {
		_mcp_respond(id, _mcp_describe_json())
		return
	}
	result, err := _mcp_invoke(id, tool, params)
	if err.code != "" {
		_mcp_respond_error(id, err.code, err.message)
		return
	}
	if result == MCP_DEFERRED do return // handler responds later
	_mcp_respond(id, result)
}

// tools/list payload, built from the generated table.
@(private = "file")
_mcp_describe_json :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "[")
	for def, i in _mcp_tool_table() {
		if i > 0 do strings.write_string(&b, ",")
		name, _ := json.marshal(def.name, {}, context.temp_allocator)
		desc, _ := json.marshal(def.description, {}, context.temp_allocator)
		fmt.sbprintf(&b, `{{"name":%s,"description":%s,"inputSchema":%s}}`,
			string(name), string(desc), def.schema)
	}
	strings.write_string(&b, "]")
	return strings.to_string(b)
}

// --- Tool helpers ----------------------------------------------------------------


@(mcp_tool={
	description="Recent editor console entries, newest last.",
	param_max="integer:How many entries to return (default 30)",
})
mcp_tool_read_log :: proc(id: i64, params: json.Object) -> (string, Mcp_Error) {
	max_entries := int(mcp.json_int(params, "max", 30))
	Entry :: struct {
		level:   string,
		message: string,
	}
	out := make([dynamic]Entry, context.temp_allocator)
	first := max(0, len(log.entries) - max_entries)
	for e in log.entries[first:] {
		append(&out, Entry{level = fmt.tprintf("%v", e.level), message = e.message})
	}
	return mcp.tool_ok(out[:])
}

// Several tools in one round trip. The frame-polled bridge answers one call
// per frame, so N separate calls cost N frames and N envelopes; authoring a
// scene is mostly repetition, which is exactly what that penalizes.
//
// Every command goes through _mcp_invoke — the same path a standalone call
// takes — so batching changes when a tool runs, never what it does. Each
// command keeps its own undo step: a batch is a convenience, not a transaction,
// and nothing here merges or rolls back across commands.
@(mcp_tool={
	description="Run several tools in one round trip. Strongly preferred for repetitive work — setting many properties, renaming several objects — since the bridge otherwise answers one call per frame. Each command is {\"tool\": name, \"params\": {...}} and keeps its own undo step, so this is a convenience, not a transaction: a later failure does not roll back an earlier success. Max 100 commands. Cannot nest, and cannot carry screenshot (it answers across frames).",
	param_commands="object[]!:Commands to run in order, each {\"tool\": name, \"params\": {...}}",
	param_fail_fast="boolean:Stop at the first failure (default true)",
})
mcp_tool_batch :: proc(id: i64, params: json.Object) -> (string, Mcp_Error) {
	raw, has := params["commands"].(json.Array)
	if !has do return mcp.tool_fail("bad_request", "need commands: an array of {tool, params}")
	if len(raw) == 0 do return mcp.tool_fail("bad_request", "commands is empty")
	if len(raw) > 100 do return mcp.tool_fail("bad_request", "%d commands, max 100", len(raw))
	fail_fast := true
	if v, hf := params["fail_fast"].(json.Boolean); hf do fail_fast = bool(v)

	// Results splice each handler's already-marshaled JSON, the way
	// _mcp_describe_json does — no parse-and-remarshal round trip.
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "[")
	ran, failed := 0, 0
	for entry, i in raw {
		if i > 0 do strings.write_string(&b, ",")
		cmd, is_obj := entry.(json.Object)
		tool: string
		if is_obj {
			tool, _ = cmd["tool"].(json.String)
		}
		name_json, _ := json.marshal(tool, {}, context.temp_allocator)

		err: Mcp_Error
		result: string
		switch {
		case !is_obj:
			err = {"bad_request", "each command must be an object"}
		case tool == "":
			err = {"bad_request", "command has no tool"}
		case tool == "batch":
			err = {"bad_request", "batch cannot nest"}
		case:
			cmd_params, _ := cmd["params"].(json.Object)
			result, err = _mcp_invoke(id, tool, cmd_params)
			if err.code == "" && result == MCP_DEFERRED {
				// The batch answers once, so a handler that replies across
				// frames would strand its result.
				err = {"bad_request", fmt.tprintf("%s answers across frames and cannot run in a batch", tool)}
				result = ""
			}
		}

		if err.code != "" {
			failed += 1
			code, _ := json.marshal(err.code, {}, context.temp_allocator)
			msg, _ := json.marshal(err.message, {}, context.temp_allocator)
			fmt.sbprintf(&b, `{{"tool":%s,"status":"error","code":%s,"message":%s}}`,
				string(name_json), string(code), string(msg))
			if fail_fast {
				ran += 1
				break
			}
		} else {
			fmt.sbprintf(&b, `{{"tool":%s,"status":"ok","result":%s}}`, string(name_json), result)
		}
		ran += 1
	}
	strings.write_string(&b, "]")
	return fmt.tprintf(`{{"ran":%d,"failed":%d,"stopped_early":%t,"results":%s}}`,
		ran, failed, ran < len(raw), strings.to_string(b)), {}
}

@(mcp_tool={description="Every invokable editor menu path, actions and toggles alike, including per-view menus addressed View/<view>/<label>. invoke_menu fires any of them: an action runs, a toggle flips and the reply says which way it landed."})
mcp_tool_list_menus :: proc(id: i64, params: json.Object) -> (string, Mcp_Error) {
	// The main menu and the per-view menus are separate registries, so a
	// listing that showed only one would hide half the editor's commands.
	paths := make([dynamic]string, context.temp_allocator)
	append(&paths, ..menu.collect_invokable_paths())
	append(&paths, ..view_menu_paths())
	return mcp.tool_ok(paths[:])
}

@(mcp_tool={
	description="Open a scene file as the active scene — same flow as double-clicking it in the project view (unloads every loaded scene first).",
	param_path="string:Scene path relative to the project root, e.g. packages/app/assets/demo_prefabs/bullet.scene",
})
mcp_tool_open_scene :: proc(id: i64, params: json.Object) -> (string, Mcp_Error) {
	path, ok := params["path"].(json.String)
	if !ok || !strings.has_suffix(string(path), ".scene") {
		return mcp.tool_fail("bad_path", "path must name a .scene file")
	}
	if _, gok := assets.asset_db_get_guid(string(path)); !gok {
		return mcp.tool_fail("not_found", "no asset at %q", string(path))
	}
	// The project view's own flow, then the engine's active document.
	_project_activate_file(string(path))
	active, aok := viewport.document_active_path()
	if !aok do return mcp.tool_fail("load_failed", "scene did not load")
	return mcp.tool_ok(struct{ path: string }{path = active})
}

@(mcp_tool={
	description="Ping an asset in the project view — reveal its folder and flash it, the same as clicking a scene title or a Ref field value. Navigating the project view also renders thumbnails for the revealed folder. Pass select to also make it the active file, which is what Assets menu actions like Extract Assets act on.",
	param_path="string:Asset path relative to the project root",
	param_select="boolean:Also select it, so Assets menu actions target it",
})
mcp_tool_ping_asset :: proc(id: i64, params: json.Object) -> (string, Mcp_Error) {
	path, ok := params["path"].(json.String)
	if !ok do return mcp.tool_fail("bad_path", "path required")
	guid, gok := assets.asset_db_get_guid(string(path))
	if !gok do return mcp.tool_fail("not_found", "no asset at %q", string(path))
	select, _ := params["select"].(json.Boolean)
	if select {
		core.inspector_request_select_asset(core.Asset_GUID(guid))
	} else {
		core.inspector_request_ping_asset(core.Asset_GUID(guid))
	}
	return mcp.tool_ok(struct{ pinged: string, selected: bool }{pinged = string(path), selected = bool(select)})
}

@(mcp_tool={
	description="Read editor settings (no args) or set ONE scalar field.",
	param_name="string:Setting field name, e.g. project_zoom",
	param_value="string:JSON-encoded scalar, e.g. 0.5 or true",
})
mcp_tool_editor_setting :: proc(id: i64, params: json.Object) -> (string, Mcp_Error) {
	name, has_name := params["name"].(json.String)
	if !has_name do return mcp.tool_ok(editor_settings)
	value, has_value := params["value"].(json.String)
	if !has_value do return mcp.tool_fail("bad_request", "set needs value (JSON-encoded scalar as string)")

	patch := fmt.tprintf(`{{"%s": %s}}`, name, value)
	if json.unmarshal(transmute([]u8)patch, &editor_settings) != nil {
		return mcp.tool_fail("bad_value", "could not apply %s = %s", name, value)
	}
	return mcp.tool_ok(struct{ applied: bool }{true})
}

@(mcp_tool={
	description="Invoke an editor menu item by path, e.g. Edit/Undo (same as clicking it). An action runs. A TOGGLE FLIPS — it does not take a value — so the reply carries its resulting state, and asking twice puts it back.",
	param_path="string!:Menu path from list_menus",
})
mcp_tool_invoke_menu :: proc(id: i64, params: json.Object) -> (string, Mcp_Error) {
	path, has := params["path"].(json.String)
	if !has do return mcp.tool_fail("bad_request", "missing path")
	ok, state := menu.invoke_path(path)
	if !ok do ok, state = view_menu_invoke(path)
	if !ok {
		return mcp.tool_fail("menu_unavailable", "%q not found, not invokable, or disabled — see list_menus", path)
	}
	// A toggle FLIPS, so the reply carries where it landed — an agent has no
	// other way to read menu state, and asking twice would undo the first ask.
	// An item that asks first (Delete) opens a dialog: the reply names it, so
	// the agent knows to answer it with the dialog tool.
	d, _ := widgets.dialog_current()
	return mcp.tool_ok(struct {
		invoked: bool,
		state:   bool,
		dialog:  string,
	}{invoked = true, state = state, dialog = d.title})
}

@(mcp_tool={
	description="The open confirmation dialog (title, text, buttons), or none. Pass press=<button label> to answer it, same as clicking the button.",
	param_press="string:Label of the button to press",
})
mcp_tool_dialog :: proc(id: i64, params: json.Object) -> (string, Mcp_Error) {
	d, open := widgets.dialog_current()
	press, has_press := params["press"].(json.String)
	if !has_press {
		labels := make([]string, len(d.buttons), context.temp_allocator)
		for b, i in d.buttons do labels[i] = b.label
		return mcp.tool_ok(struct {
			open:        bool,
			title:       string,
			description: string,
			buttons:     []string,
		}{open = open, title = d.title, description = d.description, buttons = labels})
	}
	if !open do return mcp.tool_fail("no_dialog", "no dialog is open")
	for b, i in d.buttons {
		if b.label == press {
			widgets.dialog_choose(i)
			return mcp.tool_ok(struct{ pressed: string }{press})
		}
	}
	return mcp.tool_fail("bad_request", "%q is not a button of %q", press, d.title)
}

// --- Screenshot ------------------------------------------------------------------

@(mcp_tool={
	description="Capture a view's render target (previous frame). Full PNG saved to library/screenshots, downscaled copy returned inline as an image. Costs context — prefer text tools unless the question is visual.",
	param_view="string:scene (default), game, or editor for the whole editor window including the inspector and other panels",
	param_max_size="integer:Inline image longest edge in pixels (default 640)",
})
mcp_tool_screenshot :: proc(id: i64, params: json.Object) -> (string, Mcp_Error) {
	view, _ := params["view"].(json.String)
	if view == "" do view = "scene"
	max_size := int(mcp.json_int(params, "max_size", _MCP_DEFAULT_IMAGE_MAX))

	// The shot completes frames later, after this frame's temp allocations
	// are gone — store the STATIC literal, never the parsed param string.
	// The whole editor window, imgui panels included. Those panels draw straight
	// to the swapchain and never reach a render target, so this copies the
	// swapchain itself — which is only legal AFTER the UI pass has drawn, and the
	// bridge tick runs before it. So the request is queued and serviced at the
	// end of this frame (mcp_bridge_capture_frame). Nothing outside the editor's
	// own window exists in a swapchain image, so there is nothing else to leak.
	if view == "editor" {
		_mcp.pending_window_shot = _Mcp_Window_Shot{
			id = id, max_size = max(max_size, 16), wanted = true,
		}
		return MCP_DEFERRED, {} // answered once the frame's image is copied
	}

	rt: ^gfx.Render_Target
	switch view {
	case "scene":
		rt = scene_rt
		view = "scene"
	case "game":
		rt = game_rt
		view = "game"
	case:
		return mcp.tool_fail("bad_request", "view must be scene, game or editor")
	}
	if rt == nil || rt.width < 2 || rt.height < 2 {
		return mcp.tool_fail("view_not_available", "%s view has not rendered yet", view)
	}
	dl := gfx.rt_download_begin(rt)
	if dl == nil do return mcp.tool_fail("readback_failed", "could not begin GPU readback")

	append(&_mcp.shots, _Mcp_Shot{id = id, dl = dl, view = view, max_size = max(max_size, 16)})
	return MCP_DEFERRED, {} // _mcp_poll_shots responds when the pixels land
}

// Services a queued full-window capture. Called at the END of the frame, after
// the imgui pass has drawn into the swapchain and while the command buffer is
// still open — the only moment the swapchain holds the finished UI and can
// still be copied from.
mcp_bridge_capture_frame :: proc() {
	if !_mcp.active || !_mcp.pending_window_shot.wanted do return
	req := _mcp.pending_window_shot
	_mcp.pending_window_shot = {}

	// Copy AND download are encoded into this frame's command buffer, so they
	// land in queue order behind the UI draw. Starting a separate download here
	// would submit ahead of the copy and read an untouched texture.
	dl := gfx.swapchain_capture_begin()
	if dl == nil {
		_mcp_respond_error(req.id, "capture_failed", "no swapchain image this frame (window minimized?)")
		return
	}
	append(&_mcp.shots, _Mcp_Shot{id = req.id, dl = dl, view = "editor", max_size = req.max_size})
}

@(private = "file")
_mcp_poll_shots :: proc() {
	for i := 0; i < len(_mcp.shots); {
		shot := _mcp.shots[i]
		if !gfx.texture_download_ready(shot.dl) {
			i += 1
			continue
		}
		unordered_remove(&_mcp.shots, i)
		w := int(shot.dl.width)
		h := int(shot.dl.height)
		pixels := gfx.texture_download_take(shot.dl, context.temp_allocator) // frees dl
		if pixels == nil {
			_mcp_respond_error(shot.id, "readback_failed", "GPU readback returned no pixels")
			continue
		}
		_mcp_finish_shot(shot, pixels, w, h)
	}
}

// PNG bytes in memory via stb's to-func writer (c callback, no context).
@(private = "file")
_mcp_png_encode :: proc(pixels: []u8, w, h: int) -> []u8 {
	sink := make([dynamic]u8, 0, w * h, context.temp_allocator)
	cb :: proc "c" (ctx: rawptr, data: rawptr, size: c.int) {
		context = runtime.default_context()
		context.allocator = context.temp_allocator
		out := (^[dynamic]u8)(ctx)
		bytes := ([^]u8)(data)[:size]
		append(out, ..bytes)
	}
	if stbi.write_png_to_func(cb, &sink, c.int(w), c.int(h), 4, raw_data(pixels), c.int(w * 4)) == 0 {
		return nil
	}
	return sink[:]
}

@(private = "file")
_mcp_finish_shot :: proc(shot: _Mcp_Shot, pixels: []u8, w, h: int) {
	// Full resolution to disk.
	os.make_directory("library")
	os.make_directory(_MCP_SCREENSHOT_DIR)
	_mcp.shot_counter += 1
	path := fmt.tprintf("%s/%s_%03d.png", _MCP_SCREENSHOT_DIR, shot.view, _mcp.shot_counter)
	full_png := _mcp_png_encode(pixels, w, h)
	if full_png == nil {
		_mcp_respond_error(shot.id, "encode_failed", "PNG encode failed")
		return
	}
	if os.write_entire_file(path, full_png) != nil {
		log.errorf("[MCP] Screenshot write failed: %s", path)
		path = ""
	}

	// Inline copy, downscaled so the longest edge fits max_size.
	inline_pixels := pixels
	iw, ih := w, h
	if w > shot.max_size || h > shot.max_size {
		scale := f32(shot.max_size) / f32(max(w, h))
		iw = max(int(f32(w) * scale), 1)
		ih = max(int(f32(h) * scale), 1)
		scaled := make([]u8, iw * ih * 4, context.temp_allocator)
		if stbi.resize_uint8(raw_data(pixels), c.int(w), c.int(h), c.int(w * 4),
			raw_data(scaled), c.int(iw), c.int(ih), c.int(iw * 4), 4) == 0 {
			_mcp_respond_error(shot.id, "encode_failed", "downscale failed")
			return
		}
		inline_pixels = scaled
	}
	inline_png := _mcp_png_encode(inline_pixels, iw, ih)
	if inline_png == nil {
		_mcp_respond_error(shot.id, "encode_failed", "PNG encode failed")
		return
	}
	b64, b64err := base64.encode(inline_png, allocator = context.temp_allocator)
	if b64err != nil {
		_mcp_respond_error(shot.id, "encode_failed", "base64 encode failed")
		return
	}

	result, err := mcp.tool_ok(struct {
		path:         string,
		width:        int,
		height:       int,
		image_base64: string,
		image_mime:   string,
	}{
		path = path, width = w, height = h,
		image_base64 = b64, image_mime = "image/png",
	})
	if err.code != "" {
		_mcp_respond_error(shot.id, err.code, err.message)
		return
	}
	_mcp_respond(shot.id, result)
}
