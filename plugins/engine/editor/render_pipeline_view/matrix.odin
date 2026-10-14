package render_pipeline_view

// The matrix: passes as columns in run order (the frame lane's left of a
// divider, each lane closed by a "+" column), resources as rows. A cell marks
// what the pass does to the resource, a bar spans the resource's lifetime.
//
// - Selecting a pass (its header or any of its cells) tints the rows it reads
//   in one color, the rows it writes in another, rows it reads and writes in
//   place in a third.
// - Selecting a row (its label or a cell) marks its writers and readers.
// - A header drags onto another header (insert before it) or onto a lane's
//   "+" (append). Its context menu inserts, mutes, opens code or removes.

import "core:fmt"
import "core:math"
import im "moonhug:external/odin-imgui"
import "moonhug:editor/widgets"

_CW    :: f32(30)  // column width
_RH    :: f32(24)  // row height
_LW    :: f32(200) // the row labels
_HH    :: f32(165) // the header with the rotated pass names
_ANGLE :: f32(-55) // the pass names' rotation, degrees

// The matrix's visible columns as laid out: column index into the model, or
// -1 for a lane's "+" column (frame = which lane).
_Slot :: struct {
	col:   int,
	frame: bool,
}

_rp_matrix :: proc(m: ^_Model) {
	slots := make([dynamic]_Slot, context.temp_allocator)
	for c, i in m.cols do if c.frame && _rp_col_visible(c) do append(&slots, _Slot{col = i, frame = true})
	append(&slots, _Slot{col = -1, frame = true})
	divider := len(slots)
	for c, i in m.cols do if !c.frame && _rp_col_visible(c) do append(&slots, _Slot{col = i})
	append(&slots, _Slot{col = -1})
	rows := make([dynamic]int, context.temp_allocator)
	for &r, i in m.res do if _rp_row_visible(&r) do append(&rows, i)

	origin := im.GetCursorScreenPos()
	dl := im.GetWindowDrawList()
	grid_x := origin.x + _LW
	body_y := origin.y + _HH
	body_h := f32(len(rows)) * _RH
	slot_x :: proc(grid_x: f32, k: int) -> f32 { return grid_x + f32(k) * _CW }
	col_slot := make(map[int]int, context.temp_allocator) // model column -> slot
	for s, k in slots do if s.col >= 0 do col_slot[s.col] = k

	sel_col := _rp_find_col(m, _rp.sel)
	sel_res := _rp_find_res(m, _rp.sel_res)
	text_col := im.GetColorU32(.Text)
	dim_col := im.GetColorU32(.TextDisabled)
	accent := im.GetStyleColorVec4(.HeaderActive)^

	// Mouse over the body: which slot and row.
	mouse := im.GetMousePos()
	hover_k, hover_row := -1, -1
	if im.IsWindowHovered() {
		if mouse.x >= grid_x && mouse.x < slot_x(grid_x, len(slots)) do hover_k = int((mouse.x - grid_x) / _CW)
		if mouse.y >= body_y && mouse.y < body_y + body_h do hover_row = int((mouse.y - body_y) / _RH)
	}

	// Backgrounds: the frame lane, the selected and hovered column, the rows
	// the selected pass touches, the selected and hovered row.
	right := slot_x(grid_x, len(slots))
	im.DrawList_AddRectFilled(dl, im.Vec2{grid_x, body_y}, im.Vec2{slot_x(grid_x, divider), body_y + body_h}, im.GetColorU32(.FrameBg, 0.35))
	if k, ok := col_slot[sel_col]; ok && sel_col >= 0 {
		im.DrawList_AddRectFilled(dl, im.Vec2{slot_x(grid_x, k), origin.y}, im.Vec2{slot_x(grid_x, k + 1), body_y + body_h}, _rp_with_alpha(accent, 0.22))
	}
	if hover_k >= 0 && hover_k < len(slots) && slots[hover_k].col >= 0 && (hover_row >= 0 || mouse.y < body_y) {
		im.DrawList_AddRectFilled(dl, im.Vec2{slot_x(grid_x, hover_k), origin.y}, im.Vec2{slot_x(grid_x, hover_k + 1), body_y + body_h}, _rp_with_alpha(accent, 0.08))
	}
	for ri, y_i in rows {
		r := &m.res[ri]
		y := body_y + f32(y_i) * _RH
		if sel_col >= 0 {
			tint: Maybe(im.Vec4)
			switch r.cells[sel_col].access {
			case .Read:       tint = _RP_IN
			case .Write:      tint = _RP_OUT
			case .Read_Write: tint = _RP_INOUT
			case .None:
			}
			if c, ok := tint.?; ok do im.DrawList_AddRectFilled(dl, im.Vec2{origin.x, y + 1}, im.Vec2{right, y + _RH - 1}, _rp_with_alpha(c, 0.24))
		}
		if r == sel_res do im.DrawList_AddRect(dl, im.Vec2{origin.x + 1, y + 1}, im.Vec2{right, y + _RH - 1}, _rp_with_alpha(accent, 0.9), 2, 2)
		else if y_i == hover_row do im.DrawList_AddRectFilled(dl, im.Vec2{origin.x, y}, im.Vec2{right, y + _RH}, _rp_with_alpha(accent, 0.06))
	}

	// Column lines and the lane divider.
	for s, k in slots {
		if s.col < 0 do continue
		cx := slot_x(grid_x, k) + _CW * 0.5
		im.DrawList_AddLine(dl, im.Vec2{cx, body_y}, im.Vec2{cx, body_y + body_h}, im.GetColorU32(.Border, 0.35))
	}
	dx := slot_x(grid_x, divider)
	im.DrawList_AddLine(dl, im.Vec2{dx, origin.y + 18}, im.Vec2{dx, body_y + body_h}, im.GetColorU32(.Border), 1.5)

	// Row labels, lifetime bars and cells.
	for ri, y_i in rows {
		r := &m.res[ri]
		y := body_y + f32(y_i) * _RH
		cy := y + _RH * 0.5
		_rp_row_label(dl, r, im.Vec2{origin.x, y})
		im.SetCursorScreenPos(im.Vec2{origin.x, y})
		if im.InvisibleButton(fmt.ctprintf("##row_%d", ri), im.Vec2{_LW, _RH}) {
			_rp_set_string(&_rp.sel_res, r.name)
			_rp.scroll_res = true
		}
		if im.IsItemHovered() do widgets.tooltip(fmt.ctprintf("%s", _rp_row_tooltip(m, r)))

		if r.first >= 0 {
			k0, ok0 := col_slot[r.first]
			k1, ok1 := col_slot[r.last]
			if ok0 && ok1 && k1 > k0 {
				_rp_lifetime_bar(dl, slot_x(grid_x, k0) + _CW * 0.5, slot_x(grid_x, k1) + _CW * 0.5, cy)
			}
		}
		for cell, ci in r.cells {
			if cell.access == .None do continue
			k, ok := col_slot[ci]
			if !ok do continue
			c := im.Vec2{slot_x(grid_x, k) + _CW * 0.5, cy}
			_rp_cell_glyph(dl, cell, c, m.cols[ci].entry.muted)
		}
	}

	// The body's clicks and tooltips.
	if body_h > 0 {
		im.SetCursorScreenPos(im.Vec2{grid_x, body_y})
		clicked := im.InvisibleButton("##grid", im.Vec2{max(right - grid_x, 1), body_h})
		if im.IsItemHovered() && hover_k >= 0 && hover_k < len(slots) && hover_row >= 0 && hover_row < len(rows) {
			s := slots[hover_k]
			r := &m.res[rows[hover_row]]
			if s.col >= 0 && widgets.tooltip_begin() {
				_rp_cell_tooltip(m, r, s.col)
				widgets.tooltip_end()
			}
			if clicked && s.col >= 0 {
				_rp.sel = m.cols[s.col].entry.id
				_rp_set_string(&_rp.sel_res, r.name)
				_rp.scroll_pass = true
				_rp.scroll_res = true
			}
		}
	}

	// The header: rotated names over the columns, the "+" columns, the lane
	// captions in the corner.
	_rp_header(m, slots[:], divider, origin, grid_x, sel_col, text_col, dim_col, accent)

	// Legend below: every mark the matrix draws, drawn the same way.
	ly := body_y + body_h + 12
	lx := origin.x + 4
	cy := ly + im.GetTextLineHeight() * 0.5
	legend :: proc(dl: ^im.DrawList, x: ^f32, y, cy: f32, cell: _Cell, label: cstring) {
		_rp_cell_glyph(dl, cell, im.Vec2{x^ + 6, cy}, false)
		im.DrawList_AddText(dl, im.Vec2{x^ + 16, y}, im.GetColorU32(.TextDisabled), label)
		x^ += 26 + im.CalcTextSize(label).x
	}
	legend(dl, &lx, ly, cy, _Cell{access = .Write}, "writes")
	legend(dl, &lx, ly, cy, _Cell{access = .Read}, "reads")
	legend(dl, &lx, ly, cy, _Cell{access = .Read, via_final = true}, "reads as final")
	legend(dl, &lx, ly, cy, _Cell{access = .Read_Write}, "reads and writes in place")
	legend(dl, &lx, ly, cy, _Cell{access = .Read, unwritten = true}, "reads, no writer")
	_rp_lifetime_bar(dl, lx, lx + 20, cy)
	im.DrawList_AddText(dl, im.Vec2{lx + 26, ly}, im.GetColorU32(.TextDisabled), "lifetime")

	im.SetCursorScreenPos(origin)
	im.Dummy(im.Vec2{right - origin.x + 160, _HH + body_h + 40})
}

_rp_header :: proc(m: ^_Model, slots: []_Slot, divider: int, origin: im.Vec2, grid_x: f32, sel_col: int, text_col, dim_col: u32, accent: im.Vec4) {
	dl := im.GetWindowDrawList()
	lh := im.GetTextLineHeight()

	// The corner: what the columns and rows are.
	n_lane := 0
	for c in m.cols do if !c.frame do n_lane += 1
	im.DrawList_AddText(dl, origin + im.Vec2{4, _HH - lh * 3 - 8}, dim_col, fmt.ctprintf("frame lane: %d", len(m.cols) - n_lane))
	im.DrawList_AddText(dl, origin + im.Vec2{4, _HH - lh * 2 - 6}, dim_col, fmt.ctprintf("slot %s: %d", _rp.slot, n_lane))
	im.DrawList_AddText(dl, origin + im.Vec2{4, _HH - lh - 4}, text_col, "Resources")

	// The rotated names may reach past the child's clip rect, which would
	// cut glyphs before the rotation: draw them under the window's own.
	wp := im.GetWindowPos()
	ws := im.GetWindowSize()
	for s, k in slots {
		x := grid_x + f32(k) * _CW
		if s.col < 0 {
			_rp_plus_column(s, x, origin)
			continue
		}
		c := m.cols[s.col]
		e := c.entry
		col := text_col
		if c.node == nil do col = im.GetColorU32ImVec4(_RP_DANGER)
		else if e.muted do col = dim_col
		name := fmt.ctprintf("%s%s", e.node, e.muted ? " (muted)" : "")
		pivot := im.Vec2{x + _CW * 0.5 - lh * 0.35, origin.y + _HH - lh * 0.6 - 10}
		im.DrawList_PushClipRect(dl, wp, wp + ws, false)
		_rp_text_rotated(dl, pivot, col, name, _ANGLE)
		if s.col == sel_col do _rp_text_rotated(dl, pivot + im.Vec2{1, 0}, col, name, _ANGLE)
		im.DrawList_PopClipRect(dl)
		pkg := c.node != nil ? _rp_package_color(c.node.pkg) : im.Vec4{0.4, 0.4, 0.4, 1}
		im.DrawList_AddRectFilled(dl, im.Vec2{x + 4, origin.y + _HH - 6}, im.Vec2{x + _CW - 4, origin.y + _HH - 2}, im.GetColorU32ImVec4(pkg))

		im.SetCursorScreenPos(im.Vec2{x, origin.y})
		im.InvisibleButton(fmt.ctprintf("##col_%d", e.id), im.Vec2{_CW, _HH}, {.MouseButtonLeft, .MouseButtonRight})
		if im.IsItemClicked(.Left) {
			_rp.sel = e.id
			_rp.scroll_pass = true
		}
		if im.IsItemClicked(.Right) {
			_rp.ctx_id = e.id
			_rp.open_ctx = true
		}
		if im.IsItemHovered() && im.GetDragDropPayload() == nil do widgets.tooltip(fmt.ctprintf("%s", _rp_column_tooltip(c)))
		if im.BeginDragDropSource() {
			id := e.id
			im.SetDragDropPayload(_RP_PAYLOAD, &id, size_of(id))
			im.TextUnformatted(fmt.ctprintf("%s", e.node))
			im.EndDragDropSource()
		}
		if _rp_drop_target(e.slot, c.pos) {
			im.DrawList_AddLine(dl, im.Vec2{x, origin.y + 20}, im.Vec2{x, origin.y + _HH}, im.GetColorU32ImVec4(accent), 3)
		}
	}
}

// A lane's "+" column: the palette for that lane, a drop target that appends.
_rp_plus_column :: proc(s: _Slot, x: f32, origin: im.Vec2) {
	dl := im.GetWindowDrawList()
	slot := s.frame ? "" : _rp.slot
	at := im.Vec2{x, origin.y + _HH - _CW - 4}
	im.SetCursorScreenPos(at)
	if im.InvisibleButton(fmt.ctprintf("##plus_%s", s.frame ? "frame" : "slot"), im.Vec2{_CW, _CW}) do _rp_open_palette(slot, -1)
	hovered := im.IsItemHovered()
	widgets.tooltip(s.frame ? "Add a pass to the frame lane: it runs once per frame, before every slot" : "Add a pass at the end of this slot")
	c := at + im.Vec2{_CW, _CW} * 0.5
	im.DrawList_AddCircleFilled(dl, c, 10, im.GetColorU32(hovered ? im.Col.ButtonHovered : im.Col.Button))
	_rp_plus(dl, c, 5, im.GetColorU32(.Text))
	if _rp_drop_target(slot, -1) do im.DrawList_AddCircle(dl, c, 12, im.GetColorU32(.HeaderActive), 0, 2)
}

// Accepts a dragged pass, inserting it into lane `slot` at lane position
// `index` (-1 = the end). True while a pass that may go there hovers it.
_rp_drop_target :: proc(slot: string, index: int) -> bool {
	if !im.BeginDragDropTarget() do return false
	defer im.EndDragDropTarget()
	payload := im.AcceptDragDropPayload(_RP_PAYLOAD, {.AcceptBeforeDelivery, .AcceptNoDrawDefaultRect})
	if payload == nil || payload.Data == nil do return false
	id := (^i32)(payload.Data)^
	if refusal := _rp_move_check(id, slot); refusal != "" {
		widgets.tooltip_unchecked(fmt.ctprintf("%s", refusal))
		return false
	}
	if payload.Delivery do _rp_move(id, slot, index)
	return true
}

// A row's label: the target's color dot, its name, its format on the right.
_rp_row_label :: proc(dl: ^im.DrawList, r: ^_Resource, at: im.Vec2) {
	cy := at.y + _RH * 0.5
	lh := im.GetTextLineHeight()
	if r.scene {
		im.DrawList_AddRect(dl, im.Vec2{at.x + 6, cy - 4}, im.Vec2{at.x + 14, cy + 4}, im.GetColorU32(.Text, 0.7))
	} else {
		im.DrawList_AddCircleFilled(dl, im.Vec2{at.x + 10, cy}, 4, im.GetColorU32ImVec4(_rp_target_color(r.name)))
	}
	col := r.missing ? im.GetColorU32ImVec4(_RP_DANGER) : im.GetColorU32(.Text)
	name := fmt.ctprintf("%s", r.name)
	im.DrawList_AddText(dl, im.Vec2{at.x + 20, cy - lh * 0.5}, col, name)
	// The format on the right when it fits beside the name, else only in the
	// row's tooltip.
	info := r.scene ? "objects" : (r.has_decl ? _rp_decl_info(r.decl) : "")
	if r.scratch do info = fmt.tprintf("%s, scratch", info)
	if info != "" {
		cinfo := fmt.ctprintf("%s", info)
		w := im.CalcTextSize(cinfo).x
		if 20 + im.CalcTextSize(name).x + 12 + w <= _LW - 8 {
			im.DrawList_AddText(dl, im.Vec2{at.x + _LW - w - 8, cy - lh * 0.5}, im.GetColorU32(.TextDisabled), cinfo)
		}
	}
}

// Write: a square. Read: a circle. Both in place: a square in the third
// color. A read without a writer: a red ring.
_rp_cell_glyph :: proc(dl: ^im.DrawList, cell: _Cell, c: im.Vec2, muted: bool) {
	a := muted ? f32(0.35) : f32(1)
	if cell.unwritten {
		im.DrawList_AddCircle(dl, c, 6, _rp_with_alpha(_RP_DANGER, a), 0, 2)
		return
	}
	switch cell.access {
	case .Write:
		im.DrawList_AddRectFilled(dl, c - im.Vec2{6, 6}, c + im.Vec2{6, 6}, _rp_with_alpha(_RP_OUT, a), 2)
	case .Read:
		im.DrawList_AddCircleFilled(dl, c, 6, _rp_with_alpha(_RP_IN, a))
		if cell.via_final do im.DrawList_AddCircleFilled(dl, c, 2, _rp_with_alpha(im.Vec4{1, 1, 1, 1}, a))
	case .Read_Write:
		im.DrawList_AddRectFilled(dl, c - im.Vec2{6, 6}, c + im.Vec2{6, 6}, _rp_with_alpha(_RP_INOUT, a), 2)
	case .None:
	}
}

// "pass reads resource", the verb in the cell's color, the resource in its
// row's, then a dim note when there is more to say.
_rp_cell_tooltip :: proc(m: ^_Model, r: ^_Resource, ci: int) {
	c := m.cols[ci]
	cell := r.cells[ci]
	verb, note: string
	verb_col := im.GetStyleColorVec4(.TextDisabled)^
	switch cell.access {
	case .Read:
		verb, verb_col = "reads", _RP_IN
		if cell.via_final do note = "as final: the finished image so far"
	case .Write:
		verb, verb_col = "writes", _RP_OUT
	case .Read_Write:
		verb, verb_col = "reads and writes", _RP_INOUT
		note = "in place: it draws over what is there"
	case .None:
		verb = "does not use"
		if r.first >= 0 && ci > r.first && ci < r.last do note = "it stays alive past this pass"
	}
	if cell.unwritten do verb_col = _RP_DANGER
	gap := im.CalcTextSize(" ").x
	im.TextUnformatted(fmt.ctprintf("%s", c.entry.node))
	im.SameLine(0, gap)
	im.TextColoredUnformatted(verb_col, fmt.ctprintf("%s", verb))
	im.SameLine(0, gap)
	im.TextColoredUnformatted(r.scene ? im.GetStyleColorVec4(.Text)^ : _rp_target_color(r.name), fmt.ctprintf("%s", r.name))
	if note != "" do im.TextDisabled("%s", fmt.ctprintf("%s", note))
	if cell.unwritten do im.TextColoredUnformatted(_RP_DANGER, "nothing writes it before this pass")
	if c.entry.muted do im.TextDisabled("muted")
}

_rp_row_tooltip :: proc(m: ^_Model, r: ^_Resource) -> string {
	if r.scene do return "The view's objects, collected before the frame runs. Passes that draw the scene read them."
	b := make([dynamic]string, context.temp_allocator)
	writers, readers: [dynamic]string
	writers.allocator = context.temp_allocator
	readers.allocator = context.temp_allocator
	for cell, ci in r.cells {
		if cell.access == .Write || cell.access == .Read_Write do append(&writers, m.cols[ci].entry.node)
		if cell.access == .Read || cell.access == .Read_Write do append(&readers, m.cols[ci].entry.node)
	}
	append(&b, r.name)
	if r.has_decl do append(&b, _rp_decl_info(r.decl))
	append(&b, fmt.tprintf("written by %s", len(writers) > 0 ? _rp_join(writers[:]) : "nothing"))
	append(&b, fmt.tprintf("read by %s", len(readers) > 0 ? _rp_join(readers[:]) : "nothing"))
	if r.scratch do append(&b, "scratch: only its writer uses it")
	return _rp_join(b[:], "\n")
}

_rp_column_tooltip :: proc(c: _Column) -> string {
	if c.node == nil do return fmt.tprintf("%s is not installed: no linked plugin declares it, so it does not run", c.entry.node)
	kind := c.node.frame ? "per frame" : "per view"
	s := fmt.tprintf("%s\n%s\n%s, %s", c.entry.node, c.node.summary, c.node.pkg, kind)
	if c.entry.muted do s = fmt.tprintf("%s\nmuted", s)
	return fmt.tprintf("%s\nDrag to reorder. Right-click for more.", s)
}

// A resource's lifetime, from its first pass to its last.
_rp_lifetime_bar :: proc(dl: ^im.DrawList, x0, x1, y: f32) {
	im.DrawList_AddLine(dl, im.Vec2{x0, y}, im.Vec2{x1, y}, im.GetColorU32(.Text, 0.3), 3)
}

// Text drawn at `pivot` and turned by `degrees` around it: the glyphs'
// vertices are rotated after they are added.
_rp_text_rotated :: proc(dl: ^im.DrawList, pivot: im.Vec2, col: u32, text: cstring, degrees: f32) {
	start := dl.VtxBuffer.Size
	im.DrawList_AddText(dl, pivot, col, text)
	verts := ([^]im.DrawVert)(dl.VtxBuffer.Data)
	rad := math.to_radians(degrees)
	s, c := math.sin(rad), math.cos(rad)
	for i in start ..< dl.VtxBuffer.Size {
		p := verts[i].pos - pivot
		verts[i].pos = pivot + im.Vec2{p.x * c - p.y * s, p.x * s + p.y * c}
	}
}

_rp_plus :: proc(dl: ^im.DrawList, c: im.Vec2, r: f32, col: u32) {
	im.DrawList_AddLine(dl, c - im.Vec2{r, 0}, c + im.Vec2{r, 0}, col, 1.5)
	im.DrawList_AddLine(dl, c - im.Vec2{0, r}, c + im.Vec2{0, r}, col, 1.5)
}

_rp_join :: proc(parts: []string, sep := ", ") -> string {
	b := make([dynamic]u8, context.temp_allocator)
	for p, i in parts {
		if i > 0 do append(&b, ..transmute([]u8)sep)
		append(&b, ..transmute([]u8)p)
	}
	return string(b[:])
}

