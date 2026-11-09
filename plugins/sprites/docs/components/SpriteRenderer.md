---
title: "SpriteRenderer"
description: "Draws a sprite, a texture or one of its slices, as a quad on its object, with a tint, a material and sort keys"
weight: 10
tags: ["sprites", "components"]
---

Draws a sprite, a whole texture or one of its slices, as a quad on its object.

## Example

```
Player          SpriteRenderer: sprite hero.png / idle_0, sorting_layer 1
└── Shadow      SpriteRenderer: sprite shadow.png, color 0,0,0,0.5, order_in_layer -1
```

## Properties

| Field | Default | What it does |
|---|---|---|
| `sprite` | none | The texture, or one of its slices. Drawn by the Sprite row, which offers the texture's slices. |
| `material` | none | The material the quad draws with. Its shader, tint and properties apply, but its texture is replaced by the sprite's. Empty is the default unlit sprite material. |
| `color` | white | The tint, alpha included. |
| `sorting_layer` | 0 | The first sort key ([Sorting](../concepts/Sorting.md)). |
| `order_in_layer` | 0 | The second sort key. |

## Behavior

- The quad lies in the object's XY plane, oriented by its transform, not facing the camera. Its size is the sprite's pixel size divided by the texture's pixels per unit, times the object's scale ([Sprites and slices](../concepts/SpritesAndSlices.md)).
- A slice id the texture no longer has draws nothing.
- Sprites draw in the transparent pass, sorted with particles and UI by their sort keys.

## In the editor

- The Sprite row shows the pick as `texture/slice`. Its picker lists every sprite in one list: a Single texture as its one sprite, a sliced texture as its slices. A texture dropped on the row picks the whole texture, a slice dragged from the Project window picks that slice. The ParticleSystem uses the same row.
- Clicking a sprite in the Scene window picks it, by the same quad it draws.

## From code

```odin
import "moonhug:packages/sprites"

_, sr := engine.transform_get_comp(player, sprites.SpriteRenderer)
sr.sprite = {guid = hero_texture, local_id = idle_slice}
sr.color.a = 0.5
```

## See also

- [SpriteSortingGroup](SpriteSortingGroup.md)
- [TweenFadeTo](../scripts/TweenFadeTo.md), fading a sprite on a timeline.
