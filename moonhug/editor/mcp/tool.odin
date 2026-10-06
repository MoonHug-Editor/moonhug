package mcp

// What a tool handler returns, and the helpers every handler uses. The bridge
// (editor/mcp_bridge.odin) dispatches to handlers in the shell, in the engine's
// editor half and in plugins, so the handler vocabulary lives here, where all
// of them can import it.

import "core:encoding/json"
import "core:fmt"

// A handler returns (result_json, error). A zero error means the result is
// sent as-is.
Tool_Error :: struct {
	code:    string, // "" = success
	message: string,
}

// A handler that answers on its own schedule (across frames) returns this.
DEFERRED :: "\x00deferred"

// Marshals `v` as the tool's result.
tool_ok :: proc(v: any) -> (string, Tool_Error) {
	data, merr := json.marshal(v, {}, context.temp_allocator)
	if merr != nil do return "", Tool_Error{"marshal_failed", fmt.tprintf("%v", merr)}
	return string(data), {}
}

tool_fail :: proc(code: string, format: string, args: ..any) -> (string, Tool_Error) {
	return "", Tool_Error{code, fmt.tprintf(format, ..args)}
}

// Integer param. json numbers parse as Integer OR Float depending on the literal.
json_int :: proc(obj: json.Object, key: string, fallback: i64) -> i64 {
	#partial switch v in obj[key] {
	case json.Integer:
		return v
	case json.Float:
		return i64(v)
	}
	return fallback
}

// Optional float param: missing keys leave the caller's current value.
json_f32 :: proc(obj: json.Object, key: string) -> (f32, bool) {
	#partial switch v in obj[key] {
	case json.Integer:
		return f32(v), true
	case json.Float:
		return f32(v), true
	}
	return 0, false
}
