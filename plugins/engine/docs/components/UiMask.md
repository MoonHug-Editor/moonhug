---
title: "UiMask"
description: "Clips the UI nodes under it to its rect, with a radius per corner, a soft edge and the alpha of a sprite: what lies outside is not drawn and takes no pointer"
weight: 150
tags: ["engine", "ui", "components", "mask", "clipping"]
path: engine/components
---

Clips the nodes under it to its rect. What lies outside the rect is not drawn and takes no pointer.

## Example

```
Viewport       RectTransform size_delta 300, 200, CanvasRenderer, Image, UiMask
└── Content    RectTransform size_delta 300, 900
    ├── Row 1  RectTransform, CanvasRenderer, Image, Button
    └── ...
```

The rows show inside the viewport's 300 by 200 rect only. A row that is half out is cut at the edge, and its hidden half cannot be pressed. Moving Content up and down scrolls the rows.

## Properties

| Field | Default | What it does |
|---|---|---|
| `corner_radius` | 0 each | A radius per corner, in canvas units: top left, top right, bottom right, bottom left. A radius is cut to half the shorter side, so a large one on a square makes a circle. |
| `softness` | 0 | The width the edge fades over, inward, in canvas units. 0 is a crisp edge. |
| `sprite` | none | An image whose alpha shapes the mask, stretched over the rect. See "A mask from a sprite". |

The rect it clips to is the node's own, from its RectTransform.

## Behavior

- The clip follows the node: turned or scaled, and on a canvas in the world or before a camera seen at any angle, the nodes under it are cut along its own edges.
- A crisp edge is one pixel soft, so a turned mask and a round corner have no stair steps.
- The node's own graphic is not clipped. It is the picture behind the content. Give it the mask's radii, a UiShape with the same `corner_radius`, and the content follows the card's corners.
- The pointer follows the outline: a round corner's cut-away part takes no pointer.
- Disabling the component stops the clipping.

## A mask in a mask

A node is cut by every mask above it, each with its own corners, its own soft edge and its own angle. A list in a panel with round corners is cut by the list's rect and by the panel's round corners.

- At most 8 masks cut one node. Past that, the nearest 8 do.
- The pointer follows every mask above a node, with no such limit.

## A mask from a sprite

With a `sprite` the mask also multiplies what is under it by the sprite's alpha: the content shows where the image is opaque, fades where it fades and is gone where it is clear. Any outline an image has, a heart or a torn edge, and any fade, a vignette or a list that fades out at both ends.

- The sprite stretches over the mask's rect, whatever its own aspect. A slice of a sliced texture works, and its 9-slice borders are not used.
- The rect, the corner radii and the soft edge still clip. Leave the radii at 0 to see the whole sprite.
- The colour of the image does not matter, only its alpha.
- The texture's own filter applies: Linear gives a smooth outline, Nearest a pixel-art one.
- The mask draws nothing itself. To show the image too, put an Image with the same sprite on the node or behind it.
- One sprite cuts a node: of the masks above it the nearest one with a sprite uses its sprite, and the masks above that one clip by their rect and corners.
- The pointer goes by the rect and its corners, not by the sprite: a clear part of the image inside the rect still takes the pointer.
- Nodes under masks with different sprites do not share a draw call.

## Draw calls

A mask adds no draw call of its own. The nodes under the same masks draw together as they do with no mask. A run of quads ends where the masks change: where a node under a mask is followed in draw order by one outside it, or by one under another mask.

## Shaders

The shader of a clipped quad does the clipping: it multiplies the alpha of its output by how much of the pixel is inside the masks.

- The built-in unlit shader, which a UI graphic with no material draws with, clips.
- A shader of a material clips as the project's **UiMask** setting says (Edit, Project Settings, UiMask, `shader_clip`):

| Option | What it does |
|---|---|
| Auto Inject (the default) | Every shader clips with nothing written in it. The importer adds the clip to each fragment shader it compiles, after the shader's own code, on the alpha of its output. |
| Manual Include | A shader clips where it says so, and nothing is added to it. |

The tab shows a description of the chosen option. A change compiles the project's shaders again.

### Manual Include

```glsl
#include "ui_clip.glsl"

void main() {
    out_color = ...;
    out_color.a *= ui_clip();
}
```

- `ui_clip()` is 1 for a quad under no mask.
- Place the call where the clip belongs: before a glow that should spill past the mask, after everything else to cut it all.
- A material whose shader does not call it draws whole under a mask. The Console names the material once.
- The same shader compiles on Auto Inject too: there `ui_clip()` is 1 and the importer's clip does the work, so the clip applies once.

### Auto Inject

- The importer renames the shader's `main()` and adds one after the shader's code that runs it and clips. The lines of the shader keep their numbers in compile errors.
- It needs one `void main(` and an output declared as `layout(location = 0) out vec4 <name>;`. A shader without them fails to import with a message that says which is missing.
- A shader used for a full-screen effect gets the clip too and is never under a mask, so nothing changes for it.
- A shader with the clip reads a mask's sprite at sampler `set = 2, binding = 6`, so its own textures use bindings 1 to 5. One that declares a texture at binding 6 fails to import with a message that says so. This holds for Manual Include shaders that include `ui_clip.glsl` as well.
- Surface shaders, the ones that write `surface()` and no `main()`, are not clipped in either setting. A lit material under a mask draws whole, and the Console names it once.

## Limits

- At most 8 masks cut one node.
- A soft edge wider than a corner's radius shows a faint crease running in from that corner.
- One sprite per node: the nearest mask's with one.
- The pointer does not follow a sprite's alpha.
- Surface (lit) shaders are not clipped.
