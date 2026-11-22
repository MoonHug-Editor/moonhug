package mhgui

import "core:math"
import "moonhug:packages/engine"

Layout_Direction :: enum u8 {
	Horizontal, // children in a row, left to right
	Vertical,   // children in a column, top to bottom
	Grid,       // cells of cell_size, from start_corner along start_axis
}

// The corner a grid's first cell is in.
Grid_Corner :: enum u8 {
	Upper_Left,
	Upper_Right,
	Lower_Left,
	Lower_Right,
}

// The way a grid fills: a row at a time, or a column at a time.
Grid_Axis :: enum u8 {
	Horizontal,
	Vertical,
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
// as a layout provider (canvas_layout_groups below).
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
	start_corner:     Grid_Corner `decor:tooltip(desc="Grid: the corner the first child's cell is in.")`,
	start_axis:       Grid_Axis `decor:tooltip(desc="Grid: Horizontal fills a row, then the next row. Vertical fills a column, then the next column.")`,
	// Horizontal, Vertical: the children fill the padded area along that
	// axis. Along the flow they share the room left over, each by its
	// LayoutElement's flexible share (1 without one). Across it each takes
	// the full size.
	expand_width:     bool `decor:tooltip(desc="Row or column: the children fill the area's width. Along a row they share the room left over, in a column each is as wide as the area.")`,
	expand_height:    bool `decor:tooltip(desc="Row or column: the children fill the area's height. Down a column they share the room left over, in a row each is as tall as the area.")`,
}

type_reset_LayoutGroup :: proc(g: ^LayoutGroup) {
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
		// How many cells fit along an axis of the padded area.
		fit :: proc(room, cell, gap: f32) -> int {
			if cell + gap <= 0 do return 1
			return max(int(math.floor((room + gap) / (cell + gap))), 1)
		}
		cols, rows := 1, 1
		count := max(int(g.constraint_count), 1)
		// The fixed count, or along the start axis what fits. The other
		// count is what the children need.
		switch g.constraint {
		case .Fixed_Column_Count:
			cols = count
			rows = max((n + cols - 1) / cols, 1)
		case .Fixed_Row_Count:
			rows = count
			cols = max((n + rows - 1) / rows, 1)
		case .Flexible:
			if g.start_axis == .Horizontal {
				cols = fit(area.size.x, cell.x, g.spacing.x)
				rows = max((n + cols - 1) / cols, 1)
			} else {
				rows = fit(area.size.y, cell.y, g.spacing.y)
				cols = max((n + rows - 1) / rows, 1)
			}
		}
		content := [2]f32{
			f32(cols) * cell.x + f32(cols - 1) * g.spacing.x,
			f32(rows) * cell.y + f32(rows - 1) * g.spacing.y,
		}
		origin_x := area.pos.x + (area.size.x - content.x) * align.x
		top := area.pos.y + area.size.y - (area.size.y - content.y) * (1 - align.y)
		from_right := g.start_corner == .Upper_Right || g.start_corner == .Lower_Right
		from_bottom := g.start_corner == .Lower_Left || g.start_corner == .Lower_Right
		for i in 0 ..< n {
			c, r := i % cols, i / cols
			if g.start_axis == .Vertical do c, r = i / rows, i % rows
			if from_right do c = cols - 1 - c
			if from_bottom do r = rows - 1 - r
			out[i] = engine.Rect{
				pos  = {origin_x + f32(c) * (cell.x + g.spacing.x), top - f32(r + 1) * cell.y - f32(r) * g.spacing.y},
				size = cell,
			}
		}
	}
}

// What a child asks of a row or a column: the least it takes, what it wants
// and its share of the room left over. From its LayoutElement, or its
// content's size, or its RectTransform's size.
Layout_Sizes :: struct {
	min:       [2]f32,
	preferred: [2]f32,
	flexible:  [2]f32,
}

// A child's say in a layout, per axis:
// - The least it takes and its share of spare room come from its
//   LayoutElement, 0 without one.
// - What it wants is its LayoutElement's preferred size when that is set
//   (0 or more), else its content's size on the axes its ContentSizeFitter
//   fits, else its size_delta.
layout_child_sizes :: proc(child: engine.Transform_Handle) -> (s: Layout_Sizes) {
	_, rt := engine.transform_get_comp(child, engine.RectTransform)
	if rt != nil do s.preferred = rt.size_delta
	// A node that sizes itself asks for its content's size on the axes it fits.
	fits: [2]bool
	if _, f := get_comp(child, ContentSizeFitter); f != nil && f.enabled {
		fits = {f.horizontal_fit == .Preferred_Size, f.vertical_fit == .Preferred_Size}
	}
	if fits.x || fits.y {
		if content, has := layout_content_size(child, 0 if fits.x else s.preferred.x); has {
			for axis in 0 ..< 2 do if fits[axis] && content[axis] >= 0 do s.preferred[axis] = content[axis]
		}
	}
	if _, el := get_comp(child, LayoutElement); el != nil && el.enabled {
		s.min = {max(el.min_size.x, 0), max(el.min_size.y, 0)}
		s.flexible = {max(el.flexible.x, 0), max(el.flexible.y, 0)}
		for axis in 0 ..< 2 do if el.preferred_size[axis] >= 0 do s.preferred[axis] = el.preferred_size[axis]
	}
	for axis in 0 ..< 2 do s.preferred[axis] = max(s.preferred[axis], s.min[axis])
	return
}

// The sizes along one axis for children that share `room`: each gets what it
// wants. Too little room takes from what they want down to their least, by
// the same share of each one's give. Room left over goes to the flexible
// ones by their shares, to all alike with `expand` when none is flexible.
layout_distribute :: proc(sizes: []Layout_Sizes, axis: int, room: f32, expand: bool, out: []f32) {
	wanted, least, flex: f32
	for s in sizes {
		wanted += s.preferred[axis]
		least += s.min[axis]
		flex += s.flexible[axis]
	}
	for s, i in sizes do out[i] = s.preferred[axis]
	if room < wanted {
		give := wanted - least
		if give <= 0 do return
		k := clamp((wanted - room) / give, 0, 1)
		for s, i in sizes do out[i] = s.preferred[axis] - (s.preferred[axis] - s.min[axis]) * k
		return
	}
	spare := room - wanted
	if spare <= 0 do return
	if flex > 0 {
		for s, i in sizes do out[i] += spare * s.flexible[axis] / flex
	} else if expand && len(sizes) > 0 {
		for _, i in sizes do out[i] += spare / f32(len(sizes))
	}
}

// The size a node's content wants, per axis, -1 where it has no say: a node
// with a LayoutGroup wants what its children want with the padding and the
// spacing, and a node with a graphic that measures itself (a Text) wants
// that. `width` is the width a wrapping content has to fit in.
layout_content_size :: proc(tH: engine.Transform_Handle, width: f32) -> (size: [2]f32, ok: bool) {
	if _, g := get_comp(tH, LayoutGroup); g != nil && g.enabled {
		w := engine.ctx_world()
		t := engine.pool_get(&w.transforms, engine.Handle(tH))
		if t == nil do return
		pad := [2]f32{g.padding.left + g.padding.right, g.padding.top + g.padding.bottom}
		n := 0
		along, across: f32
		for child in t.children {
			ch := engine.Transform_Handle(child.handle)
			if !_in_layout(ch) do continue
			want := g.cell_size if g.direction == .Grid else layout_child_sizes(ch).preferred
			if g.direction == .Vertical {
				along += want.y
				across = max(across, want.x)
			} else {
				along += want.x
				across = max(across, want.y)
			}
			n += 1
		}
		switch g.direction {
		case .Horizontal: return {along + f32(max(n - 1, 0)) * g.spacing.x + pad.x, across + pad.y}, true
		case .Vertical:   return {across + pad.x, along + f32(max(n - 1, 0)) * g.spacing.y + pad.y}, true
		case .Grid:
			cols := max(int(g.constraint_count), 1) if g.constraint == .Fixed_Column_Count else max(n, 1)
			if g.constraint == .Fixed_Row_Count do cols = max((n + max(int(g.constraint_count), 1) - 1) / max(int(g.constraint_count), 1), 1)
			if g.constraint == .Flexible && width > 0 && g.cell_size.x + g.spacing.x > 0 {
				cols = max(int(math.floor((width - pad.x + g.spacing.x) / (g.cell_size.x + g.spacing.x))), 1)
			}
			rows := (n + cols - 1) / cols if n > 0 else 0
			return {f32(cols) * g.cell_size.x + f32(max(cols - 1, 0)) * g.spacing.x + pad.x, f32(rows) * g.cell_size.y + f32(max(rows - 1, 0)) * g.spacing.y + pad.y}, true
		}
	}
	return engine.node_measure(tH, width)
}

// Whether a child takes part in its parent's layout: active, with an enabled
// RectTransform, and no LayoutElement that says to ignore the layout.
@(private = "file")
_in_layout :: proc(ch: engine.Transform_Handle) -> bool {
	t := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(ch))
	if t == nil || !t.is_active do return false
	if _, rt := engine.transform_get_comp(ch, engine.RectTransform); rt == nil || !rt.enabled do return false
	if _, el := get_comp(ch, LayoutElement); el != nil && el.enabled && el.ignore_layout do return false
	return true
}

// The engine's layout provider: a node with an enabled LayoutGroup arranges
// its RectTransform children. A row or a column sizes them from what each
// asks (layout_child_sizes) and the group's expand settings, a grid gives
// each cell_size. A child whose LayoutElement says ignore_layout keeps the
// rect its own anchors give it.
@(canvas_layout)
canvas_layout_groups :: proc(tH: engine.Transform_Handle, rect: engine.Rect, children: []engine.Transform_Handle, out: []engine.Rect) -> bool {
	_, g := get_comp(tH, LayoutGroup)
	if g == nil || !g.enabled do return false
	// The children the layout places, and where each goes in `out`.
	placed := make([dynamic]int, 0, len(children), context.temp_allocator)
	for ch, i in children {
		if _in_layout(ch) {
			append(&placed, i)
		} else if _, rt := engine.transform_get_comp(ch, engine.RectTransform); rt != nil {
			out[i] = engine.rect_resolve(rect, rt)
		}
	}
	n := len(placed)
	sizes := make([][2]f32, n, context.temp_allocator)
	if g.direction == .Grid {
		for _, k in placed do sizes[k] = g.cell_size
	} else {
		asks := make([]Layout_Sizes, n, context.temp_allocator)
		for i, k in placed do asks[k] = layout_child_sizes(children[i])
		area := rect.size - {g.padding.left + g.padding.right, g.padding.top + g.padding.bottom}
		along := make([]f32, n, context.temp_allocator)
		if g.direction == .Horizontal {
			layout_distribute(asks, 0, area.x - f32(max(n - 1, 0)) * g.spacing.x, g.expand_width, along)
			for a, k in asks do sizes[k] = {along[k], area.y if g.expand_height else a.preferred.y}
		} else {
			layout_distribute(asks, 1, area.y - f32(max(n - 1, 0)) * g.spacing.y, g.expand_height, along)
			for a, k in asks do sizes[k] = {area.x if g.expand_width else a.preferred.x, along[k]}
		}
	}
	rects := make([]engine.Rect, n, context.temp_allocator)
	layout_arrange(g, rect, sizes, rects)
	for i, k in placed do out[i] = rects[k]
	return true
}

// What a node asks of the LayoutGroup that places it.
@(component={menu="UI/LayoutElement"})
@(typ_guid={guid = "f0939073-ff36-44de-ac9f-ac43ed32bb41"})
LayoutElement :: struct {
	using base:     engine.CompData `inspect:"-"`,
	ignore_layout:  bool `decor:tooltip(desc="The layout leaves this node out: it keeps the rect its own anchors give it.")`,
	min_size:       [2]f32 `decor:min(0) decor:tooltip(desc="The least the node takes, when the layout has too little room.")`,
	preferred_size: [2]f32 `decor:tooltip(desc="What the node wants. Under 0 leaves an axis to the node's content or its own size.")`,
	flexible:       [2]f32 `decor:min(0) decor:tooltip(desc="The node's share of the room the layout has left over along its flow. 0 takes none.")`,
}

type_reset_LayoutElement :: proc(e: ^LayoutElement) {
	e.preferred_size = {-1, -1}
}

// How a ContentSizeFitter sets one axis of its node.
Fit_Mode :: enum u8 {
	Unconstrained, // the node's own size stands
	Min_Size,      // its LayoutElement's min_size
	Preferred_Size, // what its content wants (layout_content_size)
}

// Sizes its node to its content: a Text to its string, a node with a
// LayoutGroup to its children. The node grows and shrinks around its pivot,
// so a pivot at the top keeps the top edge where it is. A node a LayoutGroup
// places is sized by that group, which asks for the same sizes.
@(component={menu="UI/ContentSizeFitter"})
@(typ_guid={guid = "0d6d8690-2676-484f-98ff-c4d41661fb79"})
ContentSizeFitter :: struct {
	using base:     engine.CompData `inspect:"-"`,
	horizontal_fit: Fit_Mode,
	vertical_fit:   Fit_Mode,
}

Aspect_Mode :: enum u8 {
	None,
	Width_Controls_Height, // the height follows the width
	Height_Controls_Width, // the width follows the height
	Fit_In_Parent,         // the largest rect of the ratio inside the parent, centred
	Envelope_Parent,       // the smallest rect of the ratio that covers the parent, centred
}

// Keeps its node at a width to height ratio.
@(component={menu="UI/AspectRatioFitter"})
@(typ_guid={guid = "aae9ec5a-8b42-46d9-8e5d-537c8742d450"})
AspectRatioFitter :: struct {
	using base:   engine.CompData `inspect:"-"`,
	aspect_mode:  Aspect_Mode,
	aspect_ratio: f32 `decor:min(0.001) decor:tooltip(desc="Width over height: 2 is twice as wide as tall.")`,
}

type_reset_AspectRatioFitter :: proc(a: ^AspectRatioFitter) {
	a.aspect_ratio = 1
}

// The engine's rect provider for both fitters: a node with an enabled
// ContentSizeFitter or AspectRatioFitter gets its rect from it, around the
// node's pivot.
@(canvas_rect)
canvas_rect_fitters :: proc(tH: engine.Transform_Handle, parent: engine.Rect, rect: engine.Rect) -> (engine.Rect, bool) {
	// With no fitter in the world, no node looks for one.
	w := engine.ctx_world()
	any_fit := content_size_fitters(w).count > 0
	any_aspect := aspect_ratio_fitters(w).count > 0
	if !any_fit && !any_aspect do return rect, false
	_, rt := engine.transform_get_comp(tH, engine.RectTransform)
	if rt == nil do return rect, false
	out := rect
	changed := false
	// Resizes around the pivot: the pivot's point of the rect stays put.
	resize :: proc(r: engine.Rect, pivot: [2]f32, size: [2]f32) -> engine.Rect {
		at := r.pos + r.size * pivot
		return {pos = at - size * pivot, size = size}
	}
	if _, f := get_comp(tH, ContentSizeFitter); f != nil && f.enabled && (f.horizontal_fit != .Unconstrained || f.vertical_fit != .Unconstrained) {
		size := out.size
		_, el := get_comp(tH, LayoutElement)
		has_el := el != nil && el.enabled
		// The width first: content that wraps is as tall as its width makes it.
		modes := [2]Fit_Mode{f.horizontal_fit, f.vertical_fit}
		for axis in 0 ..< 2 {
			switch modes[axis] {
			case .Unconstrained:
			case .Min_Size:
				if has_el do size[axis] = max(el.min_size[axis], 0)
			case .Preferred_Size:
				want := f32(-1)
				if has_el && el.preferred_size[axis] >= 0 {
					want = el.preferred_size[axis]
				} else if content, has := layout_content_size(tH, 0 if modes[0] == .Preferred_Size else size.x); has {
					want = content[axis]
				}
				if want >= 0 do size[axis] = want
			}
		}
		out = resize(out, rt.pivot, size)
		changed = true
	}
	if _, a := get_comp(tH, AspectRatioFitter); a != nil && a.enabled && a.aspect_mode != .None && a.aspect_ratio > 0 {
		ratio := a.aspect_ratio
		switch a.aspect_mode {
		case .None:
		case .Width_Controls_Height:
			out = resize(out, rt.pivot, {out.size.x, out.size.x / ratio})
		case .Height_Controls_Width:
			out = resize(out, rt.pivot, {out.size.y * ratio, out.size.y})
		case .Fit_In_Parent, .Envelope_Parent:
			size := parent.size
			wide := parent.size.x / max(parent.size.y, 0.0001) > ratio // the parent is wider than the ratio
			if (a.aspect_mode == .Fit_In_Parent) == wide {
				size = {parent.size.y * ratio, parent.size.y}
			} else {
				size = {parent.size.x, parent.size.x / ratio}
			}
			out = {pos = parent.pos + (parent.size - size) * 0.5, size = size}
		}
		changed = true
	}
	return out, changed
}
