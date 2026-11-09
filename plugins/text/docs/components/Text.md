---
title: "Text"
description: "A UI graphic that draws a string in its rect: font, size and auto size, styles, alignment, wrapping, overflow and spacing"
weight: 10
tags: ["text", "components"]
---

A UI graphic that draws a string in its rect. It needs a RectTransform and a CanvasRenderer on its node ([UI canvas](/plugins/engine/docs/UICanvas.md)).

## Example

```
Score      RectTransform size_delta 300, 50, CanvasRenderer, Text text "Score: 0", font_size 36, horizontal_alignment Right
```

The score sits right-aligned in its rect. Game code sets `text` as the score changes.

## Properties

| Field | Default | What it does |
|---|---|---|
| `color`, `material`, `raycast_target` | white, none, on | The graphic's colour, its material, and whether the pointer can hit it. The material must be an [SDF material](../assets/SDFMaterial.md). |
| `text` | empty | The string, edited in a text area. |
| `font` | none | The [Font](../assets/Font.md) asset. |
| `font_size` | 36 | The size in canvas units. |
| `auto_size` | off | Picks the largest size from `auto_size_min` to `auto_size_max` whose text fits the rect. |
| `auto_size_min`, `auto_size_max` | 18, 72 | The auto size range. |
| `font_style` | none | Flags: Bold, Italic, Underline, Strikethrough, and one of Lowercase, Uppercase and Smallcaps. |
| `horizontal_alignment` | Left | Left, Center, Right, Justified or Flush. |
| `vertical_alignment` | Top | Top, Middle, Bottom, Baseline, Midline or Capline. |
| `wrap` | on | Breaks lines at spaces where a line would pass the rect. |
| `overflow` | Overflow | What happens to text that does not fit: Overflow, Ellipsis, Truncate or Masking. |
| `character_spacing`, `word_spacing`, `line_spacing`, `paragraph_spacing` | 0 | Hundredths of the font size, added to the font's own spacing. |
| `margins` | 0 | Left, top, right and bottom, in canvas units taken off the rect. |
| `kerning` | on | Uses the font's kerning pairs. |
| `parse_escape_characters` | off | `\n`, `\t` and `\\` typed into the text become those characters. |

## Styles

- **Bold** draws each glyph twice, a small offset apart, with bold spacing.
- **Italic** shears the glyphs around the baseline.
- **Underline** and **Strikethrough** stretch the font's `_` glyph along the line.
- **Smallcaps** draws lowercase letters as capitals at 80% of the size.

## Alignment and overflow

- **Justified** spreads a wrapped line's slack into its spaces. **Flush** does that for the last line too.
- **Baseline**, **Midline** and **Capline** put the first line's baseline, midline or cap height on the rect's center.
- **Ellipsis** cuts at the last line that fits and ends it with `...`. **Truncate** cuts there. **Masking** clips the glyphs to the rect.

## In the editor

- GameObject, UI, Text adds one with Roboto Medium and `TextSDF.mat`.
- The inspector draws the text area and the style toggles through the regular rows, so undo, multi-editing and prefab overrides work as on any field.

## See also

- [Layout](../concepts/Layout.md)
