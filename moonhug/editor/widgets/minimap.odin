package widgets

// The mini-map of a pannable canvas: the whole content scaled down in a corner,
// with the visible area outlined. A click or a drag on it goes there. Every
// window with a canvas draws the same one: the Workspace window and the node
// canvas (moonhug:editor/node_canvas), so Shader Graph, Playable Graph and
// Tween Graph.
//
// - The caller owns two values: `Minimap`, what to save (shown, where, how
//   big), and `Minimap_State`, the drag in progress.
// - Content is a list of rects in canvas units. `view_min` and `view_max` are
//   the visible area in the same units.
// - It answers with the canvas point to centre the view on when the user
//   clicked or dragged in it. The caller turns that into its own pan.
// - Ctrl (Cmd on macOS) and a drag moves the map, a corner drag resizes it.
// - Draw it after the canvas content: a child submitted later takes the mouse
//   first.

import im "moonhug:external/odin-imgui"

// What a mini-map saves: attached to a corner or a side of the canvas, moved
// from there by `offset`, at `size` (0 is the default size).
Minimap :: struct {
	hidden: bool,
	anchor: Minimap_Anchor,
	offset: [2]f32,
	size:   [2]f32,
}

Minimap_Anchor :: enum {
	Top_Right,
	Top,
	Top_Left,
	Left,
	Bottom_Left,
	Bottom,
	Bottom_Right,
	Right,
}

// The drag in progress on a mini-map. Zero is no drag.
Minimap_State :: struct {
	drag:       enum {None, Pan, Move, Resize},
	drag_from:  [2]f32,        // mouse at the press
	drag_start: [2]f32,        // the map's offset at the press of a move
	corner:     [2]f32,        // the corner a resize drags: -1 the left or top, 1 the right or bottom
	start:      [4]f32,        // the map's rect at the press of a resize
	frozen:     Minimap_Scale, // the scale while a drag in it pans, so it holds still
	grab:       [2]f32,        // that drag: the canvas point under the mouse, from the visible area's centre
}

// Canvas to mini-map: screen = body + base + (p - min) * scale.
Minimap_Scale :: struct {
	min:   [2]f32,
	scale: f32,
	base:  [2]f32,
}

// One thing on the canvas, in canvas units: x, y, width, height.
Minimap_Item :: struct {
	rect:      [4]f32,
	highlight: bool, // drawn lit: the focused frame, the selected node
	color:     [4]f32, // zero: the button colour
}

MINIMAP_SIZE :: [2]f32{220, 150}
MINIMAP_MIN :: [2]f32{100, 70}
MINIMAP_MARGIN :: f32(10)
// The key held to move the mini-map instead of panning.
MINIMAP_MOVE_KEY :: "Cmd" when ODIN_OS == .Darwin else "Ctrl"
@(private = "file") _PAD :: f32(24) // canvas units around the content
@(private = "file") _CORNER :: f32(10) // the resize zone in each corner

minimap_to_screen :: proc(s: Minimap_Scale, body_min: im.Vec2, p: [2]f32) -> im.Vec2 {
	return body_min + s.base + (p - s.min) * s.scale
}

minimap_to_canvas :: proc(s: Minimap_Scale, body_min: im.Vec2, p: im.Vec2) -> [2]f32 {
	return (p - body_min - s.base) / s.scale + s.min
}

// The map's rect inside the canvas `canvas` big, false while it is hidden.
// A caller keeps the mouse from the content under it with this.
minimap_rect :: proc(m: ^Minimap, canvas: [2]f32) -> (pos, size: [2]f32, shown: bool) {
	if m.hidden do return
	base: [2]f32
	base, size = _place(m, canvas)
	return _clamp(base + m.offset, size, canvas), size, true
}

// Draws the map over the canvas at `origin` (screen) `canvas` big. `extra`
// draws more over the content, such as links, with the map's scale. Answers
// the canvas point to centre the view on when the user clicked or dragged in
// the map, and `released` on the frame such a drag ends.
minimap :: proc(
	id: cstring,
	m: ^Minimap,
	st: ^Minimap_State,
	origin, canvas: im.Vec2,
	items: []Minimap_Item,
	view_min, view_max: [2]f32,
	extra: proc(dl: ^im.DrawList, s: Minimap_Scale, body_min: im.Vec2, user: rawptr) = nil,
	user: rawptr = nil,
) -> (centre: [2]f32, go: bool, released: bool) {
	if m.hidden do return
	base, size := _place(m, canvas)
	pos := _clamp(base + m.offset, size, canvas)

	im.SetCursorScreenPos(origin + pos)
	im.PushStyleVarImVec2(.WindowPadding, {0, 0})
	visible := im.BeginChild(id, size, {}, {.NoScrollbar, .NoScrollWithMouse, .NoSavedSettings})
	im.PopStyleVar()
	defer im.EndChild()
	if !visible do return
	dl := im.GetWindowDrawList()
	cmin := im.GetWindowPos()
	mouse := im.GetMousePos()
	// The panel of a Scene window overlay: see-through, rounded, outlined.
	bg := im.GetStyleColorVec4(.WindowBg)^
	bg.w = 0.85
	im.DrawList_AddRectFilled(dl, cmin, cmin + size, im.GetColorU32ImVec4(bg), 4)
	im.DrawList_AddRect(dl, cmin, cmin + size, im.GetColorU32(.Border), 4)

	// Ctrl or Cmd held over the map: a drag anywhere on it moves it. On macOS
	// imgui turns a click with the physical Ctrl key into a right click, so
	// with the key held the map takes either button.
	moving := im.GetIO().KeyCtrl || im.GetIO().KeySuper
	if st.drag == .Move || (moving && st.drag == .None && im.IsWindowHovered({})) do im.SetMouseCursor(.ResizeAll)

	// Every corner resizes it, and the opposite corner stays put. First, so a
	// corner wins over the body where they meet.
	c := _CORNER
	for corner, ci in ([4][2]f32{{-1, -1}, {1, -1}, {-1, 1}, {1, 1}}) {
		im.SetCursorScreenPos(cmin + {0 if corner.x < 0 else size.x - c, 0 if corner.y < 0 else size.y - c})
		im.PushIDInt(i32(ci))
		im.InvisibleButton("##resize", {c, c}, {.MouseButtonLeft, .MouseButtonRight})
		im.PopID()
		if !moving && (im.IsItemHovered() || im.IsItemActive()) do im.SetMouseCursor(.ResizeNWSE if corner.x == corner.y else .ResizeNESW)
		if im.IsItemActivated() && (moving || im.IsMouseClicked(.Left)) {
			st.drag = .Move if moving else .Resize
			st.drag_from = mouse
			st.drag_start = m.offset
			st.corner = corner
			st.start = {pos.x, pos.y, size.x, size.y}
		}
		if st.drag == .Resize && st.corner == corner {
			if im.IsItemActive() {
				_resize(m, st, mouse, canvas)
			} else {
				st.drag = .None
			}
		}
	}

	// The body: the content and the visible area, scaled to fit. A click or a
	// drag goes there. Grabbing the visible area keeps the grab point.
	body := size
	sc := st.frozen
	if st.drag != .Pan {
		lo, hi := view_min, view_max
		for it in items {
			lo = {min(lo.x, it.rect.x), min(lo.y, it.rect.y)}
			hi = {max(hi.x, it.rect.x + it.rect.z), max(hi.y, it.rect.y + it.rect.w)}
		}
		lo -= _PAD
		hi += _PAD
		inner := body - 8
		sc.min = lo
		sc.scale = max(min(inner.x / (hi.x - lo.x), inner.y / (hi.y - lo.y)), 0.0001)
		sc.base = (body - (hi - lo) * sc.scale) * 0.5
	}
	im.SetCursorScreenPos(cmin)
	im.InvisibleButton("##body", {max(body.x, 1), max(body.y, 1)}, {.MouseButtonLeft, .MouseButtonRight})
	if im.IsItemActivated() && moving {
		st.drag = .Move
		st.drag_from = mouse
		st.drag_start = m.offset
	} else if im.IsItemActivated() && im.IsMouseClicked(.Left) {
		st.drag = .Pan
		st.frozen = sc
		p := minimap_to_canvas(sc, cmin, mouse)
		inside := p.x >= view_min.x && p.y >= view_min.y && p.x <= view_max.x && p.y <= view_max.y
		st.grab = p - (view_min + view_max) * 0.5 if inside else {}
	}
	vmin, vmax := view_min, view_max
	if st.drag == .Pan {
		if im.IsItemActive() {
			centre = minimap_to_canvas(sc, cmin, mouse) - st.grab
			go = true
			half := (view_max - view_min) * 0.5
			vmin, vmax = centre - half, centre + half
		} else {
			st.drag = .None
			released = true
		}
	}
	tooltip("Click or drag to go there. Hold " + MINIMAP_MOVE_KEY + " to move the mini-map.")

	// A move, from the body or a corner pressed with Ctrl or Cmd held, goes
	// on until the button is released.
	if st.drag == .Move {
		if im.IsMouseDown(.Left) || im.IsMouseDown(.Right) {
			m.offset = _clamp(base + st.drag_start + (mouse - st.drag_from), size, canvas) - base
		} else {
			st.drag = .None
		}
	}

	im.PushClipRect(cmin, cmin + body, true)
	defer im.PopClipRect()
	for it in items {
		a := minimap_to_screen(sc, cmin, {it.rect.x, it.rect.y})
		b := minimap_to_screen(sc, cmin, {it.rect.x + it.rect.z, it.rect.y + it.rect.w})
		b = {max(b.x, a.x + 2), max(b.y, a.y + 2)}
		fill := im.GetColorU32(.ButtonActive if it.highlight else .Button)
		if it.color.w > 0 {
			col := it.color
			if !it.highlight do col.w *= 0.7
			fill = im.GetColorU32ImVec4(col)
		}
		im.DrawList_AddRectFilled(dl, a, b, fill)
		im.DrawList_AddRect(dl, a, b, im.GetColorU32(.Text if it.highlight else .Border))
	}
	if extra != nil do extra(dl, sc, cmin, user)
	va := minimap_to_screen(sc, cmin, vmin)
	vb := minimap_to_screen(sc, cmin, vmax)
	im.DrawList_AddRectFilled(dl, va, vb, im.GetColorU32(.Text, 0.06))
	im.DrawList_AddRect(dl, va, vb, im.GetColorU32(.Text, 0.8), 0, 1.5)
	return
}

// The items of a "Mini-map" menu: show it, attach it to a corner or a side,
// or reset its place and size. The caller opens the menu.
minimap_menu :: proc(m: ^Minimap) {
	if im.MenuItem("Show", nil, !m.hidden) {
		m.hidden = !m.hidden
	}
	if im.BeginMenu("Attach To") {
		for a in _ANCHORS {
			if a.anchor == .Left || a.anchor == .Bottom_Left do im.Separator()
			if im.MenuItem(a.label, nil, m.anchor == a.anchor) {
				m.anchor = a.anchor
				m.offset = {}
				m.hidden = false
			}
		}
		im.EndMenu()
	}
	im.Separator()
	if im.MenuItem("Reset") {
		m^ = {}
	}
	tooltip("Shown, at the top right, at its default size")
}

@(private = "file")
_ANCHORS := [?]struct {
	anchor: Minimap_Anchor,
	label:  cstring,
}{
	{.Top_Left, "Top Left"}, {.Top, "Top"}, {.Top_Right, "Top Right"},
	{.Left, "Left"}, {.Right, "Right"},
	{.Bottom_Left, "Bottom Left"}, {.Bottom, "Bottom"}, {.Bottom_Right, "Bottom Right"},
}

// Where an anchor sits on each axis: 0 the start, 0.5 the middle, 1 the end.
@(private = "file")
_anchor_t :: proc(a: Minimap_Anchor) -> [2]f32 {
	switch a {
	case .Top_Left:     return {0, 0}
	case .Top:          return {0.5, 0}
	case .Top_Right:    return {1, 0}
	case .Left:         return {0, 0.5}
	case .Right:        return {1, 0.5}
	case .Bottom_Left:  return {0, 1}
	case .Bottom:       return {0.5, 1}
	case .Bottom_Right: return {1, 1}
	}
	return {1, 0}
}

// The map's size and its position from the anchor before its offset.
@(private = "file")
_place :: proc(m: ^Minimap, canvas: [2]f32) -> (base, size: [2]f32) {
	avail := canvas - 2 * MINIMAP_MARGIN
	size = m.size if m.size.x > 0 && m.size.y > 0 else MINIMAP_SIZE
	size.x = clamp(size.x, MINIMAP_MIN.x, max(avail.x, MINIMAP_MIN.x))
	size.y = clamp(size.y, MINIMAP_MIN.y, max(avail.y, MINIMAP_MIN.y))
	base = MINIMAP_MARGIN + (avail - size) * _anchor_t(m.anchor)
	return
}

// Kept inside the canvas.
@(private = "file")
_clamp :: proc(pos, size, canvas: [2]f32) -> [2]f32 {
	return {clamp(pos.x, 0, max(canvas.x - size.x, 0)), clamp(pos.y, 0, max(canvas.y - size.y, 0))}
}

// A corner drag: the dragged corner follows the mouse and the opposite one
// stays, which sets a new size and the offset that keeps the map there.
@(private = "file")
_resize :: proc(m: ^Minimap, st: ^Minimap_State, mouse: im.Vec2, canvas: [2]f32) {
	lo := [2]f32{st.start.x, st.start.y}
	hi := lo + [2]f32{st.start.z, st.start.w}
	d := mouse - st.drag_from
	least := MINIMAP_MIN
	most := [2]f32{max(canvas.x - 2 * MINIMAP_MARGIN, least.x), max(canvas.y - 2 * MINIMAP_MARGIN, least.y)}
	for k in 0 ..< 2 {
		if st.corner[k] < 0 {
			lo[k] = max(clamp(lo[k] + d[k], hi[k] - most[k], hi[k] - least[k]), 0)
		} else {
			hi[k] = min(clamp(hi[k] + d[k], lo[k] + least[k], lo[k] + most[k]), canvas[k])
		}
	}
	m.size = hi - lo
	base, _ := _place(m, canvas)
	m.offset = lo - base
}
