package editor

// Material Symbols Outlined icon codepoints, as UTF-8 string literals for use in
// imgui text/labels (e.g. `im.Button(ICON_MD_FOLDER + " Assets")`).
//
// imgui does NOT do ligatures, so icons are addressed by their raw Private Use
// Area codepoint (\uXXXX), NOT their ligature name. Values are generated from
// external/fonts/material/MaterialSymbolsOutlined.codepoints; add more entries
// from that file as needed. Font license: Apache-2.0 (see external/fonts/material).
//
// The merge range loaded by editor_fonts_init covers the PUA block these live
// in, so any codepoint from the map works once added here.

ICON_MD_MIN :: 0xe000   // Material Symbols PUA range (inclusive)
ICON_MD_MAX :: 0xf8ff


// Project / assets
ICON_MD_FOLDER      :: "\ue2c7"   // folder
ICON_MD_FOLDER_OPEN :: "\ue2c8"   // folder_open
ICON_MD_DESCRIPTION :: "\ue873"   // description
ICON_MD_IMAGE       :: "\ue3f4"   // image
ICON_MD_MOVIE       :: "\ue684"   // movie
ICON_MD_MUSIC_NOTE  :: "\ue405"   // music_note

// Scene / hierarchy
ICON_MD_LAYERS         :: "\ue53b"   // layers
ICON_MD_WIDGETS        :: "\ue1bd"   // widgets
ICON_MD_DEPLOYED_CODE  :: "\uf720"   // deployed_code
ICON_MD_VISIBILITY     :: "\ue8f4"   // visibility
ICON_MD_VISIBILITY_OFF :: "\ue8f5"   // visibility_off

// Disclosure / navigation
ICON_MD_CHEVRON_RIGHT :: "\ue5cc"   // chevron_right
ICON_MD_CHEVRON_LEFT  :: "\ue5cb"   // chevron_left
ICON_MD_EXPAND_MORE   :: "\ue5cf"   // expand_more
ICON_MD_EXPAND_LESS   :: "\ue5ce"   // expand_less

// Log levels (console)
ICON_MD_INFO          :: "\uf52b"   // info
ICON_MD_WARNING       :: "\uf083"   // warning
ICON_MD_ERROR         :: "\uf8b6"   // error

// Actions
ICON_MD_SAVE          :: "\ue161"   // save
ICON_MD_ADD           :: "\ue145"   // add
ICON_MD_DELETE        :: "\ue92e"   // delete
ICON_MD_CONTENT_COPY  :: "\ue14d"   // content_copy
ICON_MD_CONTENT_PASTE :: "\ue14f"   // content_paste
ICON_MD_MORE_HORIZ    :: "\ue5d3"   // more_horiz
ICON_MD_SETTINGS      :: "\ue8b8"   // settings
ICON_MD_REFRESH       :: "\ue5d5"   // refresh
