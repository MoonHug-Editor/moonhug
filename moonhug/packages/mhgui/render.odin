package mhgui

// The UI render collector (engine.render_register_collector,
// docs/SDL3Renderer.md "Render collectors"). Each frame it resolves every
// canvas's rects and emits one Draw_Quad per CanvasRenderer, placed on a
// plane just inside the view's near plane so the quad lands on exactly its
// canvas pixels and nothing in the scene can draw in front of it.

import "core:encoding/uuid"
import "moonhug:engine"

// The top of the transparent-sort range: every canvas draws after every
// sprite and particle. Canvases order by sort_order inside it, elements by
// tree order.
UI_SORTING_LAYER :: i32(127)

// z01 NDC depth of the canvas plane: just inside the near plane (0).
_CANVAS_NDC_Z :: f32(0.0005)

// The package's white texture (assets/white.png, meta committed with it):
// what an untextured CanvasRenderer draws.
WHITE_TEXTURE_GUID :: "6ae7892c-14e2-4fc9-93ae-bf60599a235a"

white_texture_guid :: proc() -> engine.Asset_GUID {
	@(static) guid: engine.Asset_GUID
	if engine.asset_guid_is_empty(guid) {
		if g, err := uuid.read(WHITE_TEXTURE_GUID); err == nil do guid = engine.Asset_GUID(g)
	}
	return guid
}

// The viewport as the canvas rect (Screen Space - Overlay).
canvas_rect :: proc(view: engine.Render_View) -> Rect {
	return Rect{pos = {0, 0}, size = {view.width, view.height}}
}

// One resolved node, in draw order (parents before children, siblings in
// hierarchy order — the canvas draw order).
Node_Rect :: struct {
	tH:   engine.Transform_Handle,
	rect: Rect,
}

// Resolves the rect of the canvas node (always `root`, the canvas drives it)
// and of every active node under it, appended to `out` in draw order. A node
// without a RectTransform passes its parent's rect through, so plain grouping
// nodes cost nothing. Inactive nodes and their subtrees are skipped.
canvas_resolve_rects :: proc(canvas_tH: engine.Transform_Handle, root: Rect, out: ^[dynamic]Node_Rect) {
	w := engine.ctx_world()
	Entry :: struct {
		tH:     engine.Transform_Handle,
		parent: Rect,
	}
	stack := make([dynamic]Entry, context.temp_allocator)
	append(&stack, Entry{canvas_tH, root})
	for len(stack) > 0 {
		e := pop(&stack)
		t := engine.pool_get(&w.transforms, engine.Handle(e.tH))
		if t == nil || !t.is_active do continue
		rect := e.parent
		if e.tH != canvas_tH {
			if _, rt := get_comp(e.tH, RectTransform); rt != nil && rt.enabled {
				rect = rect_resolve(e.parent, rt)
			}
		}
		append(out, Node_Rect{e.tH, rect})
		// Pushed in reverse so the pop order is hierarchy order.
		#reverse for child in t.children {
			append(&stack, Entry{engine.Transform_Handle(child.handle), rect})
		}
	}
}

// The world-space quad a canvas rect covers in `view`: the rect's pixel
// corners unprojected onto the canvas plane. bl, br, tr, tl like Draw_Quad.
canvas_quad_corners :: proc(view: engine.Render_View, r: Rect) -> [4][3]f32 {
	x0, y0 := r.pos.x, r.pos.y
	x1, y1 := x0 + r.size.x, y0 + r.size.y
	return {
		_canvas_to_world(view, {x0, y0}),
		_canvas_to_world(view, {x1, y0}),
		_canvas_to_world(view, {x1, y1}),
		_canvas_to_world(view, {x0, y1}),
	}
}

// Canvas pixel -> world point on the canvas plane. Canvas y is up, like NDC.
_canvas_to_world :: proc(view: engine.Render_View, p: [2]f32) -> [3]f32 {
	ndc_x := 2 * p.x / max(view.width, 1) - 1
	ndc_y := 2 * p.y / max(view.height, 1) - 1
	h := view.inv_view_proj * [4]f32{ndc_x, ndc_y, _CANVAS_NDC_Z, 1}
	return h.xyz / h.w
}

// Game views only: the scene view and previews show the world, not the HUD.
collect_canvases :: proc(view: engine.Render_View, out: ^[dynamic]engine.Render_Command) {
	if view.kind != .Game do return
	w := engine.ctx_world()
	root := canvas_rect(view)
	nodes := make([dynamic]Node_Rect, context.temp_allocator)

	it := engine.pool_iterator(canvases(w))
	for canvas, _ in engine.pool_next(&it) {
		if !canvas.enabled do continue
		t := engine.pool_get(&w.transforms, engine.Handle(canvas.owner))
		if t == nil || !engine.transform_active_in_hierarchy(canvas.owner) do continue
		if t.render_layer & view.layer_mask == 0 do continue

		clear(&nodes)
		canvas_resolve_rects(canvas.owner, root, &nodes)
		seq: u16
		for n in nodes {
			_, cr := get_comp(n.tH, CanvasRenderer)
			if cr == nil || !cr.enabled do continue
			tex := cr.texture
			if engine.asset_guid_is_empty(tex) do tex = white_texture_guid()
			key: engine.Sort_Key
			key[0] = engine.sort_key_word(UI_SORTING_LAYER, canvas.sort_order, 0, seq)
			seq += 1
			append(out, engine.Render_Command{
				key     = key,
				variant = engine.Draw_Quad{
					texture = tex,
					corners = canvas_quad_corners(view, n.rect),
					uvs     = engine.QUAD_UVS_FULL,
					color   = cr.color,
				},
			})
		}
	}
}

// ImportersInit is the asset-layer init phase both binaries run — the slot
// the sprites collector registers in.
@(phase={key=ImportersInit, order=2})
mhgui_package_init :: proc() {
	@(static) done := false
	if done do return
	done = true
	engine.render_register_collector(collect_canvases)
}
