# MCP Bridge

Agent access to the running editor over [MCP](https://modelcontextprotocol.io). Two processes, no external dependencies:

- **Editor side** (`editor/mcp_bridge.odin`) — a loopback TCP endpoint inside the editor. Threadless: `mcp_bridge_tick` polls a non-blocking socket once per frame right after `gfx.frame_begin`, so every tool runs on the main thread with full editor/engine API access. Listens on the first free port from 6600, writes `library/state_cache/mcp_bridge.json` (port, pid, auth token) and removes it on shutdown.
- **Shim** (`mcp_shim/`, built to `builds/mcp_shim`) — an MCP stdio server the client spawns (`.mcp.json` → `mh mcp`). It discovers the editor through the bridge file, authenticates with the token, and translates MCP JSON-RPC to the wire protocol. The shim owns session stability: when the editor is down or restarts, tool calls return a retry hint and the MCP session survives.

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
- `param_<name>` — field is `"<string|integer|number|boolean>[!]:<description>"`, where `!` marks it required. Append `[]` to the type for an array (`"integer[]:..."`, also `"object[]"` for a list of records), which emits the JSON Schema `items` sub-object.
- handler returns marshaled JSON (`_mcp_ok`) or an error (`_mcp_fail`).
- returning `MCP_DEFERRED` means the handler answers later itself (screenshots do this while the GPU readback fence settles).

## Tools

- `editor_state` — active scene, simulate state, selection (names and `local_id`s, since names repeat)
- `read_log` — recent console entries
- `scene_dump` — scene summary (roots, counts, selection), `full=true` for the complete serialized scene. A full dump is the whole file, so it is refused above `max_bytes` (default 8000, about 2000 tokens) rather than silently filling a context — `list_objects` plus `get_property` answer most questions for a fraction of it
- `list_objects` — objects in the scene: `local_id`, name, parent and the components each carries. Filters by `name` (substring) and by `component` (exact, validated against the registry — an unknown name is an error, not an empty list), which is how "every object with an X" is answered without listing the scene. **Paginated** (`page_size` 50 by default, 500 max, `cursor` to resume, `next_cursor` is -1 on the last page) and world positions are opt-in (`detail`), because a whole scene of objects with full-precision floats is most of an agent's context for a question usually answered by a name
- `batch` — several tools in one round trip, each `{tool, params}`. The bridge answers one call per frame, so repetitive work otherwise costs one frame per command. Every command runs through the same dispatch a standalone call does and keeps its own undo step: a batch is a convenience, not a transaction, and a later failure does not roll back an earlier success. `fail_fast` (default true) stops at the first error. Max 100, no nesting, and no `screenshot` (it answers across frames)
- `describe_type` — what a component looks like: its fields, their types, and the `ref:` / `has:` tags saying what a reference field accepts. No `type` lists every registered component. Type-level, so it needs no object, and `path` walks into a field (ignoring array indices, so a `get_property` path also describes its shape). Answers "does this field exist and what does it take" before a write, instead of after a failed one
- `list_menus` / `invoke_menu` — enumerate and invoke menu items by path (same code path as clicking). Actions and toggles both, since both are clickable: an action runs, a toggle FLIPS and the reply carries its resulting state. Flipping is not idempotent and there is no way to read menu state otherwise, so "make sure X is on" means invoke, read the reply, and invoke again if it landed the wrong way
- `select` — build a selection: `local_ids` for an exact set (this is how a multi-selection is made, which is what the inspector multi-edits), `name` for every object with that name, `add=true` to extend the current one, empty to clear
- `set_transform` — position, rotation (euler degrees) or scale on one object. Omitted components keep their value
- `rename_object` — rename one object
- `get_property` / `set_property` — a component (or the transform) on an object, or one field of it, addressed by component name as `list_objects` prints it plus a dotted path with `[i]` for array elements (`layers[0].states[1].speed`). No path reads the whole component, which is how an agent learns its field names. Values are JSON in the field's own shape. A write is one undo step, obeys a reference field's `ref:` / `has:` tags the way the picker does, and on a prefab instance records the override the inspector would — on the whole array when the path indexes one (docs/InspectorProperty.md)
- `editor_setting` — read all editor settings, or set one scalar field
- `screenshot` — full-resolution PNG to `library/screenshots/`, plus a downscaled copy (default ≤640px) inline as MCP image content. Three views:
  - `scene` (default) / `game` — that view's render target. The tick runs before views draw, so the RT holds the previous frame's submitted contents and is read back asynchronously (fence polled per tick, response sent when pixels land).
  - `editor` — the whole editor window, imgui panels included (inspector, hierarchy, console). Those panels draw straight to the swapchain and never reach a render target, so this copies the swapchain image itself (`gfx.swapchain_capture`). The copy runs **only on frames a screenshot was asked for**, after the UI pass has drawn and while the command buffer is still open — so there is no per-frame cost for a feature used occasionally, and no OS screen-recording permission, since a swapchain image contains nothing but the editor's own window. The request is queued by the tool and serviced at end of frame, because the bridge tick runs before the UI draws.

Objects are addressed by `local_id` (from `list_objects`) or exact name. An ambiguous name is an error naming the count. Every object `list_objects` prints is addressable, prefab-instance content included: all bridge writes go through `inspector.property_set_json` (docs/InspectorProperty.md), which records the override the inspector would, so a write into instance content survives the next resolve exactly as an inspector edit does.

## Enabling

One switch, Edit ▸ Project Settings ▸ MCP (`enabled`, persisted to `ProjectSettings/mcp.json`, on by default, applied at editor start). Off means the editor never opens the socket and removes its bridge file, so no agent can reach it by any tool — enforceable with no per-tool knowledge and nothing a developer can forget to declare.

Editing tools go through the editor's own undo stack, so an agent edit is Ctrl+Z-able and indistinguishable from a manual one. Combined with loopback-only binding and a per-session token, anything it touches is visible and reversible.

## Answering cheaply

A tool's cost to an agent is its reply, and a scene has no natural size bound.
Two rules keep that from being the bridge's dominant cost:

- **Bounded by default, complete on request.** `list_objects` pages; a full
  `scene_dump` is refused past a byte cap it names. Both can be opened up by
  passing a parameter, so nothing is unreachable — it just has to be asked for.
- **Identify first, detail second.** A listing carries what is needed to CHOOSE
  a target (`local_id`, name, parent, component names). Values come from
  `get_property` on the one object that turned out to matter.
- **Answer from the registry, not from a failure.** `describe_type` reports a
  component's fields and their reference tags without touching an object, so a
  wrong field name costs one cheap call rather than a write that is refused.

## TODO

- pending/poll envelope for operations spanning many seconds

### Not planned, unless

- **argv mode on the shim** (`mh mcp <tool>` over the same socket)
  - Small to build. Nobody needs it:
    - an agent already has the tools, each with its own schema
    - tests call every handler in process (`mcp_tool_for_test`), so they need no
      socket and no window
    - the one generated scene in the repo is written by a script that produces
      JSON directly, not by driving the editor
    - a person has the editor open, and its windows answer faster than a command
  - Build it when one of these happens:
    - a tool that is not an MCP client needs to reach the editor
    - the editor gains a headless mode — a CLI over a headless editor validates
      scenes in CI, which a windowed editor cannot do
