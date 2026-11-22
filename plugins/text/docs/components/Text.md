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
| `rich_text` | off | Tags in the text style parts of it, below. |

## Styles

- **Bold** draws each glyph twice, a small offset apart, with bold spacing.
- **Italic** shears the glyphs around the baseline.
- **Underline** and **Strikethrough** stretch the font's `_` glyph along the line.
- **Smallcaps** draws lowercase letters as capitals at 80% of the size.

## Rich text

With `rich_text` on, tags in the string style the part between them and do not show:

```
<b>Level up!</b> You gain <color=#ffcc33>120 gold</color> and <size=150%>a new skill</size>.
```

| Tag | What it does |
|---|---|
| `<b>` `<i>` `<u>` `<s>` | Bold, italic, underline, strikethrough. |
| `<color=#rrggbb>` | A colour in place of the Text's own. Also `#rgb`, `#rrggbbaa` with alpha, and a name: white, black, red, green, blue, yellow, orange, purple, cyan, magenta, grey. |
| `<size=24>` | A size in canvas units. `<size=150%>` is a share of the Text's `font_size`, and `<size=+4>` or `<size=-4>` steps from the size around the tag. |

- Each tag runs until its closing tag: `</b>`, `</color>`, `</size>`. One left open runs to the end of the text.
- Tags nest. A closing tag ends the nearest open one of its kind, and the colour or size around it comes back.
- Tag names ignore case, and a value may be in quotes: `<COLOR="red">`.
- What is in brackets and is no tag stays in the text as typed: `a < b`, `<3`, `<unknown>`.
- A line is as tall as the largest size on it needs.
- An underline or a strikethrough under a span is the span's width and colour.
- A span's colour keeps the alpha of the Text's `color`, so a Text that fades takes its spans along. A control's colour tint does not change a span's colour.
- With `auto_size` on, sizes given in units stay as they are and percentages follow the fitted size.

## Alignment and overflow

- **Justified** spreads a wrapped line's slack into its spaces. **Flush** does that for the last line too.
- **Baseline**, **Midline** and **Capline** put the first line's baseline, midline or cap height on the rect's center.
- **Ellipsis** cuts at the last line that fits and ends it with `...`. **Truncate** cuts there. **Masking** clips the glyphs to the rect.

## In the editor

- GameObject, UI, Text adds one with Roboto Medium and `TextSDF.mat`.
- The inspector draws the text area and the style toggles through the regular rows, so undo, multi-editing and prefab overrides work as on any field.

## See also

- [Layout](../concepts/Layout.md)
