package menu

import im "moonhug:external/odin-imgui"

// Community imgui themes, taken as published (values from the ImThemes
// catalog, https://github.com/Patitotective/ImThemes, which collects the
// styles posted in https://github.com/ocornut/imgui/issues/707). Each proc
// sets every color the original author set plus the style scalars the author
// shipped. Colors imgui added after these themes were published are derived
// in _derive_recent_colors with imgui's own StyleColorsDark rules.
//
// Names imgui renamed since: TabActive -> TabSelected, TabUnfocused ->
// TabDimmed, TabUnfocusedActive -> TabDimmedSelected, NavHighlight ->
// NavCursor.

// The colors imgui introduced after 1.89, derived the way StyleColorsDark
// derives them from the classic set.
@(private = "file")
_derive_recent_colors :: proc(c: ^[im.Col.COUNT]im.Vec4) {
	fb, fbh := c[im.Col.FrameBg], c[im.Col.FrameBgHovered]
	c[im.Col.CheckboxSelectedBg]        = fb + (fbh - fb) * 0.65
	c[im.Col.InputTextCursor]           = c[im.Col.Text]
	c[im.Col.TabSelectedOverline]       = c[im.Col.HeaderActive]
	c[im.Col.TabDimmedSelectedOverline] = {0.500, 0.500, 0.500, 0.000}
	c[im.Col.DockingPreview]            = c[im.Col.HeaderActive] * im.Vec4{1, 1, 1, 0.7}
	c[im.Col.DockingEmptyBg]            = c[im.Col.WindowBg]
	c[im.Col.TextLink]                  = c[im.Col.HeaderActive]
	c[im.Col.TreeLines]                 = c[im.Col.Border]
	c[im.Col.DragDropTargetBg]          = {0.000, 0.000, 0.000, 0.000}
	c[im.Col.UnsavedMarker]             = c[im.Col.Text]
}

// Photoshop by Derydoca: "Inspired by Photoshop's UI."
style_colors_photoshop :: proc() {
	s := im.GetStyle()
	c := &s.Colors
	c[im.Col.Text]                      = {1.000, 1.000, 1.000, 1.000}
	c[im.Col.TextDisabled]              = {0.498, 0.498, 0.498, 1.000}
	c[im.Col.WindowBg]                  = {0.176, 0.176, 0.176, 1.000}
	c[im.Col.ChildBg]                   = {0.278, 0.278, 0.278, 0.000}
	c[im.Col.PopupBg]                   = {0.310, 0.310, 0.310, 1.000}
	c[im.Col.Border]                    = {0.263, 0.263, 0.263, 1.000}
	c[im.Col.BorderShadow]              = {0.000, 0.000, 0.000, 0.000}
	c[im.Col.FrameBg]                   = {0.157, 0.157, 0.157, 1.000}
	c[im.Col.FrameBgHovered]            = {0.200, 0.200, 0.200, 1.000}
	c[im.Col.FrameBgActive]             = {0.278, 0.278, 0.278, 1.000}
	c[im.Col.TitleBg]                   = {0.145, 0.145, 0.145, 1.000}
	c[im.Col.TitleBgActive]             = {0.145, 0.145, 0.145, 1.000}
	c[im.Col.TitleBgCollapsed]          = {0.145, 0.145, 0.145, 1.000}
	c[im.Col.MenuBarBg]                 = {0.192, 0.192, 0.192, 1.000}
	c[im.Col.ScrollbarBg]               = {0.157, 0.157, 0.157, 1.000}
	c[im.Col.ScrollbarGrab]             = {0.275, 0.275, 0.275, 1.000}
	c[im.Col.ScrollbarGrabHovered]      = {0.298, 0.298, 0.298, 1.000}
	c[im.Col.ScrollbarGrabActive]       = {1.000, 0.388, 0.000, 1.000}
	c[im.Col.CheckMark]                 = {1.000, 1.000, 1.000, 1.000}
	c[im.Col.SliderGrab]                = {0.388, 0.388, 0.388, 1.000}
	c[im.Col.SliderGrabActive]          = {1.000, 0.388, 0.000, 1.000}
	c[im.Col.Button]                    = {1.000, 1.000, 1.000, 0.000}
	c[im.Col.ButtonHovered]             = {1.000, 1.000, 1.000, 0.156}
	c[im.Col.ButtonActive]              = {1.000, 1.000, 1.000, 0.391}
	c[im.Col.Header]                    = {0.310, 0.310, 0.310, 1.000}
	c[im.Col.HeaderHovered]             = {0.467, 0.467, 0.467, 1.000}
	c[im.Col.HeaderActive]              = {0.467, 0.467, 0.467, 1.000}
	c[im.Col.Separator]                 = {0.263, 0.263, 0.263, 1.000}
	c[im.Col.SeparatorHovered]          = {0.388, 0.388, 0.388, 1.000}
	c[im.Col.SeparatorActive]           = {1.000, 0.388, 0.000, 1.000}
	c[im.Col.ResizeGrip]                = {1.000, 1.000, 1.000, 0.250}
	c[im.Col.ResizeGripHovered]         = {1.000, 1.000, 1.000, 0.670}
	c[im.Col.ResizeGripActive]          = {1.000, 0.388, 0.000, 1.000}
	c[im.Col.Tab]                       = {0.094, 0.094, 0.094, 1.000}
	c[im.Col.TabHovered]                = {0.349, 0.349, 0.349, 1.000}
	c[im.Col.TabSelected]               = {0.192, 0.192, 0.192, 1.000}
	c[im.Col.TabDimmed]                 = {0.094, 0.094, 0.094, 1.000}
	c[im.Col.TabDimmedSelected]         = {0.192, 0.192, 0.192, 1.000}
	c[im.Col.PlotLines]                 = {0.467, 0.467, 0.467, 1.000}
	c[im.Col.PlotLinesHovered]          = {1.000, 0.388, 0.000, 1.000}
	c[im.Col.PlotHistogram]             = {0.584, 0.584, 0.584, 1.000}
	c[im.Col.PlotHistogramHovered]      = {1.000, 0.388, 0.000, 1.000}
	c[im.Col.TableHeaderBg]             = {0.188, 0.188, 0.200, 1.000}
	c[im.Col.TableBorderStrong]         = {0.310, 0.310, 0.349, 1.000}
	c[im.Col.TableBorderLight]          = {0.227, 0.227, 0.247, 1.000}
	c[im.Col.TableRowBg]                = {0.000, 0.000, 0.000, 0.000}
	c[im.Col.TableRowBgAlt]             = {1.000, 1.000, 1.000, 0.060}
	c[im.Col.TextSelectedBg]            = {1.000, 1.000, 1.000, 0.156}
	c[im.Col.DragDropTarget]            = {1.000, 0.388, 0.000, 1.000}
	c[im.Col.NavCursor]                 = {1.000, 0.388, 0.000, 1.000}
	c[im.Col.NavWindowingHighlight]     = {1.000, 0.388, 0.000, 1.000}
	c[im.Col.NavWindowingDimBg]         = {0.000, 0.000, 0.000, 0.586}
	c[im.Col.ModalWindowDimBg]          = {0.000, 0.000, 0.000, 0.586}
	_derive_recent_colors(c)

	s.Alpha                     = 1.000
	s.DisabledAlpha             = 0.600
	s.WindowPadding             = {8.000, 8.000}
	s.WindowRounding            = 4.000
	s.WindowBorderSize          = 1.000
	s.WindowMinSize             = {32.000, 32.000}
	s.WindowTitleAlign          = {0.000, 0.500}
	s.ChildRounding             = 4.000
	s.ChildBorderSize           = 1.000
	s.PopupRounding             = 2.000
	s.PopupBorderSize           = 1.000
	s.FramePadding              = {4.000, 3.000}
	s.FrameRounding             = 2.000
	s.FrameBorderSize           = 1.000
	s.ItemSpacing               = {8.000, 4.000}
	s.ItemInnerSpacing          = {4.000, 4.000}
	s.CellPadding               = {4.000, 2.000}
	s.ColumnsMinSpacing         = 6.000
	s.ScrollbarSize             = 13.000
	s.ScrollbarRounding         = 12.000
	s.GrabMinSize               = 7.000
	s.GrabRounding              = 0.000
	s.TabRounding               = 0.000
	s.TabBorderSize             = 1.000
	s.ColorButtonPosition       = .Right
	s.ButtonTextAlign           = {0.500, 0.500}
	s.SelectableTextAlign       = {0.000, 0.000}
}

// Unreal by dev0-1: "Inspirated from UE4."
style_colors_unreal :: proc() {
	s := im.GetStyle()
	c := &s.Colors
	c[im.Col.Text]                      = {1.000, 1.000, 1.000, 1.000}
	c[im.Col.TextDisabled]              = {0.498, 0.498, 0.498, 1.000}
	c[im.Col.WindowBg]                  = {0.059, 0.059, 0.059, 0.940}
	c[im.Col.ChildBg]                   = {1.000, 1.000, 1.000, 0.000}
	c[im.Col.PopupBg]                   = {0.078, 0.078, 0.078, 0.940}
	c[im.Col.Border]                    = {0.427, 0.427, 0.498, 0.500}
	c[im.Col.BorderShadow]              = {0.000, 0.000, 0.000, 0.000}
	c[im.Col.FrameBg]                   = {0.200, 0.208, 0.220, 0.540}
	c[im.Col.FrameBgHovered]            = {0.400, 0.400, 0.400, 0.400}
	c[im.Col.FrameBgActive]             = {0.176, 0.176, 0.176, 0.670}
	c[im.Col.TitleBg]                   = {0.039, 0.039, 0.039, 1.000}
	c[im.Col.TitleBgActive]             = {0.286, 0.286, 0.286, 1.000}
	c[im.Col.TitleBgCollapsed]          = {0.000, 0.000, 0.000, 0.510}
	c[im.Col.MenuBarBg]                 = {0.137, 0.137, 0.137, 1.000}
	c[im.Col.ScrollbarBg]               = {0.020, 0.020, 0.020, 0.530}
	c[im.Col.ScrollbarGrab]             = {0.310, 0.310, 0.310, 1.000}
	c[im.Col.ScrollbarGrabHovered]      = {0.408, 0.408, 0.408, 1.000}
	c[im.Col.ScrollbarGrabActive]       = {0.510, 0.510, 0.510, 1.000}
	c[im.Col.CheckMark]                 = {0.937, 0.937, 0.937, 1.000}
	c[im.Col.SliderGrab]                = {0.510, 0.510, 0.510, 1.000}
	c[im.Col.SliderGrabActive]          = {0.859, 0.859, 0.859, 1.000}
	c[im.Col.Button]                    = {0.439, 0.439, 0.439, 0.400}
	c[im.Col.ButtonHovered]             = {0.459, 0.467, 0.478, 1.000}
	c[im.Col.ButtonActive]              = {0.420, 0.420, 0.420, 1.000}
	c[im.Col.Header]                    = {0.698, 0.698, 0.698, 0.310}
	c[im.Col.HeaderHovered]             = {0.698, 0.698, 0.698, 0.800}
	c[im.Col.HeaderActive]              = {0.478, 0.498, 0.518, 1.000}
	c[im.Col.Separator]                 = {0.427, 0.427, 0.498, 0.500}
	c[im.Col.SeparatorHovered]          = {0.718, 0.718, 0.718, 0.780}
	c[im.Col.SeparatorActive]           = {0.510, 0.510, 0.510, 1.000}
	c[im.Col.ResizeGrip]                = {0.910, 0.910, 0.910, 0.250}
	c[im.Col.ResizeGripHovered]         = {0.808, 0.808, 0.808, 0.670}
	c[im.Col.ResizeGripActive]          = {0.459, 0.459, 0.459, 0.950}
	c[im.Col.Tab]                       = {0.176, 0.349, 0.576, 0.862}
	c[im.Col.TabHovered]                = {0.259, 0.588, 0.976, 0.800}
	c[im.Col.TabSelected]               = {0.196, 0.408, 0.678, 1.000}
	c[im.Col.TabDimmed]                 = {0.067, 0.102, 0.145, 0.972}
	c[im.Col.TabDimmedSelected]         = {0.133, 0.259, 0.424, 1.000}
	c[im.Col.PlotLines]                 = {0.608, 0.608, 0.608, 1.000}
	c[im.Col.PlotLinesHovered]          = {1.000, 0.427, 0.349, 1.000}
	c[im.Col.PlotHistogram]             = {0.729, 0.600, 0.149, 1.000}
	c[im.Col.PlotHistogramHovered]      = {1.000, 0.600, 0.000, 1.000}
	c[im.Col.TableHeaderBg]             = {0.188, 0.188, 0.200, 1.000}
	c[im.Col.TableBorderStrong]         = {0.310, 0.310, 0.349, 1.000}
	c[im.Col.TableBorderLight]          = {0.227, 0.227, 0.247, 1.000}
	c[im.Col.TableRowBg]                = {0.000, 0.000, 0.000, 0.000}
	c[im.Col.TableRowBgAlt]             = {1.000, 1.000, 1.000, 0.060}
	c[im.Col.TextSelectedBg]            = {0.867, 0.867, 0.867, 0.350}
	c[im.Col.DragDropTarget]            = {1.000, 1.000, 0.000, 0.900}
	c[im.Col.NavCursor]                 = {0.600, 0.600, 0.600, 1.000}
	c[im.Col.NavWindowingHighlight]     = {1.000, 1.000, 1.000, 0.700}
	c[im.Col.NavWindowingDimBg]         = {0.800, 0.800, 0.800, 0.200}
	c[im.Col.ModalWindowDimBg]          = {0.800, 0.800, 0.800, 0.350}
	_derive_recent_colors(c)

	s.Alpha                     = 1.000
	s.DisabledAlpha             = 0.600
	s.WindowPadding             = {8.000, 8.000}
	s.WindowRounding            = 0.000
	s.WindowBorderSize          = 1.000
	s.WindowMinSize             = {32.000, 32.000}
	s.WindowTitleAlign          = {0.000, 0.500}
	s.ChildRounding             = 0.000
	s.ChildBorderSize           = 1.000
	s.PopupRounding             = 0.000
	s.PopupBorderSize           = 1.000
	s.FramePadding              = {4.000, 3.000}
	s.FrameRounding             = 0.000
	s.FrameBorderSize           = 0.000
	s.ItemSpacing               = {8.000, 4.000}
	s.ItemInnerSpacing          = {4.000, 4.000}
	s.CellPadding               = {4.000, 2.000}
	s.ColumnsMinSpacing         = 6.000
	s.ScrollbarSize             = 14.000
	s.ScrollbarRounding         = 9.000
	s.GrabMinSize               = 10.000
	s.GrabRounding              = 0.000
	s.TabRounding               = 4.000
	s.TabBorderSize             = 0.000
	s.ColorButtonPosition       = .Right
	s.ButtonTextAlign           = {0.500, 0.500}
	s.SelectableTextAlign       = {0.000, 0.000}
}

// Deep Dark by janekb04: "Some colors are not set yet. Those are set to pure red notice that they have to be modified."
style_colors_deep_dark :: proc() {
	s := im.GetStyle()
	c := &s.Colors
	c[im.Col.Text]                      = {1.000, 1.000, 1.000, 1.000}
	c[im.Col.TextDisabled]              = {0.498, 0.498, 0.498, 1.000}
	c[im.Col.WindowBg]                  = {0.098, 0.098, 0.098, 1.000}
	c[im.Col.ChildBg]                   = {0.000, 0.000, 0.000, 0.000}
	c[im.Col.PopupBg]                   = {0.188, 0.188, 0.188, 0.920}
	c[im.Col.Border]                    = {0.188, 0.188, 0.188, 0.290}
	c[im.Col.BorderShadow]              = {0.000, 0.000, 0.000, 0.240}
	c[im.Col.FrameBg]                   = {0.047, 0.047, 0.047, 0.540}
	c[im.Col.FrameBgHovered]            = {0.188, 0.188, 0.188, 0.540}
	c[im.Col.FrameBgActive]             = {0.200, 0.220, 0.227, 1.000}
	c[im.Col.TitleBg]                   = {0.000, 0.000, 0.000, 1.000}
	c[im.Col.TitleBgActive]             = {0.059, 0.059, 0.059, 1.000}
	c[im.Col.TitleBgCollapsed]          = {0.000, 0.000, 0.000, 1.000}
	c[im.Col.MenuBarBg]                 = {0.137, 0.137, 0.137, 1.000}
	c[im.Col.ScrollbarBg]               = {0.047, 0.047, 0.047, 0.540}
	c[im.Col.ScrollbarGrab]             = {0.337, 0.337, 0.337, 0.540}
	c[im.Col.ScrollbarGrabHovered]      = {0.400, 0.400, 0.400, 0.540}
	c[im.Col.ScrollbarGrabActive]       = {0.557, 0.557, 0.557, 0.540}
	c[im.Col.CheckMark]                 = {0.329, 0.667, 0.859, 1.000}
	c[im.Col.SliderGrab]                = {0.337, 0.337, 0.337, 0.540}
	c[im.Col.SliderGrabActive]          = {0.557, 0.557, 0.557, 0.540}
	c[im.Col.Button]                    = {0.047, 0.047, 0.047, 0.540}
	c[im.Col.ButtonHovered]             = {0.188, 0.188, 0.188, 0.540}
	c[im.Col.ButtonActive]              = {0.200, 0.220, 0.227, 1.000}
	c[im.Col.Header]                    = {0.000, 0.000, 0.000, 0.520}
	c[im.Col.HeaderHovered]             = {0.000, 0.000, 0.000, 0.360}
	c[im.Col.HeaderActive]              = {0.200, 0.220, 0.227, 0.330}
	c[im.Col.Separator]                 = {0.278, 0.278, 0.278, 0.290}
	c[im.Col.SeparatorHovered]          = {0.439, 0.439, 0.439, 0.290}
	c[im.Col.SeparatorActive]           = {0.400, 0.439, 0.467, 1.000}
	c[im.Col.ResizeGrip]                = {0.278, 0.278, 0.278, 0.290}
	c[im.Col.ResizeGripHovered]         = {0.439, 0.439, 0.439, 0.290}
	c[im.Col.ResizeGripActive]          = {0.400, 0.439, 0.467, 1.000}
	c[im.Col.Tab]                       = {0.000, 0.000, 0.000, 0.520}
	c[im.Col.TabHovered]                = {0.137, 0.137, 0.137, 1.000}
	c[im.Col.TabSelected]               = {0.200, 0.200, 0.200, 0.360}
	c[im.Col.TabDimmed]                 = {0.000, 0.000, 0.000, 0.520}
	c[im.Col.TabDimmedSelected]         = {0.137, 0.137, 0.137, 1.000}
	c[im.Col.PlotLines]                 = {1.000, 0.000, 0.000, 1.000}
	c[im.Col.PlotLinesHovered]          = {1.000, 0.000, 0.000, 1.000}
	c[im.Col.PlotHistogram]             = {1.000, 0.000, 0.000, 1.000}
	c[im.Col.PlotHistogramHovered]      = {1.000, 0.000, 0.000, 1.000}
	c[im.Col.TableHeaderBg]             = {0.000, 0.000, 0.000, 0.520}
	c[im.Col.TableBorderStrong]         = {0.000, 0.000, 0.000, 0.520}
	c[im.Col.TableBorderLight]          = {0.278, 0.278, 0.278, 0.290}
	c[im.Col.TableRowBg]                = {0.000, 0.000, 0.000, 0.000}
	c[im.Col.TableRowBgAlt]             = {1.000, 1.000, 1.000, 0.060}
	c[im.Col.TextSelectedBg]            = {0.200, 0.220, 0.227, 1.000}
	c[im.Col.DragDropTarget]            = {0.329, 0.667, 0.859, 1.000}
	c[im.Col.NavCursor]                 = {1.000, 0.000, 0.000, 1.000}
	c[im.Col.NavWindowingHighlight]     = {1.000, 0.000, 0.000, 0.700}
	c[im.Col.NavWindowingDimBg]         = {1.000, 0.000, 0.000, 0.200}
	c[im.Col.ModalWindowDimBg]          = {1.000, 0.000, 0.000, 0.350}
	// The author left these as pure-red placeholders; derived from the theme's accent.
	c[im.Col.PlotLines]                 = c[im.Col.CheckMark]
	c[im.Col.PlotLinesHovered]          = c[im.Col.Text]
	c[im.Col.PlotHistogram]             = c[im.Col.CheckMark]
	c[im.Col.PlotHistogramHovered]      = c[im.Col.Text]
	c[im.Col.NavCursor]                 = c[im.Col.CheckMark]
	c[im.Col.NavWindowingHighlight]     = {1.000, 1.000, 1.000, 0.700}
	c[im.Col.NavWindowingDimBg]         = {0.800, 0.800, 0.800, 0.200}
	c[im.Col.ModalWindowDimBg]          = {0.000, 0.000, 0.000, 0.350}
	_derive_recent_colors(c)

	s.Alpha                     = 1.000
	s.DisabledAlpha             = 0.600
	s.WindowPadding             = {8.000, 8.000}
	s.WindowRounding            = 7.000
	s.WindowBorderSize          = 1.000
	s.WindowMinSize             = {32.000, 32.000}
	s.WindowTitleAlign          = {0.000, 0.500}
	s.ChildRounding             = 4.000
	s.ChildBorderSize           = 1.000
	s.PopupRounding             = 4.000
	s.PopupBorderSize           = 1.000
	s.FramePadding              = {5.000, 2.000}
	s.FrameRounding             = 3.000
	s.FrameBorderSize           = 1.000
	s.ItemSpacing               = {6.000, 6.000}
	s.ItemInnerSpacing          = {6.000, 6.000}
	s.CellPadding               = {6.000, 6.000}
	s.ColumnsMinSpacing         = 6.000
	s.ScrollbarSize             = 15.000
	s.ScrollbarRounding         = 9.000
	s.GrabMinSize               = 10.000
	s.GrabRounding              = 3.000
	s.TabRounding               = 4.000
	s.TabBorderSize             = 1.000
	s.ColorButtonPosition       = .Right
	s.ButtonTextAlign           = {0.500, 0.500}
	s.SelectableTextAlign       = {0.000, 0.000}
}

// --- Posted by TheAncientOwl in imgui issue 707 (2026-03-22) --------------------
//
// These set only part of the palette; the rest stays at imgui's StyleColorsDark
// defaults, which is what the author's own setup left in place (apply_theme
// restores those defaults before every theme). The author notes the palettes
// were produced with an AI assistant from the named color schemes (Dracula,
// Catppuccin Mocha).

// Dracula
style_colors_dracula :: proc() {
	s := im.GetStyle()
	c := &s.Colors
	c[im.Col.Text]                      = {0.970, 0.970, 0.950, 1.000}
	c[im.Col.TextDisabled]              = {0.380, 0.450, 0.640, 1.000}
	c[im.Col.WindowBg]                  = {0.160, 0.160, 0.210, 1.000}
	c[im.Col.ChildBg]                   = {0.160, 0.160, 0.210, 0.000}
	c[im.Col.PopupBg]                   = {0.160, 0.160, 0.210, 0.960}
	c[im.Col.Border]                    = {0.270, 0.280, 0.350, 1.000}
	c[im.Col.BorderShadow]              = {0.000, 0.000, 0.000, 0.000}
	c[im.Col.FrameBg]                   = {0.270, 0.280, 0.350, 1.000}
	c[im.Col.FrameBgHovered]            = {0.380, 0.450, 0.640, 1.000}
	c[im.Col.FrameBgActive]             = {0.480, 0.550, 0.740, 1.000}
	c[im.Col.TitleBg]                   = {0.130, 0.140, 0.180, 1.000}
	c[im.Col.TitleBgActive]             = {0.160, 0.160, 0.210, 1.000}
	c[im.Col.TitleBgCollapsed]          = {0.130, 0.140, 0.180, 1.000}
	c[im.Col.MenuBarBg]                 = {0.130, 0.140, 0.180, 1.000}
	c[im.Col.ScrollbarBg]               = {0.160, 0.160, 0.210, 1.000}
	c[im.Col.ScrollbarGrab]             = {0.270, 0.280, 0.350, 1.000}
	c[im.Col.ScrollbarGrabHovered]      = {0.380, 0.450, 0.640, 1.000}
	c[im.Col.ScrollbarGrabActive]       = {0.480, 0.550, 0.740, 1.000}
	c[im.Col.CheckMark]                 = {0.310, 0.980, 0.480, 1.000}
	c[im.Col.SliderGrab]                = {0.740, 0.580, 0.980, 1.000}
	c[im.Col.SliderGrabActive]          = {0.840, 0.680, 1.000, 1.000}
	c[im.Col.Button]                    = {0.270, 0.280, 0.350, 1.000}
	c[im.Col.ButtonHovered]             = {1.000, 0.470, 0.780, 1.000}
	c[im.Col.ButtonActive]              = {0.800, 0.370, 0.620, 1.000}
	c[im.Col.Header]                    = {0.270, 0.280, 0.350, 1.000}
	c[im.Col.HeaderHovered]             = {0.380, 0.450, 0.640, 1.000}
	c[im.Col.HeaderActive]              = {0.480, 0.550, 0.740, 1.000}
	c[im.Col.Tab]                       = {0.160, 0.160, 0.210, 1.000}
	c[im.Col.TabHovered]                = {0.270, 0.280, 0.350, 1.000}
	c[im.Col.TabSelected]               = {0.270, 0.280, 0.350, 1.000}
	c[im.Col.TabDimmed]                 = {0.130, 0.140, 0.180, 1.000}
	c[im.Col.TabDimmedSelected]         = {0.160, 0.160, 0.210, 1.000}
	c[im.Col.TableHeaderBg]             = {0.270, 0.280, 0.350, 1.000}
	c[im.Col.TableBorderStrong]         = {0.380, 0.450, 0.640, 1.000}
	c[im.Col.TableBorderLight]          = {0.270, 0.280, 0.350, 1.000}
	c[im.Col.PlotLines]                 = {0.550, 0.910, 0.990, 1.000}
	c[im.Col.TextSelectedBg]            = {0.270, 0.280, 0.350, 1.000}
	c[im.Col.NavCursor]                 = {0.740, 0.580, 0.980, 1.000}
	_derive_recent_colors(c)
	// Author-set values for colors _derive_recent_colors otherwise fills.
	c[im.Col.DockingPreview]            = {0.740, 0.580, 0.980, 0.500}
	c[im.Col.DockingEmptyBg]            = {0.160, 0.160, 0.210, 1.000}

	s.WindowPadding             = {10.000, 10.000}
	s.FramePadding              = {6.000, 4.000}
	s.ItemSpacing               = {8.000, 6.000}
	s.ScrollbarSize             = 14.000
	s.GrabMinSize               = 12.000
	s.WindowRounding            = 6.000
	s.FrameRounding             = 4.000
	s.PopupRounding             = 4.000
	s.ScrollbarRounding         = 12.000
	s.GrabRounding              = 4.000
	s.TabRounding               = 4.000
	s.WindowBorderSize          = 1.000
	s.FrameBorderSize           = 1.000
}

// Catppuccin Mocha
style_colors_catppuccin_mocha :: proc() {
	s := im.GetStyle()
	c := &s.Colors
	c[im.Col.Text]                      = {0.800, 0.840, 0.960, 1.000}
	c[im.Col.TextDisabled]              = {0.420, 0.450, 0.550, 1.000}
	c[im.Col.WindowBg]                  = {0.120, 0.120, 0.180, 1.000}
	c[im.Col.ChildBg]                   = {0.090, 0.090, 0.150, 1.000}
	c[im.Col.PopupBg]                   = {0.070, 0.070, 0.110, 0.960}
	c[im.Col.Border]                    = {0.190, 0.200, 0.270, 1.000}
	c[im.Col.BorderShadow]              = {0.000, 0.000, 0.000, 0.000}
	c[im.Col.FrameBg]                   = {0.190, 0.200, 0.270, 1.000}
	c[im.Col.FrameBgHovered]            = {0.250, 0.260, 0.350, 1.000}
	c[im.Col.FrameBgActive]             = {0.310, 0.320, 0.420, 1.000}
	c[im.Col.TitleBg]                   = {0.090, 0.090, 0.150, 1.000}
	c[im.Col.TitleBgActive]             = {0.120, 0.120, 0.180, 1.000}
	c[im.Col.TitleBgCollapsed]          = {0.070, 0.070, 0.110, 1.000}
	c[im.Col.MenuBarBg]                 = {0.090, 0.090, 0.150, 1.000}
	c[im.Col.ScrollbarBg]               = {0.090, 0.090, 0.150, 1.000}
	c[im.Col.ScrollbarGrab]             = {0.310, 0.320, 0.420, 1.000}
	c[im.Col.ScrollbarGrabHovered]      = {0.370, 0.380, 0.510, 1.000}
	c[im.Col.ScrollbarGrabActive]       = {0.420, 0.450, 0.550, 1.000}
	c[im.Col.CheckMark]                 = {0.710, 0.750, 1.000, 1.000}
	c[im.Col.SliderGrab]                = {0.450, 0.780, 0.930, 1.000}
	c[im.Col.SliderGrabActive]          = {0.450, 0.780, 0.930, 1.000}
	c[im.Col.Button]                    = {0.190, 0.200, 0.270, 1.000}
	c[im.Col.ButtonHovered]             = {0.800, 0.650, 0.970, 1.000}
	c[im.Col.ButtonActive]              = {0.700, 0.550, 0.870, 1.000}
	c[im.Col.Header]                    = {0.190, 0.200, 0.270, 1.000}
	c[im.Col.HeaderHovered]             = {0.250, 0.260, 0.350, 1.000}
	c[im.Col.HeaderActive]              = {0.310, 0.320, 0.420, 1.000}
	c[im.Col.Tab]                       = {0.120, 0.120, 0.180, 1.000}
	c[im.Col.TabHovered]                = {0.310, 0.320, 0.420, 1.000}
	c[im.Col.TabSelected]               = {0.190, 0.200, 0.270, 1.000}
	c[im.Col.TabDimmed]                 = {0.090, 0.090, 0.150, 1.000}
	c[im.Col.TabDimmedSelected]         = {0.120, 0.120, 0.180, 1.000}
	c[im.Col.PlotLines]                 = {0.940, 0.720, 0.420, 1.000}
	c[im.Col.TextSelectedBg]            = {0.310, 0.320, 0.420, 1.000}
	c[im.Col.NavCursor]                 = {0.710, 0.750, 1.000, 1.000}
	_derive_recent_colors(c)
	// Author-set values for colors _derive_recent_colors otherwise fills.
	c[im.Col.DockingPreview]            = {0.710, 0.750, 1.000, 0.500}
	c[im.Col.DockingEmptyBg]            = {0.120, 0.120, 0.180, 1.000}

	s.WindowPadding             = {12.000, 12.000}
	s.FramePadding              = {6.000, 4.000}
	s.ItemSpacing               = {8.000, 6.000}
	s.ScrollbarSize             = 14.000
	s.GrabMinSize               = 12.000
	s.WindowRounding            = 8.000
	s.FrameRounding             = 5.000
	s.PopupRounding             = 5.000
	s.ScrollbarRounding         = 12.000
	s.GrabRounding              = 5.000
	s.TabRounding               = 5.000
	s.WindowBorderSize          = 1.000
	s.FrameBorderSize           = 0.000
	s.PopupBorderSize           = 1.000
}

// Paper And Ink
style_colors_paper_and_ink :: proc() {
	s := im.GetStyle()
	c := &s.Colors
	c[im.Col.Text]                      = {0.120, 0.120, 0.120, 1.000}
	c[im.Col.TextDisabled]              = {0.550, 0.550, 0.550, 1.000}
	c[im.Col.WindowBg]                  = {0.960, 0.960, 0.940, 1.000}
	c[im.Col.ChildBg]                   = {0.000, 0.000, 0.000, 0.030}
	c[im.Col.PopupBg]                   = {1.000, 1.000, 1.000, 1.000}
	c[im.Col.Border]                    = {0.750, 0.750, 0.720, 1.000}
	c[im.Col.BorderShadow]              = {0.000, 0.000, 0.000, 0.000}
	c[im.Col.Separator]                 = {0.800, 0.800, 0.780, 1.000}
	c[im.Col.SeparatorHovered]          = {0.170, 0.340, 0.590, 0.780}
	c[im.Col.SeparatorActive]           = {0.170, 0.340, 0.590, 1.000}
	c[im.Col.FrameBg]                   = {1.000, 1.000, 1.000, 1.000}
	c[im.Col.FrameBgHovered]            = {0.900, 0.920, 0.950, 1.000}
	c[im.Col.FrameBgActive]             = {0.850, 0.880, 0.920, 1.000}
	c[im.Col.TitleBg]                   = {0.920, 0.920, 0.900, 1.000}
	c[im.Col.TitleBgActive]             = {0.880, 0.880, 0.860, 1.000}
	c[im.Col.TitleBgCollapsed]          = {0.920, 0.920, 0.900, 0.750}
	c[im.Col.MenuBarBg]                 = {0.920, 0.920, 0.900, 1.000}
	c[im.Col.ScrollbarBg]               = {0.960, 0.960, 0.940, 1.000}
	c[im.Col.ScrollbarGrab]             = {0.800, 0.800, 0.780, 1.000}
	c[im.Col.ScrollbarGrabHovered]      = {0.700, 0.700, 0.680, 1.000}
	c[im.Col.ScrollbarGrabActive]       = {0.600, 0.600, 0.580, 1.000}
	c[im.Col.CheckMark]                 = {0.170, 0.340, 0.590, 1.000}
	c[im.Col.SliderGrab]                = {0.170, 0.340, 0.590, 0.700}
	c[im.Col.SliderGrabActive]          = {0.170, 0.340, 0.590, 1.000}
	c[im.Col.Button]                    = {0.170, 0.340, 0.590, 0.080}
	c[im.Col.ButtonHovered]             = {0.170, 0.340, 0.590, 0.200}
	c[im.Col.ButtonActive]              = {0.170, 0.340, 0.590, 0.350}
	c[im.Col.Header]                    = {0.170, 0.340, 0.590, 0.120}
	c[im.Col.HeaderHovered]             = {0.170, 0.340, 0.590, 0.250}
	c[im.Col.HeaderActive]              = {0.170, 0.340, 0.590, 0.400}
	c[im.Col.TableHeaderBg]             = {0.900, 0.900, 0.880, 1.000}
	c[im.Col.TableBorderStrong]         = {0.750, 0.750, 0.720, 1.000}
	c[im.Col.TableBorderLight]          = {0.850, 0.850, 0.820, 1.000}
	c[im.Col.TableRowBgAlt]             = {0.000, 0.000, 0.000, 0.030}
	c[im.Col.Tab]                       = {0.920, 0.920, 0.900, 1.000}
	c[im.Col.TabHovered]                = {1.000, 1.000, 1.000, 1.000}
	c[im.Col.TabSelected]               = {1.000, 1.000, 1.000, 1.000}
	c[im.Col.TabDimmed]                 = {0.920, 0.920, 0.900, 1.000}
	c[im.Col.TabDimmedSelected]         = {0.960, 0.960, 0.940, 1.000}
	c[im.Col.PlotLines]                 = {0.170, 0.340, 0.590, 1.000}
	c[im.Col.PlotHistogram]             = {0.170, 0.340, 0.590, 1.000}
	c[im.Col.TextSelectedBg]            = {0.170, 0.340, 0.590, 0.250}
	c[im.Col.DragDropTarget]            = {0.170, 0.340, 0.590, 0.900}
	c[im.Col.NavCursor]                 = {0.170, 0.340, 0.590, 1.000}
	_derive_recent_colors(c)
	// Author-set values for colors _derive_recent_colors otherwise fills.
	c[im.Col.DockingPreview]            = {0.170, 0.340, 0.590, 0.400}
	c[im.Col.DockingEmptyBg]            = {0.960, 0.960, 0.940, 1.000}

	s.WindowPadding             = {12.000, 12.000}
	s.FramePadding              = {6.000, 4.000}
	s.CellPadding               = {6.000, 4.000}
	s.ItemSpacing               = {8.000, 6.000}
	s.ItemInnerSpacing          = {6.000, 4.000}
	s.ScrollbarSize             = 14.000
	s.GrabMinSize               = 12.000
	s.WindowRounding            = 2.000
	s.ChildRounding             = 2.000
	s.FrameRounding             = 2.000
	s.PopupRounding             = 2.000
	s.ScrollbarRounding         = 12.000
	s.GrabRounding              = 2.000
	s.TabRounding               = 2.000
	s.WindowBorderSize          = 1.000
	s.ChildBorderSize           = 1.000
	s.PopupBorderSize           = 1.000
	s.FrameBorderSize           = 1.000
	s.TabBorderSize             = 1.000
}
