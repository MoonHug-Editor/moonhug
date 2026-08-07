# MCP Bridge

Agent access to the running editor over [MCP](https://modelcontextprotocol.io). Two processes, no external dependencies:

- **Editor side** (`editor/mcp_bridge.odin`) — a loopback TCP endpoint inside the editor. Threadless: `mcp_bridge_tick` polls a non-blocking socket once per frame right after `gfx.frame_begin`, so every tool runs on the main thread with full editor/engine API access. Listens on the first free port from 6600, writes `Library/StateCache/mcp_bridge.json` (port, pid, auth token) and removes it on shutdown.
- **Shim** (`mcp_shim/`, built to `builds/mcp_shim`) — an MCP stdio server the client spawns (`.mcp.json` → `run_mcp_shim.sh`). It discovers the editor through the bridge file, authenticates with the token, and translates MCP JSON-RPC to the wire protocol. The shim owns session stability: when the editor is down or restarts, tool calls return a retry hint and the MCP session survives.

## Wire protocol (`moonhug/mcp`)

Length-prefixed frames (4-byte big-endian size + JSON, 16 MB cap) after a `WELCOME MOONHUG-MCP 1` handshake line. The client's first frame must carry the bridge-file token. Envelope: `{id, tool, params}` → `{id, status, result}` or `{id, status: "error", error: {code, message, retry_after_ms}}`. One client at a time — a new connection replaces the previous one.

## Tools

- `editor_state` — active scene, simulate state, selection
- `read_log` — recent console entries
- `scene_dump` — scene summary (roots, counts, selection), `full=true` for the complete serialized scene
- `list_menus` / `invoke_menu` — enumerate and invoke menu actions by path (same code path as clicking)
- `editor_setting` — read all editor settings, or set one scalar field
- `screenshot` — a view's render target (scene or game). The tick runs before views draw, so the RT holds the previous frame's submitted contents and is read back asynchronously (fence polled per tick, response sent when pixels land). Full-resolution PNG goes to `Library/Screenshots/`, a downscaled copy (default ≤640px) returns inline as MCP image content.

Tool metadata lives editor-side (the `describe` command) — the shim forwards it as `tools/list`, so adding a tool touches only `mcp_bridge.odin`.

## TODO

- write tools (create entity, set component property) routed through undo commands, shared foundation with inspector multiedit
- argv mode on the shim binary (`moonhug` CLI front-end over the same socket)
- pending/poll envelope for operations spanning many seconds
