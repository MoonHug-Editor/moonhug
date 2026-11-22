package engine

// The canvas tree: the layout half of UI (plugins/engine/docs/UICanvas.md). RectTransform lays a
// node out inside its parent's rect, Canvas roots a tree on the game
// viewport, CanvasRenderer marks a node as drawing and CanvasGroup fades a
// subtree. The canvas's scale and what clips its nodes are installed by a
// plugin (canvas_scale_install, canvas_clip_install): the mhgui plugin's
// CanvasScaler and UiMask. The pointer is that plugin's too. What a node draws is a graphic
// component (Image in packages/mhgui, Text in packages/text) embedding
// `Graphic` and registered through canvas_graphic_register; the one canvas
// collector here walks the tree and asks each graphic for its quads. Layout
// containers plug in through canvas_layout_register.

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:encoding/uuid"
import "moonhug:libs/log"
import gfx "moonhug:libs/gfx"

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
@(component={menu="UI/RectTransform"})
@(typ_guid={guid = "36e133bb-7979-48ba-8b1b-57385558f37d"})
RectTransform :: struct {
	using base:        CompData `inspect:"-"`,
	anchor_min:        [2]f32, // parent-relative 0..1, bottom-left anchor
	anchor_max:        [2]f32, // parent-relative 0..1, top-right anchor
	pivot:             [2]f32, // 0..1 inside the node's own rect
	anchored_position: [3]f32, // pivot offset from the anchor reference point, canvas units; z is depth off the canvas plane (Unity's anchoredPosition3D)
	size_delta:        [2]f32, // size added to the anchor span, canvas units
	z_index:           i32,    // draw and hit order in the canvas: higher over lower, added to the parent's
}

type_reset_RectTransform :: proc(rt: ^RectTransform) {
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

// Where a canvas lives (Unity's Canvas.renderMode), see canvas_placement.
Canvas_Render_Mode :: enum u8 {
	ScreenSpaceOverlay, // the game viewport in canvas units, drawn over everything, the node's transform ignored
	ScreenSpaceCamera,  // a plane plane_distance in front of render_camera, sized to fill its view, drawn by that camera with depth
	WorldSpace,          // a world object: the node's RectTransform gives the size, its transform places it, one canvas unit per world unit
}

// The root of a UI tree. Canvases stack by sort_order.
@(component={menu="UI/Canvas"})
@(typ_guid={guid = "ba2db3cd-79be-4d26-9cab-be3fc317d685"})
Canvas :: struct {
	using base:     CompData `inspect:"-"`,
	render_mode:    Canvas_Render_Mode,
	sort_order:     i32, // higher draws over lower canvases
	render_camera:  Ref_Local `ref:"Transform"`, // ScreenSpaceCamera: the camera node; empty falls back to overlay
	plane_distance: f32, // ScreenSpaceCamera: how far in front of the camera the canvas plane sits
}

type_reset_Canvas :: proc(c: ^Canvas) {
	c.plane_distance = 100
}

// Marks a node as drawing. What it draws comes from the node's graphic
// (packages/mhgui Image); a CanvasRenderer without one draws nothing.
// Disabling it hides the node's graphic without touching the graphic's
// settings.
@(component={menu="UI/CanvasRenderer"})
@(typ_guid={guid = "56334c3e-5a5d-4a74-981f-3682e7c9dc9a"})
CanvasRenderer :: struct {
	using base: CompData `inspect:"-"`,
	// A runtime tint over the graphic's color (Unity's CanvasRenderer.SetColor):
	// what a Selectable's transition writes. Never saved; `tinted` says the
	// tint is set, so a loaded (zeroed) renderer draws untinted.
	tint:   [4]f32 `json:"-" inspect:"-"`,
	tinted: bool   `json:"-" inspect:"-"`,
}

// Settings for a whole subtree of UI: everything under the node, the node
// included. Groups nest: a node takes the alpha of every group above it
// multiplied, and is interactable and hit by the pointer only when every
// group above it says so. A group with ignore_parent_groups starts over.
@(component={menu="UI/CanvasGroup"})
@(typ_guid={guid = "a38382c2-9aa1-46bc-9b65-814fa68cb532"})
CanvasGroup :: struct {
	using base:      CompData `inspect:"-"`,
	alpha:           f32 `decor:range(0, 1) decor:tooltip(desc="How opaque the subtree draws: multiplies the alpha of every graphic under it.")`,
	interactable:    bool `decor:tooltip(desc="Off, the controls under it cannot be used and show as disabled.")`,
	blocks_raycasts: bool `decor:tooltip(desc="Off, the pointer passes through everything under it to what is behind.")`,
	ignore_parent_groups: bool `decor:tooltip(desc="The groups above this one do not count for what is under it.")`,
}

type_reset_CanvasGroup :: proc(g: ^CanvasGroup) {
	g.alpha = 1
	g.interactable = true
	g.blocks_raycasts = true
}

// What the CanvasGroups on a node and above it make of it.
Canvas_Group_State :: struct {
	alpha:           f32,
	interactable:    bool,
	blocks_raycasts: bool,
}

// The groups' say over a node: full alpha, interactable and hit with no
// group above it.
canvas_group_state :: proc(tH: Transform_Handle) -> Canvas_Group_State {
	state := Canvas_Group_State{1, true, true}
	w := ctx_world()
	// With no CanvasGroup in the world, no node looks for one.
	if canvas_groups(w).count == 0 do return state
	node := tH
	for n := 0; node != {} && n < 4096; n += 1 {
		t := pool_get(&w.transforms, Handle(node))
		if t == nil do break
		if _, g := transform_get_comp(node, CanvasGroup); g != nil && g.enabled {
			state.alpha *= clamp(g.alpha, 0, 1)
			state.interactable &&= g.interactable
			state.blocks_raycasts &&= g.blocks_raycasts
			if g.ignore_parent_groups do break
		}
		node = Transform_Handle(t.parent.handle)
	}
	return state
}

// Where a canvas's points land in a view's target, for the masks: the pixel
// a quad's corner is drawn at.
Canvas_Pixels :: struct {
	view:      Render_View,
	overlay:   bool,            // a Game view's overlay canvas: canvas units times `scale` are pixels
	scale:     f32,
	to_world:  matrix[4, 4]f32, // else: canvas space to world
}

// The target pixel (y down) a canvas point is drawn at. False behind the camera.
canvas_point_pixel :: proc(c: Canvas_Pixels, canvas_point: [3]f32) -> (pixel: [2]f32, ok: bool) {
	if c.overlay {
		return {canvas_point.x * c.scale, c.view.height - canvas_point.y * c.scale}, true
	}
	clip := c.view.view_proj * (c.to_world * [4]f32{canvas_point.x, canvas_point.y, canvas_point.z, 1})
	if clip.w <= 1e-6 do return {}, false
	ndc := clip.xy / clip.w
	return {(ndc.x * 0.5 + 0.5) * c.view.width, (0.5 - ndc.y * 0.5) * c.view.height}, true
}

// What clips the nodes of a canvas: installed by the plugin that has masks
// (the mhgui UiMask). The collector asks it which mask a node is under and
// what the masks above it are in a view, and hands the answer to gfx with
// the node's quads.
Canvas_Clip_Provider :: struct {
	any:     proc() -> bool,                                   // whether the world holds a mask at all
	nearest: proc(tH: Transform_Handle) -> Transform_Handle,   // the nearest mask above a node, {} for none
	stack:   proc(c: Canvas_Pixels, tH: Transform_Handle, nodes: []Node_Rect) -> []gfx.Clip_Mask, // the masks above a node, the nearest first, temp-allocated
}

@(private = "file")
_canvas_clip: Canvas_Clip_Provider

// Installs what clips canvas nodes, from an @(init) proc.
canvas_clip_install :: proc(p: Canvas_Clip_Provider) {
	_canvas_clip = p
}

canvas_clip_any :: proc() -> bool {
	return _canvas_clip.any != nil && _canvas_clip.any()
}

canvas_clip_nearest :: proc(tH: Transform_Handle) -> Transform_Handle {
	return _canvas_clip.nearest(tH) if _canvas_clip.nearest != nil else Transform_Handle{}
}

canvas_clip_stack :: proc(c: Canvas_Pixels, tH: Transform_Handle, nodes: []Node_Rect) -> []gfx.Clip_Mask {
	return _canvas_clip.stack(c, tH, nodes) if _canvas_clip.stack != nil else nil
}

canvas_renderer_set_tint :: proc(cr: ^CanvasRenderer, tint: [4]f32) {
	cr.tint = tint
	cr.tinted = true
}

type_reset_CanvasRenderer :: proc(cr: ^CanvasRenderer) {
}

// --- Canvas scale -------------------------------------------------------------------------

// How many screen pixels a canvas unit is, for a canvas and a screen size.
Canvas_Scale_Proc :: proc(canvas_tH: Transform_Handle, screen: [2]f32) -> f32

@(private = "file")
_canvas_scale_proc: Canvas_Scale_Proc

// Installs the proc that says a canvas's scale. A plugin with a scaler
// component does, from an @(init) proc (the mhgui CanvasScaler).
canvas_scale_install :: proc(fn: Canvas_Scale_Proc) {
	_canvas_scale_proc = fn
}

// The canvas node's scale for `screen`: what the installed proc says, or 1.
canvas_scale :: proc(canvas_tH: Transform_Handle, screen: [2]f32) -> f32 {
	if _canvas_scale_proc != nil do return _canvas_scale_proc(canvas_tH, screen)
	return 1
}

// --- Canvas space -------------------------------------------------------------------------

// The game viewport in pixels as last rendered (render_world_cameras), the
// size every canvas measures itself against outside a Game window: the Scene
// window, the rect tool, position conversion. 1920x1080 until a frame rendered.
@(private = "file") _canvas_game_viewport: [2]f32 = {1920, 1080}

canvas_set_game_viewport :: proc(size: [2]f32) {
	if size.x > 0 && size.y > 0 do _canvas_game_viewport = size
}

canvas_game_viewport :: proc() -> [2]f32 {
	return _canvas_game_viewport
}

// The canvas rect for a Game window: the viewport in canvas units.
canvas_rect :: proc(view: Render_View, canvas_tH: Transform_Handle) -> Rect {
	screen := [2]f32{view.width, view.height}
	return Rect{pos = {0, 0}, size = screen / canvas_scale(canvas_tH, screen)}
}

// The canvas in WORLD space (the Scene window): a rect with its bottom-left at
// the origin in the XY plane, one world unit per canvas unit, sized like the
// game viewport over the canvas scale. Editor tools work in this space.
canvas_world_rect :: proc(canvas_tH: Transform_Handle) -> Rect {
	vp := _canvas_game_viewport
	return Rect{pos = {0, 0}, size = vp / canvas_scale(canvas_tH, vp)}
}

// Where a canvas sits: its root rect in canvas units and the matrix taking
// canvas space to world. `screen` is the viewport the canvas measures against
// (a Game window's size, else canvas_game_viewport).
//
// - Overlay: the viewport rect at the world origin, identity. `in_world` is
//   false: a Game window maps it onto its pixels instead (canvas_view_corners).
// - ScreenSpaceCamera: the viewport rect, placed plane_distance in front of
//   the camera, facing it, scaled so its height spans the camera's view there
//   (2 d tan(fov/2)). Without a resolvable camera it behaves as Overlay.
// - WorldSpace: the node's RectTransform size around its pivot, through the
//   node's world transform.
canvas_placement :: proc(canvas_tH: Transform_Handle, screen: [2]f32) -> (root: Rect, xform: matrix[4, 4]f32, in_world: bool) {
	_, canvas := transform_get_comp(canvas_tH, Canvas)
	root = Rect{pos = {0, 0}, size = screen / canvas_scale(canvas_tH, screen)}
	xform = linalg.MATRIX4F32_IDENTITY
	if canvas == nil do return
	switch canvas.render_mode {
	case .ScreenSpaceOverlay:
	case .ScreenSpaceCamera:
		cam_tH := Transform_Handle(canvas.render_camera.handle)
		_, cam := transform_get_comp(cam_tH, Camera)
		if cam == nil do return
		tw := transform_world(cam_tH)
		rot := quat_to_matrix3(tw.rotation)
		forward := [3]f32{-rot[0, 2], -rot[1, 2], -rot[2, 2]}
		d := max(canvas.plane_distance, cam.near_clip)
		height := 2 * camera_half_height_at(cam, d)
		k := height / max(root.size.y, 1)
		center := tw.position + forward * d
		xform = trs_matrix(center, tw.rotation, {k, k, k}) * linalg.matrix4_translate_f32({-root.size.x * 0.5, -root.size.y * 0.5, 0})
		in_world = true
	case .WorldSpace:
		size := [2]f32{100, 100}
		pivot := [2]f32{0.5, 0.5}
		if _, rt := transform_get_comp(canvas_tH, RectTransform); rt != nil {
			size = rt.size_delta
			pivot = rt.pivot
		}
		root = Rect{pos = -size * pivot, size = size}
		tw := transform_world(canvas_tH)
		xform = trs_matrix(tw.position, tw.rotation, tw.scale)
		in_world = true
	}
	return
}

// anchored_position and size_delta that resolve to `rect` under the current
// anchors and pivot: what keeps a rect in place while its anchors or pivot
// change (the inspector and the rect tool, Unity's non-raw editing).
rect_transform_keep_rect :: proc(rt: ^RectTransform, parent, rect: Rect) {
	lo := parent.pos + parent.size * rt.anchor_min
	hi := parent.pos + parent.size * rt.anchor_max
	rt.size_delta = rect.size - (hi - lo)
	pivot_pos := rect.pos + rect.size * rt.pivot
	rt.anchored_position.xy = pivot_pos - (lo + (hi - lo) * rt.pivot)
}

// Whether a layout provider (a LayoutGroup) owns the node's rect: its
// anchored position and size are not its own then.
rect_transform_driven :: proc(tH: Transform_Handle) -> bool {
	canvas := canvas_of(tH)
	if canvas == (Transform_Handle{}) || canvas == tH do return false
	nodes := make([dynamic]Node_Rect, context.temp_allocator)
	canvas_resolve_rects(canvas, canvas_world_rect(canvas), &nodes)
	for n in nodes do if n.tH == tH do return n.driven
	return false
}

// The canvas's nodes with WORLD transforms (canvas_placement applied), for
// gizmos, picking and framing in the Scene window. Returns the placement too.
canvas_resolve_placed :: proc(canvas_tH: Transform_Handle, out: ^[dynamic]Node_Rect) -> (root: Rect, xform: matrix[4, 4]f32) {
	root, xform, _ = canvas_placement(canvas_tH, _canvas_game_viewport)
	canvas_resolve_rects(canvas_tH, root, out)
	for &n in out do n.xform = xform * n.xform
	return
}

// z01 NDC depth of the canvas plane in a Game window: just inside the near
// plane (0), so nothing in the scene passes the depth test in front of it.
CANVAS_NDC_Z :: f32(0.0005)

// The world-space quad screen-pixel corners cover in a Game window: each
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

// One resolved node, in draw order: lower `z` first, and inside one `z`
// parents before children and siblings in hierarchy order. `z` is the sum
// of z_index down the node's RectTransform chain, so a raised parent takes
// its children along. `rect` is the node's rect in its
// PARENT's unrotated space; `xform` maps that space, and the space the
// node's own children resolve in, to canvas space: the parent chain, then
// this node's Transform rotation and scale around its pivot. Canvas space is
// 3D with the canvas in the XY plane: a rotation around X or Y tilts the
// rect out of the plane, which the Game window draws orthographically (the
// tilt shows as foreshortening) and the Scene window shows in depth. Nodes
// without a RectTransform add nothing to the chain.
Node_Rect :: struct {
	tH:     Transform_Handle,
	rect:   Rect,
	xform:  matrix[4, 4]f32,
	driven: bool, // the rect came from a layout provider, not the node's own anchors and size
	z:      i32,  // the node's z_index plus its ancestors'
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
// A package declares one with @(canvas_layout) on the proc.
Canvas_Layout_Provider :: proc(tH: Transform_Handle, rect: Rect, children: []Transform_Handle, out: []Rect) -> bool

_canvas_layout_providers: [dynamic]Canvas_Layout_Provider

// Declares a layout provider, asked for every canvas node with its rect and
// its RectTransform children. It lays the node's children out and returns
// true, or returns false to leave them to their anchors. Process-global
// registry: never borrows the caller's allocator.
@(extension_point={attribute="canvas_layout", target="proc", fields=""})
canvas_layout_register :: proc(p: Canvas_Layout_Provider) {
	context.allocator = runtime.default_allocator()
	if _canvas_layout_providers == nil do _canvas_layout_providers = make([dynamic]Canvas_Layout_Provider)
	append(&_canvas_layout_providers, p)
}

// A component that sets its own node's rect (packages/mhgui
// ContentSizeFitter, AspectRatioFitter): asked for every node that resolves
// from its own anchors, with its parent's rect and the rect the anchors gave.
// A provider that sets the node's rect returns it and true. A node a layout
// container placed is not asked: the container's rect stands. A package
// declares one with @(canvas_rect) on the proc.
Canvas_Rect_Provider :: proc(tH: Transform_Handle, parent: Rect, rect: Rect) -> (Rect, bool)

_canvas_rect_providers: [dynamic]Canvas_Rect_Provider

// Declares a rect provider: a proc that may replace the rect a node's
// anchors gave it. Process-global registry: never borrows the caller's
// allocator.
@(extension_point={attribute="canvas_rect", target="proc", fields=""})
canvas_rect_register :: proc(p: Canvas_Rect_Provider) {
	context.allocator = runtime.default_allocator()
	if _canvas_rect_providers == nil do _canvas_rect_providers = make([dynamic]Canvas_Rect_Provider)
	append(&_canvas_rect_providers, p)
}

// How large a component wants its node to be, from what it holds: a Text
// from its string, an Image from its sprite. `width` is the width it has to
// fit in, for content that wraps, 0 or less for no limit.
Canvas_Measure_Proc :: proc(comp: rawptr, width: f32) -> [2]f32

// Declares `canvas_measure_<T>`, the proc that says how large a component of
// type T wants its node to be. T is a @(component) of the same package and
// the proc takes a ^T and the width to fit in. A type has at most one.
@(extension_point={attribute="canvas_measure", target="proc", fields=""})
canvas_measure_procs: [TypeKey]Canvas_Measure_Proc

canvas_measure_register :: proc(key: TypeKey, fn: Canvas_Measure_Proc) {
	canvas_measure_procs[key] = fn
}

// The size the node's content wants (canvas_measure), from the first enabled
// component on it that says. False when none does.
node_measure :: proc(tH: Transform_Handle, width: f32) -> (size: [2]f32, ok: bool) {
	w := ctx_world()
	t := pool_get(&w.transforms, Handle(tH))
	if t == nil do return
	for owned in t.components {
		fn := canvas_measure_procs[owned.handle.type_key]
		if fn == nil do continue
		c := world_pool_get(w, owned.handle)
		if c == nil || !(cast(^CompData)c).enabled do continue
		return fn(c, width), true
	}
	return
}

// Resolves the rect of the canvas node (always `root`, the canvas drives it)
// and of every active node under it, appended to `out` in draw order
// (Node_Rect). A node
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
		z:      i32,  // the parent's z
	}
	first := len(out)
	raised := false
	stack := make([dynamic]Entry, context.temp_allocator)
	append(&stack, Entry{tH = canvas_tH, parent = root, xform = linalg.MATRIX4F32_IDENTITY})
	children := make([dynamic]Transform_Handle, context.temp_allocator)
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
			// A component of the node may set its rect: a fitter.
			for p in _canvas_rect_providers {
				if fitted, ok := p(e.tH, e.parent, rect); ok {
					rect = fitted
					break
				}
			}
		}
		// The node's own rotation and scale, around its pivot, in the parent's
		// space. The canvas node itself never rotates (overlay).
		if rt != nil && e.tH != canvas_tH {
			rot := _quat_safe(t.rotation)
			if rot != QUAT_IDENTITY || t.scale != {1, 1, 1} || rt.anchored_position.z != 0 {
				xform = e.xform * rect_affine(rect.pos + rect.size * rt.pivot, rt.anchored_position.z, rot, t.scale)
			}
		}
		z := e.z
		if rt != nil do z += rt.z_index
		if z != 0 do raised = true
		append(out, Node_Rect{e.tH, rect, xform, e.laid, z})

		// A layout container arranges the active RectTransform children; the
		// rest pass the rect through as usual.
		clear(&children)
		for child in t.children {
			ch := Transform_Handle(child.handle)
			ct := pool_get(&w.transforms, Handle(ch))
			if ct == nil || !ct.is_active do continue
			if _, rt := transform_get_comp(ch, RectTransform); rt != nil && rt.enabled do append(&children, ch)
		}
		has_layout := false
		if len(children) > 0 {
			resize(&laid, len(children))
			for p in _canvas_layout_providers {
				if p(e.tH, rect, children[:], laid[:]) {
					has_layout = true
					break
				}
			}
		}

		// Pushed in reverse so the pop order is hierarchy order; laid-out
		// children take their slot in the order they were listed.
		slot := len(children) - 1
		#reverse for child in t.children {
			ch := Transform_Handle(child.handle)
			entry := Entry{tH = ch, parent = rect, xform = xform, z = z}
			if slot >= 0 && children[slot] == ch {
				if has_layout {
					entry.forced = laid[slot]
					entry.laid = true
				}
				slot -= 1
			}
			append(&stack, entry)
		}
	}
	// Stable: nodes of one z keep the hierarchy order.
	if raised do slice.stable_sort_by(out[first:], proc(a, b: Node_Rect) -> bool { return a.z < b.z })
}

// --- Position through the Transform API -----------------------------------------------------
//
// anchored_position is the stored value, the only one. The procs below are
// a second door into it: a set converts the given position into
// anchored_position, a read derives the position from it. Local positions
// are relative to the parent's pivot point, in the parent's space (its
// rotation and scale included), like localPosition under a RectTransform;
// z passes straight through as depth off the canvas plane. World positions
// are canvas-space points, the space the Scene window shows.

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
	canvas_resolve_placed(canvas, &nodes)
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
	material:       PPtr `ext:"mat"`, // shader/tint/properties; the quad's texture stays its own. empty = unlit
	raycast_target: bool, // takes pointer events (input)
}

// One quad in the node's rect space, canvas units, bottom-left origin.
//
// What a graphic emits: a rect (`pos`, `size`, with `skew` for italic text),
// or with `free` any four points (`corners`), which is how a graphic emits a
// mesh: a triangle is a quad with two corners at one point (graphic_triangle).
// With `colored` each corner has its own colour, which multiplies the
// graphic's: a gradient, a fade along an edge. With `absolute` the quad's
// colours stand as they are and only the alpha of the graphic's colour
// applies: a shadow or an outline behind a graphic keeps its own colour.
Graphic_Quad :: struct {
	pos:     [2]f32,
	size:    [2]f32,
	skew:    [2]f32, // x shift of the bottom and the top edge (italic text); zero = a rect
	corners: [4][2]f32, // free: bl, br, tr, tl in the node's space
	free:    bool,
	colors:  [4][4]f32, // colored: bl, br, tr, tl
	colored: bool,
	absolute: bool,
	uvs:     [4][2]f32, // bl, br, tr, tl
	texture: Asset_GUID,
	// The material the quad draws with when the graphic names none: a graphic
	// that needs its own shader (the mhgui UiShape) works with no setup.
	material:   Asset_GUID,
	// Values of that shader for this quad alone (Draw_Quad.properties). Frame
	// lifetime: populate allocates them with the temp allocator.
	properties: []Draw_Property,
}

// Appends a triangle: a free quad whose last two corners are one point. With
// `colors` each point has its own colour.
graphic_triangle :: proc(out: ^[dynamic]Graphic_Quad, points: [3][2]f32, uvs: [3][2]f32, texture: Asset_GUID, colors: ^[3][4]f32 = nil) {
	q := Graphic_Quad{
		free    = true,
		corners = {points[0], points[1], points[2], points[2]},
		uvs     = {uvs[0], uvs[1], uvs[2], uvs[2]},
		texture = texture,
	}
	if colors != nil {
		q.colored = true
		q.colors = {colors[0], colors[1], colors[2], colors[2]}
	}
	append(out, q)
}

// The four points of a quad in the node's space, whichever way it was given:
// bl, br, tr, tl.
graphic_quad_points :: proc(q: Graphic_Quad) -> [4][2]f32 {
	if q.free do return q.corners
	x0, y0 := q.pos.x, q.pos.y
	x1, y1 := x0 + q.size.x, y0 + q.size.y
	return {{x0 + q.skew[0], y0}, {x1 + q.skew[0], y0}, {x1 + q.skew[1], y1}, {x0 + q.skew[1], y1}}
}

// Changes the quads of the graphic on its node after the graphic made them:
// a shadow or an outline adds copies behind them, a gradient colours them.
Canvas_Effect_Proc :: proc(comp: rawptr, rect: Rect, quads: ^[dynamic]Graphic_Quad)

// Declares `canvas_effect_<T>`, the proc that changes the quads of the
// graphic on the node a component of type T is on. T is a @(component) of
// the same package and the proc takes a ^T, the node's rect and the quads.
// Effects on one node run in the order of its components.
@(extension_point={attribute="canvas_effect", target="proc", fields=""})
canvas_effect_procs: [TypeKey]Canvas_Effect_Proc

@(private = "file")
_canvas_effects_any: bool

canvas_effect_register :: proc(key: TypeKey, fn: Canvas_Effect_Proc) {
	canvas_effect_procs[key] = fn
	_canvas_effects_any = true
}

// Runs the effects on a node over its graphic's quads.
node_effects :: proc(tH: Transform_Handle, rect: Rect, quads: ^[dynamic]Graphic_Quad) {
	if !_canvas_effects_any do return
	w := ctx_world()
	t := pool_get(&w.transforms, Handle(tH))
	if t == nil do return
	for owned in t.components {
		fn := canvas_effect_procs[owned.handle.type_key]
		if fn == nil do continue
		c := world_pool_get(w, owned.handle)
		if c == nil || !(cast(^CompData)c).enabled do continue
		fn(c, rect, quads)
	}
}

// The quad's corners through the node's transform, skew applied.
graphic_quad_corners :: proc(q: Graphic_Quad, m: matrix[4, 4]f32) -> [4][3]f32 {
	if q.free {
		return {rect_apply(m, q.corners[0]), rect_apply(m, q.corners[1]), rect_apply(m, q.corners[2]), rect_apply(m, q.corners[3])}
	}
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
// transform, the canvas scale and the view. A package declares one with
// @(canvas_graphic) on `canvas_populate_<T>`, which takes a ^T: the
// generated registration (canvas_gen) writes this descriptor around it.
Graphic_Desc :: struct {
	key:            TypeKey,
	graphic_offset: uintptr, // offset_of(T, graphic)
	populate:       proc(comp: rawptr, rect: Rect, out: ^[dynamic]Graphic_Quad),
}

_canvas_graphics: [dynamic]Graphic_Desc

// Declares `canvas_populate_<T>`, the proc that appends the quads a canvas
// component of type T draws inside its resolved rect. T is a struct of the
// same package with a `graphic` field, and the proc takes a ^T. Process-global
// registry: never borrows the caller's allocator.
@(extension_point={attribute="canvas_graphic", target="proc", fields=""})
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

// The materials already named as drawing whole under a mask.
@(private = "file")
_unclipped_named: map[Asset_GUID]bool

// Says once, in the Console, that a material under a UiMask draws whole
// because its shader has no UI clip: the project's UiMask setting on Manual
// Include with a shader that never calls ui_clip(), or the built-in lit
// shader.
@(private = "file")
_warn_unclipped :: proc(material: Asset_GUID, node: Transform_Handle) {
	if material == {} || material in _unclipped_named || material_clips_ui(material) do return
	context.allocator = runtime.default_allocator()
	_unclipped_named[material] = true
	path, _ := asset_db_get_path(uuid.Identifier(material))
	name := "?"
	if t := pool_get(&ctx_world().transforms, Handle(node)); t != nil do name = t.name
	log.warningf("[UiMask] The material %s on '%s' is under a UiMask and draws whole: its shader has no UI clip. Add #include \"ui_clip.glsl\" and multiply the output's alpha by ui_clip(), or set Project Settings, UiMask to Auto Inject", path, name)
}

// The top of the transparent-sort range: every canvas draws after every
// sprite and particle. Canvases order by sort_order inside it, nodes by
// their index in the rect walk (draw order: z_index, then hierarchy order).
CANVAS_SORTING_LAYER :: i32(127)

// The canvas collector (render_collect_commands): Game windows draw each
// canvas over the viewport, canvas units mapped to pixels through the canvas
// scale and onto the near plane; the Scene window draws it as the world rect
// at the origin. Previews show neither. One Draw_Quad per graphic quad, in
// the graphic's color and material.
@(render_collector)
canvas_collect_graphics :: proc(view: Render_View, out: ^[dynamic]Render_Command) {
	if view.kind == .Preview || len(_canvas_graphics) == 0 do return
	w := ctx_world()
	stacks := make(map[Transform_Handle][]gfx.Clip_Mask, context.temp_allocator)

	it := pool_iterator(canvases(w))
	for canvas, _ in pool_next(&it) {
		if !canvas.enabled do continue
		ct := pool_get(&w.transforms, Handle(canvas.owner))
		if ct == nil || !transform_active_in_hierarchy(canvas.owner) do continue
		if ct.render_layer & view.layer_mask == 0 do continue

		// A camera-space canvas is drawn by its camera only.
		if canvas.render_mode == .ScreenSpaceCamera && view.kind == .Game {
			if cam_tH := Transform_Handle(canvas.render_camera.handle); cam_tH != {} && cam_tH != view.camera do continue
		}
		screen := [2]f32{view.width, view.height} if view.kind == .Game else _canvas_game_viewport
		root, canvas_xform, in_world := canvas_placement(canvas.owner, screen)
		scale := canvas_scale(canvas.owner, screen)
		// What the canvas draws, kept while nothing under it changes
		// (ui_canvas_cache.odin). The rest of this places it in the view.
		kept := _canvas_kept(canvas.owner, root, screen)
		pixels := Canvas_Pixels{view = view, overlay = !in_world && view.kind == .Game, scale = scale, to_world = canvas_xform if in_world else 1}
		clear(&stacks)
		overlay := !in_world && view.kind == .Game
		reserve(out, len(out) + len(kept.quads))
		for n in kept.drawn {
			// The masks above it. Nodes under the same nearest mask are under
			// the same masks, and share one slice so their quads merge.
			clip: []gfx.Clip_Mask
			if n.mask != {} {
				shared, known := stacks[n.mask]
				if !known {
					shared = canvas_clip_stack(pixels, n.tH, kept.nodes[:])
					stacks[n.mask] = shared
				}
				clip = shared
			}
			key: Sort_Key
			key[0] = sort_key_word(CANVAS_SORTING_LAYER, canvas.sort_order, 0, u16(n.index))
			xform := canvas_xform * n.xform if in_world else n.xform
			// Once a node, not once a quad: a Text is a quad a glyph.
			if len(clip) > 0 do _warn_unclipped(kept.quads[n.first].material, n.tH)
			for q in kept.quads[n.first:][:n.count] {
				corners := graphic_quad_corners(q, xform)
				if overlay {
					px: [4][2]f32
					for c, k in corners do px[k] = c.xy * scale
					corners = canvas_view_corners(view, px)
				}
				append(out, Render_Command{
					key     = key,
					owner   = n.tH,
					variant = Draw_Quad{
						texture  = q.texture,
						material = q.material,
						corners  = corners,
						uvs      = q.uvs,
						color    = n.color if !q.absolute else {1, 1, 1, n.color.a},
						colors   = q.colors,
						colored  = q.colored,
						properties = q.properties,
						clip     = clip,
					},
				})
			}
		}
	}
}

// The point of a canvas under a viewport point (pixels, y down), in canvas
// units with y up, in any render mode: an overlay canvas maps through its
// scale, a canvas in the world or before a camera through the camera's ray
// against its plane. False when the ray misses the plane or there is no
// camera.
canvas_point_at :: proc(canvas_tH: Transform_Handle, point: [2]f32, viewport: [2]f32) -> (cp: [2]f32, ok: bool) {
	_, xform, in_world := canvas_placement(canvas_tH, viewport)
	if !in_world {
		scale := canvas_scale(canvas_tH, viewport)
		// Viewport y is down, canvas y is up.
		return {point.x / scale, (viewport.y - point.y) / scale}, true
	}
	// The pointer's camera ray against the canvas plane, in canvas units.
	_, canvas := transform_get_comp(canvas_tH, Canvas)
	cam := camera_active()
	if canvas != nil && canvas.render_mode == .ScreenSpaceCamera {
		if _, rc := transform_get_comp(Transform_Handle(canvas.render_camera.handle), Camera); rc != nil do cam = rc
	}
	if cam == nil do return {}, false
	ray := camera_screen_ray(cam, point, viewport)
	origin := (xform * [4]f32{0, 0, 0, 1}).xyz
	normal := linalg.normalize0((xform * [4]f32{0, 0, 1, 0}).xyz)
	denom := linalg.dot(ray.direction, normal)
	if math.abs(denom) < 1e-6 do return {}, false
	t := linalg.dot(origin - ray.origin, normal) / denom
	if t < 0 do return {}, false
	local := linalg.inverse(xform) * [4]f32{ray.origin.x + ray.direction.x * t, ray.origin.y + ray.direction.y * t, ray.origin.z + ray.direction.z * t, 1}
	return local.xy, true
}

