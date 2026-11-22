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
| 3 | Mask, rectangle | `UiMask`, an engine component: clips the nodes under it in the shader. Works turned and in a world-space canvas, adds no draw call. A clipped part takes no pointer | | Done |
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
| 12 | Mask, rounded and shaped | Corner radii, a soft edge, a circle, and drawing clipped by every mask above a node, not the nearest only | 1, 3 | Open |
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
| 29 | Hit test by shape | The pointer hits a UiShape's outline and a sprite's alpha, not the rect: the empty corner of a rounded card takes no click | 2 | Open |
| 30 | Touch | Each finger is a pointer with its own id. The events carry the id now, and the input library reads the mouse only | touch in the input library | Open |
| 31 | Drag threshold by screen density | The threshold is 8 viewport pixels on every screen now | | Open |
| 32 | Watchers | A component sees events another one used, for sounds and analytics | 2 | Open |
| 33 | Pointer events for world objects | The same events on a 3D or 2D object with a collider, as `comp_on_pointer_<kind>` beside `comp_on_pointer_ui` | 2 | Open |

## Draw calls

Quads merge into one draw call when they are neighbours in draw order with the same texture, shader and values. Shapes with equal values and size merge now.

| # | Item | What it is | Needs | Status |
|---|---|---|---|---|
| 25 | Batching by draw order | The collector draws nodes that do not overlap together, so a list of background, label, background, label becomes two draws | | Open |
| 26 | Shape values in a shared buffer | Every UiShape draws with one material and reads its values from a buffer by index, so shapes that differ merge too. Stays crisp and free to animate | a per-frame data buffer in gfx | Open |
| 27 | Cached UiShape | A UiShape with `dynamic` off is drawn once into an atlas and is an Image after that. The cheapest per pixel. Fixed resolution, redrawn when a field or the size changes | a runtime sprite atlas | Open |

## With every item

- The UI sample scene gains a panel that shows the feature: `ui_demo.scene` in the `mhgui_sample` package.
- A docs page for each new component, tests, and a scenario where the editor side changes.

## Open questions

- None.
