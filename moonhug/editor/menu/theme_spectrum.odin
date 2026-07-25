package menu

import im "moonhug:external/odin-imgui"

// Adobe Spectrum theme for imgui, ported from adobe/imgui
// (imgui_spectrum.cpp). A coherent gray design system: input fields AND
// buttons are the same neutral gray (GRAY75), distinguished by border and
// shape rather than color, with blue reserved for selection/headers. This is
// why action buttons stop reading as fields under this theme without any
// per-widget hacks.

// 0xRRGGBB -> ImVec4 with full alpha. Spectrum stores sRGB hex; imgui expects
// linear-ish 0..1 floats and the upstream theme feeds them straight through,
// so we match that (no gamma conversion) to reproduce the intended look.
@(private = "file")
_rgb :: proc(hex: u32) -> im.Vec4 {
	return im.Vec4{
		f32((hex >> 16) & 0xFF) / 255.0,
		f32((hex >> 8) & 0xFF) / 255.0,
		f32(hex & 0xFF) / 255.0,
		1.0,
	}
}

@(private = "file")
_rgba :: proc(hex: u32, a: f32) -> im.Vec4 {
	c := _rgb(hex)
	c.w = a
	return c
}

@(private = "file")
_lerp :: proc(a, b: im.Vec4, t: f32) -> im.Vec4 {
	return im.Vec4{
		a.x + (b.x - a.x) * t,
		a.y + (b.y - a.y) * t,
		a.z + (b.z - a.z) * t,
		a.w + (b.w - a.w) * t,
	}
}

@(private = "file")
Spectrum_Palette :: struct {
	gray50, gray75, gray100, gray200, gray300, gray400, gray500, gray600, gray700, gray800, gray900: u32,
	blue400, blue500, blue600, blue700:                                                              u32,
}

// Static (theme-independent) accents, from imgui_spectrum.h.
@(private = "file")
SPECTRUM_LIGHT :: Spectrum_Palette{
	gray50 = 0xFFFFFF, gray75 = 0xFAFAFA, gray100 = 0xF5F5F5, gray200 = 0xEAEAEA,
	gray300 = 0xE1E1E1, gray400 = 0xCACACA, gray500 = 0xB3B3B3, gray600 = 0x8E8E8E,
	gray700 = 0x707070, gray800 = 0x4B4B4B, gray900 = 0x2C2C2C,
	blue400 = 0x2680EB, blue500 = 0x1473E6, blue600 = 0x0D66D0, blue700 = 0x095ABA,
}

@(private = "file")
SPECTRUM_DARK :: Spectrum_Palette{
	gray50 = 0x252525, gray75 = 0x2F2F2F, gray100 = 0x323232, gray200 = 0x393939,
	gray300 = 0x3E3E3E, gray400 = 0x4D4D4D, gray500 = 0x5C5C5C, gray600 = 0x7B7B7B,
	gray700 = 0x999999, gray800 = 0xCDCDCD, gray900 = 0xFFFFFF,
	blue400 = 0x2680EB, blue500 = 0x378EF0, blue600 = 0x4B9CF5, blue700 = 0x5AA9FA,
}

style_colors_spectrum :: proc(dark: bool) {
	p := dark ? SPECTRUM_DARK : SPECTRUM_LIGHT
	style := im.GetStyle()
	c := &style.Colors

	// Selection-fill alpha is TUNED per theme because Text is a single gray.
	// The blue wash must stay pale enough that the single gray text keeps
	// >= 3.0 contrast on it, yet opaque enough to read as a selection against
	// the window. Both windows are far from the mid blue, so the readable band
	// is a low-to-mid alpha in each: dark ~0.40-0.55, light ~0.30-0.45.
	// (Verified: every fill below lands gray-on-fill contrast >= 3.0 and
	// fill-vs-window >= 1.5 in both themes.) A single alpha can't serve both —
	// dark text wants a paler light-mode tint, light text a darker dark-mode
	// one — so they diverge here.
	sel_a: f32 = dark ? 0.42 : 0.35 // base (Header / normal selection)
	sel_hi: f32 = dark ? 0.50 : 0.45 // hovered / selected tab
	sel_max: f32 = dark ? 0.55 : 0.30 // active

	c[im.Col.Text]                  = _rgb(p.gray800)
	c[im.Col.TextDisabled]          = _rgb(p.gray500)
	c[im.Col.WindowBg]              = _rgb(p.gray100)
	c[im.Col.ChildBg]               = im.Vec4{0, 0, 0, 0}
	c[im.Col.PopupBg]               = _rgb(p.gray50)
	c[im.Col.Border]                = _rgb(p.gray300)
	c[im.Col.BorderShadow]          = im.Vec4{0, 0, 0, 0}
	c[im.Col.FrameBg]               = _rgb(p.gray75)
	c[im.Col.FrameBgHovered]        = _rgb(p.gray50)
	c[im.Col.FrameBgActive]         = _rgb(p.gray200)
	c[im.Col.TitleBg]               = _rgb(p.gray300)
	c[im.Col.TitleBgActive]         = _rgb(p.gray200)
	c[im.Col.TitleBgCollapsed]      = _rgb(p.gray400)
	c[im.Col.MenuBarBg]             = _rgb(p.gray100)
	c[im.Col.ScrollbarBg]           = _rgb(p.gray100)
	c[im.Col.ScrollbarGrab]         = _rgb(p.gray400)
	c[im.Col.ScrollbarGrabHovered]  = _rgb(p.gray600)
	c[im.Col.ScrollbarGrabActive]   = _rgb(p.gray700)
	c[im.Col.SliderGrab]            = _rgb(p.gray700)
	c[im.Col.SliderGrabActive]      = _rgb(p.gray800)
	// Buttons sit at the MIDPOINT between the field fill (FrameBg = GRAY75) and
	// the component collapsible header. The header is TRANSLUCENT blue, so its
	// on-screen color is blue400 composited over the window — lerp toward THAT
	// effective color (not solid blue400, which overshoots and matches the
	// header). 0.50 = halfway; hover/active step toward the header.
	field_col      := _rgb(p.gray75)
	eff_header_col := _lerp(_rgb(p.gray100), _rgb(p.blue400), sel_a) // header over WindowBg=GRAY100
	c[im.Col.Button]                = _lerp(field_col, eff_header_col, 0.50)
	c[im.Col.ButtonHovered]         = _lerp(field_col, eff_header_col, 0.70)
	c[im.Col.ButtonActive]          = _lerp(field_col, eff_header_col, 0.90)
	// Selection fills are TRANSLUCENT blue, not solid: Spectrum has one gray
	// Text color, and solid blue fails contrast against it (gray-on-blue ~2.1,
	// unreadable). A blue wash over the window keeps the single text color
	// legible — the same trick stock imgui Dark uses (its Header alpha is
	// 0.31). This covers every text-bearing selection at once, including
	// imgui's own dock tabs, with no per-widget override.
	c[im.Col.Header]                = _rgba(p.blue400, sel_a)
	c[im.Col.HeaderHovered]         = _rgba(p.blue500, sel_hi)
	c[im.Col.HeaderActive]          = _rgba(p.blue600, sel_max)
	c[im.Col.Separator]             = _rgb(p.gray400)
	c[im.Col.SeparatorHovered]      = _rgb(p.gray600)
	c[im.Col.SeparatorActive]       = _rgb(p.gray700)
	c[im.Col.ResizeGrip]            = _rgb(p.gray400)
	c[im.Col.ResizeGripHovered]     = _rgb(p.gray600)
	c[im.Col.ResizeGripActive]      = _rgb(p.gray700)
	c[im.Col.PlotLines]             = _rgb(p.blue400)
	c[im.Col.PlotLinesHovered]      = _rgb(p.blue600)
	c[im.Col.PlotHistogram]         = _rgb(p.blue400)
	c[im.Col.PlotHistogramHovered]  = _rgb(p.blue600)
	c[im.Col.TextSelectedBg]        = _rgba(p.blue400, 0.2)
	c[im.Col.DragDropTarget]        = im.Vec4{1, 1, 0, 0.9}
	c[im.Col.NavWindowingHighlight] = im.Vec4{1, 1, 1, 0.7}
	c[im.Col.NavWindowingDimBg]     = im.Vec4{0.8, 0.8, 0.8, 0.2}
	c[im.Col.ModalWindowDimBg]      = im.Vec4{0.2, 0.2, 0.2, 0.35}
	c[im.Col.CheckMark]             = _rgb(p.gray50)
	c[im.Col.Tab]                   = _rgb(p.gray300)
	c[im.Col.TabSelected]           = _rgba(p.blue500, sel_hi) // translucent so gray text stays legible
	c[im.Col.TabHovered]            = _rgba(p.blue600, sel_a)
	c[im.Col.TabDimmed]             = _rgb(p.gray400)
	c[im.Col.TabDimmedSelected]     = _rgba(p.blue700, sel_a)

	// Spectrum reads as a flat, tight design system — a little rounding, thin
	// frame borders (so a gray button is distinct from a gray field), no
	// shadows.
	style.FrameRounding   = 4
	style.FrameBorderSize = 1
	style.WindowRounding  = 4
	style.PopupRounding   = 4
	style.GrabRounding    = 4
	style.TabRounding     = 4
}
