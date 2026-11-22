---
title: "Roadmap"
description: "The plan for the mhgui plugin: every item, its order, what it needs and its status"
weight: 900
tags: ["mhgui", "roadmap"]
---

The plan for the mhgui plugin, in build order. Each item ships on its own unless the Needs column names another.

Status is one of: Done, In progress, Next, Open, Parked.

## Tier 1: UI that looks right and scrolls

| # | Item | What it is | Needs | Status |
|---|---|---|---|---|
| 1 | Procedural shape | A rounded rectangle drawn in the shader: a radius per corner, a border, a two-stop gradient, a drop shadow and an inner shadow. A shape setting, with Rect the first shape | per-draw shader values | Done |
| 2 | Pointer events | Enter, exit, down, up, click, hold, drag, scroll and cancel, taken by any component with `@(comp_on_pointer_ui)`. A HitArea takes the pointer and draws nothing. Button is written with it | | Done |
| 3 | Mask, rectangle | A component that clips its children in the shader. Works turned and in a world-space canvas. A clipped part takes no clicks | per-draw shader values (in place since 1) | Open |
| 4 | ScrollRect and Scrollbar | Scrolling content with inertia and elastic edges | 2, 3 | Open |
| 5 | Slider, Toggle, ToggleGroup | The simple controls on the selectable base Button established | 2 | Open |

## Tier 2: layouts that hold together

| # | Item | What it is | Needs | Status |
|---|---|---|---|---|
| 6 | LayoutElement and child expand | Minimum, preferred and flexible sizes. Children stretch to fill | | Open |
| 7 | ContentSizeFitter | A node sizes itself to its text or its children | 6 | Open |
| 8 | AspectRatioFitter | A node keeps a ratio inside its parent | | Open |
| 9 | CanvasGroup | Alpha, interactable and blocks-raycasts for a whole subtree | | Open |

## Tier 3: the full control set

| # | Item | What it is | Needs | Status |
|---|---|---|---|---|
| 10 | InputField | Text entry with a caret, a selection and the clipboard. Needs caret and selection drawing in the text plugin | 2, 3 | Open |
| 11 | Dropdown | A button that opens a list | 4 | Open |
| 12 | Mask, rounded and shaped | Corner radii, a soft edge, a circle, nested masks | 1, 3 | Open |
| 13 | Mask, sprite alpha | Any outline from an image, and soft masks | 3 | Open |
| 14 | More shapes | Circle, ring, pill, polygon and star for the procedural shape | 1 | Open |
| 15 | Button transitions | Sprite swap and animation. Colour tint is the only one now | | Open |
| 16 | Explicit navigation | A selectable names its neighbour per direction, or stays out of navigation. Automatic navigation is the only mode now | | Open |

## Tier 4: triangles and a colour per vertex in the UI path

| # | Item | What it is | Needs | Status |
|---|---|---|---|---|
| 17 | UI mesh output | A graphic emits triangles with a colour per vertex. A graphic emits quads of one colour now | | Open |
| 18 | Filled image | Radial and linear fills, for cooldowns and health bars | 17 | Open |
| 19 | Mesh shapes | Free-form outlines from points | 17 | Open |
| 20 | Text colour gradient, Outline and Shadow effects | Effects that set a colour per vertex | 17 | Open |

## Tier 5: smaller or later

| # | Item | What it is | Status |
|---|---|---|---|
| 21 | RawImage | A texture that is not a sprite, such as a render target | Open |
| 22 | Rich text tags | Bold, colour and size inside one Text | Open |
| 23 | Grid layout extras | Start corner and start axis | Open |
| 24 | Navigation through input actions | The submit and move keys come from the input_actions plugin | Parked |

## Pointer

| # | Item | What it is | Needs | Status |
|---|---|---|---|---|
| 28 | Drag and drop | A drag carries a payload. Nodes say whether they accept it, and the drop goes to the node under the pointer, the dragged node left out | 2 | Open |
| 29 | Hit test by shape | The pointer hits a Shape's outline and a sprite's alpha, not the rect: the empty corner of a rounded card takes no click | 2 | Open |
| 30 | Touch | Each finger is a pointer with its own id. The events carry the id now, and the input library reads the mouse only | touch in the input library | Open |
| 31 | Drag threshold by screen density | The threshold is 8 viewport pixels on every screen now | | Open |
| 32 | Watchers | A component sees events another one used, for sounds and analytics | 2 | Open |
| 33 | Pointer events for world objects | The same events on a 3D or 2D object with a collider, as `comp_on_pointer_<kind>` beside `comp_on_pointer_ui` | 2 | Open |

## Draw calls

Quads merge into one draw call when they are neighbours in draw order with the same texture, shader and values. Shapes with equal values and size merge now.

| # | Item | What it is | Needs | Status |
|---|---|---|---|---|
| 25 | Batching by draw order | The collector draws nodes that do not overlap together, so a list of background, label, background, label becomes two draws | | Open |
| 26 | Shape values in a shared buffer | Every Shape draws with one material and reads its values from a buffer by index, so shapes that differ merge too. Stays crisp and free to animate | a per-frame data buffer in gfx | Open |
| 27 | Cached Shape | A Shape with `dynamic` off is drawn once into an atlas and is an Image after that. The cheapest per pixel. Fixed resolution, redrawn when a field or the size changes | a runtime sprite atlas | Open |

## With every item

- The UI sample scene gains a panel that shows the feature: `ui_demo.scene` in the `mhgui_sample` package.
- A docs page for each new component, tests, and a scenario where the editor side changes.

## Decisions

- **Masks clip in the shader, with no stencil.** A mask's shape is a formula shape (rectangle, rounded rectangle, circle, star) or a sprite's alpha. Geometry made at runtime is not a mask shape.
- **The procedural shape is drawn in the shader, not as a generated mesh.** One quad per shape at any size, edges antialiased per pixel, exact soft shadows. Free-form outlines are a separate feature (19) that generates a mesh.
- **The procedural shape is its own component**, next to Image: it needs no sprite.
- **Pointer events are one mechanism for every component**: `@(comp_on_pointer_ui={component=T})`, one proc that gets every event of its node. The name goes from the general to the specific, so another kind of pointer event takes a sibling name with no rename.
- **Events go up the parent chain, with no pass down from the root first.** The simpler model. A parent takes a gesture through `Drag_Begin`.
- **Keyboard and gamepad send no pointer events.** A key that should run what a click runs is bound through input actions (24), not faked in the UI.
- **Draw call work is in three steps.** Equal shapes share a draw call (done). A shared value buffer (26) and a cached mode (27) are later updates.
- **The procedural shape, the mask and the mesh shapes are separate features.** They share one shader include file of distance formulas and nothing else.

## Open questions

- None.
