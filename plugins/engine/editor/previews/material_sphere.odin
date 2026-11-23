package previews

// A material shown on a sphere: its thumbnail, and its live preview in the
// inspector, orbited like a model's. The sphere is made once, here, so the
// engine's previews need no mesh asset from a plugin.

import "core:math"
import "core:math/linalg"
import engine "moonhug:packages/engine"
import gfx "moonhug:libs/gfx"
import "moonhug:editor/thumbnails"

@(private = "file") _sphere: gfx.Mesh
@(private = "file") _sphere_made: bool

// A unit sphere with normals, uvs (u around, v from the top down) and
// tangents along u, for a material's normal map.
@(private = "file")
_material_sphere :: proc() -> gfx.Mesh {
	if _sphere_made do return _sphere
	AROUND :: 48
	DOWN :: 24
	vertices := make([dynamic]gfx.Vertex, 0, (AROUND + 1) * (DOWN + 1), context.temp_allocator)
	indices := make([dynamic]u32, 0, AROUND * DOWN * 6, context.temp_allocator)
	for row in 0 ..= DOWN {
		v := f32(row) / DOWN
		theta := v * math.PI
		for col in 0 ..= AROUND {
			u := f32(col) / AROUND
			phi := u * math.TAU
			p := [3]f32{math.sin(theta) * math.cos(phi), math.cos(theta), math.sin(theta) * math.sin(phi)}
			append(&vertices, gfx.Vertex{
				position = p,
				normal   = p,
				uv       = {u, v},
				color    = {255, 255, 255, 255},
				tangent  = {-math.sin(phi), 0, math.cos(phi), 1},
			})
		}
	}
	for row in 0 ..< DOWN {
		for col in 0 ..< AROUND {
			a := u32(row * (AROUND + 1) + col)
			b := a + AROUND + 1
			append(&indices, a, a + 1, b, a + 1, b + 1, b)
		}
	}
	_sphere = gfx.mesh_create(vertices[:], indices[:])
	_sphere_made = true
	return _sphere
}

material_sphere_shutdown :: proc() {
	if !_sphere_made do return
	gfx.mesh_destroy(&_sphere)
	_sphere_made = false
}

// Draws the sphere with the material `guid` into the open pass, lit by a
// light from the camera. `forward` is the camera's direction.
_material_sphere_draw :: proc(guid: engine.Asset_GUID) {
	shader, tex, color, data, extra := engine.material_resolve_draw(guid)
	gfx.draw_mesh(_material_sphere(), tex, linalg.MATRIX4F32_IDENTITY, color, shader, 0, 0, data, extra)
}

// The thumbnail: the sphere from the three-quarter view a model's part has.
_thumb_render_material :: proc(path: string, guid: engine.Asset_GUID, sub: engine.Local_ID, target: ^gfx.Render_Target) -> bool {
	forward := linalg.normalize([3]f32{-1, -0.7, -1})
	fov := math.to_radians(f32(35))
	dist := 1 / math.sin(fov * 0.5) * 1.05
	view := linalg.matrix4_look_at_f32(-forward * dist, [3]f32{}, [3]f32{0, 1, 0})
	proj := gfx.matrix4_perspective_z01(fov, 1, max(dist - 2, 0.01), dist + 2)
	rv := engine.render_view_make(view, proj, thumbnails.SIZE, thumbnails.SIZE, _THUMB_LAYER, .Preview)

	gfx.set_lights([]gfx.Light{{kind = .Directional, direction = forward, color = {1, 1, 1}, intensity = 1, culling_mask = ~u32(0)}}, 0.35)
	gfx.pass_begin_target(target, [4]f32{0.16, 0.16, 0.18, 1})
	gfx.set_view_proj(rv.view_proj, rv.cam_pos)
	_material_sphere_draw(guid)
	gfx.pass_end()
	gfx.set_lights_default()
	return true
}
