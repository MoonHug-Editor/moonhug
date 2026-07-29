package editor

// Shared node-graph canvas (docs/PlayableGraph.md, Graph UI): pan/zoom grid,
// node chrome with ports, bezier edge routing, node dragging and selection.
// Strictly presentation and interaction — no document model. Each client
// (the PlayableGraph visualizer today; Controller/ShaderGraph/VfxGraph
// canvases later) supplies node content, port meaning and what happens on
// edit. The first client is read-only, so ports render but do not interact —
// marquee selection and edit undo arrive with the first editing client.
//
// Coordinates: nodes live in CANVAS units (zoom-independent). screen =
// origin + (p + pan) * zoom. Client code converts through canvas_to_screen
// and the port helpers so pan/zoom stays the canvas's business.

import "core:fmt"
import "core:math"
import im "moonhug:external/odin-imgui"

CANVAS_NODE_W :: f32(170)      // node width, canvas units
CANVAS_HEADER_H :: f32(22)     // node title bar
CANVAS_LINE_H :: f32(16)       // one body text line
CANVAS_PORT_R :: f32(4)        // port dot radius
CANVAS_GRID :: f32(32)
CANVAS_ZOOM_MIN :: f32(0.25)
CANVAS_ZOOM_MAX :: f32(2.5)

Node_Canvas :: struct {
	pan:  im.Vec2, // canvas-unit offset of the origin
	zoom: f32,
	sel:  int, // selected node id, -1 = none

	// Per-frame, set by canvas_begin.
	origin: im.Vec2, // screen top-left of the canvas rect
	size:   im.Vec2,
}

canvas_init :: proc(cv: ^Node_Canvas) {
	cv.zoom = 1
	cv.sel = -1
}

canvas_to_screen :: proc(cv: ^Node_Canvas, p: im.Vec2) -> im.Vec2 {
	return cv.origin + (p + cv.pan) * cv.zoom
}

canvas_node_size :: proc(n_lines: int) -> im.Vec2 {
	return im.Vec2{CANVAS_NODE_W, CANVAS_HEADER_H + f32(n_lines) * CANVAS_LINE_H + 6}
}

// Input port i of n, stacked on the node's left edge (screen coords).
canvas_port_in :: proc(cv: ^Node_Canvas, pos: im.Vec2, n_lines: int, i, n: int) -> im.Vec2 {
	sz := canvas_node_size(n_lines)
	k := n > 0 ? (f32(i) + 1) / (f32(n) + 1) : 0.5
	return canvas_to_screen(cv, im.Vec2{pos.x, pos.y + sz.y * k})
}

// The single output port on the node's right edge (screen coords).
canvas_port_out :: proc(cv: ^Node_Canvas, pos: im.Vec2, n_lines: int) -> im.Vec2 {
	sz := canvas_node_size(n_lines)
	return canvas_to_screen(cv, im.Vec2{pos.x + sz.x, pos.y + sz.y * 0.5})
}

// Child region + grid. Draw edges, then nodes, then canvas_end. The
// background pan surface is submitted by canvas_end: overlapping imgui items
// go to the FIRST submitted one, so the node buttons (submitted between
// begin and end) win their clicks and the background takes the rest.
canvas_begin :: proc(cv: ^Node_Canvas, id: cstring) -> bool {
	if cv.zoom == 0 do canvas_init(cv)
	if !im.BeginChild(id, im.Vec2{0, 0}, {.Borders}, {.NoScrollbar, .NoScrollWithMouse}) {
		return false
	}
	cv.origin = im.GetCursorScreenPos()
	cv.size = im.GetContentRegionAvail()
	if cv.size.x < 1 || cv.size.y < 1 {
		return true
	}

	// Grid, offset with the pan so it reads as a surface.
	dl := im.GetWindowDrawList()
	grid_col := im.GetColorU32(.Border, 0.35)
	sp := CANVAS_GRID * cv.zoom
	for x := math.mod(cv.pan.x * cv.zoom, sp); x < cv.size.x; x += sp {
		im.DrawList_AddLine(dl, im.Vec2{cv.origin.x + x, cv.origin.y}, im.Vec2{cv.origin.x + x, cv.origin.y + cv.size.y}, grid_col, 1)
	}
	for y := math.mod(cv.pan.y * cv.zoom, sp); y < cv.size.y; y += sp {
		im.DrawList_AddLine(dl, im.Vec2{cv.origin.x, cv.origin.y + y}, im.Vec2{cv.origin.x + cv.size.x, cv.origin.y + y}, grid_col, 1)
	}
	return true
}

// Background interaction (left/middle-drag pans, wheel zooms around the
// cursor, click on empty space deselects), then the child closes.
canvas_end :: proc(cv: ^Node_Canvas) {
	if cv.size.x >= 1 && cv.size.y >= 1 {
		im.SetCursorScreenPos(cv.origin)
		im.InvisibleButton("##canvas_bg", cv.size)
		if im.IsItemActive() && im.IsMouseDragging(.Left, 0) {
			cv.pan += im.GetIO().MouseDelta / cv.zoom
		}
		if im.IsItemClicked(.Left) do cv.sel = -1
		if im.IsWindowHovered(im.HoveredFlags_ChildWindows) {
			if im.IsMouseDragging(.Middle, 0) {
				cv.pan += im.GetIO().MouseDelta / cv.zoom
			}
			wheel := im.GetIO().MouseWheel
			if wheel != 0 {
				mp := im.GetMousePos()
				world := (mp - cv.origin) / cv.zoom - cv.pan
				cv.zoom = clamp(cv.zoom * math.pow(f32(1.1), wheel), CANVAS_ZOOM_MIN, CANVAS_ZOOM_MAX)
				cv.pan = (mp - cv.origin) / cv.zoom - world
			}
		}
	}
	im.EndChild()
}

// One node: header with `title` tinted by `color`, body `lines`, `n_in` port
// dots on the left edge and one output dot on the right. Draggable (writes
// `pos` back in canvas units), click selects. Draw after the edges.
canvas_node :: proc(cv: ^Node_Canvas, id: int, pos: ^im.Vec2, title: cstring, color: im.Vec4, lines: []cstring, n_in: int, has_out: bool) {
	dl := im.GetWindowDrawList()
	sz := canvas_node_size(len(lines))
	rmin := canvas_to_screen(cv, pos^)
	rmax := rmin + sz * cv.zoom
	rounding := 4 * cv.zoom
	font := im.GetFont()
	font_sz := max(im.GetFontSize() * cv.zoom, 7)

	// Interaction first: the button claims hover over the background pan
	// surface, the visuals draw over both.
	im.SetCursorScreenPos(rmin)
	im.InvisibleButton(fmt.ctprintf("##canvas_node_%d", id), rmax - rmin)
	if im.IsItemActivated() do cv.sel = id
	if im.IsItemActive() && im.IsMouseDragging(.Left, 0) {
		pos^ += im.GetIO().MouseDelta / cv.zoom
	}

	body_col := im.GetStyleColorVec4(.FrameBg)^
	body_col.w = 0.95
	im.DrawList_AddRectFilled(dl, rmin, rmax, im.GetColorU32ImVec4(body_col), rounding)
	header_col := color
	header_col.w = 0.9
	im.DrawList_AddRectFilled(dl, rmin, im.Vec2{rmax.x, rmin.y + CANVAS_HEADER_H * cv.zoom}, im.GetColorU32ImVec4(header_col), rounding, im.DrawFlags_RoundCornersTop)
	border := cv.sel == id ? im.GetColorU32(.CheckMark) : im.GetColorU32(.Border)
	im.DrawList_AddRect(dl, rmin, rmax, border, rounding, cv.sel == id ? 2 : 1)

	im.DrawList_AddTextImFontPtr(dl, font, font_sz, rmin + im.Vec2{6, 3} * cv.zoom, im.GetColorU32ImVec4(im.Vec4{1, 1, 1, 1}), title)
	for line, i in lines {
		ly := CANVAS_HEADER_H + 3 + f32(i) * CANVAS_LINE_H
		im.DrawList_AddTextImFontPtr(dl, font, font_sz, rmin + im.Vec2{6, ly} * cv.zoom, im.GetColorU32(.Text), line)
	}

	port_col := im.GetColorU32(.Text)
	for i in 0 ..< n_in {
		im.DrawList_AddCircleFilled(dl, canvas_port_in(cv, pos^, len(lines), i, n_in), CANVAS_PORT_R * cv.zoom, port_col)
	}
	if has_out {
		im.DrawList_AddCircleFilled(dl, canvas_port_out(cv, pos^, len(lines)), CANVAS_PORT_R * cv.zoom, port_col)
	}
}

// Bezier edge between two port positions (screen coords), horizontal
// tangents, optional label at the midpoint. Draw before the nodes.
canvas_link :: proc(cv: ^Node_Canvas, from, to: im.Vec2, col: u32, thickness: f32 = 1.5, label: cstring = nil) {
	dl := im.GetWindowDrawList()
	d := clamp(abs(to.x - from.x) * 0.5, 30 * cv.zoom, 120 * cv.zoom)
	im.DrawList_AddBezierCubic(dl, from, from + im.Vec2{d, 0}, to - im.Vec2{d, 0}, to, col, thickness * cv.zoom)
	if label != nil {
		mid := (from + to) * 0.5
		font_sz := max(im.GetFontSize() * cv.zoom * 0.9, 7)
		im.DrawList_AddTextImFontPtr(dl, im.GetFont(), font_sz, mid + im.Vec2{3, -font_sz - 2}, im.GetColorU32(.Text), label)
	}
}
