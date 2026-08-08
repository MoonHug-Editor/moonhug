package tests

// Framing layer of the MCP bridge wire protocol (moonhug/mcp): length-
// prefixed frames accumulated from arbitrary recv chunk boundaries.

import "core:testing"
import mcp "moonhug:editor/mcp"

@(private = "file")
_frame_bytes :: proc(payload: string, allocator := context.temp_allocator) -> []u8 {
	out := make([dynamic]u8, 0, 4 + len(payload), allocator)
	n := u32(len(payload))
	append(&out, u8(n >> 24), u8(n >> 16), u8(n >> 8), u8(n))
	append(&out, ..transmute([]u8)payload)
	return out[:]
}

@(test)
test_mcp_frame_roundtrip :: proc(t: ^testing.T) {
	fb: mcp.Frame_Buffer
	defer mcp.frame_buffer_destroy(&fb)

	mcp.frame_buffer_push(&fb, _frame_bytes(`{"id":1}`))
	payload, ok, malformed := mcp.frame_buffer_next(&fb)
	testing.expect(t, ok && !malformed)
	testing.expect_value(t, string(payload), `{"id":1}`)
	mcp.frame_buffer_consume(&fb)

	_, ok2, _ := mcp.frame_buffer_next(&fb)
	testing.expect(t, !ok2, "buffer should be empty after consume")
}

@(test)
test_mcp_frame_partial_and_coalesced :: proc(t: ^testing.T) {
	fb: mcp.Frame_Buffer
	defer mcp.frame_buffer_destroy(&fb)

	// Two frames arriving as three arbitrary chunks.
	a := _frame_bytes("hello")
	b := _frame_bytes("world!")
	both := make([dynamic]u8, context.temp_allocator)
	append(&both, ..a)
	append(&both, ..b)

	mcp.frame_buffer_push(&fb, both[:3]) // header split mid-way
	_, ok, _ := mcp.frame_buffer_next(&fb)
	testing.expect(t, !ok, "incomplete header yields nothing")

	mcp.frame_buffer_push(&fb, both[3:12])
	payload, ok1, _ := mcp.frame_buffer_next(&fb)
	testing.expect(t, ok1)
	testing.expect_value(t, string(payload), "hello")
	mcp.frame_buffer_consume(&fb)

	_, ok2, _ := mcp.frame_buffer_next(&fb)
	testing.expect(t, !ok2, "second frame incomplete")

	mcp.frame_buffer_push(&fb, both[12:])
	payload2, ok3, _ := mcp.frame_buffer_next(&fb)
	testing.expect(t, ok3)
	testing.expect_value(t, string(payload2), "world!")
}

@(test)
test_mcp_frame_malformed :: proc(t: ^testing.T) {
	fb: mcp.Frame_Buffer
	defer mcp.frame_buffer_destroy(&fb)

	// Zero-length frame is a protocol violation.
	mcp.frame_buffer_push(&fb, []u8{0, 0, 0, 0})
	_, _, malformed := mcp.frame_buffer_next(&fb)
	testing.expect(t, malformed)

	clear(&fb.data)
	// Oversized length prefix likewise.
	mcp.frame_buffer_push(&fb, []u8{0xFF, 0xFF, 0xFF, 0xFF})
	_, _, malformed2 := mcp.frame_buffer_next(&fb)
	testing.expect(t, malformed2)
}
