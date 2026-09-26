# Handles

`editor/handles` is the scene-view interaction layer for editor code and package editors: immediate-mode handles that draw themselves through `engine/gizmos` (docs/Gizmos.md), report hover, and turn a mouse drag into an offset on a plane. The mhgui rect tool and the physics collider bounds use it.

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

The mhgui rect tool: its anchors work in every tool, T adds resizing, moving and the pivot, and its outline is a gizmo. The physics colliders show bounds handles in T only.

## Space

Handle procs take positions and normals in the current gizmos space, as shapes do, and report drags in it. A handle drawn inside `gizmos.in_local_space(c.owner)` works in the component's own frame:

```odin
gizmos.in_local_space(c.owner, use_scale = false)
d := handles.box_bounds(handles.id_of(h), &center, &size)
```

- Lengths (dot sizes, radii) are world units: `world_per_pixels` returns them.
- `project(pos)` and `world_per_pixels(pos, px)` take points in the current space too.
- `ray_plane` is plain math on world rays and ignores the space.

## Frame

The editor's gizmo pass calls `handles.frame_begin(view, input)` once per frame with the scene view's camera, before the handle hooks run (docs/Gizmos.md, Recording). No render pass needs to be open. `handles.Input` carries what handles read from the user:

- `mouse` in scene image pixels, `hovered` when the pointer is over the view
- `down` and `clicked` for the left button
- `alt` and `shift`
- `snap` and `snap_angle`: the move step (world units) and the rotate step (radians) while snapping is on (the Snap popup's toggle, flipped by holding Ctrl or Cmd), else 0

Handles never read imgui themselves, so a test drives them with a scripted `Input` (tests/common/handles_driver.odin). The scene view asks `handles.consumes_mouse()` before click picking and before starting a box select, so a hot or dragged handle never selects through.

## Handles

Every handle takes a caller id, non-zero and stable across frames, and returns a `Drag`:

- `hot` — hovered, or being dragged.
- `started` — the mouse went down on it this frame.
- `dragging` — the mouse is down on it, the start frame included.
- `released` — the mouse came up this frame.
- `delta` — the offset of the current drag-plane point from the grab point. `point` is the current plane point.

`id_of(value, slot)` makes an id from any value, a component's pool handle for example (`engine.comp_handle_of(&c.base)`), so two components on one object never share ids.

Kinds:

- `dot(id, pos, normal, size_px, color)` — a draggable point drawn as a camera-facing square. Drags move on the plane through `pos` with `normal`.
- `slider(id, pos, dir, size_px, color, prio)` — a dot that moves along `dir` only. The drag plane holds the line and turns to the camera. The distance moved is `linalg.dot(d.delta, linalg.normalize(dir))`.
- `point`, `segment`, `area` — draggable spots that draw nothing, for a marker the caller draws itself (the rect tool's pivot, edges and anchor triangles).
- `quad(id, corners, normal)` — an invisible draggable surface, the quad bl, br, tr, tl. Dots take priority over quads, so handles on a rect's edges win over its body.

Hot resolution is one frame late, the imgui way: handles propose themselves during the frame, the nearest highest-priority one wins, and every handle reads the previous frame's winner. One handle is active at a time. It stays active while the mouse is down and is dropped when its owner stops calling.

## Snapping

Every handle snaps its own drag while snapping is on. Callers never snap:

- Plane handles (`dot`, `point`, `segment`, `area`, `quad`) snap each axis of `delta` in the current space. On a plane oblique to the axes, the snapped point goes back onto the plane.
- A slider snaps the distance along its line.
- `point` follows the snapped `delta`.
- `with_snap(false)` turns snapping off until the end of the enclosing block, for handles whose values are not distances. The rect tool's anchors and pivot are fractions of the parent rect, and the pivot keeps its own Ctrl snap to 0, 0.5 and 1.
- `snap(amount)` and `snap_angle(radians)` round to the move and rotate steps, for a custom handle that measures a distance or an angle of its own. Both honor `with_snap`.

## Bounds

Composites made of sliders that resize a shape. Each edits the values passed by pointer while one of its dots drags, and returns one `Drag` for all of its dots:

- `box_bounds(id, &center, &size, axes, color)` — a dot on each face.
- `sphere_bounds(id, &center, &radius, axes, color)` — a dot at each end of every axis.
- `capsule_bounds(id, &center, &radius, &height, axis, axes, color)` — the dots on `axis` change the height (caps included), the others the radius.

Behavior:

- Dragging a face moves it and keeps the opposite face in place: the center moves by half the change. Alt moves both faces and keeps the center. Shift (box) scales the other axes by the same ratio.
- Sizes stop at zero. A capsule's height never goes below its diameter, and a radius past half the height pushes the height out.
- `axes` limits the dots: 2D shapes pass `{.X, .Y}`.
- Dots on faces turned away from the camera draw faint and lose the pointer to front dots at the same spot.
- The procs draw only the dots. The shape is the component's gizmo.

The physics colliders use them: box, sphere and capsule in physics3d, box, circle and capsule in physics2d (the 2D capsule's size is its bounding box, so it takes box bounds). They work on the scaled sizes inside the collider's space, then write each field back divided by the scale, on the axes the drag changed only.

## Undo

Undo is the caller's. Open an undo session on `started`, edit on `dragging`, close on `released`, and one drag is one undo step. Rebuilding the edit from the grab-time values plus the total `delta` every frame keeps a drag a pure function of where the pointer is. The rect tool and the bounds composites do that.

## Drawing

Plain shapes and labels come from `engine/gizmos` (docs/Gizmos.md). Handles add the chrome a handle needs, drawn over everything and styled to read on any background with a dark half-transparent line one pixel off each edge:

- `rect_outlined`, `circle_outlined`, `dot_outlined`
- camera-facing caps: `square`, `square_outline`, `triangle`, `triangle_outline`, with `triangle_points` for a hit area that matches the drawing

## Picking providers

`handles.pick_register(proc(view, ray) -> (transform, t, ok))` adds a package's clickable shapes to scene-view click picking. The editor takes the nearest hit across sprites, meshes and every provider. Box select does not consult providers yet.

## Not yet

- The move, rotate and scale gizmo in `editor/gizmo.odin` predates this package and keeps its own input handling. Porting it onto handles is the step that leaves one input system.
