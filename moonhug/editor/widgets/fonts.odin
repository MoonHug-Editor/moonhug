package widgets

// The editor's base font size and its large icon font, for views outside the
// editor root package. The editor loads the fonts (editor/fonts.odin) and sets
// the font here at init (widgets can't import the editor).

import im "moonhug:external/odin-imgui"

// Roboto Medium's pixel size, the base UI font.
FONT_SIZE :: 15

// The standalone large Material icon font. Nil until the fonts load.
icon_font_lg: ^im.Font
