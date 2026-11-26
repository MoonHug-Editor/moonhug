package widgets

// The editor's base font size and its large icon font, for windows outside the
// editor root package. The editor loads the fonts (editor/fonts.odin) and sets
// the font here at init (widgets can't import the editor).

import im "moonhug:external/odin-imgui"

// Roboto Medium's pixel size, the base UI font.
FONT_SIZE :: 15

// The standalone large Material icon font. Nil until the fonts load.
icon_font_lg: ^im.Font

// The inspectors' two text fonts at FONT_SIZE, icons merged: Roboto Light for
// rows, and the base Roboto Medium for header names. Nil until the fonts
// load, and pushing nil keeps the current font, so code that pushes them runs
// in a test too.
font_rows: ^im.Font
font_headers: ^im.Font
