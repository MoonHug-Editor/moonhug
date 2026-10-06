---
title: "Gizmos"
description: "The gizmos API that draws debug and editor shapes for gizmo procs, editor handles and in-game debug drawing"
weight: 170
tags: ["gizmos", "handles", "engine", "editor"]
---

`host/gizmos` draws debug and editor shapes: collider wires, a camera frustum, handle chrome, the transform gizmo, a raycast from gameplay code. One API serves the editor's gizmo hooks, `editor/handles` and in-game debug drawing.

## Where to draw from

- `@(on_draw_gizmos={component=T})` runs for every enabled `T` each frame, from the editor's gizmo pass (see Recording). It draws only. The proc takes `(c: ^T, ctx: handles.Gizmo_Context)` and decides from `ctx.state` what to draw: `.Selected` (this object), `.Active` (the active object of the selection), `.In_Selection` (it or an ancestor is selected). A gizmo that shows only for the selection starts with `if .In_Selection not_in ctx.state do return`.
- `@(on_scene_handles={component=T})` takes the same parameters and runs for selected objects, in every tool: interactive handles go there (docs/core/Handles.md).
- A `@(phase={key=DebugDraw, mode=App})` subscriber runs in the standalone app while debug drawing is on (F3). `host/gizmos` subscribes too, at order 1000, and draws the gameplay shapes after the others recorded theirs.
- Any other code (`update`, `fixed_update`, an editor tool) can draw too. Nothing needs an open render pass.

```odin
@(on_draw_gizmos={component=CapsuleCollider})
capsule_collider_gizmos :: proc(c: ^physics3d.CapsuleCollider, ctx: handles.Gizmo_Context) {
	if .In_Selection not_in ctx.state do return
	gizmos.with_color(physics3d.COLLIDER_GIZMO_COLOR)
	gizmos.in_local_space(c.owner, use_scale = false)
	gizmos.wire_capsule(a, b, radius)
}
```

## Recording

A gizmo call records world-space lines, triangles and labels into the current context's buffer (`engine.Gizmo_Buffer` on the `UserContext`). Each view draws the buffer inside its own pass. So:

- A call works from anywhere, with no pass open.
- The space applies at call time: a shape stays where it was drawn.
- A preview world has its own context and buffer, so its drawing never shows in the scene view.
- Shapes drawn without depth test paint in the order they were recorded. The buffer keeps lines and triangles in one list for that reason.

Channels say who a shape is for, and draw in this order:

- `.Game` — gameplay and `@(debug_draw)` code. The scene view shows it, the game view with Gizmos on in its ⋮ menu or with debug drawing on, the standalone app with debug drawing on (F3).
- `.Editor` — the `@(on_draw_gizmos)` procs, recorded with the scene camera. The scene view shows it.
- `.Editor_Game` — the same procs recorded with the game camera. The game view shows it with Gizmos on in its ⋮ menu.
- `.Tools` — handles, the transform gizmo, the selection outline. Scene view only.

A view draws depth-tested shapes first, then the ones drawn over everything, each channel in that order, so tools always paint over gizmos, whatever order they were recorded in.

The editor's gizmo pass (editor/gizmo_pass.odin) records once per frame, after the sim tick and before any view renders:

- The selection outline, the `@(on_scene_handles)` procs and then the transform gizmo record first, into `.Tools`, while the scene view is on screen. An edit from a handle or the gizmo then shows in the same frame's gizmos and render.
- The `@(on_draw_gizmos)` procs record once per view that shows gizmos, with that view's camera: into `.Editor` for the scene view, into `.Editor_Game` for the game view. Pixel sizes and camera-facing parts fit the view that shows them, and the scene view never affects what the game view shows. With both views showing gizmos the procs run twice a frame, so code with side effects (a log) sees both runs. The game view has gizmos with the scene view closed, and none without a camera.
- Gameplay code (update, fixed ticks) records once, measured against the game camera: the editor sets its view before the sim tick, the standalone app before its update. The scene view shows those shapes too.

## Scopes

State comes from scopes that undo themselves at the end of the enclosing block (`@(deferred_out)`). Shape procs take only geometry.

- `with_color(color)` — the default is white.
- `with_matrix(m)` — composes with the current space, so nested scopes nest spaces.
- `in_local_space(transform, use_scale := true)` — the transform's world position, rotation and optionally scale. It replaces the current space instead of composing with it. Colliders pass `use_scale = false` because their sizes are scaled already.
- `in_world_space()` — replaces the current space with world space, for code that already converted its points (handles do).
- `with_view(v)` — `v` is the current view until the end of the block, then the previous one comes back. The game view draws with its camera's view this way.
- `with_shapes(enabled)` and `with_icons(enabled)` — off, lines, triangles and labels (or icons) record nothing. The gizmo settings hide a component type this way around its hook.
- `with_depth_test(enabled)` — on by default. Handles and the transform gizmo turn it off to draw over everything.
- `with_channel(channel)` — `.Game` by default, shown in the game view and the scene view. The editor sets the channel around its `@(on_draw_gizmos)` procs, handles and the transform gizmo, so their code never calls it.

```odin
{
	gizmos.with_color({1, 0, 0, 1})
	gizmos.line(a, b) // red
}
gizmos.line(c, d) // back to the previous color
```

## Shapes

Names group by family:

| Family | Procs |
|---|---|
| `line` / `line_*` (straight strokes) | `line`, `line_ray`, `line_arrow`, `line_poly`, `line_dashed`, `line_cross`, `line_axes`, `line_grid` |
| `curve_*` (curved strokes) | `curve_bezier` |
| `wire_*` / `solid_*` (always a pair) | `circle`, `arc`, `rect`, `quad`, `triangle`, `polygon`, `box`, `sphere`, `capsule`, `cylinder`, `cone`, `frustum` |
| text | `label(pos, text, align, rotated, offset_px)` |
| icons | `icon(pos, size_px, owner, image, color, backdrop)`, and `helper_icon_space(view, pos, size_px)` for the space one draws in |
| helpers | `helper_pixel(pos, px)`, `helper_project(pos)`, `helper_pixel_in` / `helper_project_in` for a given view, `helper_matrix()` for the current space |

- Angles are radians. `rect` and `line_grid` lie in the local XY plane: rotate them with `with_matrix`.
- Capsules, cylinders and cones take the two points of their axis. Circles and arcs take a center and a normal.
- Solids are unlit color, alpha allowed.
- A solid volume (box, sphere, capsule, cylinder, cone, frustum) drawn without depth test keeps only the faces turned to the camera, each shaded by how much it faces it. Nothing sorts the triangles, so a back face would otherwise paint over the front. The faces record as data (`.Face`, wound outward), and each view culls and shades them for its own camera when it draws (`helper_face`), so recording one needs no view.
- Labels show in the editor's scene and game views, drawn over the view's image and never depth-tested. Each view shows the labels of the channels it draws, projected with its own camera. The standalone app draws no text yet.
- An icon records as data (position, pixel size, image, colors, owner). Each view builds it when it draws, facing that view's camera at that view's pixel size, so icons face the game camera in the game view. The scene view picks the owner on a click inside it (`icons()` returns this frame's). `handles.icon` draws the editor's (docs/core/Handles.md).
- An icon's image is a symbol (a proc drawing with shapes), a glyph (a codepoint of the editor's icon font) or a texture asset. A glyph or texture draws as a quad over the backdrop. Glyphs come from the glyph source the editor installs (`set_glyph_source`): without one, a glyph icon fails loudly, so the standalone app cannot draw them.
- `helper_pixel` and `helper_project` measure against the current view: the view the `@(on_draw_gizmos)` procs record for, or the game camera for gameplay code.

## Gizmo settings

Both the scene and the game view menus (the ⋮ button on the tab bar) have:

- `Gizmos` — the view's toggle for every gizmo and icon in it. Off in the scene view, handles, the transform gizmo and gameplay shapes (`.Game`) still show, and icons no longer take clicks.
- `Gizmo Settings` — shared by both views: the icon size, and one row per component type with an `@(on_draw_gizmos)` hook, with an Icon and a Gizmo checkbox.

The gizmo dispatcher applies the checkboxes around each hook (`with_icons`, `with_shapes`), so hook code never checks them, and a type with both off does not run its hook. gizmos_gen lists the types, so a package's own gizmo hooks get rows too. Everything persists in the editor settings, per type by name.

## Lifetime

A shape lives for one frame: the buffer drops the previous frame's shapes when a new frame starts (`gfx.frame_index` moved on), so no main loop ends the frame for it. A shape recorded during a fixed tick lives until the next tick starts (`engine.fixed_tick_begin`), so it does not flicker on frames that run no tick. Stop (`engine.fixed_reset`) drops those.

Two scopes keep shapes longer, in groups of their own in the same buffer. They draw with the other shapes, channel by channel:

- `with_duration(seconds, clock)` — the shapes stay for `seconds`. `.Game` (the default) is the simulation's clock, fixed ticks: it waits while the game is paused or not running, and Stop drops what it timed. `.Real` is wall time, for editor tools. A raycast drawn once with a duration stays visible after the frame that cast it.
- `with_key(key)` — the shapes stay until `clear_key(key)`. The first shapes recorded under `key` in a later frame replace them, so a path is drawn once and redrawn only when it changes. Within one frame, shapes under the same key add up. `key` is any non-zero id.

The innermost scope wins, and either one takes precedence over the fixed tick lifetime.

## Not yet

- Line width.
- Labels in the standalone app: it draws no text yet.
