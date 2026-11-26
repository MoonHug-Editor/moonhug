package mhgui

// What the pointer hits: the engine.canvases that take it (GraphicRaycaster), the
// nodes that take it (a graphic with raycast_target, or a HitArea), the test
// a graphic may add to its rect (@(canvas_hit)), and the raycast itself. The
// pointer pass that sends events from it is the engine's pointer package
// (plugins/engine/pointer), where this plugin registers the raycast.

import "core:math/linalg"
import "core:slice"
import "moonhug:packages/engine"
import pointer "moonhug:packages/engine/pointer"

// Makes a canvas receive pointer events: the pointer pass (canvas_raycast)
// only looks at engine.canvases carrying one. GameObject > UI > engine.Canvas adds it.
@(component={menu="UI/GraphicRaycaster", icon="ADS_CLICK"})
@(typ_guid={guid = "b625f6b5-e1fd-4590-9757-ffa073e23bef"})
GraphicRaycaster :: struct {
	using base:               engine.CompData `inspect:"-"`,
	ignore_reversed_graphics: bool, // a graphic whose rect faces away from the viewer (flipped by a transform) is not hit
}

type_reset_GraphicRaycaster :: proc(r: ^GraphicRaycaster) {
	r.ignore_reversed_graphics = true
}

// A node the pointer can hit that draws nothing: its rect takes pointer
// events as a graphic with raycast_target does. For an
// invisible button over a picture, a drag surface, or a larger touch area
// around a small icon. It needs no engine.CanvasRenderer.
@(component={menu="UI/HitArea", icon="TOUCH_APP"})
@(typ_guid={guid = "1b81a833-e1e0-4857-bb17-eea53665ee29"})
HitArea :: struct {
	using base: engine.CompData `inspect:"-"`,
}

// Whether the pointer can hit the node: an enabled HitArea, or a drawn
// graphic with raycast_target on.
node_takes_pointer :: proc(tH: engine.Transform_Handle) -> bool {
	takes := false
	if _, area := engine.transform_get_comp(tH, HitArea); area != nil && area.enabled {
		takes = true
	} else if _, cr := engine.transform_get_comp(tH, engine.CanvasRenderer); cr != nil && cr.enabled {
		_, g, _, ok := engine.node_graphic(tH)
		takes = ok && g.raycast_target
	}
	// A CanvasGroup above it may let the pointer through.
	return takes && engine.canvas_group_state(tH).blocks_raycasts
}

// Whether the pointer at `point`, in the node's space and inside its rect,
// hits what the component draws there: a shape's outline, an image's
// opaque part.
Canvas_Hit_Proc :: proc(comp: rawptr, rect: engine.Rect, point: [2]f32) -> bool

// Declares `canvas_hit_<T>`, the proc that says whether a point of the
// node's rect hits a component of type T. T is a @(component) of the same
// package and the proc takes a ^T, the node's rect and the point. A type
// has at most one. A node with none is hit anywhere in its rect.
@(extension_point={attribute="canvas_hit", target="proc", fields=""})
canvas_hit_procs: [engine.TypeKey]Canvas_Hit_Proc

@(private = "file")
_canvas_hits_any: bool

canvas_hit_register :: proc(key: engine.TypeKey, fn: Canvas_Hit_Proc) {
	canvas_hit_procs[key] = fn
	_canvas_hits_any = true
}

// Whether a point of a node's rect hits the node: every enabled component
// on it that has a hit proc says so.
node_hit :: proc(tH: engine.Transform_Handle, rect: engine.Rect, point: [2]f32) -> bool {
	if !_canvas_hits_any do return true
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return true
	for owned in t.components {
		fn := canvas_hit_procs[owned.handle.type_key]
		if fn == nil do continue
		c := engine.world_pool_get(w, owned.handle)
		if c == nil || !(cast(^engine.CompData)c).enabled do continue
		if !fn(c, rect, point) do return false
	}
	return true
}

// The selected node: the one keyboard and gamepad input acts on, where
// navigation starts from. A press with the left button selects the UI node
// it lands on, and a press on the world or on nothing clears it (ui_tick
// reads the press from the pointer package). Code selects a node with
// ui_set_selected.
@(private) _selected: engine.Transform_Handle

// Selects `node`, {} for none.
ui_set_selected :: proc(node: engine.Transform_Handle) {
	_selected = node
}

ui_selected :: proc() -> engine.Transform_Handle {
	return _selected
}

// The UI's raycaster for the pointer package: the canvas node under the
// pointer. Its order is ORDER_UI, before the world's, so a pointer over UI
// hits nothing behind it.
@(pointer_raycaster={order=-100})
canvas_pointer_raycast :: proc(position: [2]f32, viewport: [2]f32) -> (hit: pointer.Pointer_Hit, ok: bool) {
	node := canvas_raycast(position, viewport)
	return {node = node, source = .UI}, node != {}
}

// The topmost raycast-target graphic under a viewport point (pixels, y
// down), across the engine.canvases with an enabled GraphicRaycaster, in draw
// order: higher sort_order over lower, higher z_index over lower, later
// nodes over earlier. {} when nothing is hit.
canvas_raycast :: proc(point: [2]f32, viewport: [2]f32) -> engine.Transform_Handle {
	w := engine.ctx_world()
	if w == nil do return {}

	Hit_Canvas :: struct {
		tH:         engine.Transform_Handle,
		sort_order: i32,
		ignore_reversed: bool,
	}
	hit_canvases := make([dynamic]Hit_Canvas, context.temp_allocator)
	it := engine.pool_iterator(engine.canvases(w))
	for canvas, _ in engine.pool_next(&it) {
		if !canvas.enabled || !engine.transform_active_in_hierarchy(canvas.owner) do continue
		_, rc := engine.transform_get_comp(canvas.owner, GraphicRaycaster)
		if rc == nil || !rc.enabled do continue
		append(&hit_canvases, Hit_Canvas{canvas.owner, canvas.sort_order, rc.ignore_reversed_graphics})
	}
	slice.stable_sort_by(hit_canvases[:], proc(a, b: Hit_Canvas) -> bool { return a.sort_order < b.sort_order })

	// Overlay engine.canvases lie over the camera-space and world ones, so they are
	// tested last and win.
	slice.stable_sort_by(hit_canvases[:], proc(a, b: Hit_Canvas) -> bool {
		_, ca := engine.transform_get_comp(a.tH, engine.Canvas)
		_, cb := engine.transform_get_comp(b.tH, engine.Canvas)
		oa := ca != nil && ca.render_mode == .ScreenSpaceOverlay
		ob := cb != nil && cb.render_mode == .ScreenSpaceOverlay
		return !oa && ob
	})

	hit: engine.Transform_Handle
	nodes := make([dynamic]engine.Node_Rect, context.temp_allocator)
	for c in hit_canvases {
		root, _, _ := engine.canvas_placement(c.tH, viewport)
		cp, on_canvas := engine.canvas_point_at(c.tH, point, viewport)
		if !on_canvas do continue
		clear(&nodes)
		engine.canvas_resolve_rects(c.tH, root, &nodes)
		for n in nodes {
			if !node_takes_pointer(n.tH) do continue
			corners := engine.rect_corners(n.rect, n.xform)
			if c.ignore_reversed && _quad_reversed(corners) do continue
			if !_point_in_quad(cp, corners) do continue
			// Inside the rect: the graphic may say the point misses it.
			if _canvas_hits_any {
				local := linalg.inverse(n.xform) * [4]f32{cp.x, cp.y, 0, 1}
				if !node_hit(n.tH, n.rect, local.xy) do continue
			}
			// Outside a mask above it, the node is not there to hit. Every
			// mask up the chain counts here.
			clipped_away := false
			for mask_tH := node_mask(n.tH); mask_tH != {} && !clipped_away; mask_tH = node_mask(mask_tH) {
				for m in nodes do if m.tH == mask_tH {
					if !mask_contains(mask_tH, m, cp) do clipped_away = true
					break
				}
			}
			if !clipped_away do hit = n.tH
		}
	}
	return hit
}

// The quad's winding on the canvas plane: negative area means a transform
// flipped it, so it faces away.
@(private = "file")
_quad_reversed :: proc(c: [4][3]f32) -> bool {
	a := c[1].xy - c[0].xy
	b := c[3].xy - c[0].xy
	return a.x * b.y - a.y * b.x < 0
}

@(private = "file")
_point_in_quad :: proc(p: [2]f32, c: [4][3]f32) -> bool {
	in_tri :: proc(p, a, b, c: [2]f32) -> bool {
		s1 := (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
		s2 := (c.x - b.x) * (p.y - b.y) - (c.y - b.y) * (p.x - b.x)
		s3 := (a.x - c.x) * (p.y - c.y) - (a.y - c.y) * (p.x - c.x)
		neg := s1 < 0 || s2 < 0 || s3 < 0
		pos := s1 > 0 || s2 > 0 || s3 > 0
		return !(neg && pos)
	}
	return in_tri(p, c[0].xy, c[1].xy, c[2].xy) || in_tri(p, c[0].xy, c[2].xy, c[3].xy)
}

