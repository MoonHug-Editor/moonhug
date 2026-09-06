package mhgui

import "core:math"
import "moonhug:engine"

Layout_Direction :: enum u8 {
	Horizontal, // children in a row, left to right
	Vertical,   // children in a column, top to bottom
	Grid,       // cells of cell_size, rows top to bottom, each row left to right
}

// Where the laid-out content sits inside the padded area when it does not
// fill it, and where each child sits across the flow axis.
Child_Alignment :: enum u8 {
	Upper_Left, Upper_Center, Upper_Right,
	Middle_Left, Middle_Center, Middle_Right,
	Lower_Left, Lower_Center, Lower_Right,
}

Grid_Constraint :: enum u8 {
	Flexible,           // as many columns as fit the padded width
	Fixed_Column_Count, // constraint_count columns
	Fixed_Row_Count,    // constraint_count rows
}

Rect_Offset :: struct {
	left, right, top, bottom: f32,
}

// Lays out the node's children with a RectTransform in a row, a column or a
// grid, in canvas units. A laid-out child's anchors and anchored_position
// are ignored: in a row or column its size is its size_delta, in a grid it is
// cell_size, and its rect comes from the flow. Children without a
// RectTransform stay out of the layout. Plugged into the engine's rect walk
// as a layout provider (engine.canvas_layout_register).
@(component={menu="UI/LayoutGroup"})
@(typ_guid={guid = "de2516a6-7a94-4f67-9c0b-fc2d4c78dbdd"})
LayoutGroup :: struct {
	using base:       engine.CompData `inspect:"-"`,
	direction:        Layout_Direction,
	padding:          Rect_Offset,
	spacing:          [2]f32, // x between columns / row items, y between rows / column items
	child_alignment:  Child_Alignment,
	cell_size:        [2]f32, // Grid
	constraint:       Grid_Constraint, // Grid
	constraint_count: i32, // Grid, Fixed_* constraints
}

reset_LayoutGroup :: proc(g: ^LayoutGroup) {
	g.spacing = {8, 8}
	g.cell_size = {100, 100}
	g.constraint_count = 2
}

// Alignment as fractions: x 0 left .. 1 right, y 0 bottom .. 1 top.
@(private = "file")
_alignment_fractions :: proc(a: Child_Alignment) -> [2]f32 {
	col := f32(int(a) % 3) * 0.5
	row := 1 - f32(int(a) / 3) * 0.5
	return {col, row}
}

// The rects of `sizes` laid out inside `rect`, written to `out` (same length
// as sizes). Pure: the layout provider below calls it for a node with a
// LayoutGroup, and the tests cover it directly.
layout_arrange :: proc(g: ^LayoutGroup, rect: engine.Rect, sizes: [][2]f32, out: []engine.Rect) {
	n := len(sizes)
	if n == 0 do return
	area := engine.Rect{
		pos  = rect.pos + {g.padding.left, g.padding.bottom},
		size = rect.size - {g.padding.left + g.padding.right, g.padding.top + g.padding.bottom},
	}
	align := _alignment_fractions(g.child_alignment)

	switch g.direction {
	case .Horizontal:
		total := f32(n - 1) * g.spacing.x
		line_h := f32(0)
		for s in sizes {
			total += s.x
			line_h = max(line_h, s.y)
		}
		x := area.pos.x + (area.size.x - total) * align.x
		for s, i in sizes {
			y := area.pos.y + (area.size.y - s.y) * align.y
			out[i] = engine.Rect{pos = {x, y}, size = s}
			x += s.x + g.spacing.x
		}
	case .Vertical:
		total := f32(n - 1) * g.spacing.y
		for s in sizes do total += s.y
		// The column hangs from its top: alignment picks where the top sits.
		top := area.pos.y + area.size.y - (area.size.y - total) * (1 - align.y)
		for s, i in sizes {
			x := area.pos.x + (area.size.x - s.x) * align.x
			out[i] = engine.Rect{pos = {x, top - s.y}, size = s}
			top -= s.y + g.spacing.y
		}
	case .Grid:
		cell := g.cell_size
		cols := 1
		switch g.constraint {
		case .Fixed_Column_Count:
			cols = max(int(g.constraint_count), 1)
		case .Fixed_Row_Count:
			rows := max(int(g.constraint_count), 1)
			cols = max((n + rows - 1) / rows, 1)
		case .Flexible:
			if cell.x + g.spacing.x > 0 {
				cols = max(int(math.floor((area.size.x + g.spacing.x) / (cell.x + g.spacing.x))), 1)
			}
		}
		rows := (n + cols - 1) / cols
		content := [2]f32{
			f32(cols) * cell.x + f32(cols - 1) * g.spacing.x,
			f32(rows) * cell.y + f32(rows - 1) * g.spacing.y,
		}
		origin_x := area.pos.x + (area.size.x - content.x) * align.x
		top := area.pos.y + area.size.y - (area.size.y - content.y) * (1 - align.y)
		for i in 0 ..< n {
			c := i % cols
			r := i / cols
			out[i] = engine.Rect{
				pos  = {origin_x + f32(c) * (cell.x + g.spacing.x), top - f32(r + 1) * cell.y - f32(r) * g.spacing.y},
				size = cell,
			}
		}
	}
}

// The engine's layout provider: a node with an enabled LayoutGroup arranges
// its RectTransform children. Sizes come from the children (size_delta), or
// from cell_size for a grid.
layout_provider :: proc(tH: engine.Transform_Handle, rect: engine.Rect, children: []engine.Transform_Handle, out: []engine.Rect) -> bool {
	_, g := get_comp(tH, LayoutGroup)
	if g == nil || !g.enabled do return false
	sizes := make([][2]f32, len(children), context.temp_allocator)
	for ch, i in children {
		if g.direction == .Grid {
			sizes[i] = g.cell_size
		} else if _, rt := engine.transform_get_comp(ch, engine.RectTransform); rt != nil {
			sizes[i] = rt.size_delta
		}
	}
	layout_arrange(g, rect, sizes, out)
	return true
}
