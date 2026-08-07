package mcp_shim

// MCP stdio server bridging Claude Code (or any MCP client) to the MoonHug
// editor's TCP bridge (docs/McpBridge.md). Speaks newline-delimited JSON-RPC
// 2.0 on stdin/stdout — the small MCP surface an agent needs: initialize,
// tools/list, tools/call, ping. The editor side is moonhug/editor/
// mcp_bridge.odin, the shared wire protocol moonhug/mcp.
//
// The shim owns session stability: it discovers the editor through the
// bridge file, reconnects with fresh state when the editor restarts, and
// answers tool calls with a retry hint while the editor is down — the MCP
// session itself never dies with the editor.
//
// Run from the repo root (the bridge file path is root-relative); an
// explicit path to mcp_bridge.json may be passed as the only argument.

import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import mcp "../mcp"

PROTOCOL_VERSION :: "2025-06-18"
EDITOR_CALL_TIMEOUT :: 30 * time.Second

_shim: struct {
	bridge_path: string,
	sock:        net.TCP_Socket,
	connected:   bool,
	fb:          mcp.Frame_Buffer,
	next_id:     i64,
	link_mutex:  sync.Mutex, // guards sock/connected/fb/next_id
	out_mutex:   sync.Mutex, // guards stdout (watcher notifies from its thread)
}

// A session usually starts before the editor does — tools/list then comes
// back empty. The watcher polls for the bridge and pushes tools/list_changed
// the moment the editor appears, so the client re-lists without a reconnect.
_watch_editor :: proc(_: ^thread.Thread) {
	for {
		time.sleep(2 * time.Second)
		notify := false
		{
			sync.mutex_guard(&_shim.link_mutex)
			if !_shim.connected && _connect() == "" {
				notify = true
			}
		}
		if notify {
			_out(`{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}`)
		}
	}
}

main :: proc() {
	_shim.bridge_path = mcp.BRIDGE_FILE_FROM_ROOT
	if len(os.args) > 1 do _shim.bridge_path = os.args[1]

	watcher := thread.create(_watch_editor)
	thread.start(watcher)

	stdin_buf := make([dynamic]u8)
	chunk: [65536]u8
	for {
		n, rerr := os.read(os.stdin, chunk[:])
		if rerr != nil || n <= 0 do break // client closed stdin: exit
		append(&stdin_buf, ..chunk[:n])
		for {
			nl := -1
			for b, i in stdin_buf {
				if b == '\n' {
					nl = i
					break
				}
			}
			if nl < 0 do break
			line := strings.trim_space(string(stdin_buf[:nl]))
			if len(line) > 0 do _handle_line(line)
			remove_range(&stdin_buf, 0, nl + 1)
			free_all(context.temp_allocator)
		}
	}
}

_out :: proc(line: string) {
	sync.mutex_guard(&_shim.out_mutex)
	os.write_string(os.stdout, line)
	os.write_string(os.stdout, "\n")
}

_logf :: proc(f: string, args: ..any) {
	fmt.eprintf("[mcp_shim] ")
	fmt.eprintf(f, ..args)
	fmt.eprintf("\n")
}

// --- JSON value writer -----------------------------------------------------------
// core json can't re-marshal a parsed json.Value, so the shim writes values
// itself (id echo, argument forwarding, image-field stripping).

_write_value :: proc(b: ^strings.Builder, v: json.Value) {
	switch t in v {
	case json.Null:
		strings.write_string(b, "null")
	case json.Boolean:
		strings.write_string(b, t ? "true" : "false")
	case json.Integer:
		fmt.sbprintf(b, "%d", t)
	case json.Float:
		fmt.sbprintf(b, "%.17g", t)
	case json.String:
		_write_json_string(b, t)
	case json.Array:
		strings.write_byte(b, '[')
		for e, i in t {
			if i > 0 do strings.write_byte(b, ',')
			_write_value(b, e)
		}
		strings.write_byte(b, ']')
	case json.Object:
		strings.write_byte(b, '{')
		first := true
		for k, e in t {
			if !first do strings.write_byte(b, ',')
			first = false
			_write_json_string(b, k)
			strings.write_byte(b, ':')
			_write_value(b, e)
		}
		strings.write_byte(b, '}')
	}
}

_write_json_string :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for r in s {
		switch r {
		case '"':
			strings.write_string(b, `\"`)
		case '\\':
			strings.write_string(b, `\\`)
		case '\n':
			strings.write_string(b, `\n`)
		case '\r':
			strings.write_string(b, `\r`)
		case '\t':
			strings.write_string(b, `\t`)
		case:
			if r < 0x20 {
				fmt.sbprintf(b, `\u%04x`, int(r))
			} else {
				strings.write_rune(b, r)
			}
		}
	}
	strings.write_byte(b, '"')
}

_value_text :: proc(v: json.Value) -> string {
	b := strings.builder_make(context.temp_allocator)
	_write_value(&b, v)
	return strings.to_string(b)
}

// --- JSON-RPC dispatch -----------------------------------------------------------

_handle_line :: proc(line: string) {
	val, jerr := json.parse(transmute([]u8)line, allocator = context.temp_allocator)
	if jerr != nil {
		_logf("bad json-rpc line: %v", jerr)
		return
	}
	obj, is_obj := val.(json.Object)
	if !is_obj do return

	method, _ := obj["method"].(json.String)
	id_val, has_id := obj["id"]
	id_text := has_id ? _value_text(id_val) : ""

	switch method {
	case "initialize":
		requested := PROTOCOL_VERSION
		if params, has := obj["params"].(json.Object); has {
			if pv, pv_ok := params["protocolVersion"].(json.String); pv_ok do requested = pv
		}
		_out(fmt.tprintf(
			`{{"jsonrpc":"2.0","id":%s,"result":{{"protocolVersion":"%s","capabilities":{{"tools":{{"listChanged":true}}}},"serverInfo":{{"name":"moonhug-editor","version":"0.1.0"}}}}}}`,
			id_text, requested))
	case "notifications/initialized", "notifications/cancelled", "notifications/roots/list_changed":
		// fire-and-forget
	case "ping":
		_out(fmt.tprintf(`{{"jsonrpc":"2.0","id":%s,"result":{{}}}}`, id_text))
	case "tools/list":
		_tools_list(id_text)
	case "tools/call":
		params, _ := obj["params"].(json.Object)
		_tools_call(id_text, params)
	case:
		if has_id {
			_out(fmt.tprintf(`{{"jsonrpc":"2.0","id":%s,"error":{{"code":-32601,"message":"method not found: %s"}}}}`, id_text, method))
		}
	}
}

_tools_list :: proc(id_text: string) {
	result, err_msg := _editor_call("describe", "{}")
	if err_msg != "" {
		// No editor: an empty tool list keeps the session alive; the client
		// re-lists later and finds the tools once the editor is up.
		_logf("tools/list without editor: %s", err_msg)
		_out(fmt.tprintf(`{{"jsonrpc":"2.0","id":%s,"result":{{"tools":[]}}}}`, id_text))
		return
	}
	_out(fmt.tprintf(`{{"jsonrpc":"2.0","id":%s,"result":{{"tools":%s}}}}`, id_text, result))
}

_tools_call :: proc(id_text: string, params: json.Object) {
	name, n_ok := params["name"].(json.String)
	if !n_ok {
		_tool_error(id_text, "tools/call needs params.name")
		return
	}
	args_text := "{}"
	if args, has := params["arguments"]; has {
		if _, is_o := args.(json.Object); is_o do args_text = _value_text(args)
	}

	result, err_msg := _editor_call(name, args_text)
	if err_msg != "" {
		_tool_error(id_text, err_msg)
		return
	}

	// Result → MCP content. A result carrying image_base64 becomes text +
	// image blocks, with the blob stripped from the text copy.
	rval, rerr := json.parse(transmute([]u8)result, allocator = context.temp_allocator)
	image_b64, image_mime: string
	text := result
	if rerr == nil {
		if robj, is_o := rval.(json.Object); is_o {
			if b64, has := robj["image_base64"].(json.String); has {
				image_b64 = b64
				image_mime = "image/png"
				if m, m_has := robj["image_mime"].(json.String); m_has do image_mime = m
				delete_key(&robj, "image_base64")
				delete_key(&robj, "image_mime")
				text = _value_text(robj)
			}
		}
	}

	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"jsonrpc":"2.0","id":%s,"result":{{"content":[{{"type":"text","text":`, id_text)
	_write_json_string(&b, text)
	strings.write_byte(&b, '}')
	if image_b64 != "" {
		fmt.sbprintf(&b, `,{{"type":"image","data":"%s","mimeType":"%s"}}`, image_b64, image_mime)
	}
	strings.write_string(&b, `]}}`)
	_out(strings.to_string(b))
}

// MCP tool-level failure: isError result, not a protocol error — the model
// sees the message and can act on it (retry, fix arguments).
_tool_error :: proc(id_text: string, message: string) {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"jsonrpc":"2.0","id":%s,"result":{{"isError":true,"content":[{{"type":"text","text":`, id_text)
	_write_json_string(&b, message)
	strings.write_string(&b, `}]}}`)
	_out(strings.to_string(b))
}

// --- Editor link -----------------------------------------------------------------

_disconnect :: proc() {
	if _shim.connected do net.close(_shim.sock)
	_shim.connected = false
	clear(&_shim.fb.data)
}

_connect :: proc() -> (err_msg: string) {
	if _shim.connected do return ""

	data, rerr := os.read_entire_file(_shim.bridge_path, context.temp_allocator)
	if rerr != nil {
		return "MoonHug editor is not running (no bridge file) — start the editor and retry in a few seconds"
	}
	info: mcp.Bridge_Info
	if json.unmarshal(data, &info, allocator = context.temp_allocator) != nil || info.port == 0 {
		return "bridge file unreadable — editor restarting? retry in a few seconds"
	}

	sock, derr := net.dial_tcp_from_endpoint(net.Endpoint{address = net.IP4_Loopback, port = info.port})
	if derr != nil {
		return "MoonHug editor is not reachable (stale bridge file?) — start the editor and retry in a few seconds"
	}
	_ = net.set_option(sock, .Receive_Timeout, EDITOR_CALL_TIMEOUT)

	// Handshake line, then token auth.
	line: [64]u8
	got := 0
	for got < len(line) {
		n, lerr := net.recv_tcp(sock, line[got:got + 1])
		if lerr != nil || n == 0 {
			net.close(sock)
			return "editor handshake failed"
		}
		if line[got] == '\n' {
			got += 1
			break
		}
		got += 1
	}
	if string(line[:got]) != mcp.HANDSHAKE {
		net.close(sock)
		return fmt.tprintf("editor protocol mismatch (expected %q)", strings.trim_space(mcp.HANDSHAKE))
	}

	_shim.sock = sock
	_shim.connected = true
	auth := fmt.tprintf(`{{"token":"%s"}}`, info.token)
	if !mcp.write_frame(sock, transmute([]u8)auth) {
		_disconnect()
		return "editor auth send failed"
	}
	reply, ok := _read_frame()
	if !ok || !strings.contains(string(reply), `"ok":true`) {
		_disconnect()
		return "editor rejected the auth token (stale bridge file?) — retry in a few seconds"
	}
	_logf("connected to editor on port %d", info.port)
	return ""
}

// One complete frame from the editor (blocking, Receive_Timeout-bounded).
_read_frame :: proc() -> ([]u8, bool) {
	buf: [65536]u8
	for {
		payload, ok, malformed := mcp.frame_buffer_next(&_shim.fb)
		if malformed {
			_disconnect()
			return nil, false
		}
		if ok do return payload, true
		n, rerr := net.recv_tcp(_shim.sock, buf[:])
		if rerr != nil || n == 0 {
			_disconnect()
			return nil, false
		}
		mcp.frame_buffer_push(&_shim.fb, buf[:n])
	}
}

// Sends one tool request and returns the matching result JSON text. err_msg
// is human-readable and pre-phrased for the model (includes retry guidance).
// Serialized against the watcher thread by link_mutex.
_editor_call :: proc(tool: string, params_json: string) -> (result: string, err_msg: string) {
	sync.mutex_guard(&_shim.link_mutex)
	if msg := _connect(); msg != "" do return "", msg

	_shim.next_id += 1
	req_id := _shim.next_id
	req := fmt.tprintf(`{{"id":%d,"tool":"%s","params":%s}}`, req_id, tool, params_json)
	if !mcp.write_frame(_shim.sock, transmute([]u8)req) {
		_disconnect()
		return "", "editor connection lost while sending — retry in a few seconds"
	}

	for {
		payload, ok := _read_frame()
		if !ok {
			return "", "editor connection lost while waiting (editor closed or busy >30s) — retry in a few seconds"
		}
		val, jerr := json.parse(payload, allocator = context.temp_allocator)
		mcp.frame_buffer_consume(&_shim.fb)
		if jerr != nil do continue
		obj, is_o := val.(json.Object)
		if !is_o do continue
		id_f: i64
		#partial switch idv in obj["id"] {
		case json.Integer:
			id_f = idv
		case json.Float:
			id_f = i64(idv)
		}
		if id_f != req_id do continue

		status, _ := obj["status"].(json.String)
		if status == "ok" {
			r, has := obj["result"]
			if !has do return "{}", ""
			return _value_text(r), ""
		}
		if eobj, e_ok := obj["error"].(json.Object); e_ok {
			code, _ := eobj["code"].(json.String)
			message, _ := eobj["message"].(json.String)
			return "", fmt.tprintf("editor error [%s]: %s", code, message)
		}
		return "", "editor returned a malformed response"
	}
}
