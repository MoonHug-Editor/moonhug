# Handles

`editor/handles` is the scene-view interaction layer for editor code and package editors: immediate-mode handles that draw themselves through `engine/gizmos` (docs/Gizmos.md), report hover, and turn a mouse drag into a world-space offset on a plane. The mhgui rect tool is the first user.

## Where handles live

Interactive handles go in one hook per component:

```odin
@(on_scene_handles={component=RectTransform})
rect_transform_handles :: proc(rt: ^engine.RectTransform, ctx: handles.Gizmo_Context) {
	anchors(rt)                                     // every tool
	if ctx.tool != .Handles do return
	resize_and_pivot(rt)                            // the Handles tool (T) only
}
```

- It runs every frame in the scene view, in every tool, for each object that is selected itself (not for the children of a selected parent). gizmos_gen emits the `__scene_handles` dispatcher.
- What it records goes to the scene-only `.Tools` channel, drawn over every gizmo, so handles are never covered by another component's drawing and never show in the game view.
- `ctx.tool` says which tool is active. The Handles tool (T, after Q W E R) hides the transform gizmo, so the parts that only make sense without it go behind `ctx.tool == .Handles`.
- All of the selection's handles are live together: handle ids must be unique per handle, and priorities decide who gets the pointer where handles overlap. A hot handle also wins the click over the transform gizmo.
- Drawing that is not interactive (an outline) belongs in `@(on_draw_gizmos)` (docs/Gizmos.md).

The mhgui rect tool is the first user: its anchors work in every tool, T adds resizing, moving and the pivot, and its outline is a gizmo.

## Frame

The scene view calls `handles.frame_begin(view, mouse, hovered)` once per
frame with its pass open, before the gizmo hooks run. `mouse` is in scene
image pixels, `hovered` says the pointer is over the view. The scene view
asks `handles.consumes_mouse()` before click picking and before starting a
box select, so a hot or dragged handle never selects through.

## Handles

Every handle takes a caller id, non-zero and stable across frames, and
returns a `Drag`:

- `hot` — hovered, or being dragged.
- `started` — the mouse went down on it this frame.
- `dragging` — the mouse is down on it, the start frame included.
- `released` — the mouse came up this frame.
- `delta` — the world offset of the current drag-plane point from the grab
  point. `point` is the current plane point.

Kinds:

- `dot(id, pos, normal, size_px, color)` — a draggable point drawn as a
  camera-facing square. Drags move on the plane through `pos` with `normal`.
- `quad(id, corners, normal)` — an invisible draggable surface, the quad bl,
  br, tr, tl. Dots take priority over quads, so handles on a rect's edges win
  over its body.

Hot resolution is one frame late, the imgui way: handles propose themselves
during the frame, the nearest highest-priority one wins, and every handle
reads the previous frame's winner. One handle is active at a time; it stays
active while the mouse is down and is dropped when its owner stops calling.

## Undo

Undo is the caller's. Open an undo session on `started`, edit on `dragging`,
close on `released`, and one drag is one undo step. Rebuilding the edit from
the grab-time values plus the total `delta` every frame keeps a drag a pure
function of where the pointer is, which is what the mhgui rect tool does.

## Drawing

Plain shapes and labels come from `engine/gizmos` (docs/Gizmos.md). Handles add the chrome a handle needs, drawn over everything and styled to read on any background with a dark half-transparent line one pixel off each edge:

- `rect_outlined`, `circle_outlined`, `dot_outlined`
- camera-facing caps: `square`, `square_outline`, `triangle`, `triangle_outline`, with `triangle_points` for a hit area that matches the drawing

`world_per_pixels(pos, px)` sizes things in screen pixels and `project` finds where a world point lands, both in the handles frame's view.

## Picking providers

`handles.pick_register(proc(view, ray) -> (transform, t, ok))` adds a
package's clickable shapes to scene-view click picking. The editor takes the
nearest hit across sprites, meshes and every provider. Box select does not
consult providers yet.

## Not yet

The move, rotate and scale gizmo in `editor/gizmo.odin` predates this
package and keeps its own input handling. Porting it onto handles is the
step that leaves one input system.
