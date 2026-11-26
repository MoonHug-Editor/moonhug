package mhgui

import "base:runtime"
import "core:math"
import "moonhug:packages/engine"

// How the canvas resolution follows the screen. Sits on the Canvas node.
Scale_Mode :: enum u8 {
	Constant_Pixel_Size,    // one canvas unit is scale_factor screen pixels
	Scale_With_Screen_Size, // the canvas is reference_resolution units wide/tall, scaled to fit the screen
}

// Scales the canvas as a whole so a layout authored once holds up across
// window sizes. Without a CanvasScaler one canvas unit is one screen pixel.
@(component={menu="UI/CanvasScaler", icon="FIT_SCREEN"})
@(typ_guid={guid = "39805feb-6d86-481c-bb1a-f662b7309f64"})
CanvasScaler :: struct {
	using base:           engine.CompData `inspect:"-"`,
	mode:                 Scale_Mode,
	scale_factor:         f32,    // Constant_Pixel_Size
	reference_resolution: [2]f32, // Scale_With_Screen_Size: the authored canvas size
	// Scale_With_Screen_Size: 0 fits the reference width, 1 the reference
	// height, values between blend the two (logarithmically, so 0.5 is the
	// geometric mean).
	match:                f32,
}

type_reset_CanvasScaler :: proc(cs: ^CanvasScaler) {
	cs.mode = .Scale_With_Screen_Size
	cs.scale_factor = 1
	cs.reference_resolution = {1920, 1080}
	cs.match = 0.5
}

// Screen pixels per canvas unit for `screen`.
scaler_factor :: proc(cs: ^CanvasScaler, screen: [2]f32) -> f32 {
	switch cs.mode {
	case .Constant_Pixel_Size:
		return max(cs.scale_factor, 0.0001)
	case .Scale_With_Screen_Size:
		ref := cs.reference_resolution
		if ref.x <= 0 || ref.y <= 0 || screen.x <= 0 || screen.y <= 0 do return 1
		log_w := math.log2(screen.x / ref.x)
		log_h := math.log2(screen.y / ref.y)
		m := clamp(cs.match, 0, 1)
		return math.pow(f32(2), log_w * (1 - m) + log_h * m)
	}
	return 1
}

// The canvas node's scale for `screen`: its CanvasScaler's, or 1.
canvas_scaler_scale :: proc(canvas_tH: engine.Transform_Handle, screen: [2]f32) -> f32 {
	if _, cs := engine.transform_get_comp(canvas_tH, CanvasScaler); cs != nil && cs.enabled {
		return scaler_factor(cs, screen)
	}
	return 1
}


// The engine asks this for a canvas's scale (engine.canvas_scale).
@(init)
_canvas_scaler_install :: proc "contextless" () {
	context = runtime.default_context()
	engine.canvas_scale_install(canvas_scaler_scale)
}
