# GUI (mhgui)

`packages/mhgui` is the UI package: RectTransform
lays a node out, Canvas roots a UI tree, Image draws through a
CanvasRenderer. It is a plugin
package: it owns its component pools and draws through the renderer's
collector registry (docs/SDL3Renderer.md), the engine has no UI code.

## Components

- **Canvas** — the root of a UI tree. Screen-space overlay: the canvas rect
  is the game viewport in pixels and everything under it draws over the
  scene. `sort_order` stacks canvases.
- **RectTransform** — the layout component, in canvas pixels with a bottom-left
  origin. `anchor_min` / `anchor_max` pick a sub-rect of the parent rect,
  `size_delta` adds to that span (equal anchors give a fixed size, spread
  anchors stretch and `size_delta` is the margin), `pivot` sits at the anchor
  reference point plus `anchored_position`. The node's Transform position,
  rotation and scale take no part. A node without a RectTransform passes its
  parent's rect through.
- **CanvasRenderer** — marks a node as drawing. It has no settings of its own:
  what it draws comes from the node's graphic. Disabling it hides the graphic.
- **Image** — the graphic. `sprite` is a texture plus slice reference (the
  shared sprite picker in the inspector), empty draws the package's white
  texture so the rect is a solid `color`. `preserve_aspect` fits the largest
  aspect-correct rect centered in the node's rect instead of stretching. The
  inspector's Set Native Size button sizes the RectTransform to the sprite's
  pixels, one undo step.

## Drawing

The collector runs for Game views and the scene view. Per enabled canvas it
resolves every active node's rect in hierarchy order (parents before
children, siblings in order) and emits one `Draw_Quad` per node with an enabled
CanvasRenderer and Image.

- **Game views**: quads sit on a plane just inside the view's near plane,
  with the rect's pixel corners unprojected through the view, so they land on
  exactly those pixels for any camera and nothing in the scene passes the
  depth test in front of them.
- **Scene view**: the canvas is a world rect with its bottom-left at the
  origin in the XY plane, one world unit per canvas pixel, sized like the
  last Game view (1920x1080 before one has drawn). This is where the rect
  tool lives.

Sort keys use layer 127, the top of the transparent range, then the canvas
`sort_order`, then tree order.

## Editor

GameObject > UI > Canvas creates a canvas at the scene root. GameObject > UI >
Image creates a RectTransform + CanvasRenderer + Image node under the selection when
the selection sits in a canvas, else under a new canvas. Each is one undo
step.

Clicking a UI rect in the scene view selects it (a picking provider,
docs/Handles.md). The selected RectTransform shows the rect tool, built on
`editor/handles`: the rect outline, four corner and four edge handles that
resize with the opposite edge fixed, the body that moves, the parent's anchor
markers, and the pivot ring. One drag is one undo step. Anchor and pivot
dragging come later.

## Not yet

Screen Space - Camera and World Space render modes, CanvasScaler reference
resolution, Image types beyond Simple (Sliced, Tiled, Filled), Text, raycast and input, layout
groups, anchor and pivot dragging in the rect tool, box select of UI rects.
