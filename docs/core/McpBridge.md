---
title: "MCP Bridge"
description: "Agent access to the running editor over MCP through an editor TCP endpoint and a stdio shim, its protocol and tools"
weight: 190
tags: ["mcp", "editor"]
path: editor
---

Agent access to the running editor over [MCP](https://modelcontextprotocol.io). Two processes, no external dependencies:

- **Editor side** (`editor/mcp_bridge.odin`) — a loopback TCP endpoint inside the editor. The file holds the transport and the shell's own tools (console, menus, dialogs, settings, screenshots, the project view). The tools that read or edit the world are the engine's, in `plugins/engine/editor/mcp_tools`. Threadless: `mcp_bridge_tick` polls a non-blocking socket once per frame right after `gfx.frame_begin`, so every tool runs on the main thread with full editor/engine API access. Listens on the first free port from 6600, writes `library/state_cache/mcp_bridge.json` (port, pid, auth token) and removes it on shutdown.
- **Shim** (`mcp_shim/`, built to `builds/mcp_shim`) — an MCP stdio server the client spawns (`.mcp.json` → `mh mcp`). It discovers the editor through the bridge file, authenticates with the token, and translates MCP JSON-RPC to the wire protocol. The shim owns session stability: when the editor is down or restarts, tool calls return a retry hint and the MCP session survives.

## Wire protocol (`editor/mcp`)

Length-prefixed frames (4-byte big-endian size + JSON, 16 MB cap) after a `WELCOME MOONHUG-MCP 1` handshake line. The client's first frame must carry the bridge-file token. Envelope: `{id, tool, params}` → `{id, status, result}` or `{id, status: "error", error: {code, message, retry_after_ms}}`. One client at a time — a new connection replaces the previous one.

## Declaring a tool

`mcp_tool_gen` scans the attribute in every package and emits `editor/mcp_tools_generated.odin`, so the schema the agent reads comes from the same declaration. A tool outside the editor package (`plugins/engine/editor/mcp_tools`, a plugin) is imported through the `moonhug:` collection and qualified by its package:

```odin
@(mcp_tool={
    description="Rename one object. One undo step.",
    param_local_id="integer:Object local_id from list_objects",
    param_new_name="string!:The new name",
})
mcp_tool_rename_object :: proc(id: i64, params: json.Object) -> (string, mcp.Tool_Error) { ... }
```

- `mcp_tool_<name>` — the tool name is the proc name minus prefix
- `param_<name>` — field is `"<string|integer|number|boolean>[!]:<description>"`, where `!` marks it required. Append `[]` to the type for an array (`"integer[]:..."`, also `"object[]"` for a list of records), which emits the JSON Schema `items` sub-object.
- handler returns marshaled JSON (`mcp.tool_ok`) or an error (`mcp.tool_fail`). The handler vocabulary (`mcp.Tool_Error`, `mcp.json_int`, `mcp.json_f32`) is in `editor/mcp`, which every package can import.
- returning `mcp.DEFERRED` means the handler answers later itself (screenshots do this while the GPU readback fence settles).

## Tools

The shell's tools (`editor/mcp_bridge.odin`, the view tools in `editor/mcp_views.odin`, the input tools in `editor/mcp_input.odin`) are `read_log`, `batch`, `list_menus`, `invoke_menu`, `dialog`, `open_scene`, `ping_asset`, `editor_setting`, `render_stats`, `screenshot`, `window_list`, `window_place`, `window_resize`, `editor_size`, `input` and `item_rect`. The engine's (`plugins/engine/editor/mcp_tools`) are `editor_state`, `scene_dump`, `list_objects`, `describe_type`, `select`, `set_transform`, `rename_object`, `get_property` and `set_property`. `open_scene` runs the project view's open flow and reads the active scene through `session.Document_Actions`.

- `editor_state` — active scene, simulate state, selection (names and `local_id`s, since names repeat)
- `read_log` — recent console entries
- `scene_dump` — scene summary (roots, counts, selection), `full=true` for the complete serialized scene. A full dump is the whole file, so it is refused above `max_bytes` (default 8000, about 2000 tokens) rather than silently filling a context — `list_objects` plus `get_property` answer most questions for a fraction of it
- `list_objects` — objects in the scene: `local_id`, name, parent and the components each carries. Filters by `name` (substring) and by `component` (exact, validated against the registry — an unknown name is an error, not an empty list), which is how "every object with an X" is answered without listing the scene. **Paginated** (`page_size` 50 by default, 500 max, `cursor` to resume, `next_cursor` is -1 on the last page) and world positions are opt-in (`detail`), because a whole scene of objects with full-precision floats is most of an agent's context for a question usually answered by a name
- `batch` — several tools in one round trip, each `{tool, params}`. The bridge answers one call per frame, so repetitive work otherwise costs one frame per command. Every command runs through the same dispatch a standalone call does and keeps its own undo step: a batch is a convenience, not a transaction, and a later failure does not roll back an earlier success. `fail_fast` (default true) stops at the first error. Max 100, no nesting, and no `screenshot` (it answers across frames)
- `describe_type` — what a component looks like: its fields, their types, and the `ref:` / `has:` tags saying what a reference field accepts. No `type` lists every registered component. Type-level, so it needs no object, and `path` walks into a field (ignoring array indices, so a `get_property` path also describes its shape). Answers "does this field exist and what does it take" before a write, instead of after a failed one
- `list_menus` / `invoke_menu` — enumerate and invoke menu items by path (same code path as clicking). Actions and toggles both, since both are clickable: an action runs, a toggle FLIPS and the reply carries its resulting state. Flipping is not idempotent and there is no way to read menu state otherwise, so "make sure X is on" means invoke, read the reply, and invoke again if it landed the wrong way. Items inside a dynamic submenu (Recent Scenes) are drawn at runtime and are not in the tree, so neither tool sees them
- `dialog` — the open confirmation dialog (title, text, button labels), or `open: false`. `press=<label>` answers it, same as a click. A menu item that asks first (Edit/Delete on assets) opens one, and `invoke_menu` names it in its `dialog` reply field, so an agent knows the action is waiting.
- `select` — build a selection: `local_ids` for an exact set (this is how a multi-selection is made, which is what the inspector multi-edits), `name` for every object with that name, `add=true` to extend the current one, empty to clear
- `set_transform` — position, rotation (euler degrees) or scale on one object. Omitted components keep their value
- `rename_object` — rename one object
- `get_property` / `set_property` — a component (or the transform) on an object, or one field of it, addressed by component name as `list_objects` prints it plus a dotted path with `[i]` for array elements (`layers[0].states[1].speed`). No path reads the whole component, which is how an agent learns its field names. Values are JSON in the field's own shape. A write is one undo step, obeys a reference field's `ref:` / `has:` tags the way the picker does, and on a prefab instance records the override the inspector would — on the whole array when the path indexes one (docs/core/InspectorProperty.md)
- `editor_setting` — read all editor settings, or set one scalar field
- `render_stats` — render statistics of recent frames (gfx frame statistics, plugins/engine/docs/SDL3Renderer.md): draw calls, instances, triangles, render passes, CPU milliseconds and GPU wait milliseconds, averaged over `frames` (default 60) plus the last frame. Turn idle throttling off first (Frame Pacing) or an idle editor averages over a few frames a second
- `screenshot` — full-resolution PNG to `library/screenshots/`, plus a downscaled copy (default ≤640px) inline as MCP image content. Four views:
  - `scene` (default) / `game` — that view's render target. The tick runs before views draw, so the RT holds the previous frame's submitted contents and is read back asynchronously (fence polled per tick, response sent when pixels land).
  - `editor` — the whole editor window, imgui panels included (inspector, hierarchy, console). Those panels draw straight to the swapchain and never reach a render target, so this copies the swapchain image itself (`gfx.swapchain_capture`). The copy runs **only on frames a screenshot was asked for**, after the UI pass has drawn and while the command buffer is still open — so there is no per-frame cost for a feature used occasionally, and no OS screen-recording permission, since a swapchain image contains nothing but the editor's own window. The request is queued by the tool and serviced at end of frame, because the bridge tick runs before the UI draws.
  - `window` — one window of the editor (`window=`, a title or id from `window_list`): the `editor` capture cropped to that window's rectangle. A docked window behind another tab is refused: `window_place` brings it forward

### Views

`window_list`, `window_place`, `window_resize` and `editor_size` set the editor's layout up the way a person drags tabs, so an agent can read a window at a useful size:

- `window_list` — every open window: title, id, rectangle in points from the editor's top-left, docked or floating, drawn or behind another tab. Plus the editor's size and pixels per point
- `window_place` — floats a window at a rectangle (undocking it first), or with `dock` puts it beside another docked window (`side` left, right, top or bottom, `ratio` its share) or as a tab next to it (`side` tab)
- `window_resize` — a floating window takes the size as given. A docked one moves the split between its dock node and the neighbour along each axis given, so every tab of that node changes size with it, as a drag on the node's edge does
- `editor_size` — the editor window's own size, the same every run for comparable screenshots
- a window is named by its title or id, case ignored, or by a part of either that names one window only. An ambiguous name is an error listing the matches
- imgui applies layout inside a frame, so `window_place` and `window_resize` queue the change, `mcp_bridge_window_ops` applies it right after `im.NewFrame` (before the dockspace and the views draw), and the tool answers with the window's rectangle once the change shows: a frame later, a few for an undock. They cannot run in a `batch`
- the changes are the layout imgui saves to `imgui.ini`, and the editor's size goes to `UserSettings/editor_settings.json`, as a person's are. A script that measures on someone's project saves and restores both
- the Odin binding of imgui's `Window` struct declares C bitfields as whole fields, so the fields after the first bitfield (`DockNode`, `DockIsActive`, `LastFrameActive`, `RootWindow`) sit at the wrong offsets and read garbage. The view tools read only the fields before it (name, flags, position, size, `Active`, `Hidden`) and find a window's dock node by walking the dock tree from the dockspace (`dock_space_id`). `DockNode` keeps its bitfields at the end, after every field the tools use, and they are never written

### Input

`input` and `item_rect` drive the editor's real widgets, so a gesture the inspector handles (a drag on a row, a click into a field, a shortcut) is tested through the bridge instead of a throwaway window that injects events:

- `input` — a script of steps played into imgui's event queue, one step per frame, the way the SDL backend feeds the OS's input. Each step is an object with a `type`: `move` (`x`, `y`), `down` and `up` (`button`: left, right, middle, left by default), `key` (`name`, `down`, true by default), `text` (`text`, the characters typed into the focused field) and `wait` (`frames`). A click is `down` then `up`, a drag is `move`, `down`, moves, `up`. Answers once the script is done, with what each step's frame saw: imgui's mouse position, the view window under it, whether an item was hovered and whether one was active (held, or being edited). One script at a time, and not in a `batch`
- positions are points from the editor window's top-left, the frame `window_list` and `item_rect` use
- key names are imgui's (`A`, `5`, `Enter`, `Space`, `Tab`, `Backspace`, `Escape`, `Delete`, `UpArrow`, `F3`, `Keypad1`, ...), case ignored, plus `ctrl`, `shift`, `alt` and `cmd` (also `super`) for the physical modifier keys, which send the modifier flag the backend sends with them, and `esc`, `return`, `del`, `up`, `down`, `left`, `right`, `pgup`, `pgdn` as shorthand. On macOS imgui swaps Ctrl and Cmd as the backend hands keys in, and the script's keys take the same swap, so `ctrl` is the physical Ctrl key there too and `cmd` the Cmd key: `cmd` plus a click opens a drag field for typing, `cmd` plus `z` is undo. A `key` step sends no characters, `text` does
- the script's events go into the queue after the backend's for the frame and before imgui reads it (`mcp_bridge_input_feed`, between the backend's NewFrame and `im.NewFrame` in `main.odin`), and the script's mouse position is re-sent every frame it runs: when the editor window has focus and the real cursor is off it, the backend queues the cursor's position every frame, which would otherwise win. The position holds after the script until the real cursor moves. An editor without focus is the quiet case, so a test editor is driven from another window
- imgui's event trickling (`ConfigInputTrickleEventQueue`) is off while a script runs and restored after: with it on, a button event queued behind a position that differs from the current one waits a frame, and one step per frame would drift
- a script keeps the editor at its full frame rate (`gfx.keep_awake`): injected events are not input to the frame pacing, and an idle editor plays a step a few times a second
- `item_rect` — where to aim: by window (`window_list` names) and `label`, the rectangle of an inspector row's widget by the field it edits (`duration`, as `get_property` addresses it) and of any text drawn in the window whose text contains the label, case ignored (a component header, a button, a tab, an object in the hierarchy). Answers after the next frame draws, with every match: `kind` row or text, the label or the text as drawn, `x`, `y`, `width`, `height`
- rows come from the inspector's own row drawing: the tool arms a probe (`inspector/row_probe.odin`), the row edit records the field name and its last widget's rectangle for one frame, and the tool reads them at the next tick. A row folded away or scrolled out of view is not drawn, so it is not found: `window_place` and `window_resize` make room first. A row of several widgets (a vector) reports the last one
- text comes from the frame's draw data (`im.GetDrawData`, valid at the tick, before `im.NewFrame`): a glyph is a quad whose texture rectangle names the glyph in the atlas, glyphs drawn in a row on one line make one run, and a gap of a space width between two glyphs puts a space back, since a space draws nothing. Glyphs are matched at the size each font was last drawn at (`Font.LastBaked`), and the main viewport only: text in a window floating outside the editor is not found. Text clipped away is not drawn, so it is not found either
- imgui records no item rectangles of its own (its test engine hooks are not compiled in), so nothing beyond rows and text is found. A widget without text (a color swatch, a checkbox) is reached from its row, or from the text beside it

Example, the documented flow against a scene whose object `Bullet` carries a `Lifetime` component (a `duration` field that the component validates to zero or more):

1. `select` `{"name": "Bullet"}` puts the object in the inspector
2. `item_rect` `{"window": "Inspector", "label": "duration"}` answers `{"window": "Inspector", "matches": [{"kind": "row", "label": "duration", "x": 1491, "y": 266, "width": 233, "height": 21}, {"kind": "text", "label": "duration", "x": 1390.75, "y": 271, "width": 47.6, "height": 11}]}`: the row's drag widget, and the label text beside it
3. `input` with the steps `move` to the widget's centre (1607, 276), `wait` 2, `down`, fifteen `move`s 20 points further left each, `up`, `wait` 2. The reply lists every step: `active` turns true at the `down` and stays true through the moves, `window` becomes `Scene` once the mouse leaves the inspector (the drag holds), `active` turns false at the `up`
4. `get_property` `{"name": "Bullet", "component": "Lifetime", "path": "duration"}` answers `0`: the drag took the value from 1 to below zero and the component's validation held it at zero, as a drag by hand does

A click into the same widget with `cmd` held (`key` cmd down, `down`, `up`, `key` cmd up) opens it for typing, `text` `"2.5"` and `key` enter down and up commit it, and `key` cmd down, `key` z down and up, `key` cmd up undoes it: `get_property` reads 2.5 and then 0 again.

Objects are addressed by `local_id` (from `list_objects`) or exact name. An ambiguous name is an error naming the count. Every object `list_objects` prints is addressable, prefab-instance content included: all bridge writes go through `inspector.property_set_json` (docs/core/InspectorProperty.md), which records the override the inspector would, so a write into instance content survives the next resolve exactly as an inspector edit does.

## Enabling

One switch, Edit ▸ Project Settings ▸ MCP (`mcp.mcp_settings` in `editor/mcp/settings.odin`, field `enabled`, persisted to `ProjectSettings/mcp.json`, on by default, applied at editor start). Off means the editor never opens the socket and removes its bridge file, so no agent can reach it by any tool — enforceable with no per-tool knowledge and nothing a developer can forget to declare.

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
    - tests call every handler in process (`run_mcp_tool_for_test`), so they need no
      socket and no window
    - the one generated scene in the repo is written by a script that produces
      JSON directly, not by driving the editor
    - a person has the editor open, and its windows answer faster than a command
  - Build it when one of these happens:
    - a tool that is not an MCP client needs to reach the editor
    - the editor gains a headless mode — a CLI over a headless editor validates
      scenes in CI, which a windowed editor cannot do
