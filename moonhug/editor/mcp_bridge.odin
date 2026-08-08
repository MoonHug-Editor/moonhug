package editor

// MCP bridge (docs/McpBridge.md): a loopback TCP endpoint inside the editor
// that the mcp_shim binary translates to MCP for agent clients. Threadless —
// mcp_bridge_tick polls a non-blocking socket once per frame, right after
// gfx.frame_begin, so tools run on the main thread with every editor and
// engine API available. Wire protocol lives in editor/mcp (length-prefixed
// JSON envelope, token auth from the bridge file).
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
import engine "../engine"
import gfx "../engine/gfx"
import "../engine/log"
import "menu"
import "undo"
import sim "./simulate"

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
	engine.project_settings_load("MCP", &engine.mcp_settings)
	if !engine.mcp_settings.enabled {
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

// Optional float param: missing keys leave the caller's current value.
@(private = "file")
_json_f32 :: proc(obj: json.Object, key: string) -> (f32, bool) {
	#partial switch v in obj[key] {
	case json.Integer:
		return f32(v), true
	case json.Float:
		return f32(v), true
	}
	return 0, false
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
// the bridge is on or off (engine.mcp_settings), so no tool needs to declare
// what it touches and none can be mislabeled.
Mcp_Error :: struct {
	code:    string, // "" = success
	message: string,
}

Mcp_Tool_Def :: struct {
	name:        string,
	description: string,
	schema:      string,
	handler:     proc(id: i64, params: json.Object) -> (string, Mcp_Error),
}

// A handler that answers on its own schedule (across frames).
MCP_DEFERRED :: "\x00deferred"

@(private = "file")
_mcp_dispatch :: proc(id: i64, tool: string, params: json.Object) {
	if tool == "describe" {
		_mcp_respond(id, _mcp_describe_json())
		return
	}
	for def in _mcp_tool_table() {
		if def.name != tool do continue
		result, err := def.handler(id, params)
		if err.code != "" {
			_mcp_respond_error(id, err.code, err.message)
			return
		}
		if result == MCP_DEFERRED do return // handler responds later
		_mcp_respond(id, result)
		return
	}
	_mcp_respond_error(id, "unknown_tool", fmt.tprintf("no tool named %q", tool))
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

@(private = "file")
_mcp_ok :: proc(v: any) -> (string, Mcp_Error) {
	data, merr := json.marshal(v, {}, context.temp_allocator)
	if merr != nil do return "", Mcp_Error{"marshal_failed", fmt.tprintf("%v", merr)}
	return string(data), {}
}

@(private = "file")
_mcp_fail :: proc(code: string, format: string, args: ..any) -> (string, Mcp_Error) {
	return "", Mcp_Error{code, fmt.tprintf(format, ..args)}
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

// --- Read tools ------------------------------------------------------------------

@(mcp_tool={description="Editor status: active scene, simulate state, selection. Call first to orient."})
mcp_tool_editor_state :: proc(id: i64, params: json.Object) -> (string, Mcp_Error) {
	scene_path: string
	if s := engine.sm_scene_get_active(); s != nil do scene_path = s.path
	return _mcp_ok(struct {
		scene:     string,
		simulate:  string,
		selection: []string,
	}{
		scene     = scene_path,
		simulate  = fmt.tprintf("%v", sim.state()),
		selection = _mcp_selection_names(),
	})
}

@(mcp_tool={
	description="Recent editor console entries, newest last.",
	param_max="integer:How many entries to return (default 30)",
})
mcp_tool_read_log :: proc(id: i64, params: json.Object) -> (string, Mcp_Error) {
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
	return _mcp_ok(out[:])
}

@(mcp_tool={
	description="Active scene contents: a summary (roots, transform count, selection) or the full serialized scene.",
	param_full="boolean:Return the complete serialized scene JSON instead of the summary",
})
mcp_tool_scene_dump :: proc(id: i64, params: json.Object) -> (string, Mcp_Error) {
	s := engine.sm_scene_get_active()
	if s == nil do return _mcp_fail("no_scene", "no active scene")

	full, _ := params["full"].(json.Boolean)
	if full {
		data, ok := engine.scene_serialize(s)
		if !ok do return _mcp_fail("serialize_failed", "scene_serialize failed")
		defer delete(data)
		return _mcp_ok(struct {
			path:  string,
			scene: string,
		}{path = s.path, scene = string(data)})
	}

	w := engine.ctx_world()
	roots := make([dynamic]string, context.temp_allocator)
	count := 0
	it := engine.pool_iterator(&w.transforms)
	for t, _ in engine.pool_next(&it) {
		if t.scene != s do continue
		count += 1
		if t.parent.handle == s.root.handle do append(&roots, t.name)
	}
	return _mcp_ok(struct {
		path:            string,
		transform_count: int,
		roots:           []string,
		selection:       []string,
	}{path = s.path, transform_count = count, roots = roots[:], selection = _mcp_selection_names()})
}

@(mcp_tool={description="Every invokable editor menu path."})
mcp_tool_list_menus :: proc(id: i64, params: json.Object) -> (string, Mcp_Error) {
	return _mcp_ok(menu.collect_action_paths())
}

@(mcp_tool={
	description="Objects in the active scene with their transform and components. Names repeat, so use the returned local_id to address one.",
	param_name="string:Only objects whose name contains this text",
})
mcp_tool_list_objects :: proc(id: i64, params: json.Object) -> (string, Mcp_Error) {
	s := engine.sm_scene_get_active()
	if s == nil do return _mcp_fail("no_scene", "no active scene")
	filter, _ := params["name"].(json.String)

	Obj :: struct {
		local_id:   u64,
		name:       string,
		parent:     string,
		position:   [3]f32,
		components: []string,
	}
	w := engine.ctx_world()
	out := make([dynamic]Obj, context.temp_allocator)
	it := engine.pool_iterator(&w.transforms)
	for t, h in engine.pool_next(&it) {
		if t.scene != s do continue
		if filter != "" && !strings.contains(t.name, filter) do continue
		parent_name: string
		if pt := engine.pool_get(&w.transforms, t.parent.handle); pt != nil do parent_name = pt.name
		comps := make([dynamic]string, context.temp_allocator)
		for c in t.components {
			if tid := engine.get_typeid_by_type_key(c.handle.type_key); tid != nil {
				append(&comps, fmt.tprintf("%v", tid))
			}
		}
		h := h
		h.type_key = .Transform
		append(&out, Obj{
			local_id   = u64(t.local_id),
			name       = t.name,
			parent     = parent_name,
			position   = engine.transform_world(engine.Transform_Handle(h)).position,
			components = comps[:],
		})
	}
	return _mcp_ok(out[:])
}

// --- Write tools -----------------------------------------------------------------
// Every mutation runs through the editor's own undo stack, so an agent edit is
// Ctrl+Z-able and indistinguishable from a manual one.

// Resolves an object by local_id (from list_objects), else by exact name.
@(private = "file")
_mcp_find_object :: proc(params: json.Object) -> (engine.Transform_Handle, Mcp_Error) {
	s := engine.sm_scene_get_active()
	if s == nil do return {}, Mcp_Error{"no_scene", "no active scene"}

	if lid := _json_int(params, "local_id", 0); lid != 0 {
		if tH, ok := engine.scene_find_outer_transform_local_id(s, engine.Local_ID(lid)); ok {
			return tH, {}
		}
		return {}, Mcp_Error{"not_found", fmt.tprintf("no object with local_id %d — see list_objects", lid)}
	}

	name, has := params["name"].(json.String)
	if !has do return {}, Mcp_Error{"bad_request", "need local_id or name"}
	w := engine.ctx_world()
	found: engine.Transform_Handle
	matches := 0
	it := engine.pool_iterator(&w.transforms)
	for t, h in engine.pool_next(&it) {
		if t.scene != s || t.name != name do continue
		matches += 1
		h := h
		h.type_key = .Transform
		found = engine.Transform_Handle(h)
	}
	if matches == 0 do return {}, Mcp_Error{"not_found", fmt.tprintf("no object named %q — see list_objects", name)}
	if matches > 1 {
		return {}, Mcp_Error{"ambiguous", fmt.tprintf("%d objects named %q — use local_id from list_objects", matches, name)}
	}
	return found, {}
}

@(mcp_tool={
	description="Select objects in the scene by name (exact). Empty name clears the selection.",
	param_name="string:Object name to select; omit or empty to clear",
})
mcp_tool_select :: proc(id: i64, params: json.Object) -> (string, Mcp_Error) {
	name, has := params["name"].(json.String)
	if !has || name == "" {
		sel_scene_clear()
		return _mcp_ok(struct{ selected: int }{0})
	}
	s := engine.sm_scene_get_active()
	if s == nil do return _mcp_fail("no_scene", "no active scene")
	w := engine.ctx_world()
	sel_scene_clear()
	count := 0
	it := engine.pool_iterator(&w.transforms)
	for t, h in engine.pool_next(&it) {
		if t.scene != s || t.name != name do continue
		h := h
		h.type_key = .Transform
		sel_scene_add(engine.Transform_Handle(h))
		count += 1
	}
	if count == 0 do return _mcp_fail("not_found", "no object named %q — see list_objects", name)
	return _mcp_ok(struct{ selected: int }{count})
}

@(mcp_tool={
	description="Set a transform field on one object. Address it by local_id (preferred) or exact name. One undo step.",
	param_local_id="integer:Object local_id from list_objects",
	param_name="string:Exact object name (alternative to local_id)",
	param_field="string!:position, rotation (euler degrees) or scale",
	param_x="number:X component",
	param_y="number:Y component",
	param_z="number:Z component",
})
mcp_tool_set_transform :: proc(id: i64, params: json.Object) -> (string, Mcp_Error) {
	tH, ferr := _mcp_find_object(params)
	if ferr.code != "" do return "", ferr
	field, has := params["field"].(json.String)
	if !has do return _mcp_fail("bad_request", "need field (position, rotation or scale)")

	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return _mcp_fail("not_found", "object went away")

	// Missing components keep their current value (partial edits).
	current: [3]f32
	switch field {
	case "position": current = t.position
	case "scale":    current = t.scale
	case "rotation": current = engine.quat_to_euler_xyz(t.rotation)
	case:
		return _mcp_fail("bad_request", "field must be position, rotation or scale")
	}
	v := current
	if f, ok := _json_f32(params, "x"); ok do v.x = f
	if f, ok := _json_f32(params, "y"); ok do v.y = f
	if f, ok := _json_f32(params, "z"); ok do v.z = f

	switch field {
	case "position":
		e := undo.edit_begin(tH, &t.position, typeid_of([3]f32), "Set Position (MCP)")
		defer undo.edit_end(&e)
		t.position = v
	case "scale":
		e := undo.edit_begin(tH, &t.scale, typeid_of([3]f32), "Set Scale (MCP)")
		defer undo.edit_end(&e)
		t.scale = v
	case "rotation":
		e := undo.edit_begin(tH, &t.rotation, typeid_of([4]f32), "Set Rotation (MCP)")
		defer undo.edit_end(&e)
		t.rotation = engine.quat_from_euler_xyz(v.x, v.y, v.z)
	}
	return _mcp_ok(struct {
		field: string,
		value: [3]f32,
	}{field = field, value = v})
}

@(mcp_tool={
	description="Rename one object. Address it by local_id (preferred) or exact current name. One undo step.",
	param_local_id="integer:Object local_id from list_objects",
	param_name="string:Exact current name (alternative to local_id)",
	param_new_name="string!:The new name",
})
mcp_tool_rename_object :: proc(id: i64, params: json.Object) -> (string, Mcp_Error) {
	tH, ferr := _mcp_find_object(params)
	if ferr.code != "" do return "", ferr
	new_name, has := params["new_name"].(json.String)
	if !has || new_name == "" do return _mcp_fail("bad_request", "need new_name")

	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return _mcp_fail("not_found", "object went away")

	e := undo.edit_begin(tH, &t.name, typeid_of(string), "Rename (MCP)")
	defer undo.edit_end(&e)
	delete(t.name)
	t.name = strings.clone(new_name)
	return _mcp_ok(struct{ name: string }{new_name})
}

@(mcp_tool={
	description="Read editor settings (no args) or set ONE scalar field.",
	param_name="string:Setting field name, e.g. project_zoom",
	param_value="string:JSON-encoded scalar, e.g. 0.5 or true",
})
mcp_tool_editor_setting :: proc(id: i64, params: json.Object) -> (string, Mcp_Error) {
	name, has_name := params["name"].(json.String)
	if !has_name do return _mcp_ok(editor_settings)
	value, has_value := params["value"].(json.String)
	if !has_value do return _mcp_fail("bad_request", "set needs value (JSON-encoded scalar as string)")

	patch := fmt.tprintf(`{{"%s": %s}}`, name, value)
	if json.unmarshal(transmute([]u8)patch, &editor_settings) != nil {
		return _mcp_fail("bad_value", "could not apply %s = %s", name, value)
	}
	return _mcp_ok(struct{ applied: bool }{true})
}

@(mcp_tool={
	description="Invoke an editor menu action by path, e.g. Edit/Undo (same as clicking it).",
	param_path="string!:Menu path from list_menus",
})
mcp_tool_invoke_menu :: proc(id: i64, params: json.Object) -> (string, Mcp_Error) {
	path, has := params["path"].(json.String)
	if !has do return _mcp_fail("bad_request", "missing path")
	if !menu.invoke_path(path) {
		return _mcp_fail("menu_unavailable", "%q not found, not an action, or disabled — see list_menus", path)
	}
	return _mcp_ok(struct{ invoked: bool }{true})
}

// --- Screenshot ------------------------------------------------------------------

@(mcp_tool={
	description="Capture a view's render target (previous frame). Full PNG saved to library/screenshots, downscaled copy returned inline as an image. Costs context — prefer text tools unless the question is visual.",
	param_view="string:scene (default) or game",
	param_max_size="integer:Inline image longest edge in pixels (default 640)",
})
mcp_tool_screenshot :: proc(id: i64, params: json.Object) -> (string, Mcp_Error) {
	view, _ := params["view"].(json.String)
	if view == "" do view = "scene"
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
		return _mcp_fail("bad_request", "view must be scene or game")
	}
	if rt == nil || rt.width < 2 || rt.height < 2 {
		return _mcp_fail("view_not_available", "%s view has not rendered yet", view)
	}
	dl := gfx.rt_download_begin(rt)
	if dl == nil do return _mcp_fail("readback_failed", "could not begin GPU readback")

	append(&_mcp.shots, _Mcp_Shot{id = id, dl = dl, view = view, max_size = max(max_size, 16)})
	return MCP_DEFERRED, {} // _mcp_poll_shots responds when the pixels land
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

	result, err := _mcp_ok(struct {
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
