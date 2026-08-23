package sprites

// The sprite render collector — the first package consumer of the renderer
// seam (engine.render_register_collector, docs/SDL3Renderer.md "Render
// commands"). The package owns the SpriteRenderer pool and emits Draw_Quad
// commands; the engine sorts and submits them.

import "moonhug:engine"

// The world-space quad and uvs a SpriteRenderer covers: bl, br, tr, tl. One
// resolve shared by command collection, scene picking and thumbnails so they
// can't diverge. Sprites are transform-oriented (not billboards), sized
// px/pixels_per_unit — the texture's import setting (Unity's Pixels Per
// Unit, default 100). sprite.local_id == 0 covers the whole texture
// (Unity's Single mode, center pivot). An id that no slice carries returns
// ok=false — the sprite renders nothing, like Unity's missing sprite.
sprite_quad :: proc(sr: ^SpriteRenderer, tw: engine.Transform_World, tex: ^engine.Texture2D) -> (corners: [4][3]f32, uvs: [4][2]f32, ok: bool) {
	rect := [4]f32{0, 0, f32(tex.width), f32(tex.height)}
	pivot := [2]f32{0.5, 0.5}
	if sr.sprite.local_id != 0 {
		s, found := engine.texture_sprite_rect(tex, sr.sprite.local_id)
		if !found do return {}, {}, false
		rect = s.rect
		pivot = s.pivot
	}

	ppu := max(tex.pixels_per_unit, 0.0001)
	w := tw.scale.x * rect.z / ppu
	h := tw.scale.y * rect.w / ppu
	rot := engine.quat_to_matrix3(tw.rotation)
	right := [3]f32{rot[0, 0], rot[1, 0], rot[2, 0]}
	up := [3]f32{rot[0, 1], rot[1, 1], rot[2, 1]}
	// The transform sits at the pivot: {0, 0} = bottom-left of the rect.
	bl := tw.position - right * (pivot.x * w) - up * (pivot.y * h)
	corners = {
		bl,
		bl + right * w,
		bl + right * w + up * h,
		bl + up * h,
	}

	// Pixel rect (top-left origin, y down) -> normalized uvs. uv origin is
	// top-left too, so the rect's top edge is the smaller v.
	u0 := rect.x / f32(tex.width)
	u1 := (rect.x + rect.z) / f32(tex.width)
	v_top := rect.y / f32(tex.height)
	v_bottom := (rect.y + rect.w) / f32(tex.height)
	uvs = {{u0, v_bottom}, {u1, v_bottom}, {u1, v_top}, {u0, v_top}}
	return corners, uvs, true
}

_collect_sprites :: proc(view: engine.Render_View, out: ^[dynamic]engine.Render_Command) {
	w := engine.ctx_world()

	// One tree pass resolves every sprite's sort key (groups folded in).
	sort_keys := sprite_sort_build_keys(view)

	sr_it := engine.pool_iterator(sprite_renderers(w))
	for sr, _ in engine.pool_next(&sr_it) {
		if !sr.enabled do continue
		if engine.asset_guid_is_empty(sr.sprite.guid) do continue

		t := engine.pool_get(&w.transforms, engine.Handle(sr.owner))
		if t == nil || !engine.transform_active_in_hierarchy(sr.owner) do continue
		if t.render_layer & view.layer_mask == 0 do continue

		tex, ok := engine.texture_load(sr.sprite.guid)
		if !ok do continue

		tw := engine.transform_world(engine.Transform_Handle(sr.owner))
		corners, uvs, quad_ok := sprite_quad(sr, tw, tex)
		if !quad_ok do continue

		key, in_tree := sort_keys[engine.Transform_Handle(sr.owner)]
		if !in_tree do key = sprite_sort_orphan_key(view, sr)
		append(out, engine.Render_Command{
			key     = key,
			variant = engine.Draw_Quad{
				texture  = sr.sprite.guid,
				material = sr.material,
				corners  = corners,
				uvs      = uvs,
				color    = sr.color,
			},
		})
	}
}

// ImportersInit is the asset-layer init phase both binaries run (the editor
// via phase_editor_run, the app via app_init) — same slot the animation
// package uses.
@(phase={key=ImportersInit, order=2})
sprites_package_init :: proc() {
	@(static) done := false
	if done do return
	done = true
	engine.render_register_collector(_collect_sprites)
}
