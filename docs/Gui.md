# GUI (mhgui)

UI has two halves. The canvas tree is engine vocabulary in
`engine/ui_canvas.odin`: Canvas, RectTransform, CanvasRenderer, CanvasScaler
and the rect walk that resolves every node's rect. `packages/mhgui` owns what
gets drawn: the Image graphic, the LayoutGroup container, the render
collector that turns a canvas into `Draw_Quad` commands, and the editor
tooling (menus, rect tool, picking). The split follows Unity's: the layout
vocabulary is core so any package can build on it, the graphics are content.
Packages reach the tree through `canvas_resolve_rects` and plug containers in
with `canvas_layout_register`.

## Components

- **Canvas** — the root of a UI tree. Screen-space overlay: the canvas rect
  is the game viewport in pixels and everything under it draws over the
  scene. `sort_order` stacks canvases.
- **RectTransform** — the layout component, in canvas pixels with a bottom-left
  origin. `anchor_min` / `anchor_max` pick a sub-rect of the parent rect,
  `size_delta` adds to that span (equal anchors give a fixed size, spread
  anchors stretch and `size_delta` is the margin), `pivot` sits at the anchor
  reference point plus `anchored_position`. Its third component is depth off
  the canvas plane, Unity's anchoredPosition3D: inert in the overlay, which
  draws orthographically, meaningful once Screen Space - Camera and World
  Space modes exist. The node's Transform rotation
  and scale apply around the pivot and compose down the hierarchy: a rotated
  panel rotates its children. A rotation around X or Y tilts the rect out of
  the canvas plane; the Game view draws the overlay orthographically, so the
  tilt shows as foreshortening, and the scene view shows the depth. The rect
  itself is still resolved in the parent's unrotated space, so anchors and
  layout keep their meaning. A node without a RectTransform passes its
  parent's rect through.
- **CanvasRenderer** — marks a node as drawing. It has no settings of its own:
  what it draws comes from the node's graphic. Disabling it hides the graphic.
- **CanvasScaler** — on the Canvas node. Constant Pixel Size: one canvas unit
  is `scale_factor` screen pixels. Scale With Screen Size: the canvas is
  `reference_resolution` units, scaled to fit the screen; `match` 0 fits the
  reference width, 1 the height, in between blends logarithmically. Without
  a scaler one canvas unit is one screen pixel. Rects, the rect tool and the
  scene view all work in canvas units; the Game view maps them to pixels.
- **LayoutGroup** — lays out the node's RectTransform children in a row, a
  column or a grid, with padding, spacing and a child alignment. A laid-out
  child's anchors and anchored position are ignored: its size is its
  `size_delta` (a grid uses `cell_size`), its rect comes from the flow. Rows
  run left to right, columns and grid rows top to bottom. Grid columns are
  as many as fit, or a fixed column or row count. Children without a
  RectTransform stay out of the layout.
- **Graphic** — not a component but the struct every drawable UI component
  embeds, as `using graphic: engine.Graphic` with the `inline:""` tag:
  `color`, `material` and `raycast_target`, serialized under "graphic" and
  drawn flat in the inspector. A package registers its graphic type with
  `canvas_graphic_register`: the component's TypeKey, the offset of the
  embedded Graphic, and a `populate` proc that returns the quads the
  component draws inside its rect. The engine's canvas collector walks each
  canvas once, finds the graphic on every CanvasRenderer node through that
  registry, and emits the quads in hierarchy order — so Image and Text draw
  through one path without the engine knowing either type.
- **Text** lives in its own plugin, `packages/text` (docs/Text.md):
  TextMeshPro-shaped, SDF fonts baked at import and an SDF material shader,
  a swappable glyph backend under a backend-neutral layout. Neither the
  canvas tree nor mhgui knows about it.
- **Image** — a graphic (embeds Graphic). `sprite` is a texture plus slice reference (the
  shared sprite picker in the inspector), empty draws the package's white
  texture so the rect is a solid `color`. `preserve_aspect` fits the largest
  aspect-correct rect centered in the node's rect instead of stretching. The
  inspector's Set Native Size button sizes the RectTransform to the sprite's
  pixels, one undo step.

## Position

`anchored_position` is the stored value, the only one. The Transform API is
a second door into it, so one call moves a bullet or a health bar:

- `transform_set_local_position` on a RectTransform node converts the given
  position into `anchored_position`; `transform_local_position` returns the
  value derived from it. Local positions are relative to the parent's pivot
  point, in the parent's space, like localPosition under a RectTransform.
  Z passes through as depth.
- `transform_world_position` and `transform_set_world_position` work on the
  canvas plane, the world space the scene view shows (one unit per canvas
  unit, canvas bottom-left at the origin).
- The move gizmo and the Transform inspector's Position row go through
  these procs on UI nodes, and record `anchored_position` for undo. The
  Transform's own position field is never read or written for UI, so scenes
  and prefab overrides carry no derived value.

## Drawing

The engine's canvas collector runs for Game views and the scene view. Per
enabled canvas it resolves every active node's rect in hierarchy order
(parents before children, siblings in order) and, for each node with an
enabled CanvasRenderer and a registered graphic, emits one `Draw_Quad` per
quad the graphic populates, in the graphic's color and material.

- **Game views**: quads sit on a plane just inside the view's near plane,
  with the rect's pixel corners unprojected through the view, so they land on
  exactly those pixels for any camera and nothing in the scene passes the
  depth test in front of them.
- **Scene view**: the canvas is a world rect with its bottom-left at the
  origin in the XY plane, one world unit per canvas unit, sized like the
  last Game view (1920x1080 before one has drawn). This is where the rect
  tool lives.

Sort keys use layer 127, the top of the transparent range, then the canvas
`sort_order`, then the node's index in the walk.

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

The RectTransform inspector (`editor/view_rect_transform.odin`) has Unity's
layout for a single UI node, and the Transform section is hidden for it:

- The anchor preset button opens the 4 by 4 grid (left, center, right,
  stretch by top, middle, bottom, stretch). Shift also sets the pivot, Alt
  also moves the rect onto the anchors. The icons draw the actual anchors.
- Per axis the fields follow the anchors: Pos X and Width when the anchors
  coincide, Left and Right when they are apart (Pos Y and Height, or Top and
  Bottom). Pos Z is the depth.
- Anchors (Min, Max) and Pivot edits keep the rect where it is. The [R]
  toggle is raw edit mode: only the values change and the rect moves.
- Rotation and Scale are the Transform's rows.

Every gesture is one undo step over the RectTransform fields that changed.
With several objects selected the rows show the active object's values with
a dash where the others disagree, and an edit writes the edited value into
each object through its own anchors, pivot and parent, recording each
object's prefab override. The labels follow the active object's anchors. A
selection with a canvas root draws the generic rows instead.

## TODO

Ordered by what unblocks the most next.

1. **Sliced and Tiled Image.** Needs sprite border data in the texture
   importer's Sprite_Rect; the Image then emits a 9-slice.
2. **Input.** Raycast target on Image, a pointer event pass over the canvas
   tree, Button as the first consumer.
3. **Rect tool: anchor and pivot dragging**, and driven fields greyed under a
   LayoutGroup instead of snapping back.
4. **Box select of UI rects** in the scene view (the pick provider covers
   clicks only).
5. **Screen Space - Camera and World Space** render modes.
6. **LayoutGroup extras** (low priority): content size fitting, child
   expand, start corner and axis for grids.
