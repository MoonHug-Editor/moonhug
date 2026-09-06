package engine

// The canvas tree: the layout half of UI (docs/Gui.md). RectTransform lays a
// node out inside its parent's rect, Canvas roots a tree on the game
// viewport, CanvasScaler sets how many screen pixels a canvas unit is, and
// CanvasRenderer marks a node as drawing. What a node draws is a graphic
// component (Image in packages/mhgui, Text in packages/text) embedding
// `Graphic` and registered through canvas_graphic_register; the one canvas
// collector here walks the tree and asks each graphic for its quads. Layout
// containers plug in through canvas_layout_register.

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "moonhug:engine/input"

// A rectangle in canvas units: bottom-left origin, y up, the same
// orientation as NDC.
Rect :: struct {
	pos:  [2]f32, // bottom-left corner
	size: [2]f32,
}

// --- RectTransform ----------------------------------------------------------------------

// Lays the node out inside the PARENT rect: the anchors pick a sub-rect of
// it, size_delta grows that sub-rect, and the pivot lands on the anchor
// reference point plus anchored_position. The node's Transform position
// takes no part; rotation and scale apply around the pivot.
@(component={menu="UI/Rect Transform"})
@(typ_guid={guid = "36e133bb-7979-48ba-8b1b-57385558f37d"})
RectTransform :: struct {
	using base:        CompData `inspect:"-"`,
	anchor_min:        [2]f32, // parent-relative 0..1, bottom-left anchor
	anchor_max:        [2]f32, // parent-relative 0..1, top-right anchor
	pivot:             [2]f32, // 0..1 inside the node's own rect
	anchored_position: [3]f32, // pivot offset from the anchor reference point, canvas units; z is depth off the canvas plane (Unity's anchoredPosition3D)
	size_delta:        [2]f32, // size added to the anchor span, canvas units
}

reset_RectTransform :: proc(rt: ^RectTransform) {
	rt.anchor_min = {0.5, 0.5}
	rt.anchor_max = {0.5, 0.5}
	rt.pivot = {0.5, 0.5}
	rt.size_delta = {100, 100}
}

// The rect math. With both anchors equal the node has a fixed size
// (size_delta) at a point; with anchors apart it stretches with the parent
// and size_delta is the margin (negative shrinks).
rect_resolve :: proc(parent: Rect, rt: ^RectTransform) -> Rect {
	lo := parent.pos + parent.size * rt.anchor_min
	hi := parent.pos + parent.size * rt.anchor_max
	size := (hi - lo) + rt.size_delta
	pivot_pos := lo + (hi - lo) * rt.pivot + rt.anchored_position.xy
	return Rect{pos = pivot_pos - size * rt.pivot, size = size}
}

// --- Canvas -----------------------------------------------------------------------------

// The root of a UI tree, in screen-space overlay mode: its rect is the whole
// game viewport in canvas units, and everything under it draws over the
// scene. Canvases stack by sort_order.
@(component={menu="UI/Canvas"})
@(typ_guid={guid = "ba2db3cd-79be-4d26-9cab-be3fc317d685"})
Canvas :: struct {
	using base: CompData `inspect:"-"`,
	sort_order: i32, // higher draws over lower canvases
}

reset_Canvas :: proc(c: ^Canvas) {
}

// Makes a canvas receive pointer events: the pointer pass (canvas_raycast)
// only looks at canvases carrying one. GameObject > UI > Canvas adds it.
@(component={menu="UI/Graphic Raycaster"})
@(typ_guid={guid = "b625f6b5-e1fd-4590-9757-ffa073e23bef"})
GraphicRaycaster :: struct {
	using base:               CompData `inspect:"-"`,
	ignore_reversed_graphics: bool, // a graphic whose rect faces away from the viewer (flipped by a transform) is not hit
}

reset_GraphicRaycaster :: proc(r: ^GraphicRaycaster) {
	r.ignore_reversed_graphics = true
}

// Marks a node as drawing. What it draws comes from the node's graphic
// (packages/mhgui Image); a CanvasRenderer without one draws nothing.
// Disabling it hides the node's graphic without touching the graphic's
// settings.
@(component={menu="UI/Canvas Renderer"})
@(typ_guid={guid = "56334c3e-5a5d-4a74-981f-3682e7c9dc9a"})
CanvasRenderer :: struct {
	using base: CompData `inspect:"-"`,
	// A runtime tint over the graphic's color (Unity's CanvasRenderer.SetColor):
	// what a Selectable's transition writes. Never saved; `tinted` says the
	// tint is set, so a loaded (zeroed) renderer draws untinted.
	tint:   [4]f32 `json:"-" inspect:"-"`,
	tinted: bool   `json:"-" inspect:"-"`,
}

canvas_renderer_set_tint :: proc(cr: ^CanvasRenderer, tint: [4]f32) {
	cr.tint = tint
	cr.tinted = true
}

reset_CanvasRenderer :: proc(cr: ^CanvasRenderer) {
}

// --- CanvasScaler -----------------------------------------------------------------------

// How the canvas resolution follows the screen. Sits on the Canvas node.
Scale_Mode :: enum u8 {
	Constant_Pixel_Size,    // one canvas unit is scale_factor screen pixels
	Scale_With_Screen_Size, // the canvas is reference_resolution units wide/tall, scaled to fit the screen
}

// Scales the canvas as a whole so a layout authored once holds up across
// window sizes. Without a CanvasScaler one canvas unit is one screen pixel.
@(component={menu="UI/Canvas Scaler"})
@(typ_guid={guid = "39805feb-6d86-481c-bb1a-f662b7309f64"})
CanvasScaler :: struct {
	using base:           CompData `inspect:"-"`,
	mode:                 Scale_Mode,
	scale_factor:         f32,    // Constant_Pixel_Size
	reference_resolution: [2]f32, // Scale_With_Screen_Size: the authored canvas size
	// Scale_With_Screen_Size: 0 fits the reference width, 1 the reference
	// height, values between blend the two (logarithmically, so 0.5 is the
	// geometric mean).
	match:                f32,
}

reset_CanvasScaler :: proc(cs: ^CanvasScaler) {
	cs.mode = .Scale_With_Screen_Size
	cs.scale_factor = 1
	cs.reference_resolution = {1920, 1080}
	cs.match = 0.5
}

// Screen pixels per canvas unit for `screen`.
scaler_factor :: proc(cs: ^CanvasScaler, screen: [2]f32) -> f32 {
	switch cs.mode {
	case .Constant_Pixel_Size:
		return max(cs.scale_factor, 0.0001)
	case .Scale_With_Screen_Size:
		ref := cs.reference_resolution
		if ref.x <= 0 || ref.y <= 0 || screen.x <= 0 || screen.y <= 0 do return 1
		log_w := math.log2(screen.x / ref.x)
		log_h := math.log2(screen.y / ref.y)
		m := clamp(cs.match, 0, 1)
		return math.pow(f32(2), log_w * (1 - m) + log_h * m)
	}
	return 1
}

// The canvas node's scale for `screen`: its CanvasScaler's, or 1.
canvas_scale :: proc(canvas_tH: Transform_Handle, screen: [2]f32) -> f32 {
	if _, cs := transform_get_comp(canvas_tH, CanvasScaler); cs != nil && cs.enabled {
		return scaler_factor(cs, screen)
	}
	return 1
}

// --- Canvas space -------------------------------------------------------------------------

// The game viewport in pixels as last rendered (render_world_cameras), the
// size every canvas measures itself against outside a Game view: the scene
// view, the rect tool, position conversion. 1920x1080 until a frame rendered.
@(private = "file") _canvas_game_viewport: [2]f32 = {1920, 1080}

canvas_set_game_viewport :: proc(size: [2]f32) {
	if size.x > 0 && size.y > 0 do _canvas_game_viewport = size
}

canvas_game_viewport :: proc() -> [2]f32 {
	return _canvas_game_viewport
}

// The canvas rect for a Game view: the viewport in canvas units.
canvas_rect :: proc(view: Render_View, canvas_tH: Transform_Handle) -> Rect {
	screen := [2]f32{view.width, view.height}
	return Rect{pos = {0, 0}, size = screen / canvas_scale(canvas_tH, screen)}
}

// The canvas in WORLD space (the scene view): a rect with its bottom-left at
// the origin in the XY plane, one world unit per canvas unit, sized like the
// game viewport over the canvas scale. Editor tools work in this space.
canvas_world_rect :: proc(canvas_tH: Transform_Handle) -> Rect {
	vp := _canvas_game_viewport
	return Rect{pos = {0, 0}, size = vp / canvas_scale(canvas_tH, vp)}
}

// z01 NDC depth of the canvas plane in a Game view: just inside the near
// plane (0), so nothing in the scene passes the depth test in front of it.
CANVAS_NDC_Z :: f32(0.0005)

// The world-space quad screen-pixel corners cover in a Game view: each
// unprojected onto the canvas plane, so the quad lands on exactly those
// pixels whatever the camera does. Screen y is up, like canvas space.
canvas_view_corners :: proc(view: Render_View, screen: [4][2]f32) -> [4][3]f32 {
	to_world :: proc(view: Render_View, p: [2]f32) -> [3]f32 {
		ndc_x := 2 * p.x / max(view.width, 1) - 1
		ndc_y := 2 * p.y / max(view.height, 1) - 1
		h := view.inv_view_proj * [4]f32{ndc_x, ndc_y, CANVAS_NDC_Z, 1}
		return h.xyz / h.w
	}
	return {to_world(view, screen[0]), to_world(view, screen[1]), to_world(view, screen[2]), to_world(view, screen[3])}
}

// World corners of a canvas rect: bl, br, tr, tl at z = 0.
canvas_world_corners :: proc(r: Rect) -> [4][3]f32 {
	x0, y0 := r.pos.x, r.pos.y
	x1, y1 := x0 + r.size.x, y0 + r.size.y
	return {{x0, y0, 0}, {x1, y0, 0}, {x1, y1, 0}, {x0, y1, 0}}
}

// --- Rect walk ------------------------------------------------------------------------------

// One resolved node, in draw order (parents before children, siblings in
// hierarchy order — the canvas draw order). `rect` is the node's rect in its
// PARENT's unrotated space; `xform` maps that space, and the space the
// node's own children resolve in, to canvas space: the parent chain, then
// this node's Transform rotation and scale around its pivot. Canvas space is
// 3D with the canvas in the XY plane: a rotation around X or Y tilts the
// rect out of the plane, which the Game view draws orthographically (the
// tilt shows as foreshortening) and the scene view shows in depth. Nodes
// without a RectTransform add nothing to the chain.
Node_Rect :: struct {
	tH:    Transform_Handle,
	rect:  Rect,
	xform: matrix[4, 4]f32,
}

// The transform that lifts a node `depth` off the canvas plane and rotates
// by `rotation` and scales by `scale` around `pivot` (a canvas point on the
// plane).
rect_affine :: proc(pivot: [2]f32, depth: f32, rotation: [4]f32, scale: [3]f32) -> matrix[4, 4]f32 {
	p := [3]f32{pivot.x, pivot.y, 0}
	return trs_matrix({p.x, p.y, depth}, _quat_safe(rotation), scale) * linalg.matrix4_translate_f32(-p)
}

// A canvas point through a node transform: the 3D point it lands on.
rect_apply :: proc(m: matrix[4, 4]f32, p: [2]f32) -> [3]f32 {
	r := m * [4]f32{p.x, p.y, 0, 1}
	return r.xyz
}

// A canvas direction through a node transform (no translation), projected
// back onto the plane.
rect_apply_dir :: proc(m: matrix[4, 4]f32, v: [2]f32) -> [2]f32 {
	r := m * [4]f32{v.x, v.y, 0, 0}
	return r.xy
}

// The corners of `r` (bl, br, tr, tl) through `m`: 3D canvas-space points,
// on the plane unless the chain tilts them.
rect_corners :: proc(r: Rect, m: matrix[4, 4]f32) -> [4][3]f32 {
	x0, y0 := r.pos.x, r.pos.y
	x1, y1 := x0 + r.size.x, y0 + r.size.y
	return {rect_apply(m, {x0, y0}), rect_apply(m, {x1, y0}), rect_apply(m, {x1, y1}), rect_apply(m, {x0, y1})}
}

// A layout container (packages/mhgui LayoutGroup): asked for every node in
// the walk with the node's rect and its active RectTransform children in
// order. A provider that lays the node out fills `out` (one rect per child)
// and returns true; otherwise the children resolve from their own anchors.
Canvas_Layout_Provider :: proc(tH: Transform_Handle, rect: Rect, children: []Transform_Handle, out: []Rect) -> bool

_canvas_layout_providers: [dynamic]Canvas_Layout_Provider

// Process-global registry: never borrows the caller's allocator.
canvas_layout_register :: proc(p: Canvas_Layout_Provider) {
	context.allocator = runtime.default_allocator()
	if _canvas_layout_providers == nil do _canvas_layout_providers = make([dynamic]Canvas_Layout_Provider)
	append(&_canvas_layout_providers, p)
}

// Resolves the rect of the canvas node (always `root`, the canvas drives it)
// and of every active node under it, appended to `out` in draw order. A node
// without a RectTransform passes its parent's rect through, so plain grouping
// nodes cost nothing. A node a layout provider claims places its RectTransform
// children itself. Inactive nodes and their subtrees are skipped.
canvas_resolve_rects :: proc(canvas_tH: Transform_Handle, root: Rect, out: ^[dynamic]Node_Rect) {
	w := ctx_world()
	Entry :: struct {
		tH:     Transform_Handle,
		parent: Rect,
		xform:  matrix[4, 4]f32, // the parent's space -> canvas space
		forced: Rect, // the rect a layout assigned
		laid:   bool, // forced is set
	}
	stack := make([dynamic]Entry, context.temp_allocator)
	append(&stack, Entry{tH = canvas_tH, parent = root, xform = linalg.MATRIX4F32_IDENTITY})
	kids := make([dynamic]Transform_Handle, context.temp_allocator)
	laid := make([dynamic]Rect, context.temp_allocator)
	for len(stack) > 0 {
		e := pop(&stack)
		t := pool_get(&w.transforms, Handle(e.tH))
		if t == nil || !t.is_active do continue
		rect := e.parent
		xform := e.xform
		_, rt := transform_get_comp(e.tH, RectTransform)
		if rt != nil && !rt.enabled do rt = nil
		if e.laid {
			rect = e.forced
		} else if e.tH != canvas_tH && rt != nil {
			rect = rect_resolve(e.parent, rt)
		}
		// The node's own rotation and scale, around its pivot, in the parent's
		// space. The canvas node itself never rotates (overlay).
		if rt != nil && e.tH != canvas_tH {
			rot := _quat_safe(t.rotation)
			if rot != QUAT_IDENTITY || t.scale != {1, 1, 1} || rt.anchored_position.z != 0 {
				xform = e.xform * rect_affine(rect.pos + rect.size * rt.pivot, rt.anchored_position.z, rot, t.scale)
			}
		}
		append(out, Node_Rect{e.tH, rect, xform})

		// A layout container arranges the active RectTransform children; the
		// rest pass the rect through as usual.
		clear(&kids)
		for child in t.children {
			ch := Transform_Handle(child.handle)
			ct := pool_get(&w.transforms, Handle(ch))
			if ct == nil || !ct.is_active do continue
			if _, rt := transform_get_comp(ch, RectTransform); rt != nil && rt.enabled do append(&kids, ch)
		}
		has_layout := false
		if len(kids) > 0 {
			resize(&laid, len(kids))
			for p in _canvas_layout_providers {
				if p(e.tH, rect, kids[:], laid[:]) {
					has_layout = true
					break
				}
			}
		}

		// Pushed in reverse so the pop order is hierarchy order; laid-out
		// children take their slot in the order they were listed.
		slot := len(kids) - 1
		#reverse for child in t.children {
			ch := Transform_Handle(child.handle)
			entry := Entry{tH = ch, parent = rect, xform = xform}
			if slot >= 0 && kids[slot] == ch {
				if has_layout {
					entry.forced = laid[slot]
					entry.laid = true
				}
				slot -= 1
			}
			append(&stack, entry)
		}
	}
}

// --- Position through the Transform API -----------------------------------------------------
//
// anchored_position is the stored value, the only one. The procs below are
// a second door into it: a set converts the given position into
// anchored_position, a read derives the position from it. Local positions
// are relative to the parent's pivot point, in the parent's space (its
// rotation and scale included), like localPosition under a RectTransform;
// z passes straight through as depth off the canvas plane. World positions
// are canvas-space points, the space the scene view shows.

// The canvas node above `tH`, or the zero handle.
canvas_of :: proc(tH: Transform_Handle) -> Transform_Handle {
	w := ctx_world()
	h := tH
	for h != (Transform_Handle{}) {
		if _, c := transform_get_comp(h, Canvas); c != nil do return h
		t := pool_get(&w.transforms, Handle(h))
		if t == nil do break
		h = Transform_Handle(t.parent.handle)
	}
	return {}
}

// The frame a RectTransform node's position lives in: its parent's rect and
// xform, the parent's pivot point in that rect (0.5 for a parent without a
// RectTransform), and the node's own anchor reference point. ok=false when
// the node has no RectTransform or no canvas above it.
Rect_Frame :: struct {
	parent:       Rect,
	parent_xform: matrix[4, 4]f32,
	parent_pivot: [2]f32, // canvas units, in the parent's space
	anchor_ref:   [2]f32, // canvas units, in the parent's space
	rt:           ^RectTransform,
}

rect_frame :: proc(tH: Transform_Handle) -> (f: Rect_Frame, ok: bool) {
	_, rt := transform_get_comp(tH, RectTransform)
	if rt == nil do return {}, false
	canvas := canvas_of(tH)
	if canvas == (Transform_Handle{}) || canvas == tH do return {}, false
	w := ctx_world()
	t := pool_get(&w.transforms, Handle(tH))
	if t == nil do return {}, false
	parent_tH := Transform_Handle(t.parent.handle)

	nodes := make([dynamic]Node_Rect, context.temp_allocator)
	canvas_resolve_rects(canvas, canvas_world_rect(canvas), &nodes)
	for n in nodes {
		if n.tH != parent_tH do continue
		f.parent = n.rect
		f.parent_xform = n.xform
		f.parent_pivot = n.rect.pos + n.rect.size * 0.5
		if _, prt := transform_get_comp(parent_tH, RectTransform); prt != nil && prt.enabled {
			f.parent_pivot = n.rect.pos + n.rect.size * prt.pivot
		}
		lo := n.rect.pos + n.rect.size * rt.anchor_min
		hi := n.rect.pos + n.rect.size * rt.anchor_max
		f.anchor_ref = lo + (hi - lo) * rt.pivot
		f.rt = rt
		return f, true
	}
	return {}, false
}

// The node's pivot point in the parent's space, depth included.
rect_pivot_local :: proc(f: Rect_Frame) -> [3]f32 {
	p := f.anchor_ref + f.rt.anchored_position.xy
	return {p.x, p.y, f.rt.anchored_position.z}
}

// The node's position relative to the parent's pivot, in the parent's
// space, or its Transform position for a non-UI node.
transform_local_position :: proc(tH: Transform_Handle) -> [3]f32 {
	if f, ok := rect_frame(tH); ok {
		p := rect_pivot_local(f)
		return {p.x - f.parent_pivot.x, p.y - f.parent_pivot.y, p.z}
	}
	w := ctx_world()
	t := pool_get(&w.transforms, Handle(tH))
	if t == nil do return {}
	return t.position
}

// Sets the node's position relative to the parent's pivot: converted into
// anchored_position for a UI node, written to the Transform otherwise.
transform_set_local_position :: proc(tH: Transform_Handle, local: [3]f32) {
	if f, ok := rect_frame(tH); ok {
		xy := f.parent_pivot + local.xy - f.anchor_ref
		f.rt.anchored_position = {xy.x, xy.y, local.z}
		return
	}
	w := ctx_world()
	t := pool_get(&w.transforms, Handle(tH))
	if t == nil do return
	t.position = local
}

// The UI node's pivot point in canvas (world) space. ok=false for non-UI nodes.
rect_transform_world_position :: proc(tH: Transform_Handle) -> (pos: [3]f32, ok: bool) {
	f, found := rect_frame(tH)
	if !found do return {}, false
	p := rect_pivot_local(f)
	return (f.parent_xform * [4]f32{p.x, p.y, p.z, 1}).xyz, true
}

// Places the UI node's pivot at a canvas (world) point. ok=false for non-UI nodes.
rect_transform_set_world_position :: proc(tH: Transform_Handle, world: [3]f32) -> bool {
	f, found := rect_frame(tH)
	if !found do return false
	// Back into the parent's space: x and y against the anchor reference, z
	// as depth off the parent's plane.
	local := (linalg.inverse(f.parent_xform) * [4]f32{world.x, world.y, world.z, 1}).xyz
	f.rt.anchored_position = {local.x - f.anchor_ref.x, local.y - f.anchor_ref.y, local.z}
	return true
}

// --- Graphics -------------------------------------------------------------------------------
//
// Every drawable UI component embeds Graphic as `using graphic: engine.Graphic`
// with the `inline:""` tag: the fields every graphic shares, serialized under
// "graphic" and drawn flat in the inspector. The package then registers the
// component type with the offset of that field and a populate proc, and the
// canvas collector below can find the Graphic on any node and ask for its
// geometry without knowing the type.

Graphic :: struct {
	color:          [4]f32 `decor:color()`,
	material:       Asset_GUID `ext:"mat"`, // shader/tint/properties; the quad's texture stays its own. empty = unlit
	raycast_target: bool, // takes pointer events (input)
}

// One quad in the node's rect space, canvas units, bottom-left origin.
Graphic_Quad :: struct {
	pos:     [2]f32,
	size:    [2]f32,
	skew:    [2]f32, // x shift of the bottom and the top edge (italic text); zero = a rect
	uvs:     [4][2]f32, // bl, br, tr, tl
	texture: Asset_GUID,
}

// The quad's corners through the node's transform, skew applied.
graphic_quad_corners :: proc(q: Graphic_Quad, m: matrix[4, 4]f32) -> [4][3]f32 {
	x0, y0 := q.pos.x, q.pos.y
	x1, y1 := x0 + q.size.x, y0 + q.size.y
	return {
		rect_apply(m, {x0 + q.skew[0], y0}),
		rect_apply(m, {x1 + q.skew[0], y0}),
		rect_apply(m, {x1 + q.skew[1], y1}),
		rect_apply(m, {x0 + q.skew[1], y1}),
	}
}

// A registered graphic type. `populate` appends the quads a component draws
// inside `rect` (its resolved rect); the collector applies the node's
// transform, the canvas scale and the view.
Graphic_Desc :: struct {
	key:            TypeKey,
	graphic_offset: uintptr, // offset_of(T, graphic)
	populate:       proc(comp: rawptr, rect: Rect, out: ^[dynamic]Graphic_Quad),
}

_canvas_graphics: [dynamic]Graphic_Desc

// Process-global registry: never borrows the caller's allocator.
canvas_graphic_register :: proc(desc: Graphic_Desc) {
	context.allocator = runtime.default_allocator()
	if _canvas_graphics == nil do _canvas_graphics = make([dynamic]Graphic_Desc)
	for d in _canvas_graphics {
		if d.key == desc.key do return
	}
	append(&_canvas_graphics, desc)
}

// The first enabled registered graphic on a node: its component, its
// Graphic part and its descriptor. ok=false when the node draws nothing.
node_graphic :: proc(tH: Transform_Handle) -> (comp: rawptr, graphic: ^Graphic, desc: ^Graphic_Desc, ok: bool) {
	w := ctx_world()
	t := pool_get(&w.transforms, Handle(tH))
	if t == nil do return
	for &d in _canvas_graphics {
		owned, idx := transform_find_comp(t, d.key)
		if idx < 0 do continue
		c := world_pool_get(w, owned.handle)
		if c == nil || !(cast(^CompData)c).enabled do continue
		return c, cast(^Graphic)(uintptr(c) + d.graphic_offset), &d, true
	}
	return
}

// The top of the transparent-sort range: every canvas draws after every
// sprite and particle. Canvases order by sort_order inside it, nodes by
// their index in the rect walk (hierarchy order).
CANVAS_SORTING_LAYER :: i32(127)

// The canvas collector (render_collect_commands): Game views draw each
// canvas over the viewport, canvas units mapped to pixels through the canvas
// scale and onto the near plane; the scene view draws it as the world rect
// at the origin. Previews show neither. One Draw_Quad per graphic quad, in
// the graphic's color and material.
canvas_collect_graphics :: proc(view: Render_View, out: ^[dynamic]Render_Command) {
	if view.kind == .Preview || len(_canvas_graphics) == 0 do return
	w := ctx_world()
	nodes := make([dynamic]Node_Rect, context.temp_allocator)
	quads := make([dynamic]Graphic_Quad, context.temp_allocator)

	it := pool_iterator(canvases(w))
	for canvas, _ in pool_next(&it) {
		if !canvas.enabled do continue
		ct := pool_get(&w.transforms, Handle(canvas.owner))
		if ct == nil || !transform_active_in_hierarchy(canvas.owner) do continue
		if ct.render_layer & view.layer_mask == 0 do continue

		root: Rect
		scale := f32(1)
		if view.kind == .Game {
			root = canvas_rect(view, canvas.owner)
			scale = canvas_scale(canvas.owner, {view.width, view.height})
		} else {
			root = canvas_world_rect(canvas.owner)
		}
		clear(&nodes)
		canvas_resolve_rects(canvas.owner, root, &nodes)
		for n, i in nodes {
			_, cr := transform_get_comp(n.tH, CanvasRenderer)
			if cr == nil || !cr.enabled do continue
			comp, g, desc, ok := node_graphic(n.tH)
			if !ok do continue
			clear(&quads)
			desc.populate(comp, n.rect, &quads)
			key: Sort_Key
			key[0] = sort_key_word(CANVAS_SORTING_LAYER, canvas.sort_order, 0, u16(i))
			for q in quads {
				if asset_guid_is_empty(q.texture) do continue
				corners := graphic_quad_corners(q, n.xform)
				if view.kind == .Game {
					screen: [4][2]f32
					for c, k in corners do screen[k] = c.xy * scale
					corners = canvas_view_corners(view, screen)
				}
				append(out, Render_Command{
					key     = key,
					variant = Draw_Quad{
						texture  = q.texture,
						material = g.material,
						corners  = corners,
						uvs      = q.uvs,
						color    = g.color * cr.tint if cr.tinted else g.color,
					},
				})
			}
		}
	}
}

// --- Pointer -----------------------------------------------------------------------------
// The event system's pointer pass. Every frame canvas_pointer_update reads the
// mouse (viewport coordinates, see engine/input) and raycasts the canvases
// that carry a GraphicRaycaster: the topmost graphic with raycast_target under
// the pointer is `hovered`. The left button's press remembers its target
// (`pressed`, also `selected`, like Unity's EventSystem selecting on pointer
// down), and a release over that same target is a `clicked`, for one frame.
// Components read the state (ui_pointer) instead of receiving events; the
// mhgui package's Button is the first reader. Nothing while the application
// has no focus.

UI_Pointer :: struct {
	position: [2]f32, // viewport pixels, y down
	hovered:  Transform_Handle,
	pressed:  Transform_Handle, // where the left button went down, until it comes up
	selected: Transform_Handle, // the last node pressed on; pressing on nothing clears it
	clicked:  Transform_Handle, // released this frame over the node it was pressed on
}

@(private = "file") _ui_pointer: UI_Pointer

ui_pointer :: proc() -> UI_Pointer {
	return _ui_pointer
}

canvas_pointer_update :: proc() {
	p := &_ui_pointer
	p.clicked = {}
	if !application_is_focused() {
		p.hovered = {}
		return
	}
	p.position = input.mouse_position()
	p.hovered = canvas_raycast(p.position, input.viewport_size())
	if input.mouse_pressed(.Left) {
		p.pressed = p.hovered
		p.selected = p.hovered
	}
	if input.mouse_released(.Left) {
		if p.pressed != {} && p.pressed == p.hovered do p.clicked = p.pressed
		p.pressed = {}
	}
}

// The topmost raycast-target graphic under a viewport point (pixels, y
// down), across the canvases with an enabled GraphicRaycaster, in draw
// order: higher sort_order over lower, later nodes over earlier. {} when
// nothing is hit.
canvas_raycast :: proc(point: [2]f32, viewport: [2]f32) -> Transform_Handle {
	w := ctx_world()
	if w == nil || len(_canvas_graphics) == 0 do return {}

	Hit_Canvas :: struct {
		tH:         Transform_Handle,
		sort_order: i32,
		ignore_reversed: bool,
	}
	hit_canvases := make([dynamic]Hit_Canvas, context.temp_allocator)
	it := pool_iterator(canvases(w))
	for canvas, _ in pool_next(&it) {
		if !canvas.enabled || !transform_active_in_hierarchy(canvas.owner) do continue
		_, rc := transform_get_comp(canvas.owner, GraphicRaycaster)
		if rc == nil || !rc.enabled do continue
		append(&hit_canvases, Hit_Canvas{canvas.owner, canvas.sort_order, rc.ignore_reversed_graphics})
	}
	slice.stable_sort_by(hit_canvases[:], proc(a, b: Hit_Canvas) -> bool { return a.sort_order < b.sort_order })

	hit: Transform_Handle
	nodes := make([dynamic]Node_Rect, context.temp_allocator)
	for c in hit_canvases {
		scale := canvas_scale(c.tH, viewport)
		root := Rect{pos = {0, 0}, size = viewport / scale}
		// Viewport y is down, canvas y is up.
		cp := [2]f32{point.x / scale, (viewport.y - point.y) / scale}
		clear(&nodes)
		canvas_resolve_rects(c.tH, root, &nodes)
		for n in nodes {
			_, cr := transform_get_comp(n.tH, CanvasRenderer)
			if cr == nil || !cr.enabled do continue
			_, g, _, ok := node_graphic(n.tH)
			if !ok || !g.raycast_target do continue
			corners := rect_corners(n.rect, n.xform)
			if c.ignore_reversed && _quad_reversed(corners) do continue
			if _point_in_quad(cp, corners) do hit = n.tH
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

