package engine

import rl "vendor:raylib"
import gl "vendor:raylib/rlgl"

render_world_cameras :: proc() {
	world := ctx_world()

	best_idx := -1
	best_order: i32 = min(i32)
	for i in 0 ..< len(world.cameras.slots) {
		slot := &world.cameras.slots[i]
		if !slot.alive do continue
		cam := &slot.data
		if !cam.enabled do continue
		if !transform_active_in_hierarchy(cam.owner) do continue
		if cam.order > best_order {
			best_order = cam.order
			best_idx = i
		}
	}

	if best_idx < 0 do return

	cam := &world.cameras.slots[best_idx].data

	cc := cam.clear_color
	rl.ClearBackground({u8(cc[0] * 255), u8(cc[1] * 255), u8(cc[2] * 255), u8(cc[3] * 255)})

	tw := transform_world(Transform_Handle(cam.owner))
	rot := quat_to_matrix3(tw.rotation)
	forward := rl.Vector3{-rot[0, 2], -rot[1, 2], -rot[2, 2]}
	up := rl.Vector3{rot[0, 1], rot[1, 1], rot[2, 1]}
	pos := rl.Vector3{tw.position.x, tw.position.y, tw.position.z}

	cam3d := rl.Camera3D{
		position   = pos,
		target     = pos + forward,
		up         = up,
		fovy       = cam.fov,
		projection = .PERSPECTIVE,
	}

	rl.BeginMode3D(cam3d)
	render_sprite_renderers(cam.render_layer_mask)
	rl.EndMode3D()
}

render_sprite_renderers :: proc(layer_mask: u32) {
	world := ctx_world()
	for i in 0 ..< len(world.sprite_renderers.slots) {
		slot := &world.sprite_renderers.slots[i]
		if !slot.alive do continue
		sr := &slot.data
		if !sr.enabled do continue
		if sr.texture == {} do continue

		t := pool_get(&world.transforms, Handle(sr.owner))
		if t == nil || !transform_active_in_hierarchy(sr.owner) do continue
		if t.render_layer & layer_mask == 0 do continue

		tex, ok := texture_load(sr.texture)
		if !ok do continue

		tw := transform_world(Transform_Handle(sr.owner))
		pos := rl.Vector3{tw.position.x, tw.position.y, tw.position.z}
		tint := rl.Color{
			u8(sr.color[0] * 255),
			u8(sr.color[1] * 255),
			u8(sr.color[2] * 255),
			u8(sr.color[3] * 255),
		}

		PIXELS_PER_UNIT :: 100.0
		half_w := tw.scale.x * f32(tex.width) / (2.0 * PIXELS_PER_UNIT)
		half_h := tw.scale.y * f32(tex.height) / (2.0 * PIXELS_PER_UNIT)

		rot := quat_to_matrix3(tw.rotation)
		right := rl.Vector3{rot[0, 0], rot[1, 0], rot[2, 0]}
		up := rl.Vector3{rot[0, 1], rot[1, 1], rot[2, 1]}

		p0 := pos - right * half_w - up * half_h
		p1 := pos + right * half_w - up * half_h
		p2 := pos + right * half_w + up * half_h
		p3 := pos - right * half_w + up * half_h

		gl.SetTexture(tex.rl_texture.id)
		gl.Begin(gl.QUADS)
		gl.Color4ub(tint.r, tint.g, tint.b, tint.a)

		gl.TexCoord2f(0, 1)
		gl.Vertex3f(p0.x, p0.y, p0.z)
		gl.TexCoord2f(1, 1)
		gl.Vertex3f(p1.x, p1.y, p1.z)
		gl.TexCoord2f(1, 0)
		gl.Vertex3f(p2.x, p2.y, p2.z)
		gl.TexCoord2f(0, 0)
		gl.Vertex3f(p3.x, p3.y, p3.z)

		gl.End()
		gl.SetTexture(0)
	}
}
