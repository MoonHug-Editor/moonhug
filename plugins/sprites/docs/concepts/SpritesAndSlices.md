---
title: "Sprites and slices"
description: "What a sprite is: a texture or one of its slices, sized by pixels per unit, referenced by texture guid and slice id, drawn as a quad"
weight: 10
tags: ["sprites", "concepts"]
---

A sprite is a texture or a rectangle of one. The code is `render.odin`, and the slices live in the engine's texture import settings.

## Textures and slices

- A texture's import settings say whether it is one sprite or many: `sprite_mode` Single uses the whole texture, Multiple lists slices in `sprites`.
- A slice has a persistent id, a name, a rectangle in pixels, a pivot from 0 to 1 within the rectangle, and borders in pixels for 9-slice drawing. The [Sprite Editor](../windows/SpriteEditorWindow.md) edits them.
- The slices are import data, so they bake into the catalog with the texture's other settings and reach a game build with nothing else to do.

## References

A SpriteRenderer's `sprite` is a `PPtr`: the texture's guid and a slice's id. Id 0 is the whole texture. The id stays when a slice is renamed or moved, so references survive editing the slices.

## Size

A sprite's world size is its pixel size divided by the texture's `pixels_per_unit`, 100 by default, times its object's scale. At 100, 100 pixels are 1 world unit, 1 metre, the size physics assumes.

## Rendering

- The plugin's `@(render_collector)` emits one quad per SpriteRenderer into the transparent pass, with its sort key ([Sorting](Sorting.md)). The engine sorts and draws them.
- The quad lies in the object's XY plane, placed by its pivot. Whole textures have a centered pivot.
- The editor picks, outlines and frames sprites by the same quads the collector emits, so what is clicked is what is drawn.
