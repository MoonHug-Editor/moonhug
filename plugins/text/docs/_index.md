---
title: "text"
description: "Sharp text for the UI canvas: fonts baked to signed-distance-field atlases at import, the Text component with styles, alignment and overflow, and an SDF material with outline and shadow"
tags: ["text", "ui", "plugin"]
---

The text plugin draws text on the UI canvas. A font imports into a signed-distance-field atlas, and glyphs draw through an SDF material, so text stays sharp at any size and gets an outline, a shadow, dilation and softness from the shader. Layout is separate from the glyph source, so another plugin can supply its own.

The engine's canvas tree and the mhgui plugin know nothing about this plugin. Text embeds `engine.Graphic` and registers as a graphic, so the canvas collector draws it in hierarchy order next to images.

## What it adds

**Components**

- [Text](components/Text.md) draws a string in its rect, with styles, alignment, wrapping and overflow.

**Assets**

- [Font](assets/Font.md): a `.ttf` or `.otf`, baked to an SDF atlas, with glyphs it lacks added at runtime.
- [SDF material](assets/SDFMaterial.md): the shader and material text draws with, and their outline and shadow settings.

**Concepts**

- [Layout](concepts/Layout.md): lines, wrapping, alignment and overflow, and the glyph backend under them.

[Roadmap](Roadmap.md): rich text, effects and what else is not built.

## What it needs

- The engine plugin, whose canvas tree and material system Text uses.
- It ships `Roboto-Medium.ttf`, `materials/TextSDF.mat` and `shaders/text_sdf.glsl`.

## Quick start

1. GameObject, UI, Text: a Text under the selected canvas, with Roboto Medium and the SDF material.
2. Type in its text area and set the size and alignment.
3. For an outline, copy `TextSDF.mat`, set its `outline_width` and colour, and pick the copy in the Text's `material`.

## Extending

The plugin declares no attributes. `backend_set` replaces the glyph source from an `ImportersInit` phase proc at an order above 2, and the component, the layout, the drawing and the editor stay ([Layout](concepts/Layout.md), "Backends").

## Limits

- No rich text tags, per-character effects, gradients or glow.
- No shaping, so scripts that join or reorder glyphs draw wrong.

## Reference

- [API reference](/docs/reference/packages/text/text.md) of the `text` package.
