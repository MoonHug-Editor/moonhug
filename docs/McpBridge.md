# MCP Bridge

Agent access to the running editor over [MCP](https://modelcontextprotocol.io). Two processes, no external dependencies:

- **Editor side** (`editor/mcp_bridge.odin`) — a loopback TCP endpoint inside the editor. Threadless: `mcp_bridge_tick` polls a non-blocking socket once per frame right after `gfx.frame_begin`, so every tool runs on the main thread with full editor/engine API access. Listens on the first free port from 6600, writes `Library/StateCache/mcp_bridge.json` (port, pid, auth token) and removes it on shutdown.
- **Shim** (`mcp_shim/`, built to `builds/mcp_shim`) — an MCP stdio server the client spawns (`.mcp.json` → `run_mcp_shim.sh`). It discovers the editor through the bridge file, authenticates with the token, and translates MCP JSON-RPC to the wire protocol. The shim owns session stability: when the editor is down or restarts, tool calls return a retry hint and the MCP session survives.

## Wire protocol (`moonhug/mcp`)

Length-prefixed frames (4-byte big-endian size + JSON, 16 MB cap) after a `WELCOME MOONHUG-MCP 1` handshake line. The client's first frame must carry the bridge-file token. Envelope: `{id, tool, params}` → `{id, status, result}` or `{id, status: "error", error: {code, message, retry_after_ms}}`. One client at a time — a new connection replaces the previous one.

## Declaring a tool

Tools are declarations, not registrations — `mcp_tool_gen` scans the attribute and emits `mcp_tools_generated.odin`, so the schema the agent reads comes from the same declaration as the handler and cannot drift:

```odin
@(mcp_tool={
    description="Rename one object. One undo step.",
    param_local_id="integer:Object local_id from list_objects",
    param_new_name="string!:The new name",
})
mcp_tool_rename_object :: proc(id: i64, params: json.Object) -> (string, Mcp_Error) { ... }
```

The tool name is the proc name minus `mcp_tool_`. Each `param_<name>` field is `"<string|integer|number|boolean>[!]:<description>"`, where `!` marks it required. A handler returns marshaled JSON (`_mcp_ok`) or an error (`_mcp_fail`); returning `MCP_DEFERRED` means the handler answers later itself (screenshots do this while the GPU readback fence settles).

A tool declares WHAT it takes, never what it touches. There is deliberately no per-tool read/write classification: such a flag is hand-typed, so it needs a developer to correctly judge every tool (and every later refactor of one), and a mislabeled tool would sneak past whatever it gated. Access is all-or-nothing at the endpoint instead — see Enabling below.

## Tools

- `editor_state` — active scene, simulate state, selection
- `read_log` — recent console entries
- `scene_dump` — scene summary (roots, counts, selection), `full=true` for the complete serialized scene
- `list_objects` — every object in the scene: name, parent, world position, components, and the `local_id` used to address one
- `list_menus` / `invoke_menu` — enumerate and invoke menu actions by path (same code path as clicking)
- `select` — select objects by name, or clear the selection
- `set_transform` — position, rotation (euler degrees) or scale on one object; omitted components keep their value
- `rename_object` — rename one object
- `editor_setting` — read all editor settings, or set one scalar field
- `screenshot` — a view's render target (scene or game). The tick runs before views draw, so the RT holds the previous frame's submitted contents and is read back asynchronously (fence polled per tick, response sent when pixels land). Full-resolution PNG goes to `Library/Screenshots/`, a downscaled copy (default ≤640px) returns inline as MCP image content.

Objects are addressed by `local_id` (from `list_objects`) or exact name; an ambiguous name is an error naming the count, and lookups are outer-transform only, so nested-scene contents are never mutated through the bridge.

## Enabling

One switch, Edit ▸ Project Settings ▸ MCP (`enabled`, persisted to `ProjectSettings/mcp.json`, on by default, applied at editor start). Off means the editor never opens the socket and removes its bridge file, so no agent can reach it by any tool — enforceable with no per-tool knowledge and nothing a developer can forget to declare.

Editing tools go through the editor's own undo stack, so an agent edit is Ctrl+Z-able and indistinguishable from a manual one. Combined with loopback-only binding and a per-session token, that is the safety story: not a promise that a given tool won't touch anything, but that anything it touches is visible and reversible.

## TODO

- component property writes (needs the reflection-driven path the inspector uses; shares its foundation with multiedit)
- argv mode on the shim binary (`moonhug` CLI front-end over the same socket)
- pending/poll envelope for operations spanning many seconds
