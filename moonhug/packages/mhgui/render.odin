package mhgui

// mhgui — the drawing half of UI (docs/Gui.md). The canvas tree (Canvas,
// RectTransform, CanvasRenderer, CanvasScaler and the rect walk) is engine
// vocabulary (engine/ui_canvas.odin); this package owns the graphics (Image)
// and the render collector (engine.render_register_collector) that turns a
// canvas into Draw_Quad commands, plus the LayoutGroup container.

import "core:encoding/uuid"
import "moonhug:engine"

// The top of the transparent-sort range: every canvas draws after every
// sprite and particle. Canvases order by sort_order inside it, elements by
// tree order.
UI_SORTING_LAYER :: i32(127)

// z01 NDC depth of the canvas plane in a Game view: just inside the near
// plane (0), so nothing in the scene passes the depth test in front of it.
_CANVAS_NDC_Z :: f32(0.0005)

// The package's white texture (assets/white.png, meta committed with it):
// what an Image without a sprite draws.
WHITE_TEXTURE_GUID :: "6ae7892c-14e2-4fc9-93ae-bf60599a235a"

white_texture_guid :: proc() -> engine.Asset_GUID {
	@(static) guid: engine.Asset_GUID
	if engine.asset_guid_is_empty(guid) {
		if g, err := uuid.read(WHITE_TEXTURE_GUID); err == nil do guid = engine.Asset_GUID(g)
	}
	return guid
}

// The world-space quad screen-pixel corners cover in a Game view: each
// unprojected onto the canvas plane, so the quad lands on exactly those
// pixels whatever the camera does. bl, br, tr, tl.
canvas_quad_corners :: proc(view: engine.Render_View, c: [4][2]f32) -> [4][3]f32 {
	return {
		_canvas_to_world(view, c[0]),
		_canvas_to_world(view, c[1]),
		_canvas_to_world(view, c[2]),
		_canvas_to_world(view, c[3]),
	}
}

// Screen pixel -> world point on the canvas plane. Canvas y is up, like NDC.
_canvas_to_world :: proc(view: engine.Render_View, p: [2]f32) -> [3]f32 {
	ndc_x := 2 * p.x / max(view.width, 1) - 1
	ndc_y := 2 * p.y / max(view.height, 1) - 1
	h := view.inv_view_proj * [4]f32{ndc_x, ndc_y, _CANVAS_NDC_Z, 1}
	return h.xyz / h.w
}

// Game views draw each canvas over the viewport, canvas units mapped to
// pixels through the canvas scale. The scene view draws it as the world rect
// at the origin (engine.canvas_world_rect), where the rect tool lives.
// Previews show neither.
collect_canvases :: proc(view: engine.Render_View, out: ^[dynamic]engine.Render_Command) {
	if view.kind == .Preview do return
	w := engine.ctx_world()
	nodes := make([dynamic]engine.Node_Rect, context.temp_allocator)

	it := engine.pool_iterator(engine.canvases(w))
	for canvas, _ in engine.pool_next(&it) {
		if !canvas.enabled do continue
		t := engine.pool_get(&w.transforms, engine.Handle(canvas.owner))
		if t == nil || !engine.transform_active_in_hierarchy(canvas.owner) do continue
		if t.render_layer & view.layer_mask == 0 do continue

		root: engine.Rect
		scale := f32(1)
		if view.kind == .Game {
			root = engine.canvas_rect(view, canvas.owner)
			scale = engine.canvas_scale(canvas.owner, {view.width, view.height})
		} else {
			root = engine.canvas_world_rect(canvas.owner)
		}
		clear(&nodes)
		engine.canvas_resolve_rects(canvas.owner, root, &nodes)
		seq: u16
		for n in nodes {
			_, cr := engine.transform_get_comp(n.tH, engine.CanvasRenderer)
			if cr == nil || !cr.enabled do continue
			_, img := get_comp(n.tH, Image)
			if img == nil || !img.enabled do continue
			tex, px, tex_size, ok := image_source(img)
			if !ok do continue
			rect := image_fit(n.rect, {px.z, px.w}, img.preserve_aspect)
			corners := engine.rect_corners(rect, n.xform) // canvas units, rotation and scale applied
			// Overlay draws orthographically: a tilt out of the plane foreshortens.
			screen: [4][2]f32
			for c, i in corners do screen[i] = c.xy * scale
			key: engine.Sort_Key
			key[0] = engine.sort_key_word(UI_SORTING_LAYER, canvas.sort_order, 0, seq)
			seq += 1
			append(out, engine.Render_Command{
				key     = key,
				variant = engine.Draw_Quad{
					texture = tex,
					corners = canvas_quad_corners(view, screen) if view.kind == .Game else corners,
					uvs     = image_uvs(tex_size, px),
					color   = img.color,
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
	engine.canvas_layout_register(layout_provider)
}
