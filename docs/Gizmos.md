# Gizmos

`engine/gizmos` draws debug and editor shapes: collider wires, a camera frustum, handle chrome, the transform gizmo, a raycast from gameplay code. One API serves the editor's gizmo hooks, `editor/handles` and in-game debug drawing.

## Where to draw from

- `@(on_draw_gizmos={component=T})` runs for every enabled `T` each frame, from the editor's gizmo pass (see Recording). It draws only. The proc takes `(c: ^T, ctx: handles.Gizmo_Context)` and decides from `ctx.state` what to draw: `.Selected` (this object), `.Active` (the active object of the selection), `.In_Selection` (it or an ancestor is selected). A gizmo that shows only for the selection starts with `if .In_Selection not_in ctx.state do return`.
- `@(on_scene_handles={component=T})` takes the same parameters and runs for selected objects, in every tool: interactive handles go there (docs/Handles.md).
- A `@(phase={key=DebugDraw, mode=App})` subscriber runs in the standalone app while debug drawing is on (F3). `engine/gizmos` subscribes too, at order 1000, and draws the gameplay shapes after the others recorded theirs.
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
- `.Editor` — `@(on_draw_gizmos)` hooks. The scene view shows it, the game view with Gizmos on in its ⋮ menu.
- `.Tools` — handles, the transform gizmo, the selection outline. Scene view only.

A view draws depth-tested shapes first, then the ones drawn over everything, each channel in that order, so tools always paint over gizmos, whatever order they were recorded in.

The editor's gizmo pass (editor/gizmo_pass.odin) records the hooks once per frame, after the sim tick and before any view renders, so every view draws the same shapes:

- The selection outline, the `@(on_scene_handles)` procs and then the transform gizmo record first, into `.Tools`, while the scene view is on screen. An edit from a handle or the gizmo then shows in the same frame's gizmos and render.
- The `@(on_draw_gizmos)` procs record into `.Editor` while the scene view is on screen or the game view shows gizmos. The game view has them with the scene view closed.
- Pixel-sized gizmos measure against the scene view's camera while the scene view is on screen, else the game view's camera. With both open, a pixel-sized gizmo in the game view has the scene view's size.

## Scopes

State comes from scopes that undo themselves at the end of the enclosing block (`@(deferred_out)`). Shape procs take only geometry.

- `with_color(color)` — the default is white.
- `with_matrix(m)` — composes with the current space, so nested scopes nest spaces.
- `in_local_space(transform, use_scale := true)` — the transform's world position, rotation and optionally scale. It replaces the current space instead of composing with it. Colliders pass `use_scale = false` because their sizes are scaled already.
- `in_world_space()` — replaces the current space with world space, for code that already converted its points (handles do).
- `with_depth_test(enabled)` — on by default. Handles and the transform gizmo turn it off to draw over everything.
- `with_channel(channel)` — `.Game` by default, shown in the game view and the scene view. The editor sets `.Editor` around its hooks, handles and the transform gizmo, shown in the scene view only. Hook code never calls it.

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
| helpers | `helper_pixel(pos, px)`, `helper_project(pos)`, `helper_pixel_in` / `helper_project_in` for a given view, `helper_matrix()` for the current space |

- Angles are radians. `rect` and `line_grid` lie in the local XY plane: rotate them with `with_matrix`.
- Capsules, cylinders and cones take the two points of their axis. Circles and arcs take a center and a normal.
- Solids are unlit color, alpha allowed.
- A solid volume (box, sphere, capsule, cylinder, cone, frustum) drawn without depth test keeps only the faces turned to the camera, each shaded by how much it faces it. Nothing sorts the triangles, so a back face would otherwise paint over the front. This needs the current view (`set_view`, which the scene view calls before its hooks), so draw those from a view's hooks.
- Labels show in views that draw text: the scene view today. They are never depth-tested.
- `helper_pixel` and `helper_project` measure against the current view, so they belong in a view's hooks too.

## Lifetime

A shape lives for one frame: the buffer drops the previous frame's shapes when a new frame starts (`gfx.frame_index` moved on), so no main loop ends the frame for it. A shape recorded during a fixed tick lives until the next tick starts (`engine.fixed_tick_begin`), so it does not flicker on frames that run no tick. Stop (`engine.fixed_reset`) drops those.

## Not yet

- Shapes that stay for N seconds (`with_duration(seconds, clock)`) and shapes that stay until cleared (`with_key(key)`). They extend the same buffer.
- Line width.
- Labels in the game view and the standalone app: those views draw no text yet.
