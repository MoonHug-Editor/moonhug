# GUI (mhgui)

`packages/mhgui` is the UI package: RectTransform
lays a node out, Canvas roots a UI tree, CanvasRenderer draws. It is a plugin
package: it owns its component pools and draws through the renderer's
collector registry (docs/SDL3Renderer.md), the engine has no UI code.

## Components

- **Canvas** — the root of a UI tree. Screen Space - Overlay: the canvas rect
  is the game viewport in pixels and everything under it draws over the
  scene. `sort_order` stacks canvases.
- **RectTransform** — the layout component, in canvas pixels with a bottom-left
  origin. `anchor_min` / `anchor_max` pick a sub-rect of the parent rect,
  `size_delta` adds to that span (equal anchors give a fixed size, spread
  anchors stretch and `size_delta` is the margin), `pivot` sits at the anchor
  reference point plus `anchored_position`. The node's Transform position,
  rotation and scale take no part. A node without a RectTransform passes its
  parent's rect through.
- **CanvasRenderer** — draws the node's rect as one quad: `texture` (empty
  draws the package's white texture, so the quad is a solid `color`) tinted by
  `color`. Graphics such as Image or Text will feed it geometry later. Until
  those exist the texture and color live here.

## Drawing

The collector runs for Game views only. Per enabled canvas it resolves every
active node's rect in hierarchy order (parents before children, siblings in
order) and emits one `Draw_Quad` per enabled
CanvasRenderer. Quads sit on a plane just inside the view's near plane, with
the rect's pixel corners unprojected through the view, so they land on
exactly those pixels for any camera and nothing in the scene passes the depth
test in front of them. Sort keys use layer 127, the top of the transparent
range, then the canvas `sort_order`, then tree order.

## Editor

GameObject > UI > Canvas creates a canvas at the scene root. GameObject > UI >
Image creates a RectTransform + CanvasRenderer node under the selection when
the selection sits in a canvas, else under a new canvas. Each is one undo
step.

## Not yet

Screen Space - Camera and World Space render modes, CanvasScaler reference
resolution, Image (sprite slices, 9-slice), Text, raycast and input, layout
groups.
