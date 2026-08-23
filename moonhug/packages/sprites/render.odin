package sprites

// The sprite render collector — the first package consumer of the renderer
// seam (engine.render_register_collector, docs/SDL3Renderer.md "Render
// commands"). The package owns the SpriteRenderer pool and emits Draw_Quad
// commands; the engine sorts and submits them.

import "moonhug:engine"

// The world-space quad a SpriteRenderer covers: bl, br, tr, tl. Used by BOTH
// command collection and scene picking so they can't diverge. Sprites are
// transform-oriented (not billboards), sized tex_pixels/pixels_per_unit —
// the texture's import setting (Unity's Pixels Per Unit, default 100).
sprite_world_corners :: proc(tw: engine.Transform_World, tex: ^engine.Texture2D) -> [4][3]f32 {
	ppu := max(tex.pixels_per_unit, 0.0001)
	half_w := tw.scale.x * f32(tex.width) / (2.0 * ppu)
	half_h := tw.scale.y * f32(tex.height) / (2.0 * ppu)
	rot := engine.quat_to_matrix3(tw.rotation)
	right := [3]f32{rot[0, 0], rot[1, 0], rot[2, 0]}
	up := [3]f32{rot[0, 1], rot[1, 1], rot[2, 1]}
	pos := tw.position
	return {
		pos - right * half_w - up * half_h,
		pos + right * half_w - up * half_h,
		pos + right * half_w + up * half_h,
		pos - right * half_w + up * half_h,
	}
}

_collect_sprites :: proc(view: engine.Render_View, out: ^[dynamic]engine.Render_Command) {
	w := engine.ctx_world()

	// One tree pass resolves every sprite's sort key (groups folded in).
	sort_keys := sprite_sort_build_keys(view)

	sr_it := engine.pool_iterator(sprite_renderers(w))
	for sr, _ in engine.pool_next(&sr_it) {
		if !sr.enabled do continue
		if sr.texture == {} do continue

		t := engine.pool_get(&w.transforms, engine.Handle(sr.owner))
		if t == nil || !engine.transform_active_in_hierarchy(sr.owner) do continue
		if t.render_layer & view.layer_mask == 0 do continue

		tex, ok := engine.texture_load(sr.texture)
		if !ok do continue

		tw := engine.transform_world(engine.Transform_Handle(sr.owner))
		key, in_tree := sort_keys[engine.Transform_Handle(sr.owner)]
		if !in_tree do key = sprite_sort_orphan_key(view, sr)
		append(out, engine.Render_Command{
			key     = key,
			variant = engine.Draw_Quad{
				texture  = sr.texture,
				material = sr.material,
				corners  = sprite_world_corners(tw, tex),
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
