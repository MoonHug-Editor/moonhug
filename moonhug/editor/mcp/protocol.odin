package mcp

// Wire protocol shared by the editor's MCP bridge and the mcp_shim binary
// (docs/McpBridge.md). The editor listens on loopback TCP and speaks a plain
// envelope — the shim translates it to MCP proper for the client.
//
// Wire format, both directions after the handshake:
//   [4-byte big-endian u32 payload length][UTF-8 JSON payload]
// On accept the editor sends the HANDSHAKE line (newline-terminated, read
// with read_line before any frame). The client's first frame must be
// {"token":"<token>"} matching the bridge file; the editor answers
// {"ok":true} or closes.
//
// Requests:  {"id":N, "tool":"name", "params":{...}}
// Responses: {"id":N, "status":"ok",    "result":{...}}
//            {"id":N, "status":"error", "error":{"code","message","retry_after_ms"?}}

import "core:encoding/json"
import "core:net"

HANDSHAKE :: "WELCOME MOONHUG-MCP 1\n"
MAX_FRAME :: 16 * 1024 * 1024

// Written by the editor next to its other session state; the shim reads it
// to find and authenticate to the running editor. Paths are cwd-relative:
// the editor runs from moonhug/, the shim from the repo root.
BRIDGE_FILE_FROM_EDITOR :: "library/state_cache/mcp_bridge.json"
BRIDGE_FILE_FROM_ROOT :: "moonhug/library/state_cache/mcp_bridge.json"

Bridge_Info :: struct {
	port:    int,
	pid:     int,
	token:   string,
	project: string,
}

Request :: struct {
	id:     i64,
	tool:   string,
	params: json.Object,
}

Wire_Error :: struct {
	code:           string,
	message:        string,
	retry_after_ms: int `json:"retry_after_ms,omitempty"`,
}

// Sends one length-prefixed frame. The socket must be in blocking mode for
// the duration (partial sends are looped until done).
write_frame :: proc(sock: net.TCP_Socket, payload: []u8) -> bool {
	if len(payload) > MAX_FRAME do return false
	header: [4]u8
	n := u32(len(payload))
	header[0] = u8(n >> 24)
	header[1] = u8(n >> 16)
	header[2] = u8(n >> 8)
	header[3] = u8(n)
	if !send_all(sock, header[:]) do return false
	return send_all(sock, payload)
}

// Raw send loop, used for the handshake line (frames go through write_frame).
send_all :: proc(sock: net.TCP_Socket, data: []u8) -> bool {
	sent := 0
	for sent < len(data) {
		n, err := net.send_tcp(sock, data[sent:])
		if err != nil do return false
		if n <= 0 do return false
		sent += n
	}
	return true
}

// Accumulates received bytes and yields complete frames. Push whatever a
// recv returned, then drain with next until it reports no frame.
Frame_Buffer :: struct {
	data: [dynamic]u8,
}

frame_buffer_destroy :: proc(fb: ^Frame_Buffer) {
	delete(fb.data)
	fb.data = nil
}

frame_buffer_push :: proc(fb: ^Frame_Buffer, bytes: []u8) {
	append(&fb.data, ..bytes)
}

// The returned payload is a view into the buffer, valid until the next push
// or next call — consume (parse/copy) before continuing. malformed=true means
// the peer violated the protocol (oversized/zero frame): close the connection.
frame_buffer_next :: proc(fb: ^Frame_Buffer) -> (payload: []u8, ok: bool, malformed: bool) {
	if len(fb.data) < 4 do return
	n := u32(fb.data[0]) << 24 | u32(fb.data[1]) << 16 | u32(fb.data[2]) << 8 | u32(fb.data[3])
	if n == 0 || n > MAX_FRAME do return nil, false, true
	total := 4 + int(n)
	if len(fb.data) < total do return
	payload = fb.data[4:total]
	return payload, true, false
}

// Removes the frame returned by the last successful next.
frame_buffer_consume :: proc(fb: ^Frame_Buffer) {
	if len(fb.data) < 4 do return
	n := u32(fb.data[0]) << 24 | u32(fb.data[1]) << 16 | u32(fb.data[2]) << 8 | u32(fb.data[3])
	total := min(4 + int(n), len(fb.data))
	remove_range(&fb.data, 0, total)
}
