package previews

// A material shown on a shape: on a sphere in its thumbnail, and on the shape
// the preview settings pick in its live preview in the inspector, orbited
// like a model's. The shapes are made here, once each, so the engine's
// previews need no mesh asset from a plugin.

import "core:math"
import "core:math/linalg"
import engine "moonhug:packages/engine"
import gfx "moonhug:libs/gfx"
import "moonhug:editor/thumbnails"

// The shapes a material previews on.
Preview_Shape :: enum u8 {
	// The shader ball, the shape a material shows on first: a ball with a
	// slice cut off at an angle and a smaller ball inside the cut, on a
	// short neck over a small base, and a collar around the base with a
	// chamfered edge and a quarter cut out on the side the slice faces.
	// One picture shows curved parts, flat parts at several angles and
	// sharp edges.
	Collar,
	Sphere,
	Cube,
	Plane,
	// The plain shader ball: the same ball over a wide low base, with no
	// collar. Kept, and not offered in the preview's buttons.
	Ball,
}

@(private = "file") _sphere: gfx.Mesh
@(private = "file") _sphere_made: bool
@(private = "file") _shapes: [Preview_Shape]gfx.Mesh

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

// A cube of half size 0.6, a plane of half size 1 facing up, or the shader
// ball, each part with its own normals, uvs and a tangent along u. The plane
// is also the floor under the 3D previews.
_material_shape :: proc(shape: Preview_Shape) -> gfx.Mesh {
	if shape == .Sphere do return _material_sphere()
	if _shapes[shape].vbuf != nil do return _shapes[shape]
	vertices := make([dynamic]gfx.Vertex, context.temp_allocator)
	indices := make([dynamic]u32, context.temp_allocator)
	// One face: `n` its normal, `u` and `v` its axes along the uvs, `h` the half size.
	face :: proc(vertices: ^[dynamic]gfx.Vertex, indices: ^[dynamic]u32, n, u, v: [3]f32, h: f32) {
		base := u32(len(vertices))
		corners := [4][2]f32{{-1, -1}, {1, -1}, {1, 1}, {-1, 1}}
		for c in corners {
			append(vertices, gfx.Vertex{
				position = (n + u * c.x + v * c.y) * h,
				normal   = n,
				uv       = {(c.x + 1) * 0.5, (1 - c.y) * 0.5},
				color    = {255, 255, 255, 255},
				tangent  = {u.x, u.y, u.z, 1},
			})
		}
		append(indices, base, base + 1, base + 2, base, base + 2, base + 3)
	}
	// A profile turned around Y: points (radius, height) with their normals
	// in the same plane, in the order that keeps the solid on the left. A
	// crease is a point given twice with two normals. v runs along the
	// profile's length. `axis` tilts the turned part (its Y goes along
	// `axis`) and `offset` moves it. `from` and `sweep` turn it only part
	// of the way around, with open ends.
	lathe :: proc(vertices: ^[dynamic]gfx.Vertex, indices: ^[dynamic]u32, profile: [][4]f32, axis := [3]f32{0, 1, 0}, offset := [3]f32{}, from: f32 = 0, sweep: f32 = math.TAU) {
		rot := linalg.MATRIX3F32_IDENTITY
		if axis != {0, 1, 0} {
			x := linalg.normalize(linalg.cross([3]f32{0, 1, 0}, axis))
			z := linalg.cross(x, axis)
			rot = matrix[3, 3]f32{x.x, axis.x, z.x, x.y, axis.y, z.y, x.z, axis.z, z.z}
		}
		first := u32(len(vertices))
		AROUND :: 64
		length := f32(0)
		for i in 1 ..< len(profile) do length += linalg.length(profile[i].xy - profile[i - 1].xy)
		at := f32(0)
		for pt, row in profile {
			if row > 0 do at += linalg.length(pt.xy - profile[row - 1].xy)
			for col in 0 ..= AROUND {
				u := f32(col) / AROUND
				phi := from + u * sweep
				cs, sn := math.cos(phi), math.sin(phi)
				append(vertices, gfx.Vertex{
					position = rot * [3]f32{pt.x * cs, pt.y, pt.x * sn} + offset,
					normal   = rot * linalg.normalize([3]f32{pt.z * cs, pt.w, pt.z * sn}),
					uv       = {u * 2, 1 - at / length},
					color    = {255, 255, 255, 255},
					tangent  = {0, 0, 0, 1},
				})
				t := rot * [3]f32{-sn, 0, cs}
				vertices[len(vertices) - 1].tangent = {t.x, t.y, t.z, 1}
			}
		}
		for row in 0 ..< len(profile) - 1 {
			for col in 0 ..< AROUND {
				a := first + u32(row * (AROUND + 1) + col)
				b := a + AROUND + 1
				append(indices, a, b, a + 1, a + 1, b, b + 1)
			}
		}
	}
	switch shape {
	case .Sphere:
	case .Ball, .Collar:
		// A low base and a short narrow neck, turned around Y. On it a
		// ball with a slice cut off at an angle: the cut is a flat ring
		// around a smaller ball inside. The collar shape has a small base
		// and a collar around it, apart from it, with a quarter cut out on
		// the side the slice faces.
		BASE_LO, BASE_HI, RIM :: f32(-0.78), f32(-0.66), f32(0.05)
		BASE_R := f32(0.5) if shape == .Collar else f32(0.86)
		COLLAR_IN, COLLAR_OUT, COLLAR_HI, CHAMFER :: f32(0.62), f32(0.86), f32(-0.64), f32(0.05)
		// To the left of the preview's starting view.
		CUT_AXIS :: [3]f32{0.3, 0.62, 0.72}
		COVE_R, NECK_R, MEET_Y :: f32(0.4), f32(0.3), f32(-0.59)
		BALL_R, INNER_R, CUT :: f32(0.7), f32(0.5), f32(0.3)
		STEPS :: 40
		pf := make([dynamic][4]f32, context.temp_allocator)
		// The underside, then the base's side.
		append(&pf, [4]f32{0, BASE_LO, 0, -1}, [4]f32{BASE_R, BASE_LO, 0, -1})
		append(&pf, [4]f32{BASE_R, BASE_LO, 1, 0}, [4]f32{BASE_R, BASE_HI - RIM, 1, 0})
		// The rounded rim, into the flat top of the base.
		for i in 1 ..= 8 {
			a := f32(i) / 8 * math.PI / 2
			append(&pf, [4]f32{BASE_R - RIM + RIM * math.cos(a), BASE_HI - RIM + RIM * math.sin(a), math.cos(a), math.sin(a)})
		}
		append(&pf, [4]f32{COVE_R, BASE_HI, 0, 1})
		// The neck: a quarter of an ellipse rising from the flat top to
		// where it meets the ball.
		ax, ay := COVE_R - NECK_R, MEET_Y - BASE_HI
		for i in 1 ..= 8 {
			t := (1 - f32(i) / 8) * math.PI / 2
			append(&pf, [4]f32{COVE_R - ax * math.cos(t), MEET_Y - ay * math.sin(t), math.cos(t) / ax, math.sin(t) / ay})
		}
		lathe(&vertices, &indices, pf[:])
		// The ball, turned around the cut's axis: from the pole away from
		// the cut up to the cut, the flat ring inward, then the inner
		// ball's cap. Its lowest part sits inside the neck.
		ball_y := MEET_Y + math.sqrt(BALL_R * BALL_R - NECK_R * NECK_R)
		clear(&pf)
		cut_at := math.asin(CUT / BALL_R)
		for i in 0 ..= STEPS {
			a := -math.PI / 2 + (cut_at + math.PI / 2) * f32(i) / STEPS
			append(&pf, [4]f32{BALL_R * math.cos(a), BALL_R * math.sin(a), math.cos(a), math.sin(a)})
		}
		inner_at := math.asin(CUT / INNER_R)
		append(&pf, [4]f32{BALL_R * math.cos(cut_at), CUT, 0, 1}, [4]f32{INNER_R * math.cos(inner_at), CUT, 0, 1})
		for i in 0 ..= STEPS / 2 {
			a := inner_at + (math.PI / 2 - inner_at) * f32(i) / (STEPS / 2)
			append(&pf, [4]f32{INNER_R * math.cos(a), INNER_R * math.sin(a), math.cos(a), math.sin(a)})
		}
		lathe(&vertices, &indices, pf[:], linalg.normalize(CUT_AXIS), {0, ball_y, 0})
		if shape == .Ball do break
		// The collar: a ring with its outer upper edge chamfered, three
		// quarters of the way around, and a flat face on each end.
		clear(&pf)
		append(&pf, [4]f32{COLLAR_IN, BASE_LO, 0, -1}, [4]f32{COLLAR_OUT, BASE_LO, 0, -1})
		append(&pf, [4]f32{COLLAR_OUT, BASE_LO, 1, 0}, [4]f32{COLLAR_OUT, COLLAR_HI - CHAMFER, 1, 0})
		append(&pf, [4]f32{COLLAR_OUT, COLLAR_HI - CHAMFER, 1, 1}, [4]f32{COLLAR_OUT - CHAMFER, COLLAR_HI, 1, 1})
		append(&pf, [4]f32{COLLAR_OUT - CHAMFER, COLLAR_HI, 0, 1}, [4]f32{COLLAR_IN, COLLAR_HI, 0, 1})
		append(&pf, [4]f32{COLLAR_IN, COLLAR_HI, -1, 0}, [4]f32{COLLAR_IN, BASE_LO, -1, 0})
		gap := math.atan2(CUT_AXIS.z, CUT_AXIS.x)
		start, sweep := gap + math.PI / 4, f32(math.PI * 1.5)
		lathe(&vertices, &indices, pf[:], from = start, sweep = sweep)
		for end in 0 ..< 2 {
			phi := start + sweep * f32(end)
			out := [3]f32{math.cos(phi), 0, math.sin(phi)}
			n := [3]f32{-out.z, 0, out.x} * (f32(end) * 2 - 1)
			base := u32(len(vertices))
			for c in ([5][2]f32{{COLLAR_IN, BASE_LO}, {COLLAR_OUT, BASE_LO}, {COLLAR_OUT, COLLAR_HI - CHAMFER}, {COLLAR_OUT - CHAMFER, COLLAR_HI}, {COLLAR_IN, COLLAR_HI}}) {
				append(&vertices, gfx.Vertex{
					position = out * c.x + {0, c.y, 0},
					normal   = n,
					uv       = {(c.x - COLLAR_IN) / (COLLAR_OUT - COLLAR_IN), (COLLAR_HI - c.y) / (COLLAR_HI - BASE_LO)},
					color    = {255, 255, 255, 255},
					tangent  = {out.x, out.y, out.z, 1},
				})
			}
			for k in u32(1) ..< 4 {
				if end == 1 do append(&indices, base, base + k, base + k + 1)
				else do append(&indices, base, base + k + 1, base + k)
			}
		}
	case .Cube:
		H :: f32(0.6)
		face(&vertices, &indices, {1, 0, 0}, {0, 0, -1}, {0, 1, 0}, H)
		face(&vertices, &indices, {-1, 0, 0}, {0, 0, 1}, {0, 1, 0}, H)
		face(&vertices, &indices, {0, 0, 1}, {1, 0, 0}, {0, 1, 0}, H)
		face(&vertices, &indices, {0, 0, -1}, {-1, 0, 0}, {0, 1, 0}, H)
		face(&vertices, &indices, {0, 1, 0}, {1, 0, 0}, {0, 0, -1}, H)
		face(&vertices, &indices, {0, -1, 0}, {1, 0, 0}, {0, 0, 1}, H)
	case .Plane:
		// A face of half size 1 at height 0: the normal offset is undone.
		face(&vertices, &indices, {0, 1, 0}, {1, 0, 0}, {0, 0, -1}, 1)
		for &vtx in vertices do vtx.position.y = 0
	}
	_shapes[shape] = gfx.mesh_create(vertices[:], indices[:])
	return _shapes[shape]
}

material_sphere_shutdown :: proc() {
	for &m in _shapes do if m.vbuf != nil do gfx.mesh_destroy(&m)
	if !_sphere_made do return
	gfx.mesh_destroy(&_sphere)
	_sphere_made = false
}

// Draws `shape` with the material `guid` into the open pass.
_material_shape_draw :: proc(guid: engine.Asset_GUID, shape := Preview_Shape.Sphere) {
	shader, tex, color, data, extra := engine.material_resolve_draw(guid)
	gfx.draw_mesh(_material_shape(shape), tex, linalg.MATRIX4F32_IDENTITY, color, shader, 0, 0, data, extra)
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
	_material_shape_draw(guid)
	gfx.pass_end()
	gfx.set_lights_default()
	return true
}
