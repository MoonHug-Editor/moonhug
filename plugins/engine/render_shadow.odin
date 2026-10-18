package engine

// Shadows (plugins/engine/docs/RenderPipeline.md, SDL3Renderer.md "Shadows"):
//
//   shadow_cascades (per view)  the first shadowing directional Light: up to
//                               gfx.MAX_CASCADES slices of the camera's frustum,
//                               each an orthographic view in one tile of the
//                               view's "shadow" atlas
//   shadow_atlas (per frame)    every shadowing spot Light's view and every
//                               shadowing point Light's six cube faces, tiles of
//                               the frame's "shadow_atlas"
//
// scene_target_begin hands both to gfx (shadow_bind), and every shader on the
// surface template samples them (libs/gfx/shaders/surface.glsl
// cascade_shadow, punctual_shadow).
//
// Casters are every mesh in the world whose cast_shadows is not Off,
// whichever view draws it, collected once per frame through a Shadow view
// and culled per tile against the tile's view and the light's
// shadow_caster_mask. A cascade's view
// is a sphere around its slice of the frustum, so its size does not change as
// the camera turns, and its centre snaps to whole texels, so shadow edges do
// not shimmer as the camera moves. Each pass is depth-only
// (render_execute_depth): alpha-clipped materials cut their holes.

import "core:math"
import "core:math/linalg"
import gfx "moonhug:libs/gfx"
import "moonhug:libs/log"

SHADOW_TARGET       :: "shadow"
SHADOW_ATLAS_TARGET :: "shadow_atlas"

// The atlases' sizes, as the steps declare their targets (Depth@2048px).
SHADOW_CASCADE_ATLAS_SIZE :: 2048
SHADOW_ATLAS_SIZE         :: 2048

// The directional cascades' settings, per placed step (the pipeline asset).
Shadow_Settings :: struct {
	// Slices of the camera's frustum, each its own tile: more keeps the
	// shadows near the camera sharp further out.
	cascades:    int `decor:range(1, 4)`,
	// Shadows end this far from the camera, fading over the last tenth.
	distance:    f32 `decor:min(0)`,
	// How the slices divide the distance: 0 evenly, 1 logarithmically (more
	// detail near the camera).
	split:       f32 `decor:range(0, 1)`,
	// World units toward the light: hides self-shadowing acne on lit faces at
	// the cost of a little detachment at contact points.
	bias:        f32 `decor:min(0)`,
	// Texels along the surface normal, the same trade for faces at a grazing
	// angle to the light.
	normal_bias: f32 `decor:min(0)`,
}

shadow_defaults := Shadow_Settings{cascades = 4, distance = 50, split = 0.75, bias = 0.05, normal_bias = 1.5}

// The spot and point lights' shadow settings, per placed step.
Shadow_Atlas_Settings :: struct {
	bias:        f32 `decor:min(0)`, // world units along the light ray
	normal_bias: f32 `decor:min(0)`, // texels along the surface normal
}

shadow_atlas_defaults := Shadow_Atlas_Settings{bias = 0.05, normal_bias = 1.5}

@(render_step={summary="the first shadowing directional light's cascades, fitted to the view", reads="scene", writes="shadow:Depth@2048px", settings="shadow_defaults"})
shadow_cascades :: proc(ctx: ^Render_Ctx) {
	ctx.shadow_cascades = {}
	settings := (^Shadow_Settings)(ctx.settings)
	light_index, dir, caster_mask, found := _shadow_directional()
	if !found do return
	casters := _shadow_casters()
	if len(casters.list) == 0 do return

	// The view's depth range along its forward, from its near and far
	// planes' centres, and its frustum's corner rays: a point at view depth d
	// on a ray lies at the same fraction between the planes.
	v := ctx.view
	unproject :: proc(m: matrix[4, 4]f32, ndc: [3]f32) -> [3]f32 {
		p := m * [4]f32{ndc.x, ndc.y, ndc.z, 1}
		return p.xyz / p.w
	}
	near_centre := unproject(v.inv_view_proj, {0, 0, 0})
	far_centre := unproject(v.inv_view_proj, {0, 0, 1})
	forward := linalg.normalize0(far_centre - near_centre)
	near_d := linalg.dot(near_centre - v.cam_pos, forward)
	far_d := linalg.dot(far_centre - v.cam_pos, forward)
	if far_d - near_d < 1e-4 do return
	near_corners, far_corners: [4][3]f32
	for k in 0 ..< 4 {
		x := f32(k & 1 == 0 ? -1 : 1)
		y := f32(k & 2 == 0 ? -1 : 1)
		near_corners[k] = unproject(v.inv_view_proj, {x, y, 0})
		far_corners[k] = unproject(v.inv_view_proj, {x, y, 1})
	}
	start := near_d
	end := min(far_d, max(near_d, 0) + max(settings.distance, 0.01))

	count := clamp(settings.cascades, 1, gfx.MAX_CASCADES)
	splits := shadow_cascade_splits(start, end, count, settings.split)

	tile := SHADOW_CASCADE_ATLAS_SIZE / (count == 1 ? 1 : 2)
	up := abs(dir.y) < 0.99 ? [3]f32{0, 1, 0} : [3]f32{1, 0, 0}
	rot := linalg.matrix4_look_at_f32({0, 0, 0}, dir, up) // light space, rotation only

	rt := render_target(ctx, SHADOW_TARGET)
	gfx.pass_begin_target(rt, nil)
	result := gfx.Shadow_Cascades{count = count, light_index = light_index, normal_bias = settings.normal_bias, distance = end}
	for c in 0 ..< count {
		// The slice's corners, the sphere around them (rounded up, so its
		// radius holds still) and its centre snapped to whole texels.
		corners: [8][3]f32
		ta := (splits[c] - near_d) / (far_d - near_d)
		tb := (splits[c + 1] - near_d) / (far_d - near_d)
		centre: [3]f32
		for k in 0 ..< 4 {
			corners[k] = linalg.lerp(near_corners[k], far_corners[k], ta)
			corners[k + 4] = linalg.lerp(near_corners[k], far_corners[k], tb)
		}
		for p in corners do centre += p / 8
		radius: f32
		for p in corners do radius = max(radius, linalg.length(p - centre))
		radius = math.ceil(max(radius, 0.01) * 16) / 16
		texel := 2 * radius / f32(tile)
		ls := (rot * [4]f32{centre.x, centre.y, centre.z, 1}).xyz
		ls.x = math.round(ls.x / texel) * texel
		ls.y = math.round(ls.y / texel) * texel
		centre = (linalg.transpose(rot) * [4]f32{ls.x, ls.y, ls.z, 1}).xyz

		// The box reaches back toward the light as far as any caster does.
		back := radius
		for k in 0 ..< 8 {
			corner := [3]f32{
				k & 1 == 0 ? casters.lo.x : casters.hi.x,
				k & 2 == 0 ? casters.lo.y : casters.hi.y,
				k & 4 == 0 ? casters.lo.z : casters.hi.z,
			}
			back = max(back, -linalg.dot(corner - centre, dir))
		}
		eye := centre - dir * (back + 1)
		depth_range := back + 1 + radius
		view := linalg.matrix4_look_at_f32(eye, centre, up)
		proj := gfx.matrix4_ortho_z01(-radius, radius, -radius, radius, 0, depth_range)
		vp := proj * view

		x, y := count == 1 ? 0 : c % 2, count == 1 ? 0 : c / 2
		rect := [4]f32{f32(x * tile), f32(y * tile), f32(tile), f32(tile)}
		gfx.set_view_proj(vp, eye, rect)
		render_execute_depth(_shadow_tile_casters(&casters, vp, caster_mask))

		result.vp[c] = vp
		result.rects[c] = rect / SHADOW_CASCADE_ATLAS_SIZE
		result.world_texel[c] = texel
		result.depth_bias[c] = settings.bias / depth_range
	}
	gfx.pass_end()
	result.tex = gfx.rt_depth_texture(rt)
	ctx.shadow_cascades = result
}

@(render_step={summary="spot and point light shadows: a tile per spot light, six per point light", frame=true, reads="scene", writes="shadow_atlas:Depth@2048px", settings="shadow_atlas_defaults"})
shadow_atlas :: proc(ctx: ^Render_Ctx) {
	_atlas.frame = 0
	settings := (^Shadow_Atlas_Settings)(ctx.settings)

	// The shadowing spot and point lights, at their index in the light list
	// (scene_collect_lights order), which is how the shader finds its tiles.
	Shadowed :: struct {
		index:       int,
		light:       gfx.Light,
		faces:       int,
		caster_mask: u32,
	}
	// The tiles travel in the light uniform, so gfx.MAX_SHADOW_TILES is the
	// budget: lights past it in that order render unshadowed, said once.
	shadowed := make([dynamic]Shadowed, 0, 16, context.temp_allocator)
	tiles, n, skipped := 0, 0, 0
	it := pool_iterator(lights(ctx_world()))
	for l, _ in pool_next(&it) {
		if n >= gfx.MAX_LIGHTS do break
		if !l.enabled || !transform_active_in_hierarchy(l.owner) do continue
		if l.shadows && l.type != .Directional {
			faces := l.type == .Point ? 6 : 1
			if tiles + faces <= gfx.MAX_SHADOW_TILES {
				append(&shadowed, Shadowed{n, light_to_gfx(l, transform_world(Transform_Handle(l.owner))), faces, l.shadow_caster_mask})
				tiles += faces
			} else {
				skipped += 1
			}
		}
		n += 1
	}
	@(static) warned := false
	if skipped > 0 && !warned {
		warned = true
		log.warningf("[Render] %d spot or point light(s) with shadows on render without them: the shadow atlas holds %d tiles (a spot light takes 1, a point light 6)", skipped, gfx.MAX_SHADOW_TILES)
	}
	if tiles == 0 do return
	casters := _shadow_casters()

	grid, tile := shadow_atlas_grid(tiles, SHADOW_ATLAS_SIZE)
	rt := render_target(ctx, SHADOW_ATLAS_TARGET)
	gfx.pass_begin_target(rt, nil)
	data := &_atlas.data
	data^ = {bias = settings.bias, normal_bias = settings.normal_bias}
	// A point light's cube faces, in the order the shader picks them.
	faces_dirs := [6][2][3]f32{
		{{1, 0, 0}, {0, 1, 0}},
		{{-1, 0, 0}, {0, 1, 0}},
		{{0, 1, 0}, {0, 0, 1}},
		{{0, -1, 0}, {0, 0, 1}},
		{{0, 0, 1}, {0, 1, 0}},
		{{0, 0, -1}, {0, 1, 0}},
	}
	t := 0
	for s in shadowed {
		data.light_tiles[s.index] = {i32(t), i32(s.faces)}
		near := f32(0.05)
		far := max(s.light.range, near + 0.1)
		for face in 0 ..< s.faces {
			dir, up: [3]f32
			fov: f32
			if s.faces == 6 {
				dir, up = faces_dirs[face][0], faces_dirs[face][1]
				// A little wider than the 90 degree face, so filter taps near
				// a face's edge stay inside its tile.
				fov = 2 * math.atan(f32(1.1))
			} else {
				dir = linalg.normalize0(s.light.direction)
				up = abs(dir.y) < 0.99 ? [3]f32{0, 1, 0} : [3]f32{1, 0, 0}
				fov = clamp(2 * math.acos(clamp(s.light.outer_cos, -1, 1)) * 1.05, 0.05, 3)
			}
			view := linalg.matrix4_look_at_f32(s.light.position, s.light.position + dir, up)
			proj := gfx.matrix4_perspective_z01(fov, 1, near, far)
			vp := proj * view
			rect := [4]f32{f32((t % grid) * tile), f32((t / grid) * tile), f32(tile), f32(tile)}
			gfx.set_view_proj(vp, s.light.position, rect)
			render_execute_depth(_shadow_tile_casters(&casters, vp, s.caster_mask))
			data.tiles[t] = {
				vp                 = vp,
				rect               = rect / SHADOW_ATLAS_SIZE,
				near               = near,
				far                = far,
				texel_per_distance = 2 * math.tan(fov * 0.5) / f32(tile),
			}
			t += 1
		}
	}
	gfx.pass_end()
	data.tex = gfx.rt_depth_texture(rt)
	_atlas.frame = gfx.frame_index + 1
}

// Where the cascades' slices meet, from `start` to `end` along the view: an
// even split blended toward a logarithmic one by `split` (0 even, 1
// logarithmic). Entries 0 ..= count are set, the first `start`, the last `end`.
shadow_cascade_splits :: proc(start, end: f32, count: int, split: f32) -> (splits: [gfx.MAX_CASCADES + 1]f32) {
	count := clamp(count, 1, gfx.MAX_CASCADES)
	log_start := max(start, 0.01)
	for i in 0 ..= count {
		f := f32(i) / f32(count)
		even := start + (end - start) * f
		logarithmic := log_start * math.pow(end / log_start, f)
		splits[i] = math.lerp(even, logarithmic, clamp(split, 0, 1))
	}
	splits[0], splits[count] = start, end
	return
}

// The atlas's square grid for `tiles` tiles and the tile's size in pixels:
// as many tiles as needed, every light kept, so more lights make every tile
// smaller.
shadow_atlas_grid :: proc(tiles, atlas_size: int) -> (grid, tile: int) {
	grid = max(int(math.ceil(math.sqrt(f32(max(tiles, 1))))), 1)
	return grid, atlas_size / grid
}

// Hands this view's cascades and this frame's atlas to the current pass
// (scene_target_begin calls it after pass_begin), each when the running
// step reads it (`shadow?`, `shadow_atlas?`). Nothing for what no step
// rendered.
shadow_bind :: proc(ctx: ^Render_Ctx) {
	if ctx.shadow_cascades.count > 0 && render_reads(ctx, SHADOW_TARGET) do gfx.set_shadow_cascades(ctx.shadow_cascades)
	if _atlas.frame == gfx.frame_index + 1 && render_reads(ctx, SHADOW_ATLAS_TARGET) do gfx.set_shadow_atlas(&_atlas.data)
}

// This frame's atlas (shadow_atlas), stored +1 so frame 0 counts.
@(private = "file")
_atlas: struct {
	frame: u64,
	data:  gfx.Shadow_Atlas,
}

// The first enabled directional Light with shadows on, at its index in the
// light list (scene_collect_lights order), the way it travels and the
// layers that cast into its shadow map.
@(private = "file")
_shadow_directional :: proc() -> (index: int, dir: [3]f32, caster_mask: u32, found: bool) {
	n := 0
	it := pool_iterator(lights(ctx_world()))
	for l, _ in pool_next(&it) {
		if n >= gfx.MAX_LIGHTS do break
		if !l.enabled || !transform_active_in_hierarchy(l.owner) do continue
		if l.type == .Directional && l.shadows {
			gl := light_to_gfx(l, transform_world(Transform_Handle(l.owner)))
			dir = linalg.normalize0(gl.direction)
			return n, dir, l.shadow_caster_mask, dir != {}
		}
		n += 1
	}
	return
}

// Every mesh of the world as a caster, with its world bounds, and the bounds
// of them all.
@(private = "file")
_Casters :: struct {
	list:   []Render_Command,
	bounds: [][2][3]f32,
	lo, hi: [3]f32,
}

// The world's casters, collected once per frame and world (temp-allocated:
// the frame's views and the atlas share them).
@(private = "file")
_shadow_casters :: proc() -> _Casters {
	@(static) cache: struct {
		frame: u64,
		world: rawptr,
		c:     _Casters,
	}
	world := ctx_world()
	if cache.frame == gfx.frame_index + 1 && cache.world == world do return cache.c

	probe := render_view_make(linalg.MATRIX4F32_IDENTITY, linalg.MATRIX4F32_IDENTITY, 1, 1, ~u32(0), .Game)
	probe.pass = .Shadow
	commands := make([dynamic]Render_Command, 0, 64, context.temp_allocator)
	render_collect_commands(probe, &commands)
	list := make([dynamic]Render_Command, 0, len(commands), context.temp_allocator)
	bounds := make([dynamic][2][3]f32, 0, len(commands), context.temp_allocator)
	c := _Casters{lo = {max(f32), max(f32), max(f32)}, hi = {min(f32), min(f32), min(f32)}}
	for cmd in commands {
		d, is_mesh := cmd.variant.(Draw_Mesh)
		if !is_mesh do continue
		lo, hi, ok := _caster_bounds(cmd, d)
		if !ok do continue
		append(&list, cmd)
		append(&bounds, [2][3]f32{lo, hi})
		c.lo = linalg.min(c.lo, lo)
		c.hi = linalg.max(c.hi, hi)
	}
	c.list, c.bounds = list[:], bounds[:]
	cache = {frame = gfx.frame_index + 1, world = world, c = c}
	return c
}

// The casters inside one tile's view on a layer of `caster_mask`, the
// light's shadow_caster_mask (temp-allocated).
@(private = "file")
_shadow_tile_casters :: proc(c: ^_Casters, vp: matrix[4, 4]f32, caster_mask: u32) -> []Render_Command {
	f := frustum_from_view_proj(vp)
	out := make([dynamic]Render_Command, 0, len(c.list), context.temp_allocator)
	for cmd, i in c.list {
		if cmd.variant.(Draw_Mesh).layers & caster_mask == 0 do continue
		if frustum_intersects_aabb(f, c.bounds[i][0], c.bounds[i][1]) do append(&out, cmd)
	}
	return out[:]
}

// World-space bounds of one mesh command: the posed bounds of a skinned
// mesh, else the asset's box through the model matrix.
@(private = "file")
_caster_bounds :: proc(cmd: Render_Command, d: Draw_Mesh) -> (lo, hi: [3]f32, ok: bool) {
	if d.skinned != nil {
		_, smr := transform_get_comp(cmd.owner, SkinnedMeshRenderer)
		if smr == nil do return {}, {}, false
		return skinned_mesh_world_bounds(smr)
	}
	mesh, loaded := mesh_load(d.mesh, d.part)
	if !loaded do return {}, {}, false
	lo, hi = aabb_transform(mesh.aabb_min, mesh.aabb_max, d.model)
	return lo, hi, true
}
