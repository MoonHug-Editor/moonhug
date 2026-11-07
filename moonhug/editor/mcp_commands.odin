package editor

// Bridge tools over the editor's commands (editor/keymap, docs/core/Keymaps.md):
// list them with their bindings, run one by id or name.

import "core:encoding/json"
import "core:strings"
import mcp "moonhug:editor/mcp"
import "moonhug:editor/keymap"

@(mcp_tool={description="The editor's commands: id, name, whether each can run now, and its key bindings with the keymap each applies in. `filter` keeps the commands whose id or name contains it, case ignored.",
	param_filter="string:Substring of the id or name, case ignored"})
mcp_tool_commands :: proc(id: i64, params: json.Object) -> (string, mcp.Tool_Error) {
	filter := strings.to_lower(_param_string(params, "filter"), context.temp_allocator)
	Bound :: struct {
		keymap: string,
		chord:  string,
	}
	Entry :: struct {
		id:       string,
		name:     string,
		enabled:  bool,
		bindings: []Bound,
	}
	out := make([dynamic]Entry, context.temp_allocator)
	for c in keymap.commands() {
		if filter != "" && !strings.contains(strings.to_lower(c.id, context.temp_allocator), filter) && !strings.contains(strings.to_lower(c.name, context.temp_allocator), filter) do continue
		bound := make([dynamic]Bound, context.temp_allocator)
		for km in keymap.keymaps() do for &b in km.bindings do if keymap.binding_is(&b, c.id) {
			append(&bound, Bound{keymap = km.name, chord = b.text})
		}
		append(&out, Entry{id = c.id, name = c.name, enabled = keymap.command_enabled(c), bindings = bound[:]})
	}
	return mcp.tool_ok(struct {
		commands: []Entry,
		count:    int,
	}{commands = out[:], count = len(out)})
}

@(mcp_tool={description="Runs an editor command by id or name (`commands` lists them), as its key or menu item would. A disabled command is refused.",
	param_command="string!:The command's id or name"})
mcp_tool_run_command :: proc(id: i64, params: json.Object) -> (string, mcp.Tool_Error) {
	key := _param_string(params, "command")
	c := keymap.command(key)
	if c == nil do return mcp.tool_fail("not_found", "no command %q", key)
	if !keymap.command_enabled(c) do return mcp.tool_fail("disabled", "command %q cannot run now", c.name)
	keymap.command_run(c)
	return mcp.tool_ok(struct {
		id:   string,
		name: string,
	}{id = c.id, name = c.name})
}

// A string parameter, "" when absent or not a string.
@(private = "file")
_param_string :: proc(params: json.Object, key: string) -> string {
	if v, ok := params[key]; ok {
		if str, is_str := v.(json.String); is_str do return string(str)
	}
	return ""
}
