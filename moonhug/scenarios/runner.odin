package scenarios

// Editor scenarios (docs/core/Scenarios.md): tests that start the real editor
// on a project of their own, drive it through its MCP bridge
// (docs/core/McpBridge.md), and check what it answers and what it saves.
// They cover what a unit test cannot reach: windows drawn by imgui, a restart,
// the files a quit writes.
//
//   - A scenario is a @(test) proc of this package that calls begin(t) first.
//     `mh scenarios` builds the editor and runs the package with `odin test`.
//     `--name=<test>` runs one, `--show` gives the editor a window on screen,
//     which is hidden otherwise (the editor's --hidden).
//   - begin gives the scenario a new, empty project in
//     builds/scenarios/<test name>, which stays after the run with the
//     editor's output in run.log, and registers the end of the run: an editor
//     still running is killed, whatever the scenario did.
//   - The editor answers one bridge call per frame, so a call is also a
//     frame: `frames` waits that way.
//   - A lost editor (it crashed, a call got no answer) ends the scenario at
//     once (testing.fail_now).
//
// It imports only the bridge's wire protocol, so it builds without the
// editor's packages. This file is the editor part. The scenarios are in the
// files beside it.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"
import mcp "moonhug:editor/mcp"

EDITOR_BIN :: "builds/MoonHug" + (".exe" when ODIN_OS == .Windows else "")
PROJECTS_DIR :: "builds/scenarios"
BRIDGE_FILE :: mcp.BRIDGE_FILE_FROM_EDITOR
START_TIMEOUT :: 30 * time.Second
CALL_TIMEOUT :: 30 * time.Second
QUIT_TIMEOUT :: 15 * time.Second
SCENARIO_TIMEOUT :: 3 * time.Minute

// `mh scenarios --show` sets it: the editor's window is on screen.
SHOW :: #config(SCENARIOS_SHOW, false)

// One scenario's run: its project and the editor it drives.
Run :: struct {
	t:       ^testing.T,
	project: string, // absolute, owned
	bin:     string, // the editor binary, absolute, owned

	process:   os.Process,
	running:   bool,
	sock:      net.TCP_Socket,
	connected: bool,
	fb:        mcp.Frame_Buffer,
	next_id:   i64,
}

// Starts a scenario: a new, empty project named after the calling test, and
// the end of the run registered with the test. Call it first.
begin :: proc(t: ^testing.T, loc := #caller_location) -> ^Run {
	testing.set_fail_timeout(t, SCENARIO_TIMEOUT)
	cwd, cerr := os.get_working_directory(context.temp_allocator)
	if cerr != nil do testing.fail_now(t, fmt.tprintf("cannot read the working directory: %v", cerr), loc)
	if !os.exists(EDITOR_BIN) do testing.fail_now(t, fmt.tprintf("%s is not built: run `mh scenarios` from the repo root", EDITOR_BIN), loc)
	r := new(Run)
	r.t = t
	r.project, _ = filepath.join({cwd, PROJECTS_DIR, loc.procedure})
	r.bin, _ = filepath.join({cwd, EDITOR_BIN})
	testing.cleanup(t, _end, r)
	_project_make(r, loc)
	return r
}

// The end of a run, whatever the scenario did: the editor it left running is
// killed, and what the run owns is freed.
@(private = "file")
_end :: proc(data: rawptr) {
	r := (^Run)(data)
	_disconnect(r)
	if r.running {
		_ = os.process_kill(r.process)
		_, _ = os.process_wait(r.process, 5 * time.Second)
	}
	if testing.failed(r.t) do log.infof("the project and the editor's run.log are in %s", r.project)
	mcp.frame_buffer_destroy(&r.fb)
	delete(r.project)
	delete(r.bin)
	free(r)
}

// --- The project -------------------------------------------------------------

// A new, empty project for the scenario. What the last run left goes first.
@(private = "file")
_project_make :: proc(r: ^Run, loc: runtime.Source_Code_Location) {
	// Never through a link: remove_all empties what a link points at.
	if info, err := os.lstat(r.project, context.temp_allocator); err == nil {
		if info.type != .Directory do testing.fail_now(r.t, fmt.tprintf("%s is not a directory, it is left alone", r.project), loc)
		if rerr := os.remove_all(r.project); rerr != nil do testing.fail_now(r.t, fmt.tprintf("cannot empty %s: %v", r.project, rerr), loc)
	}
	for dir in ([]string{"assets", "ProjectSettings"}) {
		if err := os.make_directory_all(project_path(r, dir)); err != nil do testing.fail_now(r.t, fmt.tprintf("cannot make %s: %v", project_path(r, dir), err), loc)
	}
}

// The absolute path of `rel` in the scenario's project (temp).
project_path :: proc(r: ^Run, rel: string) -> string {
	p, _ := filepath.join({r.project, rel}, context.temp_allocator)
	return p
}

// Writes a file of the project, making its folders. Before editor_start, it
// is there when the editor first looks.
project_write :: proc(r: ^Run, rel: string, text: string, loc := #caller_location) {
	path := project_path(r, rel)
	_ = os.make_directory_all(filepath.dir(path))
	err := os.write_entire_file(path, transmute([]u8)text)
	testing.expectf(r.t, err == nil, "cannot write %s: %v", rel, err, loc = loc)
}

// Copies a file of the repo (the working directory) into the project, making
// its folders. Before editor_start, it is there when the editor first looks.
project_copy :: proc(r: ^Run, repo_path: string, rel: string, loc := #caller_location) {
	data, err := os.read_entire_file(repo_path, context.temp_allocator)
	if !testing.expectf(r.t, err == nil, "cannot read %s: %v", repo_path, err, loc = loc) do return
	project_write(r, rel, string(data), loc)
}

// A JSON file of the project (temp), nil with a failure when it does not
// read or parse.
project_json :: proc(r: ^Run, rel: string, loc := #caller_location) -> json.Value {
	data, err := os.read_entire_file(project_path(r, rel), context.temp_allocator)
	if !testing.expectf(r.t, err == nil, "cannot read %s: %v", rel, err, loc = loc) do return nil
	v, perr := json.parse(data, .JSON, true, context.temp_allocator)
	if !testing.expectf(r.t, perr == nil, "%s does not parse: %v", rel, perr, loc = loc) do return nil
	return v
}

// --- The editor --------------------------------------------------------------

// Starts the editor on the project and connects to its bridge.
editor_start :: proc(r: ^Run, loc := #caller_location) {
	if r.running do return
	bridge := project_path(r, BRIDGE_FILE)
	_ = os.remove(bridge)
	log, lerr := os.open(project_path(r, "run.log"), {.Write, .Create, .Append}, os.Permissions_Default_File)
	if lerr != nil do _lose(r, loc, "cannot open run.log: %v", lerr)
	defer os.close(log)
	command := make([dynamic]string, context.temp_allocator)
	append(&command, r.bin, fmt.tprintf("--project=%s", r.project))
	if !SHOW do append(&command, "--hidden")
	p, err := os.process_start({command = command[:], working_dir = r.project, stdout = log, stderr = log})
	if err != nil do _lose(r, loc, "cannot start %s: %v", EDITOR_BIN, err)
	r.process = p
	r.running = true

	// The bridge file appears once the editor listens.
	deadline := time.time_add(time.now(), START_TIMEOUT)
	for !os.exists(bridge) {
		if state, werr := os.process_wait(r.process, 50 * time.Millisecond); werr == nil && state.exited {
			r.running = false
			_lose(r, loc, "the editor exited while starting, code %d", state.exit_code)
		}
		if time.diff(time.now(), deadline) < 0 do _lose(r, loc, "the editor wrote no bridge file within %v", START_TIMEOUT)
	}
	if msg := _connect(r, bridge); msg != "" do _lose(r, loc, "%s", msg)
}

// Quits the editor through File/Quit, as a person does, so it saves its
// settings, and waits for it to exit.
editor_quit :: proc(r: ^Run, loc := #caller_location) {
	if !r.running do return
	call(r, "invoke_menu", `{"path":"File/Quit"}`, loc = loc)
	state, werr := os.process_wait(r.process, QUIT_TIMEOUT)
	if werr != nil || !state.exited do _lose(r, loc, "the editor did not exit within %v of File/Quit", QUIT_TIMEOUT)
	r.running = false
	_disconnect(r)
	testing.expectf(r.t, state.exit_code == 0, "the editor exited with code %d", state.exit_code, loc = loc)
}

// Quits and starts again on the same project.
editor_restart :: proc(r: ^Run, loc := #caller_location) {
	editor_quit(r, loc)
	editor_start(r, loc)
}

// Calls a bridge tool with `params` (a JSON object as text) and returns its
// result (temp). A tool error is a failure and gives nil.
call :: proc(r: ^Run, tool: string, params := "{}", loc := #caller_location) -> json.Value {
	result, code, message := call_raw(r, tool, params, loc)
	testing.expectf(r.t, code == "", "%s %s: [%s] %s", tool, params, code, message, loc = loc)
	return result
}

// As call, with the tool's error given back: for a call that is meant to be
// refused. `code` is "" on success.
call_raw :: proc(r: ^Run, tool: string, params := "{}", loc := #caller_location) -> (result: json.Value, code: string, message: string) {
	if !r.connected do _lose(r, loc, "%s: the editor is not started", tool)
	r.next_id += 1
	req := fmt.tprintf(`{{"id":%d,"tool":"%s","params":%s}}`, r.next_id, tool, params)
	if !mcp.write_frame(r.sock, transmute([]u8)req) do _lose(r, loc, "%s: the editor closed the connection", tool)
	for {
		payload, ok := _read_frame(r)
		if !ok do _lose(r, loc, "%s: no answer within %v (the editor crashed or hangs, see run.log)", tool, CALL_TIMEOUT)
		val, jerr := json.parse(payload, .JSON, true, context.temp_allocator)
		mcp.frame_buffer_consume(&r.fb)
		if jerr != nil do continue
		obj, is_obj := val.(json.Object)
		if !is_obj || as_int(obj["id"]) != r.next_id do continue
		if status, _ := obj["status"].(json.String); status == "ok" do return obj["result"], "", ""
		err, _ := obj["error"].(json.Object)
		return nil, as_string(err["code"]), as_string(err["message"])
	}
}

// Lets the editor run `n` frames.
frames :: proc(r: ^Run, n: int, loc := #caller_location) {
	for _ in 0 ..< n do call(r, "read_log", `{"max":0}`, loc)
}

// The editor is gone or cannot be reached: the scenario ends here.
@(private = "file")
_lose :: proc(r: ^Run, loc: runtime.Source_Code_Location, format: string, args: ..any) -> ! {
	testing.fail_now(r.t, fmt.tprintf(format, ..args), loc)
}

@(private = "file")
_disconnect :: proc(r: ^Run) {
	if r.connected do net.close(r.sock)
	r.connected = false
	clear(&r.fb.data)
}

// Dials the bridge the file names: the handshake line, then the token.
@(private = "file")
_connect :: proc(r: ^Run, bridge: string) -> string {
	info: mcp.Bridge_Info
	// The editor may still be writing the file.
	for _ in 0 ..< 40 {
		data, rerr := os.read_entire_file(bridge, context.temp_allocator)
		if rerr == nil && json.unmarshal(data, &info, allocator = context.temp_allocator) == nil && info.port != 0 do break
		time.sleep(50 * time.Millisecond)
	}
	if info.port == 0 do return "the bridge file does not name a port"
	sock, derr := net.dial_tcp_from_endpoint(net.Endpoint{address = net.IP4_Loopback, port = info.port})
	if derr != nil do return fmt.tprintf("cannot reach the bridge on port %d: %v", info.port, derr)
	_ = net.set_option(sock, .Receive_Timeout, CALL_TIMEOUT)
	line: [64]u8
	got := 0
	for got < len(line) {
		n, lerr := net.recv_tcp(sock, line[got:got + 1])
		if lerr != nil || n == 0 {
			net.close(sock)
			return "the bridge sent no handshake"
		}
		got += 1
		if line[got - 1] == '\n' do break
	}
	if string(line[:got]) != mcp.HANDSHAKE {
		net.close(sock)
		return fmt.tprintf("the bridge speaks another protocol (expected %q)", strings.trim_space(mcp.HANDSHAKE))
	}
	r.sock = sock
	r.connected = true
	auth := fmt.tprintf(`{{"token":"%s"}}`, info.token)
	if !mcp.write_frame(sock, transmute([]u8)auth) {
		_disconnect(r)
		return "cannot send the bridge token"
	}
	reply, ok := _read_frame(r)
	accepted := ok && strings.contains(string(reply), `"ok":true`)
	if ok do mcp.frame_buffer_consume(&r.fb)
	if !accepted {
		_disconnect(r)
		return "the bridge refused the token"
	}
	return ""
}

// One whole frame from the editor, false when the connection ended or timed
// out.
@(private = "file")
_read_frame :: proc(r: ^Run) -> ([]u8, bool) {
	buf: [65536]u8
	for {
		payload, ok, malformed := mcp.frame_buffer_next(&r.fb)
		if malformed do return nil, false
		if ok do return payload, true
		n, rerr := net.recv_tcp(r.sock, buf[:])
		if rerr != nil || n == 0 do return nil, false
		mcp.frame_buffer_push(&r.fb, buf[:n])
	}
}

// --- Reading results ---------------------------------------------------------

// The value at `path` under `v`: a string steps into an object by key, an
// int into an array by index. nil when a step does not exist.
at :: proc(v: json.Value, path: ..any) -> json.Value {
	cur := v
	for step in path {
		switch s in step {
		case string:
			obj, ok := cur.(json.Object)
			if !ok do return nil
			cur = obj[s]
		case int:
			arr, ok := cur.(json.Array)
			if !ok || s < 0 || s >= len(arr) do return nil
			cur = arr[s]
		case:
			return nil
		}
	}
	return cur
}

as_string :: proc(v: json.Value) -> string {
	s, _ := v.(json.String)
	return string(s)
}

as_bool :: proc(v: json.Value) -> bool {
	b, _ := v.(json.Boolean)
	return bool(b)
}

as_int :: proc(v: json.Value) -> i64 {
	#partial switch n in v {
	case json.Integer: return n
	case json.Float:   return i64(n)
	}
	return 0
}

as_f64 :: proc(v: json.Value) -> f64 {
	#partial switch n in v {
	case json.Integer: return f64(n)
	case json.Float:   return n
	}
	return 0
}

// Whether the array `v` holds the string `s`.
has_string :: proc(v: json.Value, s: string) -> bool {
	arr, _ := v.(json.Array)
	for e in arr do if as_string(e) == s do return true
	return false
}

// --- Windows -----------------------------------------------------------------

// What the registry holds for the window `key` (the window_state tool).
window_state :: proc(r: ^Run, key: string, loc := #caller_location) -> json.Value {
	return call(r, "window_state", fmt.tprintf(`{{"window":%q}}`, key), loc)
}

window_is_open :: proc(r: ^Run, key: string, loc := #caller_location) -> bool {
	return as_bool(at(window_state(r, key, loc), "open"))
}

// Opens the window `id`, or with `another` one more instance of it, and
// returns the instance's key.
window_open :: proc(r: ^Run, id: string, another := false, loc := #caller_location) -> string {
	res := call(r, "window_open", fmt.tprintf(`{{"id":%q,"another":%v}}`, id, another), loc)
	// A frame for the window to draw: its state exists from its first draw.
	frames(r, 2, loc)
	return strings.clone(as_string(at(res, "window")), context.temp_allocator)
}

// Closes the window `key` and lets the registry take it out.
window_close :: proc(r: ^Run, key: string, loc := #caller_location) {
	call(r, "window_close", fmt.tprintf(`{{"window":%q}}`, key), loc)
	frames(r, 2, loc)
}

// --- Input -------------------------------------------------------------------

// The rectangle of a piece of text or an inspector row drawn in `window`
// (the item_rect tool), in points from the editor's top-left: where input
// moves. False when nothing matches.
item_rect :: proc(r: ^Run, window: string, label: string, loc := #caller_location) -> (rect: [4]f64, ok: bool) {
	res, code, _ := call_raw(r, "item_rect", fmt.tprintf(`{{"window":%q,"label":%q}}`, window, label), loc)
	if code != "" do return {}, false
	m := at(res, "matches", 0)
	if m == nil do return {}, false
	return {as_f64(at(m, "x")), as_f64(at(m, "y")), as_f64(at(m, "width")), as_f64(at(m, "height"))}, true
}

// The rectangle of the window `id` as window_list reports it. False when it
// is not listed (closed, or in a workspace frame).
window_rect :: proc(r: ^Run, id: string, loc := #caller_location) -> (rect: [4]f64, ok: bool) {
	windows, _ := at(call(r, "window_list", loc = loc), "windows").(json.Array)
	for w in windows {
		if as_string(at(w, "id")) != id do continue
		return {as_f64(at(w, "x")), as_f64(at(w, "y")), as_f64(at(w, "width")), as_f64(at(w, "height"))}, true
	}
	return {}, false
}

// A left click at (x, y), as a person makes one: the mouse arrives, rests a
// frame, presses and lets go.
click :: proc(r: ^Run, x, y: f64, loc := #caller_location) {
	call(r, "input", fmt.tprintf(`{{"steps":[{{"type":"move","x":%v,"y":%v}},{{"type":"wait","frames":1}},{{"type":"down"}},{{"type":"up"}},{{"type":"wait","frames":3}}]}}`, x, y), loc)
}

// --- The log -----------------------------------------------------------------

// The editor's console entries at the level Error (temp).
log_errors :: proc(r: ^Run, loc := #caller_location) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	entries, _ := call(r, "read_log", `{"max":500}`, loc).(json.Array)
	for e in entries {
		if as_string(at(e, "level")) == "Error" do append(&out, as_string(at(e, "message")))
	}
	return out[:]
}

// --- Selection ---------------------------------------------------------------

// Selects the asset at `path` in the Project window.
select_asset :: proc(r: ^Run, path: string, loc := #caller_location) {
	call(r, "ping_asset", fmt.tprintf(`{{"path":%q,"select":true}}`, path), loc)
	frames(r, 2, loc)
}
