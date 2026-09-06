# Text

`packages/text` draws text in the canvas tree (docs/Gui.md). It is a plugin
in the full sense: the engine's canvas tree and `packages/mhgui` know nothing
about it. It hooks in through the seams every graphics package uses: its Text
component embeds `engine.Graphic` and registers as a graphic type
(`canvas_graphic_register`), so the engine's one canvas collector draws it in
hierarchy order next to images, and the editor's pick-provider registry makes
its rects clickable.

## Component

**Text** on a node that also has a RectTransform and a CanvasRenderer:
the shared Graphic fields (`color`, `material`, `raycast_target`), then
`text`, `font` (a `.ttf` or `.otf` file in assets, referenced by guid),
`font_size` in canvas units, `alignment` (nine anchors), `wrap` (break at
spaces at the rect's width) and `line_spacing`. GameObject >
UI > Text creates one with the package's Roboto Medium.

## Layout

`layout_text` is backend-neutral and pure: lines break at `\n` and, when
wrapping, at spaces once a line would pass the rect; a word wider than the
rect stays on its own line. The block is placed by the anchor's row, each
line by its column. Kerning comes from the backend. Output is one quad per
visible glyph in canvas units; `populate_text` hands them to the engine's
canvas collector, which applies the node's transform like any rect.

## Backend

The rasterizer is a `Backend` value with three procs for a font at a pixel
size:

- `metrics` — ascent, descent, line gap.
- `glyph` — advance, quad size and offset from the pen on the baseline, uvs,
  and the guid of the texture the glyph lives in.
- `kern` — the kerning adjustment between two glyphs.

Glyph textures are whatever the backend registers in `engine.texture_cache`
under a guid of its own making, so the renderer treats them like any texture.

The default, `backend_stb.odin`, is stb_truetype: the font file's bytes are
read from the asset path, ASCII and Latin-1 are baked into one bitmap atlas
per (font, size) on first use, glyphs are white with coverage as alpha and
the text color tints them. Crisp at the baked size, blurred when a rect
scales them. No import step, no dependency beyond the stb library the build
already links.

## Replacing the backend

Another package sets its own with `text.backend_set(...)` from an
`ImportersInit` phase proc at an order above 2, so it runs after this
package installs the default. Everything above the backend stays: the
component, layout, collector, editor. Candidates: an SDF or MSDF atlas baked
at import time for resolution independence, or SDL3_ttf's GPU text engine
for shaping and complex scripts. The tests drive layout and the collector
through a fake monospace backend, which is the template for a new one.

## Not yet

Rich text, glyphs outside Latin-1, shaping, clipping to the rect,
best-fit sizing, a multi-line inspector field, and a proper font asset
importer with per-font settings.
