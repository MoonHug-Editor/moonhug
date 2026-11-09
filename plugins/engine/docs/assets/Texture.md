---
title: "Texture"
description: "A .png, .jpg, .bmp or .hdr image: filtering, wrapping, colour space, size, mipmaps, and its sprite slices and pixels per unit"
weight: 10
tags: ["engine", "assets"]
path: engine/assets
---

A `.png`, `.jpg`, `.jpeg`, `.bmp` or `.hdr` image. Materials, sprites, UI images, particles and the sky use it. An `.hdr` file imports as a linear float texture.

## Import settings

Shown in the Project Inspector when the texture is selected, and applied with Apply or dropped with Revert.

| Setting | Default | What it does |
|---|---|---|
| `filter` | Linear | Linear blends between texels. Nearest keeps them square, for pixel art. |
| `wrap` | Repeat | Repeat, Clamp or Mirror, past the texture's edge. |
| `srgb` | on | The texture holds colour. Off for data such as normal and roughness maps. |
| `max_size` | 0 | Stored, but the importer does not apply it yet. |
| `mipmaps` | Generate | Generate makes the chain of smaller copies a texture seen small samples from. None suits a sliced sprite atlas, whose slices would bleed into each other. |
| `pixels_per_unit` | 100 | A sprite's world size is its pixel size divided by this. 100 pixels are 1 metre, the size physics assumes. |
| `sprite_mode` | Single | Single uses the whole texture as one sprite. Multiple lists slices in `sprites`. |
| `sprites` | empty | The slices: id, name, rectangle, pivot and borders, edited in the sprites plugin's Sprite Editor. |
| `sprite_border` | 0 | Single mode's 9-slice borders in pixels. |

## In the editor

- The Project Inspector shows the settings, a preview, and with the sprites plugin a Sprite Editor button.
- A sliced texture unfolds into its sprites in the Project window, and a sprite drags onto a Sprite field.

## See also

- [Sprites and slices](/plugins/sprites/docs/concepts/SpritesAndSlices.md)
