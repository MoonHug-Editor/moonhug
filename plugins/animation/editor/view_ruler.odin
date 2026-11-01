package animation_editor

// The ruler over the Animation window's time canvas: seconds or frame
// numbers, as labeled ticks with unlabeled marks between them.

import "core:fmt"
import "core:math"
import im "moonhug:external/odin-imgui"

// A ruler of seconds across the band at `y` of height `h`: a tick and a label
// at every step, the step the first one at least 55 px wide.
@(private)
_pv_ruler_time :: proc(dl: ^im.DrawList, y, h, tx0, pps, length: f32) {
	steps := [?]f32{0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 30, 60}
	step := steps[len(steps) - 1]
	for s in steps do if s * pps >= 55 {
		step = s
		break
	}
	_pv_ruler_ticks(dl, y, h, tx0, pps, length, step, _pv_ruler_minor(step), proc(t: f32) -> cstring { return fmt.ctprintf("%.2f", t) })
}

// The unlabeled marks between two labels: a fifth of the step when the step
// is 1 or 5 of its decade (1 -> 0.2, 5 -> 1, 10 -> 2), half of it when the
// step is 2 (2 -> 1, 20 -> 10). The mark at the step's middle is the taller.
@(private = "file")
_pv_ruler_minor :: proc(step: f32) -> f32 {
	m := step
	for m >= 10 do m /= 10
	for m < 1 do m *= 10
	if abs(m - 2) < 0.01 do return step / 2
	return step / 5
}

// A ruler of frame numbers: the step is a whole number of frames, the first
// at least 55 px wide.
@(private)
_pv_ruler_frames :: proc(dl: ^im.DrawList, y, h, tx0, pps, length, fps: f32) {
	steps := [?]f32{1, 2, 5, 10, 20, 50, 100, 200, 500, 1000}
	frames := steps[len(steps) - 1]
	for s in steps do if s / fps * pps >= 55 {
		frames = s
		break
	}
	_pv_ruler_fps = fps
	// Marks between frame labels are whole frames: every frame under a step of
	// 5, every step/5 or step/2 above.
	minor := frames / fps
	switch {
	case frames >= 5:  minor = _pv_ruler_minor(frames) / fps
	case frames == 2:  minor = 1 / fps
	}
	_pv_ruler_ticks(dl, y, h, tx0, pps, length, frames / fps, minor, proc(t: f32) -> cstring { return fmt.ctprintf("%d", i32(math.round(t * _pv_ruler_fps))) })
}

// The frame rate the frames ruler labels with, set right before its ticks
// draw: the label proc has no context of its own.
@(private = "file")
_pv_ruler_fps: f32

// Ticks and labels along a ruler band: a labeled mark every `step` seconds,
// unlabeled marks every `minor` seconds between them (the one at the step's
// middle taller than the rest), none when they would sit closer than 5 px.
// Marks rise from the band's bottom. The label is drawn at the font size
// that fits the band, so the half bands of Frames and Time stay readable.
@(private = "file")
_pv_ruler_ticks :: proc(dl: ^im.DrawList, y, h, tx0, pps, length, step, minor: f32, label: proc(t: f32) -> cstring) {
	tick_col := im.GetColorU32(.TextDisabled)
	major_h := min(f32(8), h * 0.45)
	size := min(im.GetFontSize(), h - 2)
	text_y := y + (h - size) * 0.5
	for i in 0 ..= int(length / step) {
		t := f32(i) * step
		tx := tx0 + t * pps
		im.DrawList_AddLine(dl, im.Vec2{tx, y + h - major_h}, im.Vec2{tx, y + h}, tick_col, 1)
		im.DrawList_AddTextImFontPtr(dl, im.GetFont(), size, im.Vec2{tx + 3, text_y}, tick_col, label(t))
	}
	if minor <= 0 || minor >= step || minor * pps < 5 do return
	for i in 0 ..= int(length / minor) {
		t := f32(i) * minor
		if abs(math.remainder(t, step)) < minor * 0.5 do continue // a labeled mark
		mid := abs(math.remainder(t, step)) > step * 0.5 - minor * 0.5
		mh := mid ? major_h * 0.66 : major_h * 0.4
		im.DrawList_AddLine(dl, im.Vec2{tx0 + t * pps, y + h - mh}, im.Vec2{tx0 + t * pps, y + h}, tick_col, 1)
	}
}
