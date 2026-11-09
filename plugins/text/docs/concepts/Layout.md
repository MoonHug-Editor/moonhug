---
title: "Layout"
description: "How text is laid out into glyph quads, separate from where the glyphs come from, and how a backend supplies them"
weight: 10
tags: ["text", "concepts"]
---

How text becomes quads. Layout, in `layout.odin`, knows nothing about where glyphs come from. The glyph source is a backend.

## Layout

`layout_text` is a pure proc. It takes a `Layout_Params`, the string and the rect, and returns the quads, whether the backend served the font, and whether the text overflows the rect before any cut.

- Lines break at `\n` and, when wrapping, at spaces once a line would pass the rect. A word wider than the rect stays on its own line. A tab advances four spaces.
- The block is placed by the vertical alignment, and each line by the horizontal one.
- The output is one quad per visible glyph in canvas units, plus the style extras: bold copies, underline and strikethrough bars. A quad carries a `skew` for italics, which the engine's quad passes to the collector.
- `canvas_populate_Text` applies the margins, the escape characters and auto size, which bisects for the largest size that fits, and hands the quads to the engine's canvas collector. The collector applies the node's transform like any rect's.

## Backends

A `Backend` is three procs for a font at a pixel size:

| Proc | What it returns |
|---|---|
| `metrics` | Ascent, descent and line gap. |
| `glyph` | Advance, quad size and offset from the pen on the baseline, UVs, and the texture's guid. |
| `kern` | The kerning between two codepoints. |

Glyph textures are whatever the backend registers in the engine's texture cache. The SDF font is the default, `sdf_backend`. Another plugin replaces it with `backend_set` from an `ImportersInit` phase proc at an order above 2. The tests drive layout and the collector with a fake monospace backend, which is the template for a new one.
