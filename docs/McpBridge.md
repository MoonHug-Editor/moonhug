# MCP Bridge

Agent access to the running editor over [MCP](https://modelcontextprotocol.io). Two processes, no external dependencies:

- **Editor side** (`editor/mcp_bridge.odin`) — a loopback TCP endpoint inside the editor. Threadless: `mcp_bridge_tick` polls a non-blocking socket once per frame right after `gfx.frame_begin`, so every tool runs on the main thread with full editor/engine API access. Listens on the first free port from 6600, writes `library/state_cache/mcp_bridge.json` (port, pid, auth token) and removes it on shutdown.
- **Shim** (`mcp_shim/`, built to `builds/mcp_shim`) — an MCP stdio server the client spawns (`.mcp.json` → `run_mcp_shim.sh`). It discovers the editor through the bridge file, authenticates with the token, and translates MCP JSON-RPC to the wire protocol. The shim owns session stability: when the editor is down or restarts, tool calls return a retry hint and the MCP session survives.

## Wire protocol (`editor/mcp`)

Length-prefixed frames (4-byte big-endian size + JSON, 16 MB cap) after a `WELCOME MOONHUG-MCP 1` handshake line. The client's first frame must carry the bridge-file token. Envelope: `{id, tool, params}` → `{id, status, result}` or `{id, status: "error", error: {code, message, retry_after_ms}}`. One client at a time — a new connection replaces the previous one.

## Declaring a tool

`mcp_tool_gen` scans the attribute and emits `mcp_tools_generated.odin`, so the schema the agent reads comes from the same declaration:

```odin
@(mcp_tool={
    description="Rename one object. One undo step.",
    param_local_id="integer:Object local_id from list_objects",
    param_new_name="string!:The new name",
})
mcp_tool_rename_object :: proc(id: i64, params: json.Object) -> (string, Mcp_Error) { ... }
```

- `mcp_tool_<name>` — the tool name is the proc name minus prefix
- `param_<name>` — field is `"<string|integer|number|boolean>[!]:<description>"`, where `!` marks it required. Append `[]` to the type for an array (`"integer[]:..."`), which emits the JSON Schema `items` sub-object.
- handler returns marshaled JSON (`_mcp_ok`) or an error (`_mcp_fail`).
- returning `MCP_DEFERRED` means the handler answers later itself (screenshots do this while the GPU readback fence settles).

## Tools

- `editor_state` — active scene, simulate state, selection (names and `local_id`s, since names repeat)
- `read_log` — recent console entries
- `scene_dump` — scene summary (roots, counts, selection), `full=true` for the complete serialized scene
- `list_objects` — every object in the scene: name, parent, world position, components, and the `local_id` used to address one
- `list_menus` / `invoke_menu` — enumerate and invoke menu actions by path (same code path as clicking)
- `select` — build a selection: `local_ids` for an exact set (this is how a multi-selection is made, which is what the inspector multi-edits), `name` for every object with that name, `add=true` to extend the current one, empty to clear
- `set_transform` — position, rotation (euler degrees) or scale on one object. Omitted components keep their value
- `rename_object` — rename one object
- `editor_setting` — read all editor settings, or set one scalar field
- `screenshot` — full-resolution PNG to `library/screenshots/`, plus a downscaled copy (default ≤640px) inline as MCP image content. Three views:
  - `scene` (default) / `game` — that view's render target. The tick runs before views draw, so the RT holds the previous frame's submitted contents and is read back asynchronously (fence polled per tick, response sent when pixels land).
  - `editor` — the whole editor window, imgui panels included (inspector, hierarchy, console). Those panels draw straight to the swapchain and never reach a render target, so this copies the swapchain image itself (`gfx.swapchain_capture`). The copy runs **only on frames a screenshot was asked for**, after the UI pass has drawn and while the command buffer is still open — so there is no per-frame cost for a feature used occasionally, and no OS screen-recording permission, since a swapchain image contains nothing but the editor's own window. The request is queued by the tool and serviced at end of frame, because the bridge tick runs before the UI draws.

Objects are addressed by `local_id` (from `list_objects`) or exact name. An ambiguous name is an error naming the count, and lookups are outer-transform only, so nested-scene contents are never mutated through the bridge.

## Enabling

One switch, Edit ▸ Project Settings ▸ MCP (`enabled`, persisted to `ProjectSettings/mcp.json`, on by default, applied at editor start). Off means the editor never opens the socket and removes its bridge file, so no agent can reach it by any tool — enforceable with no per-tool knowledge and nothing a developer can forget to declare.

Editing tools go through the editor's own undo stack, so an agent edit is Ctrl+Z-able and indistinguishable from a manual one. Combined with loopback-only binding and a per-session token, anything it touches is visible and reversible.

## TODO

- component property writes (needs the reflection-driven path the inspector uses, shared with multiedit)
- argv mode on the shim binary (`moonhug` CLI front-end over the same socket)
- pending/poll envelope for operations spanning many seconds
