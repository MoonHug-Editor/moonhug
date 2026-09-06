# Text

`packages/text` is TextMeshPro-shaped text for the canvas tree: a font asset
baked at import into a signed-distance-field atlas, and glyphs shaded by an
SDF material, so text stays sharp at any size and gets outline, underlay
shadow, dilation and softness from the shader. A plugin in the full sense:
the engine's canvas tree and `packages/mhgui` know nothing about it. Its Text
component embeds `engine.Graphic` and registers as a graphic type, so the
engine's canvas collector draws it in hierarchy order next to images.

Layout (lines, wrapping, alignment) is backend-neutral and lives in
`layout.odin`. The glyph source behind it is a `Backend` value; the SDF font
is the default, and another package can supply its own.

## Font asset

A `.ttf` or `.otf` in assets imports through the `font` importer into an
artifact: header (sampling size, padding, ascent, descent, line gap, atlas
size), a glyph table (atlas rect, offsets, advance per codepoint), a kerning
table, and the atlas bytes, one byte per pixel with 128 on the glyph edge.
Import settings on the file: `sampling_size` (the height the field is
sampled at, default 64), `padding` (the field's reach around each glyph, the
room outlines and shadows have, default 8), `atlas_size` (grows in powers of
two until the glyphs fit), `latin1` (bake U+00A0..U+00FF too). Reimporting
evicts the cached font.

At runtime `font_load` reads the artifact, uploads the atlas as a white
texture with the field in alpha, registers it in the engine's texture cache
under a guid derived from the font's, and serves metrics and glyphs scaled by
`font_size / sampling_size`. One atlas serves every size.
An artifact that fails to parse triggers one forced reimport in the editor
before the font is cached as empty.

## Component

**Text**: the shared Graphic fields (`color`, `material`, `raycast_target`),
then `text`, `font`, `font_size`, `alignment` (nine anchors), `wrap` (break
at spaces at the rect's width), `line_spacing`. The `material` must be an SDF
material; `assets/materials/TextSDF.mat` ships with the package and
GameObject > UI > Text assigns it along with the package's Roboto Medium.
With the plain unlit shader the raw distance field would draw as blurred
blobs.

## Layout

`layout_text` is pure and backend-neutral: lines break at `\n` and, when
wrapping, at spaces once a line would pass the rect; a word wider than the
rect stays on its own line. The block is placed by the anchor's row, each
line by its column. Kerning comes from the backend. Output is one quad per
visible glyph in canvas units; `populate_text` hands them to the engine's
canvas collector, which applies the node's transform like any rect.

## Backend

The glyph source is a `Backend` value with three procs for a font at a pixel
size: `metrics` (ascent, descent, line gap), `glyph` (advance, quad size and
offset from the pen on the baseline, uvs, the texture guid) and `kern`.
Glyph textures are whatever the backend registers in `engine.texture_cache`.
The SDF font is the default (`sdf_backend`). Another package replaces it with
`backend_set` from an `ImportersInit` phase proc at an order above 2, and the
component, layout, collector and editor stay. The tests drive layout and the
collector through a fake monospace backend, which is the template.

## Shader

`assets/shaders/text_sdf.glsl`, a user shader through the material system
(docs/Materials.md). It thresholds the field at 0.5 with an anti-aliasing
width taken from the field's screen-space derivative, so the edge is one
pixel soft at every size. Material properties, all in field units unless
noted:

- `outline_color`, `outline_width` — a second threshold outside the face.
- `underlay_color`, `underlay_offset` (atlas uv units, about 0.002 per
  pixel at 1024), `underlay_softness` — the field sampled at an offset,
  blurred, composited behind.
- `softness` — extra blur on the glyph edge.
- `dilate` — grows or thins the glyph.

Make a copy of the material per look, as with TextMeshPro's material
presets.

## Not yet

Rich text tags, per-character effects, gradients and glow, auto-size and
overflow modes, glyphs outside Latin-1, shaping. MSDF (multi-channel) would
sharpen corners at large scales; the artifact format has room for a channel
count.
