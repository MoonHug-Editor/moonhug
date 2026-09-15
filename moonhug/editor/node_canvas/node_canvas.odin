package node_canvas

// Shared node-graph canvas (docs/PlayableGraph.md, Graph UI) — an editor
// subpackage like inspector/menu/undo, so package editors can draw with it:
// pan/zoom grid,
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
//
// A node's body is a list of ROWS, each a label and a value, the same shape a
// property row has everywhere else in the editor. A row can carry an input
// port, so an edge lands on the row it feeds rather than at some fraction of
// the node's height — that is what makes a mixer with six inputs readable.

import "core:fmt"
import "core:math"
import im "moonhug:external/odin-imgui"

CANVAS_NODE_W :: f32(184) // node width, canvas units
CANVAS_HEADER_H :: f32(24) // node title bar
CANVAS_ROW_H :: f32(18) // one body row
CANVAS_PAD :: f32(7) // body inset, all four sides
CANVAS_PORT_R :: f32(4.5) // port dot radius
CANVAS_GRID :: f32(28)
CANVAS_GRID_MAJOR :: 4 // every Nth grid line draws brighter
CANVAS_ZOOM_MIN :: f32(0.25)
CANVAS_ZOOM_MAX :: f32(2.5)

// Port hues by what flows through them, so an edge says what it carries
// without following it to both ends.
PORT_POSE :: im.Vec4{0.56, 0.78, 0.44, 1}
PORT_VALUE :: im.Vec4{0.87, 0.44, 0.47, 1}

// One body row. `value` is right-aligned in the value column, `label` left in
// the label column. `port` gives the row an input dot on the left edge.
Canvas_Row :: struct {
	label: cstring,
	value: cstring,
	port:  bool,
	col:   im.Vec4, // port hue; zero alpha takes PORT_POSE
}

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

canvas_node_size :: proc(n_rows: int) -> im.Vec2 {
	return im.Vec2{CANVAS_NODE_W, CANVAS_HEADER_H + CANVAS_PAD * 2 + f32(n_rows) * CANVAS_ROW_H}
}

// Centre of row `i`, in canvas units from the node's top-left.
@(private = "file")
_row_y :: proc(i: int) -> f32 {
	return CANVAS_HEADER_H + CANVAS_PAD + f32(i) * CANVAS_ROW_H + CANVAS_ROW_H * 0.5
}

// Input port of row `row`, on the node's left edge (screen coords).
canvas_port_in :: proc(cv: ^Node_Canvas, pos: im.Vec2, row: int) -> im.Vec2 {
	return canvas_to_screen(cv, im.Vec2{pos.x, pos.y + _row_y(row)})
}

// The output port on the node's right edge, on row `row` (screen coords).
canvas_port_out :: proc(cv: ^Node_Canvas, pos: im.Vec2, row: int = 0) -> im.Vec2 {
	return canvas_to_screen(cv, im.Vec2{pos.x + CANVAS_NODE_W, pos.y + _row_y(row)})
}

// Child region + grid. Draw edges, then nodes, then canvas_end. The
// background pan surface is submitted by canvas_end: overlapping imgui items
// go to the FIRST submitted one, so the node buttons (submitted between
// begin and end) win their clicks and the background takes the rest.
canvas_begin :: proc(cv: ^Node_Canvas, id: cstring) -> bool {
	if cv.zoom == 0 do canvas_init(cv)
	// No window padding: the canvas IS the child's whole rect. With the default
	// padding the content region is inset, so the surface and the grid stop
	// short of the border and the panel colour shows through as a frame.
	im.PushStyleVarImVec2(.WindowPadding, im.Vec2{0, 0})
	open := im.BeginChild(id, im.Vec2{0, 0}, {.Borders}, {.NoScrollbar, .NoScrollWithMouse})
	im.PopStyleVar()
	if !open do return false
	cv.origin = im.GetCursorScreenPos()
	cv.size = im.GetContentRegionAvail()
	if cv.size.x < 1 || cv.size.y < 1 {
		return true
	}

	dl := im.GetWindowDrawList()

	// A surface darker than the panel it sits in, so the nodes read as objects
	// on top of something rather than panels among panels.
	im.DrawList_AddRectFilled(dl, cv.origin, cv.origin + cv.size,
		im.GetColorU32ImVec4(_scale(im.GetStyleColorVec4(.WindowBg)^, 0.55, 1)))

	// Grid, offset with the pan so it reads as a surface. Every CANVAS_GRID_MAJOR
	// line draws brighter: a uniform grid gives the eye no scale, so panning far
	// out looks like standing still.
	minor := im.GetColorU32(.Border, 0.22)
	major := im.GetColorU32(.Border, 0.45)
	sp := CANVAS_GRID * cv.zoom
	// Each line's brightness comes from its own CANVAS-space index, not from
	// how many have been drawn this frame — otherwise the major lines slide
	// with the pan instead of being pinned to the surface.
	for x := math.mod(cv.pan.x * cv.zoom, sp); x < cv.size.x; x += sp {
		idx := int(math.round((x / cv.zoom - cv.pan.x) / CANVAS_GRID))
		col := idx % CANVAS_GRID_MAJOR == 0 ? major : minor
		im.DrawList_AddLine(dl, im.Vec2{cv.origin.x + x, cv.origin.y}, im.Vec2{cv.origin.x + x, cv.origin.y + cv.size.y}, col, 1)
	}
	for y := math.mod(cv.pan.y * cv.zoom, sp); y < cv.size.y; y += sp {
		idx := int(math.round((y / cv.zoom - cv.pan.y) / CANVAS_GRID))
		col := idx % CANVAS_GRID_MAJOR == 0 ? major : minor
		im.DrawList_AddLine(dl, im.Vec2{cv.origin.x, cv.origin.y + y}, im.Vec2{cv.origin.x + cv.size.x, cv.origin.y + y}, col, 1)
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

// One node: a header tinted by `color` with the title centred in it, `rows` in
// the body, an input dot on every row that asks for one, and one output dot on
// `out_row`. Draggable (writes `pos` back in canvas units), click selects.
// Draw after the edges.
canvas_node :: proc(
	cv: ^Node_Canvas,
	id: int,
	pos: ^im.Vec2,
	title: cstring,
	color: im.Vec4,
	rows: []Canvas_Row,
	has_out: bool,
	out_row: int = 0,
) {
	dl := im.GetWindowDrawList()
	sz := canvas_node_size(len(rows))
	rmin := canvas_to_screen(cv, pos^)
	rmax := rmin + sz * cv.zoom
	rounding := 5 * cv.zoom
	font := im.GetFont()
	font_sz := max(im.GetFontSize() * cv.zoom, 7)
	selected := cv.sel == id

	// Interaction first: the button claims hover over the background pan
	// surface, the visuals draw over both.
	im.SetCursorScreenPos(rmin)
	im.InvisibleButton(fmt.ctprintf("##canvas_node_%d", id), rmax - rmin)
	if im.IsItemActivated() do cv.sel = id
	if im.IsItemActive() && im.IsMouseDragging(.Left, 0) {
		pos^ += im.GetIO().MouseDelta / cv.zoom
	}

	// Body far darker than the header, so the header carries the type colour
	// and the body stays a surface the text reads on.
	body := _scale(im.GetStyleColorVec4(.WindowBg)^, 0.9, 0.96)
	im.DrawList_AddRectFilled(dl, rmin, rmax, im.GetColorU32ImVec4(body), rounding)
	header_h := CANVAS_HEADER_H * cv.zoom
	im.DrawList_AddRectFilled(dl, rmin, im.Vec2{rmax.x, rmin.y + header_h},
		im.GetColorU32ImVec4(_scale(color, 0.78, 1)), rounding, im.DrawFlags_RoundCornersTop)

	// The border is a BRIGHT tint of the same hue rather than neutral grey:
	// it is what makes a node read as its type from across the canvas, where
	// the header text is too small to read.
	border := _tint(color, selected ? 0.75 : 0.32)
	if selected {
		// A soft halo outside the border, so selection survives a colour the
		// theme happens to sit close to.
		im.DrawList_AddRect(dl, rmin - im.Vec2{2, 2} * cv.zoom, rmax + im.Vec2{2, 2} * cv.zoom,
			im.GetColorU32ImVec4(_tint(color, 0.6, 0.30)), rounding + 2 * cv.zoom, 3 * cv.zoom)
	}
	im.DrawList_AddRect(dl, rmin, rmax, im.GetColorU32ImVec4(border), rounding, (selected ? 2.0 : 1.2) * cv.zoom)

	// Text stays inside the node: a long clip name would otherwise run across
	// the canvas and over its neighbours. Popped before the ports, which sit ON
	// the edge and would be cut in half by it.
	im.DrawList_PushClipRect(dl, rmin, rmax, true)

	tw := im.CalcTextSize(title).x * cv.zoom
	im.DrawList_AddTextImFontPtr(dl, font, font_sz,
		im.Vec2{rmin.x + (rmax.x - rmin.x - tw) * 0.5, rmin.y + (header_h - font_sz) * 0.5},
		im.GetColorU32ImVec4(im.Vec4{0.95, 0.95, 0.95, 1}), title)

	label_col := im.GetColorU32(.Text, 0.62)
	value_col := im.GetColorU32(.Text)
	pad := CANVAS_PAD * cv.zoom
	for row, i in rows {
		y := rmin.y + (_row_y(i) * cv.zoom) - font_sz * 0.5
		if row.label != nil {
			im.DrawList_AddTextImFontPtr(dl, font, font_sz, im.Vec2{rmin.x + pad, y}, label_col, row.label)
		}
		if row.value != nil {
			vw := im.CalcTextSize(row.value).x * cv.zoom
			im.DrawList_AddTextImFontPtr(dl, font, font_sz, im.Vec2{rmax.x - pad - vw, y}, value_col, row.value)
		}
	}

	im.DrawList_PopClipRect(dl)

	for row, i in rows {
		if !row.port do continue
		_port(dl, cv, canvas_port_in(cv, pos^, i), row.col)
	}
	if has_out do _port(dl, cv, canvas_port_out(cv, pos^, out_row), PORT_POSE)
}

// A port dot with a dark ring, so it stays visible against both the node body
// and the canvas behind it.
@(private = "file")
_port :: proc(dl: ^im.DrawList, cv: ^Node_Canvas, at: im.Vec2, col: im.Vec4) {
	c := col
	if c.w == 0 do c = PORT_POSE
	r := CANVAS_PORT_R * cv.zoom
	im.DrawList_AddCircleFilled(dl, at, r, im.GetColorU32ImVec4(c))
	im.DrawList_AddCircle(dl, at, r, im.GetColorU32ImVec4(_scale(c, 0.35, 1)), 0, 1.2 * cv.zoom)
}

// Bezier edge between two port positions (screen coords), horizontal
// tangents, optional label at the midpoint. Draw before the nodes.
//
// `flow` above 0 sends beads along the edge from source to target, and is how
// much is flowing (a weight in 0..1): it sets both how fast they travel and
// how bright they are. 0 draws the line alone. An idle edge and a carrying one
// then differ by MOTION, which is the one channel a static graph has no way to
// show and the eye picks up without being pointed at it.
canvas_link :: proc(
	cv: ^Node_Canvas,
	from, to: im.Vec2,
	col: u32,
	thickness: f32 = 1.5,
	flow: f32 = 0,
	label: cstring = nil,
) {
	dl := im.GetWindowDrawList()
	d := clamp(abs(to.x - from.x) * 0.5, 30 * cv.zoom, 120 * cv.zoom)
	c1 := from + im.Vec2{d, 0}
	c2 := to - im.Vec2{d, 0}
	im.DrawList_AddBezierCubic(dl, from, c1, c2, to, col, thickness * cv.zoom)

	if flow > 0.001 {
		// One bead per BEAD_SPACING of screen length, so a long edge carries
		// several and a short one does not crowd. The chord underestimates the
		// curve, which only ever spaces them slightly wider than asked.
		span := max(abs(to.x - from.x), abs(to.y - from.y))
		n := clamp(int(span / (BEAD_SPACING * cv.zoom)), 2, 10)
		// Beads move with the weight and never stall: a barely-weighted edge
		// still creeps, which is what distinguishes it from a dead one.
		phase := f32(math.mod(im.GetTime() * f64((0.25 + 0.75 * flow) * BEAD_SPEED), 1))
		r := (thickness + 0.6) * cv.zoom
		bead := (col & 0x00FFFFFF) | (u32(clamp(90 + 165 * flow, 0, 255)) << 24)
		for i in 0 ..< n {
			t := math.mod(phase + f32(i) / f32(n), 1)
			im.DrawList_AddCircleFilled(dl, _bezier(from, c1, c2, to, t), r, bead)
		}
	}

	if label != nil {
		mid := _bezier(from, c1, c2, to, 0.5)
		font_sz := max(im.GetFontSize() * cv.zoom * 0.9, 7)
		im.DrawList_AddTextImFontPtr(dl, im.GetFont(), font_sz, mid + im.Vec2{5 * cv.zoom, -font_sz - 2}, im.GetColorU32(.Text), label)
	}
}

// Screen pixels between flowing beads at zoom 1.
BEAD_SPACING :: f32(26)
// Bead travel, in edge-lengths per second at full weight.
BEAD_SPEED :: f32(0.75)

@(private = "file")
_bezier :: proc(p0, p1, p2, p3: im.Vec2, t: f32) -> im.Vec2 {
	u := 1 - t
	return p0 * (u * u * u) + p1 * (3 * u * u * t) + p2 * (3 * u * t * t) + p3 * (t * t * t)
}

// Multiplies a colour toward black, for a muted fill of the same hue.
@(private = "file")
_scale :: proc(c: im.Vec4, f: f32, a: f32) -> im.Vec4 {
	return im.Vec4{c.x * f, c.y * f, c.z * f, a}
}

// Mixes a colour toward white, for a bright border of the same hue.
@(private = "file")
_tint :: proc(c: im.Vec4, t: f32, a: f32 = 1) -> im.Vec4 {
	return im.Vec4{c.x + (1 - c.x) * t, c.y + (1 - c.y) * t, c.z + (1 - c.z) * t, a}
}
