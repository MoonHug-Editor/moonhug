---
title: "Texture"
description: "A .png, .jpg, .bmp or .hdr image: its type, filtering, wrapping, size, mipmaps, and its sprite slices and pixels per unit"
weight: 10
tags: ["engine", "assets"]
path: engine/assets
---

A `.png`, `.jpg`, `.jpeg`, `.bmp` or `.hdr` image. Materials, sprites, UI images, particles and the sky use it. An `.hdr` file imports as a linear float texture.

## Import settings

Shown in the Project Inspector when the texture is selected, and applied with Apply or dropped with Revert.

| Setting | Default | What it does |
|---|---|---|
| `texture_type` | Default | What the texture is for: Default or Sprite. Choosing a type sets the settings it expects: a Sprite clamps, a Default texture repeats. Use Sprite for sprites, UI images and particles. |
| `filter` | Linear | Linear blends between texels. Nearest keeps them square, for pixel art. |
| `wrap` | Repeat | Past the texture's edge: Repeat, Clamp or Mirror. A sprite that repeats can show a faint line of its opposite edge, so a Sprite clamps. |
| `srgb` | on | How `max_size` filters the image. On, as colour, in linear light, so the scaled colours keep their brightness. Off, the values as they are, for data such as normal maps. Drawing does not read it: each material slot decodes its texture as colour or as data. |
| `max_size` | 0 | Scales a larger image down at import so its larger side is this many pixels, keeping its aspect. 0 keeps its size. Sprite slices, pixels per unit and native sizes stay in source pixels, so the smaller texture keeps its world size. |
| `mipmaps` | Generate | Generate makes the chain of smaller copies a texture seen small samples from. None suits a sliced sprite atlas, whose slices would bleed into each other. |
| `pixels_per_unit` | 100 | A sprite's world size is its pixel size divided by this. 100 pixels are 1 metre, the size physics assumes. |
| `sprite_mode` | Single | Single uses the whole texture as one sprite. Multiple lists slices in `sprites`. |
| `sprites` | empty | The slices: id, name, rectangle, pivot and borders, edited in the sprites plugin's Sprite Editor. |
| `sprite_border` | 0 | Single mode's 9-slice borders in pixels. |

Meshes, sprites, UI images and particles sample the texture with its `filter` and `wrap`. Post-processing steps read their images linear and clamped, whatever the settings say.

## Artifact

The source file's bytes, which an export ships. A texture `max_size` scales down is a PNG instead, or a Radiance file for an `.hdr`, behind a header naming the source's size.

## In the editor

- The Project Inspector shows the settings, a preview, and with the sprites plugin a Sprite Editor button.
- Choosing a `texture_type` changes `wrap` in the same undo step.
- A sliced texture unfolds into its sprites in the Project window, and a sprite drags onto a Sprite field.

## See also

- [Sprites and slices](/plugins/sprites/docs/concepts/SpritesAndSlices.md)
