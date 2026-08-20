# Editor fonts

Fonts for the **editor UI chrome** (not app/game resources — those live in
`assets/`).

Text uses imgui's built-in **ProggyClean** (a crisp 13px bitmap font, no file
needed). Icons are **Material Symbols Outlined**, merged into that font and
embedded into the editor binary at compile time via `#load` in
`moonhug/editor/fonts.odin` — so the icon files must be present to build.

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
- Both text and the icon merge load at an explicit 13px (ProggyClean's native
  size) so the merge can nudge icon baseline via `GlyphOffset` — see
  `editor_fonts_init`.
