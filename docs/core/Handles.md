---
title: "Handles"
description: "Immediate-mode scene-view handles for editor code that draw through gizmos, report hover and turn drags into offsets"
weight: 160
tags: ["handles", "gizmos", "editor"]
---

`editor/handles` is the scene-view interaction layer for editor code and package editors: immediate-mode handles that draw themselves through `host/gizmos` (docs/core/Gizmos.md), report hover, and turn a mouse drag into an offset on a plane. The transform tool (W E R), the mhgui rect tool, the physics collider bounds, lights, audio sources and particle shapes use it.

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
- All of the selection's handles are live together: handle ids must be unique per handle, and priorities decide who gets the pointer where handles overlap. The transform gizmo's parts use `PRIO_TOOL`, below every other handle, so a component's own handle wins the click over it.
- Drawing that is not interactive (an outline) belongs in `@(on_draw_gizmos)` (docs/core/Gizmos.md).

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

The editor's gizmo pass calls `handles.frame_begin(view, input)` once per frame with the scene view's camera, before the handle hooks run (docs/core/Gizmos.md, Recording). No render pass needs to be open. `handles.Input` carries what handles read from the user:

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

The hot handle is picked when a frame begins, before any hook runs. Each handle records its hit shape during the frame (a point, a segment, a ring, a screen box, a quad or a square on a plane, in world space), and the next `frame_begin` tests those shapes with the new camera and pointer. The nearest highest-priority one wins. So:

- The highlight and a click land on the frame the pointer arrives, and hook code runs once per frame.
- Camera moves are exact, since the shapes are projected with the new camera. A handle that moved in the world since the last frame (an animated object in Play) has its hit area one frame behind.
- A handle that first appears this frame can be hot from the next one.
- A hot handle that does not call in again (its object was deselected) does not count.

One handle is active at a time. It stays active while the mouse is down and is dropped when its owner stops calling.

- `consumes_mouse()` is true while a handle is hovered or dragged. The scene view picks and box-selects only when it is false.
- `dragging()` is true while a handle is dragged. `end_drag()` ends the drag now, with no release frame, for a caller whose drag lost its target (the transform tool on a mode switch).

## Snapping

Every handle snaps its own drag while snapping is on. Callers never snap:

- Plane handles (`dot`, `point`, `segment`, `area`, `quad`) snap each axis of `delta` in the current space. On a plane oblique to the axes, the snapped point goes back onto the plane.
- A slider snaps the distance along its line.
- `point` follows the snapped `delta`.
- `with_snap(false)` turns snapping off until the end of the enclosing block, for handles whose values are not distances. The rect tool's anchors and pivot are fractions of the parent rect, and the pivot keeps its own Ctrl snap to 0, 0.5 and 1.
- `snap(amount)` and `snap_angle(radians)` round to the move and rotate steps, for a custom handle that measures a distance or an angle of its own. Both honor `with_snap`.

## Bounds

Composites made of sliders that resize a shape. Each edits the values passed by pointer while one of its dots drags, and returns one `Drag` for all of its dots:

- `box_bounds(id, &center, &size, axes, color, fixed_center)` — a dot on each face.
- `sphere_bounds(id, &center, &radius, axes, color)` — a dot at each end of every axis.
- `capsule_bounds(id, &center, &radius, &height, axis, axes, color)` — the dots on `axis` change the height (caps included), the others the radius.
- `radius_handle(id, center, &radius, axes, color)` — a dot at each end of every axis that changes the radius around a fixed center.
- `cone_handle(id, apex, dir, &range, &angle, color)` — a cone from `apex` along `dir`: the tip dot changes `range` (the length of the edges), four rim dots change `angle` (the full apex angle, radians, 1 to 179 degrees).
- `frustum_handle(id, base, dir, &radius, &angle, length, color)` — a cone frustum: four dots on the base circle change the radius, four on the far rim `length` along change `angle` (radians from the axis, 0 to 89 degrees).

Behavior:

- Dragging a face moves it and keeps the opposite face in place: the center moves by half the change. Alt moves both faces and keeps the center, and so does a box with `fixed_center` (a shape with no offset of its own). Shift (box) scales the other axes by the same ratio.
- Distances snap to the move step and angles to the rotate step, both as steps from the grab-time value, so a click without a move changes nothing.
- Sizes stop at zero. A capsule's height never goes below its diameter, and a radius past half the height pushes the height out.
- `axes` limits the dots: 2D shapes pass `{.X, .Y}`.
- Dots on faces turned away from the camera draw faint and lose the pointer to front dots at the same spot.
- The procs draw only the dots. The shape is the component's gizmo.

The physics colliders use them: box, sphere and capsule in physics3d, box, circle and capsule in physics2d (the 2D capsule's size is its bounding box, so it takes box bounds). They work on the scaled sizes inside the collider's space, then write each field back divided by the scale, on the axes the drag changed only.

Other users, each one undo step per drag:

- Lights (`plugins/engine/editor/scene_tools/light_gizmos.odin`), in every tool: a point light's range with a radius handle on the world axes, a spot light's range and spot angle with a cone handle along its forward (-Z). The gizmo draws the range sphere, the spot cone out to the range, or a directional light's ring of rays. The cone angle is `max(spot_angle, inner_spot_angle)`, the one the renderer uses.
- Audio sources (the audio plugin's `audio_gizmos.odin`), in every tool: the min and max distance, each a wire sphere with a radius handle on the world axes. The min distance past the max pushes the max out, and the max below the min pulls the min in.
- Particle shapes (the particles plugin's `particles_gizmos.odin`), in the Handles tool (T) only, like the colliders: a cone's base radius and angle with a frustum handle, a sphere's, hemisphere's, circle's or edge's radius, a box's size around its center.

## Transform handles

The transform tool's parts, for any code that edits a point, a rotation or a scale in the scene. Each edits the value passed by pointer while one of its parts drags, and returns one `Drag`:

- `position_handle(id, &pos, rotation, size, prio)` — three arrows along the axes `rotation` gives, and three squares that move `pos` in a plane. The squares sit in the quadrant turned to the camera and keep it for the whole drag. They win over an arrow they overlap.
- `rotation_handle(id, &rot, pos, size, local, prio)` — three rings around `pos` that turn `rot`. With `local` the rings follow `rot`, else they sit on the space's axes. The turn is the signed angle on the ring's plane between the grab and the pointer, around the grab-time axis.
- `scale_handle(id, &scale, pos, rotation, size, prio)` — three arrows with cube tips that scale one component of `scale`, and a center cube that scales all three (drag right or up to grow). The factor never goes below 0.01.

Behavior:

- `size` is an arrow's length or a ring's radius, in world units. The transform tool uses 0.15 of the camera distance, so the gizmo keeps its apparent size while zooming.
- Values are in the current gizmos space. The rotate and scale handles treat that space as rigid.
- They snap by themselves: arrows and squares per axis to the move step, rings to the rotate step, scale factors to `SNAP_SCALE_STEP` (0.1).
- During a move, the parts that are not moving draw faint. A square drag lights its square and its two arrows.
- Each composite salts its part ids differently, so switching tools mid-drag never hands the drag to another composite.

The transform tool (`plugins/engine/editor/scene_tools/gizmo.odin`) keeps only what a drag does: it applies the move, turn or scale factor to every selected top-level object from their grab-time states, orbits and scales their offsets around the pivot, and makes the drag one undo step. For the turn and the factor it hands the rotate and scale handles a value that starts at identity at every grab.

## Scene icons

`handles.icon(pos, owner, image, color)` draws a clickable marker for a component with nothing else to click: a dark round badge `icon_px` pixels wide (28 by default, the gizmo settings' Icon Size) facing the camera, showing `image`, one of:

- a glyph of the editor's icon font: a Material Symbols codepoint such as `'\ue90f'` (lightbulb). The names and codepoints are in `external/fonts/material/MaterialSymbolsOutlined.codepoints`.
- a texture asset: its guid, usually a component field picked in the inspector. `color` multiplies it, white by default.
- a symbol: a proc that draws with host/gizmos shapes where -1..1 spans the badge. The built-in icons for lights, cameras and audio sources are symbols.

`color` tints a glyph or a symbol. Call it from an `@(on_draw_gizmos)` hook, before the selection check, so every instance shows one:

```odin
@(on_draw_gizmos={component=AudioSource})
audio_source_gizmos :: proc(a: ^audio.AudioSource, ctx: handles.Gizmo_Context) {
	handles.icon(engine.transform_world_position(a.owner), a.owner, _icon_speaker)
	if .In_Selection not_in ctx.state do return
	...
}
```

- A click inside the badge selects `owner`, over any geometry, since icons draw over everything. Box select takes an icon whose center is inside the rect.
- Icons are gizmos (the `.Editor` channel, `.Editor_Game` for the game view): handles and the transform gizmo draw over them, and the game view shows them with its Gizmos toggle. Each view draws them facing its own camera.
- An owner inactive in the hierarchy gets no icon.
- Built in: lights (a bulb in the light's color), cameras, audio sources (a speaker), particle systems (the "snowing" glyph, `'\ue80f'`).
- Glyphs rasterize once per codepoint (`GLYPH_PX`, 64) from the font the editor hands over at startup (`icon_font_set`). A codepoint the font does not have fails loudly. `glyph_bitmap` returns a glyph's pixels.
- A texture asset that does not load (deleted) leaves the empty badge.

## Undo

Undo is the caller's. Open an undo session on `started`, edit on `dragging`, close on `released`, and one drag is one undo step. Rebuilding the edit from the grab-time values plus the total `delta` every frame keeps a drag a pure function of where the pointer is. The rect tool and the bounds composites do that.

## Drawing

Plain shapes and labels come from `host/gizmos` (docs/core/Gizmos.md). Handles add the chrome a handle needs, drawn over everything and styled to read on any background with a dark half-transparent line one pixel off each edge:

- `rect_outlined`, `circle_outlined`, `dot_outlined`
- camera-facing caps: `square`, `square_outline`, `triangle`, `triangle_outline`, with `triangle_points` for a hit area that matches the drawing

## Picking providers

The scene view picks icons, sprites, meshes and UI graphics itself: a click takes the nearest hit along the ray (an icon under the pointer first), and box select takes everything the rect touches. UI graphics are any graphic a package registers with `engine.canvas_graphic_register` (the mhgui Image, the text plugin's Text), so a package's UI needs no picking code.

`handles.pick_register(Pick_Provider{click, band})` adds a package's other selectable shapes. Both procs are required, so a shape that takes a click also takes a box select:

- `click(view, ray) -> (transform, t, ok)` — the nearest hit, joined with every other source by ray distance.
- `band(view, rmin, rmax, out)` — every transform whose shape meets the viewport-pixel rect, appended to `out`.

## Not yet

- A handle-size helper (a fixed number of pixels at a point) for callers with no size of their own.
