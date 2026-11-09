---
title: "sprites"
description: "2D sprites: the SpriteRenderer and SpriteSortingGroup components, texture slices edited in the Sprite Editor, sprite sorting and a fade tween for timelines"
tags: ["sprites", "plugin"]
---

The sprites plugin draws textures and their slices as quads in the world. A SpriteRenderer shows one sprite with a tint and a material, a SpriteSortingGroup keeps a hierarchy of sprites together in the draw order, and the Sprite Editor cuts a texture into slices.

## What it adds

**Components**

- [SpriteRenderer](components/SpriteRenderer.md) draws a sprite on its object.
- [SpriteSortingGroup](components/SpriteSortingGroup.md) sorts the sprites under it as one unit.

**Scripts**

- [TweenFadeTo](scripts/TweenFadeTo.md) fades a SpriteRenderer on a timeline. Needs the sequencer plugin.

**Windows**

- [Sprite Editor](windows/SpriteEditorWindow.md): cuts a texture into slices, with their pivots and borders.

**Concepts**

- [Sprites and slices](concepts/SpritesAndSlices.md): what a sprite is, how big it draws and how it is referenced.
- [Sorting](concepts/Sorting.md): the order sprites draw in.

[Roadmap](Roadmap.md): what is not built yet.

## What it needs

- The engine plugin, whose texture import settings hold the slices and the pixels per unit ([Asset pipeline](/docs/core/AssetPipeline.md)).
- Optional, the sequencer plugin. It adds TweenFadeTo. It lives in the plugin's `sequencer` subpackage, which builds only when the sequencer plugin is enabled ([Plugins](/docs/core/Plugins.md)).

## Quick start

1. Drop a `.png` into the project.
2. Add Component, Rendering/SpriteRenderer on any object, and pick the texture in its Sprite row.
3. To cut a sheet into sprites, select the texture and press Sprite Editor under its import settings, slice it, Apply, then pick a slice in the Sprite row.

## Extending

The plugin declares no attributes and has no registries. It is the first plugin to render through the engine's `@(render_collector)` ([Sprites and slices](concepts/SpritesAndSlices.md), "Rendering").

## Limits

- One quad per sprite, axis-aligned to its object. No 9-slice drawing in the SpriteRenderer, no tiling and no sprite masks.
- No sprite atlas: each texture is its own draw.

## Reference

- [API reference](/docs/reference/packages/sprites/sprites.md) of the `sprites` package, and of its [sequencer integration](/docs/reference/packages/sprites/sequencer.md).
