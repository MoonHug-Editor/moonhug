# Editor fonts

Fonts for the **editor UI chrome** (not app/game resources — those live in
`assets/`).

Text is **Roboto** at 15px: Medium for the editor and the inspectors' header
names (the file ships with imgui,
`moonhug/external/odin-imgui/imgui/misc/fonts`), Light for the inspectors'
rows (`roboto/`). Icons are **Material Symbols Outlined**, merged into each
text font. All of them are embedded into the editor binary at compile time via
`#load` in `moonhug/editor/fonts.odin`, so the files must be present to build.

## `roboto/`

- `Roboto-Light.ttf`: **Apache-2.0** (`LICENSE-Roboto.txt`). From the v2.138
  release of https://github.com/googlefonts/roboto (`roboto-unhinted.zip`).

## `material/`

- `MaterialSymbolsOutlined.ttf` — icon font. **Apache-2.0**
  (`LICENSE-Material.txt`). From https://github.com/google/material-design-icons
  (the variable font works; loaded at its default instance = wght 400, FILL 0).
- `MaterialSymbolsOutlined.codepoints` — icon name → codepoint map. The
  `ICON_MD_*` constants in `moonhug/editor/material_icons.odin` mirror the subset
  the editor uses; extend from this file as needed.
- `LICENSE-Material.txt` — Apache-2.0 license text.

## Notes

- imgui does NOT do ligatures — icons are addressed by raw codepoint
  (`\uXXXX`), not name. See `material_icons.odin`.
- Each text font and its icon merge load at an explicit 15px so the merge can
  nudge the icon baseline via `GlyphOffset`. See `editor_fonts_init`.
