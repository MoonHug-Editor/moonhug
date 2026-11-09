---
title: "Font"
description: "A .ttf or .otf file, baked at import into a signed-distance-field atlas that serves every size, with glyphs it lacks added at runtime"
weight: 10
tags: ["text", "assets"]
---

A `.ttf` or `.otf` file. The importer bakes it into a signed-distance-field atlas: one atlas serves every size, and the shader draws edges, outlines and shadows from the field.

## Import settings

| Setting | Default | What it does |
|---|---|---|
| `sampling_size` | 64 | The glyph height, in pixels, the field is sampled at. Sizes scale from it. |
| `padding` | 8 | Pixels of field around each glyph: how far outlines and shadows can reach. |
| `atlas_size` | 1024 | The atlas side in pixels. It grows in powers of two until the glyphs fit. |
| `latin1` | on | Also bakes U+00A0 to U+00FF. ASCII is always baked. |

## Artifact

- A header with the sampling size, padding, ascent, descent, line gap and atlas size, a glyph table with each glyph's atlas rect, offsets and advance, a kerning table, and the atlas, one byte per pixel with 128 on the glyph's edge.
- The font file itself, so glyphs and kerning pairs outside the bake come from it at runtime.
- A reimport drops the loaded font.

## At runtime

- `font_load` reads the artifact, uploads the atlas as a white texture with the field in alpha, registers it in the engine's texture cache, and serves metrics and glyphs scaled by `font_size / sampling_size`.
- A glyph outside the baked ranges is rendered from the font file on first use into a second atlas, the dynamic page, 1024 pixels square, uploaded region by region and kept.
- A glyph the font does not have draws as `?`, and so does anything once the dynamic page is full.
- In the editor, an artifact that fails to load triggers one reimport before the font is cached as empty.
