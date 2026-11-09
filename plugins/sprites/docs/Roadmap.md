---
title: "Roadmap"
description: "What the sprites plugin does not do yet"
weight: 900
tags: ["sprites", "roadmap"]
---

What the sprites plugin does not do yet. How it works is in [Sprites and slices](concepts/SpritesAndSlices.md) and [Sorting](concepts/Sorting.md).

## Next

- **Sprite atlas, for batching.** A `.spriteatlas` asset packs slices from many textures into one atlas artifact, and the sprite quad looks its texture and UVs up through the atlas, so renderers and scenes do not change. The `PPtr` of a sprite is the lookup key.

## Open

- 9-slice and tiled drawing in the SpriteRenderer. The borders exist on every slice and the UI plugin's Image draws them.
- Sprite masks.
