package editor

// Bridge tools over the editor's commands (editor/keymap, docs/core/Keymaps.md):
// list them with their bindings, run one by id or name.

import "core:encoding/json"
import "core:strings"
import mcp "moonhug:editor/mcp"
import "moonhug:editor/keymap"

@(mcp_tool={description="The editor's commands: id, name, help, whether each can run now and why not, its key bindings with the keymap each applies in, and for a command with arguments the values it runs with next. `filter` keeps the commands whose id or name contains it, case ignored.",
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
		help:     string,
		enabled:  bool,
		reason:   string, // why it cannot run now, "" when it can or its enabled proc gives no reason
		bindings: []Bound,
		args:     json.Value, // a command with arguments: the values it runs with next, null otherwise
	}
	out := make([dynamic]Entry, context.temp_allocator)
	for c in keymap.commands() {
		if filter != "" && !strings.contains(strings.to_lower(c.id, context.temp_allocator), filter) && !strings.contains(strings.to_lower(c.name, context.temp_allocator), filter) do continue
		bound := make([dynamic]Bound, context.temp_allocator)
		for km in keymap.keymaps() do for &b in km.bindings do if keymap.binding_command(&b) == c {
			append(&bound, Bound{keymap = km.name, chord = b.text})
		}
		enabled, reason := keymap.command_state(c)
		args: json.Value
		if data := keymap.command_args_json(c); data != nil {
			args, _ = json.parse(data, .JSON, true, context.temp_allocator)
		}
		append(&out, Entry{id = c.id, name = c.name, help = c.help, enabled = enabled, reason = reason, bindings = bound[:], args = args})
	}
	return mcp.tool_ok(struct {
		commands: []Entry,
		count:    int,
	}{commands = out[:], count = len(out)})
}

@(mcp_tool={description="Runs an editor command by id or name (`commands` lists them), as its key or menu item would. A disabled command is refused. A command with arguments takes `args`, the fields to change from the values it runs with next, and opens its settings panel as its key does.",
	param_command="string!:The command's id or name",
	param_args="object:For a command with arguments: the fields to set before it runs, the rest keep their values"})
mcp_tool_run_command :: proc(id: i64, params: json.Object) -> (string, mcp.Tool_Error) {
	key := _param_string(params, "command")
	c := keymap.command(key)
	if c == nil do return mcp.tool_fail("not_found", "no command %q", key)
	if enabled, reason := keymap.command_state(c); !enabled {
		if reason != "" do return mcp.tool_fail("disabled", "command %q cannot run now: %s", c.name, reason)
		return mcp.tool_fail("disabled", "command %q cannot run now", c.name)
	}
	if v, has := params["args"]; has {
		if c.args == nil do return mcp.tool_fail("bad_args", "command %q takes no arguments", c.name)
		data, merr := json.marshal(v, {spec = .JSON}, context.temp_allocator)
		if merr != nil || !keymap.command_args_set_json(c, data) {
			return mcp.tool_fail("bad_args", "args do not fit command %q: %s", c.name, string(keymap.command_args_json(c)))
		}
	}
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
