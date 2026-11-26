package mhgui

// ScrollRect: scrolls a content node inside a viewport. The viewport is this
// node, or the node `viewport` names, and usually carries a UiMask so the
// content shows inside it only. The content is a node under the viewport,
// larger than it along the axes that scroll.
//
// It takes the pointer events of its node like any other component
// (the engine pointer package):
// - A drag along an axis it scrolls is its own: it uses Drag_Begin, so a
//   Button under the pointer gets Cancel and does not click. A drag along an
//   axis it does not scroll is left unused, and reaches the ScrollRect or
//   whatever else is above it: a list that scrolls across inside one that
//   scrolls up and down.
// - The wheel scrolls it. At an end the wheel is left unused and scrolls the
//   ScrollRect around it.
// - A press stops the content where it is.
//
// After the drag the content keeps moving and slows down (`inertia`). With
// Elastic movement it can be pulled past an end and comes back, with Clamped
// it stops at the ends.

import "core:math"
import "core:math/linalg"
import "moonhug:packages/engine"
import pointer "moonhug:packages/engine/pointer"
import "moonhug:libs/input"
import "moonhug:libs/time"

Scroll_Movement :: enum u8 {
	Elastic,      // past an end it stretches, and comes back when let go
	Clamped,      // it stops at the ends
	Unrestricted, // no ends
}

@(component={menu="UI/ScrollRect", icon="SWIPE_VERTICAL"})
@(typ_guid={guid = "50a4a56d-c4e2-4cf1-bc7f-0d86f52eb9c8"})
ScrollRect :: struct {
	using base:   engine.CompData `inspect:"-"`,
	content:      engine.Ref_Local `ref:"Transform" decor:tooltip(desc="The node that moves: what is scrolled.")`,
	viewport:     engine.Ref_Local `ref:"Transform" decor:tooltip(desc="The node the content shows in. Empty is this node.")`,
	horizontal:   bool,
	vertical:     bool,
	movement:     Scroll_Movement,
	elasticity:   f32 `decor:min(0) decor:tooltip(desc="Seconds the content takes to come back from past an end, with Elastic movement.")`,
	inertia:      bool `decor:tooltip(desc="After a drag the content keeps moving and slows down.")`,
	deceleration_rate: f32 `decor:range(0, 1) decor:tooltip(desc="The share of its speed the content keeps each second, with inertia. 0 stops at once.")`,
	scroll_sensitivity: f32 `decor:tooltip(desc="Canvas units one notch of the wheel scrolls.")`,
	horizontal_scrollbar: engine.Ref_Local `ref:"Transform" decor:tooltip(desc="The node with the Scrollbar that shows and sets the place across.")`,
	vertical_scrollbar:   engine.Ref_Local `ref:"Transform" decor:tooltip(desc="The node with the Scrollbar that shows and sets the place up and down.")`,
	// Runtime state, never saved.
	velocity: [2]f32 `json:"-" inspect:"-"`, // canvas units a second, in the viewport's space
	dragging: bool   `json:"-" inspect:"-"`,
}

type_reset_ScrollRect :: proc(s: ^ScrollRect) {
	s.horizontal = false
	s.vertical = true
	s.movement = .Elastic
	s.elasticity = 0.1
	s.inertia = true
	s.deceleration_rate = 0.135
	s.scroll_sensitivity = 40
}

// The viewport's rect and the content's box in the viewport's own space, and
// what turns a move in that space into a move of the content's anchored
// position (its parent's space).
Scroll_Geometry :: struct {
	view_min, view_max:       [2]f32,
	content_min, content_max: [2]f32,
	to_parent:                matrix[4, 4]f32,
	content_rt:               ^engine.RectTransform,
}

// The ScrollRect's geometry now. False without a content node with a
// RectTransform under a canvas.
scroll_rect_geometry :: proc(s: ^ScrollRect) -> (g: Scroll_Geometry, ok: bool) {
	content_tH := engine.Transform_Handle(s.content.handle)
	if content_tH == {} do return
	view_tH := engine.Transform_Handle(s.viewport.handle)
	if view_tH == {} do view_tH = s.owner
	canvas := engine.canvas_of(content_tH)
	if canvas == {} do return
	_, g.content_rt = engine.transform_get_comp(content_tH, engine.RectTransform)
	if g.content_rt == nil do return
	w := engine.ctx_world()
	ct := engine.pool_get(&w.transforms, engine.Handle(content_tH))
	if ct == nil do return
	parent_tH := engine.Transform_Handle(ct.parent.handle)

	root, _, _ := engine.canvas_placement(canvas, input.viewport_size())
	nodes := make([dynamic]engine.Node_Rect, context.temp_allocator)
	engine.canvas_resolve_rects(canvas, root, &nodes)
	view, content, parent: engine.Node_Rect
	has_view, has_content, has_parent: bool
	for n in nodes {
		if n.tH == view_tH do view, has_view = n, true
		if n.tH == content_tH do content, has_content = n, true
		if n.tH == parent_tH do parent, has_parent = n, true
	}
	if !has_view || !has_content do return
	g.view_min, g.view_max = view.rect.pos, view.rect.pos + view.rect.size
	inv_view := linalg.inverse(view.xform)
	first := true
	for c in engine.rect_corners(content.rect, inv_view * content.xform) {
		if first {
			g.content_min, g.content_max = c.xy, c.xy
			first = false
		}
		g.content_min = {min(g.content_min.x, c.x), min(g.content_min.y, c.y)}
		g.content_max = {max(g.content_max.x, c.x), max(g.content_max.y, c.y)}
	}
	g.to_parent = linalg.inverse(parent.xform) * view.xform if has_parent else 1
	return g, true
}

// How far the content has to move, in the viewport's space, to be inside its
// ends on the axes that scroll: {} when it is. Content larger than the
// viewport covers it. Content smaller sits at its start: the left, the top.
scroll_rect_offset :: proc(s: ^ScrollRect, g: Scroll_Geometry) -> (off: [2]f32) {
	if s.movement == .Unrestricted do return
	view := g.view_max - g.view_min
	size := g.content_max - g.content_min
	if s.horizontal {
		if size.x <= view.x {
			off.x = g.view_min.x - g.content_min.x
		} else if g.content_min.x > g.view_min.x {
			off.x = g.view_min.x - g.content_min.x
		} else if g.content_max.x < g.view_max.x {
			off.x = g.view_max.x - g.content_max.x
		}
	}
	if s.vertical {
		if size.y <= view.y {
			off.y = g.view_max.y - g.content_max.y
		} else if g.content_max.y < g.view_max.y {
			off.y = g.view_max.y - g.content_max.y
		} else if g.content_min.y > g.view_min.y {
			off.y = g.view_min.y - g.content_min.y
		}
	}
	return
}

// Moves the content by `d`, a move in the viewport's space.
@(private = "file")
_scroll_move :: proc(g: Scroll_Geometry, d: [2]f32) {
	if d == {} do return
	p := engine.rect_apply_dir(g.to_parent, d)
	g.content_rt.anchored_position.x += p.x
	g.content_rt.anchored_position.y += p.y
}

// Whether the content can move along each axis: the axis scrolls and the
// content is larger than the viewport there (or the movement has no ends).
scroll_rect_can_scroll :: proc(s: ^ScrollRect, g: Scroll_Geometry) -> [2]bool {
	view := g.view_max - g.view_min
	size := g.content_max - g.content_min
	free := s.movement == .Unrestricted
	return {s.horizontal && (free || size.x > view.x + 0.01), s.vertical && (free || size.y > view.y + 0.01)}
}

// Where the content is between its ends, 0 to 1 on each axis: x 0 shows its
// left, y 1 shows its top. An axis with nothing to scroll is 0 across and 1
// up and down.
scroll_rect_normalized :: proc(s: ^ScrollRect) -> [2]f32 {
	g, ok := scroll_rect_geometry(s)
	if !ok do return {0, 1}
	view := g.view_max - g.view_min
	size := g.content_max - g.content_min
	n := [2]f32{0, 1}
	if size.x > view.x do n.x = clamp((g.view_min.x - g.content_min.x) / (size.x - view.x), 0, 1)
	if size.y > view.y do n.y = clamp((g.view_min.y - g.content_min.y) / (size.y - view.y), 0, 1)
	return n
}

// Puts the content at `n` between its ends (scroll_rect_normalized), and
// stops it there.
scroll_rect_set_normalized :: proc(s: ^ScrollRect, n: [2]f32) {
	g, ok := scroll_rect_geometry(s)
	if !ok do return
	view := g.view_max - g.view_min
	size := g.content_max - g.content_min
	d: [2]f32
	if s.horizontal && size.x > view.x do d.x = (g.view_min.x - clamp(n.x, 0, 1) * (size.x - view.x)) - g.content_min.x
	if s.vertical && size.y > view.y do d.y = (g.view_min.y - clamp(n.y, 0, 1) * (size.y - view.y)) - g.content_min.y
	_scroll_move(g, d)
	s.velocity = {}
}

// Scrolls as little as it takes to bring `node`, a node under the content,
// fully into the viewport, and stops there. A node larger than the viewport
// shows its start.
scroll_rect_show :: proc(s: ^ScrollRect, node: engine.Transform_Handle) {
	g, ok := scroll_rect_geometry(s)
	if !ok do return
	view_tH := engine.Transform_Handle(s.viewport.handle)
	if view_tH == {} do view_tH = s.owner
	canvas := engine.canvas_of(node)
	if canvas == {} do return
	root, _, _ := engine.canvas_placement(canvas, input.viewport_size())
	nodes := make([dynamic]engine.Node_Rect, context.temp_allocator)
	engine.canvas_resolve_rects(canvas, root, &nodes)
	view, target: engine.Node_Rect
	found := 0
	for n in nodes {
		if n.tH == view_tH { view = n; found += 1 }
		if n.tH == node { target = n; found += 1 }
	}
	if found < 2 do return
	lo, hi: [2]f32
	for c, k in engine.rect_corners(target.rect, linalg.inverse(view.xform) * target.xform) {
		if k == 0 do lo, hi = c.xy, c.xy
		lo = {min(lo.x, c.x), min(lo.y, c.y)}
		hi = {max(hi.x, c.x), max(hi.y, c.y)}
	}
	d: [2]f32
	if s.horizontal {
		if lo.x < g.view_min.x || hi.x - lo.x > g.view_max.x - g.view_min.x do d.x = g.view_min.x - lo.x
		else if hi.x > g.view_max.x do d.x = g.view_max.x - hi.x
	}
	if s.vertical {
		if hi.y > g.view_max.y || hi.y - lo.y > g.view_max.y - g.view_min.y do d.y = g.view_max.y - hi.y
		else if lo.y < g.view_min.y do d.y = g.view_min.y - lo.y
	}
	_scroll_move(g, d)
	s.velocity = {}
	// Not past an end.
	if g2, ok2 := scroll_rect_geometry(s); ok2 do _scroll_move(g2, scroll_rect_offset(s, g2))
}

@(comp_on_pointer={component=ScrollRect})
comp_on_pointer_ScrollRect :: proc(s: ^ScrollRect, ev: ^pointer.Pointer_Event) {
	#partial switch ev.kind {
	case .Down:
		// A press holds the content still. Not used: what is under the
		// pointer still gets its press.
		s.velocity = {}
	case .Drag_Begin:
		if ev.button != .Left do return
		g, ok := scroll_rect_geometry(s)
		if !ok do return
		can := scroll_rect_can_scroll(s, g)
		d := pointer.canvas_delta(ev)
		// Its own when the drag runs along an axis it scrolls.
		across := abs(d.x) >= abs(d.y)
		if !((across && can.x) || (!across && can.y) || (can.x && can.y)) do return
		s.dragging = true
		s.velocity = {}
		ev.used = true
	case .Drag:
		g, ok := scroll_rect_geometry(s)
		if !ok do return
		view_tH := engine.Transform_Handle(s.viewport.handle)
		if view_tH == {} do view_tH = s.owner
		d := _to_view(view_tH, pointer.canvas_delta(ev))
		if !s.horizontal do d.x = 0
		if !s.vertical do d.y = 0
		// Past an end Elastic gives way less and less: the pointer's move
		// counts for less the further past the content already is.
		if s.movement == .Elastic {
			over := -scroll_rect_offset(s, g)
			view := g.view_max - g.view_min
			if over.x != 0 && view.x > 0 do d.x *= clamp(1 - abs(over.x) / view.x, 0, 1) * 0.5
			if over.y != 0 && view.y > 0 do d.y *= clamp(1 - abs(over.y) / view.y, 0, 1) * 0.5
		}
		_scroll_move(g, d)
		// Clamped stops at the end.
		if s.movement == .Clamped {
			if g2, ok2 := scroll_rect_geometry(s); ok2 do _scroll_move(g2, scroll_rect_offset(s, g2))
		}
		// The speed the content has when let go: this frame's, smoothed.
		dt := time.delta_time(.Unscaled)
		if dt <= 0 do dt = 1.0 / 60
		s.velocity = linalg.lerp(s.velocity, d / dt, f32(min(dt * 10, 1)))
	case .Drag_End, .Cancel:
		s.dragging = false
	case .Scroll:
		g, ok := scroll_rect_geometry(s)
		if !ok do return
		can := scroll_rect_can_scroll(s, g)
		d: [2]f32
		// The wheel up shows what is above: the content moves down. A list
		// that scrolls across only takes the wheel too, unless a ScrollRect
		// above it scrolls up and down: then the wheel is that one's.
		if can.y {
			d.y = -ev.scroll.y * s.scroll_sensitivity
		} else if can.x && !_scrolls_vertically_above(s.owner) {
			d.x = ev.scroll.y * s.scroll_sensitivity
		}
		d.x += -ev.scroll.x * s.scroll_sensitivity if can.x else 0
		if d == {} do return
		before := g.content_rt.anchored_position
		_scroll_move(g, d)
		if g2, ok2 := scroll_rect_geometry(s); ok2 do _scroll_move(g2, scroll_rect_offset(s, g2))
		// At an end nothing moved: the wheel goes on to what is above.
		if linalg.length(g.content_rt.anchored_position.xy - before.xy) > 0.01 {
			s.velocity = {}
			ev.used = true
		}
	}
}

// Whether a ScrollRect above the node scrolls up and down.
@(private = "file")
_scrolls_vertically_above :: proc(node: engine.Transform_Handle) -> bool {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(node))
	for n := 0; t != nil && n < 4096; n += 1 {
		parent := engine.Transform_Handle(t.parent.handle)
		if parent == {} do return false
		if _, above := engine.transform_get_comp(parent, ScrollRect); above != nil && above.enabled && above.vertical do return true
		t = engine.pool_get(&w.transforms, engine.Handle(parent))
	}
	return false
}

// A canvas-space direction in a node's own space.
@(private = "file")
_to_view :: proc(view_tH: engine.Transform_Handle, canvas_dir: [2]f32) -> [2]f32 {
	canvas := engine.canvas_of(view_tH)
	if canvas == {} do return canvas_dir
	root, _, _ := engine.canvas_placement(canvas, input.viewport_size())
	nodes := make([dynamic]engine.Node_Rect, context.temp_allocator)
	engine.canvas_resolve_rects(canvas, root, &nodes)
	for n in nodes do if n.tH == view_tH do return engine.rect_apply_dir(linalg.inverse(n.xform), canvas_dir)
	return canvas_dir
}

// Every ScrollRect after the pointer pass: the content coasts and slows down,
// comes back from past an end, and the scrollbars follow it or lead it.
@(update={order=-90})
scroll_tick :: proc(dt_game: f32) {
	dt := time.delta_time(.Unscaled) // a menu scrolls while the game's time is held
	w := engine.ctx_world()
	it := engine.pool_iterator(scroll_rects(w))
	for s, _ in engine.pool_next(&it) {
		if !s.enabled || !engine.transform_active_in_hierarchy(s.owner) do continue
		scroll_rect_step(s, dt)
	}
}

// One ScrollRect's step of `dt` seconds (scroll_tick).
scroll_rect_step :: proc(s: ^ScrollRect, dt: f32) {
	{
		_scrollbars_lead(s)
		g, ok := scroll_rect_geometry(s)
		if !ok do return
		if !s.dragging && dt > 0 {
			off := scroll_rect_offset(s, g)
			move: [2]f32
			for axis in 0 ..< 2 {
				if off[axis] != 0 && s.movement == .Elastic {
					// Back from past the end: most of the way in `elasticity` seconds.
					k := 1 - math.exp(-dt / max(s.elasticity, 0.001) * 3)
					move[axis] = off[axis] * k if abs(off[axis]) > 0.05 else off[axis]
					s.velocity[axis] = 0
				} else if off[axis] != 0 {
					move[axis] = off[axis]
					s.velocity[axis] = 0
				} else if s.inertia && s.velocity[axis] != 0 {
					s.velocity[axis] *= math.pow(clamp(s.deceleration_rate, 0, 1), dt)
					if abs(s.velocity[axis]) < 1 do s.velocity[axis] = 0
					move[axis] = s.velocity[axis] * dt
				} else {
					s.velocity[axis] = 0
				}
			}
			_scroll_move(g, move)
			// Coasting with Clamped movement stops at the end.
			if s.movement == .Clamped {
				if g2, ok2 := scroll_rect_geometry(s); ok2 {
					off2 := scroll_rect_offset(s, g2)
					if off2 != {} {
						_scroll_move(g2, off2)
						if off2.x != 0 do s.velocity.x = 0
						if off2.y != 0 do s.velocity.y = 0
					}
				}
			}
		}
		_scrollbars_follow(s)
	}
}

// A scrollbar the pointer moved sets the place of the content.
@(private = "file")
_scrollbars_lead :: proc(s: ^ScrollRect) {
	n := scroll_rect_normalized(s)
	changed := false
	if _, bar := engine.transform_get_comp(engine.Transform_Handle(s.horizontal_scrollbar.handle), Scrollbar); bar != nil && bar.changed {
		n.x = bar.value
		bar.changed = false
		changed = true
	}
	if _, bar := engine.transform_get_comp(engine.Transform_Handle(s.vertical_scrollbar.handle), Scrollbar); bar != nil && bar.changed {
		n.y = bar.value
		bar.changed = false
		changed = true
	}
	if changed do scroll_rect_set_normalized(s, n)
}

// The scrollbars show where the content is and how much of it shows.
@(private = "file")
_scrollbars_follow :: proc(s: ^ScrollRect) {
	g, ok := scroll_rect_geometry(s)
	if !ok do return
	n := scroll_rect_normalized(s)
	view := g.view_max - g.view_min
	size := g.content_max - g.content_min
	if _, bar := engine.transform_get_comp(engine.Transform_Handle(s.horizontal_scrollbar.handle), Scrollbar); bar != nil && !bar.dragging {
		scrollbar_set(bar, n.x, view.x / size.x if size.x > view.x else 1)
	}
	if _, bar := engine.transform_get_comp(engine.Transform_Handle(s.vertical_scrollbar.handle), Scrollbar); bar != nil && !bar.dragging {
		scrollbar_set(bar, n.y, view.y / size.y if size.y > view.y else 1)
	}
}
