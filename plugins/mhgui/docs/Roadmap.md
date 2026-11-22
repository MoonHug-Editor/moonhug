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
| 2 | Pointer events | Enter, exit, down, up, click, hold, drag, scroll and cancel, taken by any component with `@(comp_on_pointer)`. A HitArea takes the pointer and draws nothing. Button is written with it | | Done |
| 3 | Mask, rectangle | `UiMask`: clips the nodes under it in the shader. Works turned and in a world-space canvas, adds no draw call. A clipped part takes no pointer | | Done |
| 12 | Mask, rounded and nested | A radius per corner, a soft edge, a circle, and a node cut by every mask above it with each mask's own shape. A project setting says whether shaders get the clip by themselves | 1, 3 | Done |
| 4 | ScrollRect and Scrollbar | Scrolling content by a drag, the wheel or a bar, with inertia and elastic or clamped ends. A list inside a list takes the drags along its own axis. GameObject, UI, Scroll View | 2, 3 | Done |
| 5 | Slider, Toggle, ToggleGroup | The simple controls. Button, Toggle and Slider share one `Selectable` part: the colour transition, the hover and press state, and keyboard and gamepad selection | 2 | Done |

## Tier 2: layouts that hold together

| # | Item | What it is | Needs | Status |
|---|---|---|---|---|
| 6 | LayoutElement and child expand | Minimum, preferred and flexible sizes. Children stretch to fill | | Done |
| 7 | ContentSizeFitter | A node sizes itself to its text or its children | 6 | Done |
| 8 | AspectRatioFitter | A node keeps a ratio inside its parent | | Done |
| 9 | CanvasGroup | Alpha, interactable and blocks-raycasts for a whole subtree | | Done |

## Tier 3: the full control set

| # | Item | What it is | Needs | Status |
|---|---|---|---|---|
| 10 | InputField | Text entry with a caret, a selection, the clipboard, a hint, content kinds and a password mode, single or multi-line. In the text plugin | 2, 3 | Done |
| 11 | Dropdown | A control that opens a list of options over the rest of the canvas and picks one. The list is a copy of a Template subtree. In the text plugin | 4 | Done |
| 13 | Mask, sprite alpha | A `sprite` on the UiMask: its alpha shapes the mask, so any outline an image has and any fade. One sprite cuts a node, the nearest mask's | 3 | Done |
| 14 | More shapes | Ellipse, polygon and star for the UiShape. A pill is a rect with a large radius, a ring an ellipse with a border and no fill | 1 | Done |
| 15 | Button transitions | Sprite swap, and animation with the animation plugin, for every control | | Done |
| 16 | Explicit navigation | `navigation` on every control: Automatic, Explicit with a neighbour named per direction, or None, which keeps the selection and stays out of automatic moves | | Done |

## Tier 4: triangles and a colour per vertex in the UI path

| # | Item | What it is | Needs | Status |
|---|---|---|---|---|
| 17 | UI mesh output | A graphic emits quads with four free corners and a colour per corner. A triangle is a quad with two corners at one point. `@(canvas_effect)` lets a component change the quads of the graphic on its node | | Done |
| 18 | Filled image | Image type Filled: a bar along an axis, or a sector of 90, 180 or 360 degrees, by `fill_amount` | 17 | Done |
| 19 | Mesh shapes | `UiPolygon`: an outline from points, filled, drawn as a line or both, with faded edges | 17 | Done |
| 20 | Text colour gradient, Outline and Shadow effects | `UiGradient`, `UiShadow` and `UiOutline`: effects for any graphic, a Text, an Image or a UiPolygon | 17 | Done |

## Tier 5: smaller or later

| # | Item | What it is | Status |
|---|---|---|---|
| 21 | RawImage | A texture drawn whole or by a `uv_rect`, with no sprite. The engine has no render target asset yet, so a texture file is what it draws | Done |
| 22 | Rich text tags | `rich_text` on a Text: `<b>`, `<i>`, `<u>`, `<s>`, `<color>` and `<size>` style parts of one string | Done |
| 23 | Grid layout extras | `start_corner` and `start_axis` on a Grid LayoutGroup | Done |
| 24 | Navigation through input actions | The submit and move keys come from the input_actions plugin | Parked |
| 39 | UiPolygon point handles | With the Handles tool the points of a UiPolygon are dragged in the Scene window, and a drag from an edge's middle adds one | Done |

## Pointer

| # | Item | What it is | Needs | Status |
|---|---|---|---|---|
| 28 | Drag and drop | A drag carries a payload. Nodes say whether they accept it, and the drop goes to the node under the pointer, the dragged node left out | 2 | Open |
| 29 | Hit test by shape | `@(canvas_hit)`: the pointer hits a UiShape and a UiPolygon by their outlines, an Image by its sprite's alpha over `alpha_hit_threshold`, and nothing under the clear part of a sprite mask | 2 | Done |
| 30 | Touch | Each finger is a pointer of its own, with its own press and drag: `input.touches()` in the input library, pointers 1 and up in the events. Not run on a touch screen yet | touch in the input library | Done |
| 31 | Drag threshold by screen density | The threshold is 8 viewport pixels on every screen now | | Open |
| 32 | Watchers | A component sees events another one used, for sounds and analytics | 2 | Open |
| 33 | Pointer events for world objects | The same events, through the same `@(comp_on_pointer)` proc, on a 3D or 2D object with a collider. A raycaster component on a camera finds it, one from each physics plugin | 2 | Done |

## Draw calls

Quads merge into one draw call when they are neighbours in draw order with the same texture, shader and values. Shapes with equal values and size merge now.

| # | Item | What it is | Needs | Status |
|---|---|---|---|---|
| 25 | Batching by draw order | The collector draws nodes that do not overlap together, so a list of background, label, background, label becomes two draws | | Open |
| 26 | Shape values in a shared buffer | Every UiShape draws with one material and reads its values from a buffer by index, so shapes that differ merge too. Stays crisp and free to animate | a per-frame data buffer in gfx | Open |
| 27 | Cached UiShape | A UiShape with `dynamic` off is drawn once into an atlas and is an Image after that. The cheapest per pixel. Fixed resolution, redrawn when a field or the size changes | a runtime sprite atlas | Open |
| 34 | Canvas redrawn only when it changed | A canvas keeps its resolved rects and its graphics' quads, and collects afresh only when a fingerprint of everything under it changes. Every view of a frame, and every frame after it, reuses them. Placing the quads in each view and drawing them is still done every time | | Done |

## Scroll views

| # | Item | What it is | Needs | Status |
|---|---|---|---|---|
| 35 | Recycled rows | A long list shows with a few row nodes that are reused as it scrolls | 4 | Open |
| 36 | Snap and pages | The content comes to rest on a row or a page, with an event when the page changes | 4 | Open |
| 37 | Scrollbars that hide | A bar hides when there is nothing to scroll, and the viewport takes its room | 4 | Open |
| 38 | Scroll follows the selection | A row the keyboard or gamepad selects out of view scrolls into view by itself | 4 | Open |

## With every item

- The UI sample scene gains a panel that shows the feature: `ui_demo.scene` in the `mhgui_sample` package.
- A docs page for each new component, tests, and a scenario where the editor side changes.

## Open questions

- None.
