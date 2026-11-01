package inspector

// The gutter: a column on the left of an inspector panel's field area where
// rows carry marks.
//
//   - Bars stack from the gutter's left edge in a fixed order, whatever
//     order the rows draw them in: the prefab override bar (blue) first, then
//     the animation bar (the driven green or red, or the dimmed has-row bar,
//     driven.odin). A bar takes the first slot free over its whole height, so
//     a bar spanning several rows (an overridden struct and its child rows)
//     never covers another. Inside a gutter scope the bars are collected and
//     drawn when the scope ends, which is what keeps the order fixed
//   - The key diamond is not a bar: it has a fixed spot at the gutter's right
//     side, with room left before the label
//
// A panel reserves the gutter around the code that draws its fields
// (gutter_begin, gutter_end): the field area moves right by GUTTER_WIDTH and
// the marks draw in the space left free, at the same x for every row however
// deep it is nested. The value column does not move (field_row.odin measures
// it from the panel, not from the indent), so labels are GUTTER_WIDTH
// narrower. A row drawn outside any gutter scope puts its marks just left of
// its own left edge instead, where the window padding may clip them.

import "base:runtime"
import "core:slice"
import im "moonhug:external/odin-imgui"

// The kinds of bar, in their order from the gutter's left edge.
Gutter_Bar_Kind :: enum u8 {
	Override,
	Animation,
}

// The reserved width.
GUTTER_WIDTH :: f32(22)
// The bars: the first slot's left edge, each bar's width, and the step from
// one slot to the next. Stacked bars touch: the step is the bar's width.
GUTTER_BAR_X :: f32(2)
GUTTER_BAR_W :: f32(2)
GUTTER_BAR_STEP :: GUTTER_BAR_W
// The key diamond: its centre from the gutter's left edge and its half
// width. It ends GUTTER_WIDTH - GUTTER_DIAMOND_X - GUTTER_DIAMOND_R before
// the label.
GUTTER_DIAMOND_X :: f32(14)
GUTTER_DIAMOND_R :: f32(3.5)

// An open gutter scope. Scopes nest: only the outermost one reserves the
// column, the inner ones (a panel drawing a panel) share it.
Gutter_Scope :: struct {
	outer: bool,
}

@(private = "file")
_gutter_depth: int

// Screen x of the open gutter's left edge.
@(private = "file")
_gutter_x: f32

// A bar: which draw list, which kind, which rows (screen y), the gutter's
// left edge, the color, and once placed its slot.
@(private = "file")
_Gutter_Bar :: struct {
	dl:     ^im.DrawList,
	kind:   Gutter_Bar_Kind,
	y0, y1: f32,
	left:   f32,
	color:  u32,
	slot:   int,
}

// The open scope's bars, drawn at its end. Default allocator: reused frame
// after frame.
@(private = "file")
_gutter_pending: [dynamic]_Gutter_Bar

// The bars placed outside any scope this frame, which draw at once in the
// order they come. Cleared on a new frame.
@(private = "file")
_gutter_bars: [dynamic]_Gutter_Bar

@(private = "file")
_gutter_frame: i32 = -1

// Reserves the gutter for the fields drawn until gutter_end: the cursor
// moves right by GUTTER_WIDTH. Call at the start of a panel's field area.
gutter_begin :: proc() -> Gutter_Scope {
	_gutter_depth += 1
	if _gutter_depth > 1 do return {}
	_gutter_x = im.GetCursorScreenPos().x
	im.Indent(GUTTER_WIDTH)
	return {outer = true}
}

gutter_end :: proc(g: Gutter_Scope) {
	assert(_gutter_depth > 0, "inspector: gutter_end matches a gutter_begin")
	_gutter_depth -= 1
	if !g.outer do return
	im.Unindent(GUTTER_WIDTH)
	_gutter_flush()
}

// Places and draws the scope's bars: kind by kind in the fixed order, each
// in the first slot free over its height.
@(private = "file")
_gutter_flush :: proc() {
	slice.stable_sort_by(_gutter_pending[:], proc(a, b: _Gutter_Bar) -> bool { return a.kind < b.kind })
	for &b, i in _gutter_pending {
		b.slot = _gutter_free_slot(_gutter_pending[:i], b)
		_gutter_draw(b)
	}
	clear(&_gutter_pending)
}

// The first slot no bar of `placed` takes over `b`'s height.
@(private = "file")
_gutter_free_slot :: proc(placed: []_Gutter_Bar, b: _Gutter_Bar) -> int {
	slot := 0
	for taken := true; taken; {
		taken = false
		for p in placed {
			if p.dl == b.dl && p.slot == slot && p.y0 < b.y1 && b.y0 < p.y1 {
				taken = true
				slot += 1
				break
			}
		}
	}
	return slot
}

@(private = "file")
_gutter_draw :: proc(b: _Gutter_Bar) {
	x := b.left + GUTTER_BAR_X + f32(b.slot) * GUTTER_BAR_STEP
	im.DrawList_AddRectFilled(b.dl, {x, b.y0}, {x + GUTTER_BAR_W, b.y1}, b.color)
}

// The gutter's left edge for a row starting at `row_min`.
@(private = "file")
_gutter_left :: proc(row_min: im.Vec2) -> f32 {
	return _gutter_depth > 0 ? _gutter_x : row_min.x - GUTTER_WIDTH
}

// A bar of kind `kind` from the row's top `rmin` to its bottom `rmax`.
// Inside a gutter scope it draws when the scope ends, in its kind's place
// (_gutter_flush). Outside one it draws at once, in the first slot free over
// its height.
gutter_bar :: proc(kind: Gutter_Bar_Kind, rmin, rmax: im.Vec2, color: im.Vec4) {
	if rmax.y <= rmin.y do return
	b := _Gutter_Bar{
		dl    = im.GetWindowDrawList(),
		kind  = kind,
		y0    = rmin.y,
		y1    = rmax.y,
		left  = _gutter_left(rmin),
		color = im.GetColorU32ImVec4(color),
	}
	if _gutter_depth > 0 {
		if _gutter_pending.allocator.procedure == nil do _gutter_pending.allocator = runtime.default_allocator()
		append(&_gutter_pending, b)
		return
	}
	if frame := im.GetFrameCount(); frame != _gutter_frame {
		_gutter_frame = frame
		if _gutter_bars.allocator.procedure == nil do _gutter_bars.allocator = runtime.default_allocator()
		clear(&_gutter_bars)
	}
	b.slot = _gutter_free_slot(_gutter_bars[:], b)
	append(&_gutter_bars, b)
	_gutter_draw(b)
}

// The key diamond at its fixed spot, centred on the row's height.
gutter_diamond :: proc(rmin, rmax: im.Vec2, color: im.Vec4) {
	if rmax.y <= rmin.y do return
	r := GUTTER_DIAMOND_R
	c := im.Vec2{_gutter_left(rmin) + GUTTER_DIAMOND_X, (rmin.y + rmax.y) * 0.5}
	im.DrawList_AddQuadFilled(im.GetWindowDrawList(), {c.x, c.y - r}, {c.x + r, c.y}, {c.x, c.y + r}, {c.x - r, c.y}, im.GetColorU32ImVec4(color))
}
