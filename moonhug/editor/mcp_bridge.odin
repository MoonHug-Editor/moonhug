package editor

// MCP bridge (docs/McpBridge.md): a loopback TCP endpoint inside the editor
// that the mcp_shim binary translates to MCP for agent clients. Threadless —
// mcp_bridge_tick polls a non-blocking socket once per frame, right after
// gfx.frame_begin, so tools run on the main thread with every editor and
// engine API available. Wire protocol lives in moonhug/mcp (length-prefixed
// JSON envelope, token auth from the bridge file).
//
// Screenshots complete across frames: the tick runs BEFORE views draw, so a
// view's render target still holds the PREVIOUS frame's submitted contents —
// downloadable immediately (gfx.rt_download_begin), fence polled per tick,
// response sent when the pixels land. Full-resolution PNG goes to
// Library/Screenshots, a ≤max_size thumbnail rides the wire as base64.

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
import mcp "../mcp"
import engine "../engine"
import gfx "../engine/gfx"
import "../engine/log"
import "menu"
import sim "./simulate"

_MCP_PORT_FIRST :: 6600
_MCP_PORT_COUNT :: 100
_MCP_SCREENSHOT_DIR :: "Library/Screenshots"
_MCP_DEFAULT_IMAGE_MAX :: 640

_Mcp_Shot :: struct {
	id:       i64,
	dl:       ^gfx.Texture_Download,
	view:     string,
	max_size: int,
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
}

mcp_bridge_init :: proc() {
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
	os.make_directory("Library")
	os.make_directory("Library/StateCache")
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

	id := _json_int(obj, "id", 0)
	tool, t_ok := obj["tool"].(json.String)
	if !t_ok {
		_mcp_respond_error(id, "bad_request", "missing tool")
		return true
	}
	params, _ := obj["params"].(json.Object)
	_mcp_dispatch(id, tool, params)
	return true
}

// json numbers parse as Integer OR Float depending on the literal.
@(private = "file")
_json_int :: proc(obj: json.Object, key: string, fallback: i64) -> i64 {
	#partial switch v in obj[key] {
	case json.Integer:
		return v
	case json.Float:
		return i64(v)
	}
	return fallback
}

// --- Tools ---------------------------------------------------------------------

// Tool metadata served to the shim (which forwards it as MCP tools/list).
@(private = "file")
_MCP_DESCRIBE :: `[
{"name":"editor_state","description":"Editor status: active scene, simulate state, selection. Call first to orient.","inputSchema":{"type":"object","properties":{}}},
{"name":"read_log","description":"Recent editor console entries, newest last.","inputSchema":{"type":"object","properties":{"max":{"type":"integer","description":"max entries, default 30"}}}},
{"name":"scene_dump","description":"Active scene contents. Default is a summary (roots, counts, selection); full=true returns the complete serialized scene JSON.","inputSchema":{"type":"object","properties":{"full":{"type":"boolean"}}}},
{"name":"list_menus","description":"Every invokable editor menu path.","inputSchema":{"type":"object","properties":{}}},
{"name":"invoke_menu","description":"Invoke an editor menu action by path, e.g. Edit/Undo (same as clicking it).","inputSchema":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}},
{"name":"editor_setting","description":"Read editor settings (no args) or set ONE scalar field: name + value, value as JSON text, e.g. name=project_zoom value=0.5.","inputSchema":{"type":"object","properties":{"name":{"type":"string"},"value":{"type":"string","description":"JSON-encoded scalar"}}}},
{"name":"screenshot","description":"Capture a view's render target (previous frame). Full PNG saved to Library/Screenshots, downscaled copy returned inline as image content.","inputSchema":{"type":"object","properties":{"view":{"type":"string","enum":["scene","game"],"description":"default scene"},"max_size":{"type":"integer","description":"inline image longest edge, default 640"}}}}
]`

@(private = "file")
_mcp_dispatch :: proc(id: i64, tool: string, params: json.Object) {
	switch tool {
	case "describe":
		_mcp_respond(id, _MCP_DESCRIBE)
	case "editor_state":
		_mcp_tool_editor_state(id)
	case "read_log":
		_mcp_tool_read_log(id, params)
	case "scene_dump":
		_mcp_tool_scene_dump(id, params)
	case "list_menus":
		_mcp_tool_list_menus(id)
	case "invoke_menu":
		_mcp_tool_invoke_menu(id, params)
	case "editor_setting":
		_mcp_tool_editor_setting(id, params)
	case "screenshot":
		_mcp_tool_screenshot(id, params)
	case:
		_mcp_respond_error(id, "unknown_tool", fmt.tprintf("no tool named %q", tool))
	}
}

@(private = "file")
_mcp_marshal_respond :: proc(id: i64, v: any) {
	data, merr := json.marshal(v, {}, context.temp_allocator)
	if merr != nil {
		_mcp_respond_error(id, "marshal_failed", fmt.tprintf("%v", merr))
		return
	}
	_mcp_respond(id, string(data))
}

@(private = "file")
_mcp_selection_names :: proc() -> []string {
	w := engine.ctx_world()
	names := make([dynamic]string, context.temp_allocator)
	for tH in _sel_scene {
		if t := engine.pool_get(&w.transforms, engine.Handle(tH)); t != nil {
			append(&names, t.name)
		}
	}
	return names[:]
}

@(private = "file")
_mcp_tool_editor_state :: proc(id: i64) {
	scene_name, scene_path: string
	if s := engine.sm_scene_get_active(); s != nil {
		scene_path = s.path
		scene_name = s.path
	}
	_mcp_marshal_respond(id, struct {
		scene:     string,
		simulate:  string,
		selection: []string,
	}{
		scene     = scene_name,
		simulate  = fmt.tprintf("%v", sim.state()),
		selection = _mcp_selection_names(),
	})
}

@(private = "file")
_mcp_tool_read_log :: proc(id: i64, params: json.Object) {
	max_entries := int(_json_int(params, "max", 30))
	Entry :: struct {
		level:   string,
		message: string,
	}
	out := make([dynamic]Entry, context.temp_allocator)
	first := max(0, len(log.entries) - max_entries)
	for e in log.entries[first:] {
		append(&out, Entry{level = fmt.tprintf("%v", e.level), message = e.message})
	}
	_mcp_marshal_respond(id, out[:])
}

@(private = "file")
_mcp_tool_scene_dump :: proc(id: i64, params: json.Object) {
	s := engine.sm_scene_get_active()
	if s == nil {
		_mcp_respond_error(id, "no_scene", "no active scene")
		return
	}
	full, _ := params["full"].(json.Boolean)
	if full {
		data, ok := engine.scene_serialize(s)
		if !ok {
			_mcp_respond_error(id, "serialize_failed", "scene_serialize failed")
			return
		}
		defer delete(data)
		_mcp_marshal_respond(id, struct {
			path:  string,
			scene: string,
		}{path = s.path, scene = string(data)})
		return
	}

	w := engine.ctx_world()
	roots := make([dynamic]string, context.temp_allocator)
	count := 0
	it := engine.pool_iterator(&w.transforms)
	for t, _ in engine.pool_next(&it) {
		if t.scene != s do continue
		count += 1
		if t.parent.handle == s.root.handle {
			append(&roots, t.name)
		}
	}
	_mcp_marshal_respond(id, struct {
		path:            string,
		transform_count: int,
		roots:           []string,
		selection:       []string,
	}{path = s.path, transform_count = count, roots = roots[:], selection = _mcp_selection_names()})
}

@(private = "file")
_mcp_tool_list_menus :: proc(id: i64) {
	_mcp_marshal_respond(id, menu.collect_action_paths())
}

@(private = "file")
_mcp_tool_invoke_menu :: proc(id: i64, params: json.Object) {
	path, has := params["path"].(json.String)
	if !has {
		_mcp_respond_error(id, "bad_request", "missing path")
		return
	}
	if !menu.invoke_path(path) {
		_mcp_respond_error(id, "menu_unavailable", fmt.tprintf("%q not found, not an action, or disabled — see list_menus", path))
		return
	}
	_mcp_respond(id, `{"invoked":true}`)
}

@(private = "file")
_mcp_tool_editor_setting :: proc(id: i64, params: json.Object) {
	name, has_name := params["name"].(json.String)
	if !has_name {
		_mcp_marshal_respond(id, editor_settings)
		return
	}
	value, has_value := params["value"].(json.String)
	if !has_value {
		_mcp_respond_error(id, "bad_request", "set needs value (JSON-encoded scalar as string)")
		return
	}
	patch := fmt.tprintf(`{{"%s": %s}}`, name, value)
	if json.unmarshal(transmute([]u8)patch, &editor_settings) != nil {
		_mcp_respond_error(id, "bad_value", fmt.tprintf("could not apply %s = %s", name, value))
		return
	}
	_mcp_respond(id, `{"applied":true}`)
}

// --- Screenshot ------------------------------------------------------------------

@(private = "file")
_mcp_tool_screenshot :: proc(id: i64, params: json.Object) {
	view := "scene"
	if v, has := params["view"].(json.String); has do view = v
	max_size := int(_json_int(params, "max_size", _MCP_DEFAULT_IMAGE_MAX))

	// The shot completes frames later, after this frame's temp allocations
	// are gone — store the STATIC literal, never the parsed param string.
	rt: ^gfx.Render_Target
	switch view {
	case "scene":
		rt = scene_rt
		view = "scene"
	case "game":
		rt = game_rt
		view = "game"
	case:
		_mcp_respond_error(id, "bad_request", "view must be scene or game")
		return
	}
	if rt == nil || rt.width < 2 || rt.height < 2 {
		_mcp_respond_error(id, "view_not_available", fmt.tprintf("%s view has not rendered yet", view))
		return
	}
	dl := gfx.rt_download_begin(rt)
	if dl == nil {
		_mcp_respond_error(id, "readback_failed", "could not begin GPU readback")
		return
	}
	append(&_mcp.shots, _Mcp_Shot{id = id, dl = dl, view = view, max_size = max(max_size, 16)})
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
	os.make_directory("Library")
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

	_mcp_marshal_respond(shot.id, struct {
		path:         string,
		width:        int,
		height:       int,
		image_base64: string,
		image_mime:   string,
	}{
		path = path, width = w, height = h,
		image_base64 = b64, image_mime = "image/png",
	})
}
