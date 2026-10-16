package engine

// Camera + render-command pipeline on the gfx package (plugins/engine/docs/SDL3Renderer.md).
// Cameras collect per-frame command lists (temp allocator) from the world's
// renderer pools and execute them through gfx draws. The editor scene view
// reuses the SAME collect/execute path with its own (non-component) camera,
// so game view and scene view render identically by construction.

import gfx "moonhug:libs/gfx"
import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:slice"

PIXELS_PER_UNIT :: 100.0

// Unity's CameraType: which surface a view renders. Collectors differentiate
// — the particles edit preview draws in scene views but never in an
// edit-mode game view.

// Alpha-blended commands sort by a lexicographic multi-level key — collectors
// build it (sprite layout: packages/sprites/sprite_sort.odin). 8 levels is
// deep enough for sprite-rigged characters (character > torso > arm > hand >
// item ...); each level costs 8 bytes per command and one compare, so raise
// freely if content ever nests deeper.
SORT_KEY_LEVELS :: 8

Sort_Key :: [SORT_KEY_LEVELS]u64

sort_key_less :: proc(a, b: Sort_Key) -> bool {
	for i in 0 ..< SORT_KEY_LEVELS {
		if a[i] != b[i] do return a[i] < b[i]
	}
	return false
}

// One transparent-sort word — the packing convention every alpha-blended
// collector shares, so sprites and particles interleave correctly:
//   layer:8 (biased) | order:16 (biased) | ~depth:24 | seq:16
// Depth quantization: positive f32 bit patterns are monotonic as integers,
// so the top 24 bits of the view-space distance's bit pattern order
// correctly without knowing near/far; inverted so a larger distance
// (farther) yields a smaller word (drawn first, back-to-front).
sort_key_word :: proc(layer, order: i32, view_depth: f32, seq: u16) -> u64 {
	l := u64(u32(clamp(layer, -128, 127) + 128))
	o := u64(u32(clamp(order, -32768, 32767) + 32768))
	d := u64(transmute(u32)max(view_depth, 0) >> 8) & 0xFFFFFF
	d = 0xFFFFFF - d
	return l << 56 | o << 40 | d << 16 | u64(seq)
}

// View-space distance of a world position (right-handed view looks down -Z,
// larger = farther) — the depth every collector feeds sort_key_word.
sort_key_depth :: proc(view: Render_View, world_pos: [3]f32) -> f32 {
	pos4 := view.view * [4]f32{world_pos.x, world_pos.y, world_pos.z, 1}
	return -pos4.z
}

// Full-texture uvs, bl br tr tl. uv origin is top-left (stb rows are
// top-down), so bl/br carry v=1 and tr/tl v=0.
QUAD_UVS_FULL :: [4][2]f32{{0, 1}, {1, 1}, {1, 0}, {0, 0}}

// A textured quad with a transparent sort key — sprites, any 2D emitter.
Draw_Quad :: struct {
	texture:  Asset_GUID,
	material: Asset_GUID, // shader/tint/properties; texture stays the quad's own. empty = unlit
	corners:  [4][3]f32, // world-space bl, br, tr, tl — shared with picking
	uvs:      [4][2]f32, // per corner; QUAD_UVS_FULL for the whole texture, a sub-rect for slices
	color:    [4]f32,
}

Draw_Mesh :: struct {
	mesh:      Asset_GUID,
	part:      i32, // resolved FILE-ORDER part: 0 = whole model, N = glTF mesh N-1 (mesh_filter_part)
	materials: []Asset_GUID, // per-submesh; view into the renderer's array (frame lifetime). missing/empty = white unlit
	model:     matrix[4, 4]f32,
	// Posed vertices from a SkinnedMeshRenderer, drawn instead of the asset's
	// own buffers. The asset is still loaded, for its submesh ranges and
	// materials. nil for a static draw.
	skinned:   ^gfx.Mesh,
}

Render_Command :: struct {
	key:     Sort_Key, // alpha-blended quads only; zero for meshes
	// The transform whose renderer emits the command. The editor picks,
	// outlines and frames package renderers by the quads they draw.
	owner:   Transform_Handle,
	variant: union #no_nil {
		Draw_Mesh,
		Draw_Quad,
	},
}

// Highest-order enabled camera — for game logic queries (mouse rays).
// Rendering iterates ALL enabled cameras (render_world_cameras).
camera_active :: proc() -> ^Camera {
	world := ctx_world()
	best: ^Camera
	best_order: i32 = min(i32)
	it := pool_iterator(cameras(world))
	for cam, _ in pool_next(&it) {
		if !cam.enabled do continue
		if !transform_active_in_hierarchy(cam.owner) do continue
		if cam.order > best_order {
			best_order = cam.order
			best = cam
		}
	}
	return best
}

// View from the camera transform's world rotation (forward = -Z column,
// up = +Y column); projection honors the component's fov/near/far — near and
// far were previously ignored (raylib hardcoded them).
camera_render_view :: proc(cam: ^Camera, width, height: f32) -> Render_View {
	tw := transform_world(Transform_Handle(cam.owner))
	rot := quat_to_matrix3(tw.rotation)
	forward := [3]f32{-rot[0, 2], -rot[1, 2], -rot[2, 2]}
	up := [3]f32{rot[0, 1], rot[1, 1], rot[2, 1]}
	view := linalg.matrix4_look_at_f32(tw.position, tw.position + forward, up)
	aspect := width / max(height, 1)
	proj := gfx.matrix4_perspective_z01(math.to_radians(cam.fov), aspect, cam.near_clip, cam.far_clip)
	rv := render_view_make(view, proj, width, height, cam.render_layer_mask)
	rv.camera = Transform_Handle(cam.owner)
	rv.cull = true
	return rv
}

camera_screen_ray :: proc(cam: ^Camera, screen_pos: [2]f32, viewport: [2]f32) -> Ray {
	view := camera_render_view(cam, viewport.x, viewport.y)
	return render_view_screen_ray(view, screen_pos.x, screen_pos.y)
}

// A collector appends commands for the renderers it owns that are visible to
// `view` (enabled, active in hierarchy, layer mask intersecting, and inside
// view.frustum when view.cull is on). `out` lives
// on the temp allocator. Packages register theirs once at an init phase —
// the registry is the seam that lets renderer components live outside the
// engine. Collection order does not matter: render_execute sorts the
// combined list.
Render_Collector :: proc(view: Render_View, out: ^[dynamic]Render_Command)

// Process-lifetime registry on the default allocator — registration must not
// capture the caller's context allocator (a test-local or temp allocator
// would free the backing array under the registry).
_render_collectors: [dynamic]Render_Collector

@(init)
_render_collectors_init :: proc "contextless" () {
	context = runtime.default_context()
	_render_collectors = make([dynamic]Render_Collector, runtime.default_allocator())
}

render_register_collector :: proc(c: Render_Collector) {
	append(&_render_collectors, c)
}

// Appends commands for every renderer visible to `view`: the engine's
// built-in collectors, then every registered one. meshes=false leaves out the
// engine's mesh and skinned mesh renderers: the editor's quad queries need
// neither, and collecting skinned meshes poses them for the frame.
render_collect_commands :: proc(view: Render_View, out: ^[dynamic]Render_Command, meshes := true) {
	if meshes {
		_collect_mesh_renderers(view, out)
		skinned_mesh_collect(out, view) // component_SkinnedMeshRenderer.odin
	}
	canvas_collect_graphics(view, out) // the canvas tree (ui_canvas.odin)
	for c in _render_collectors do c(view, out)
}

_collect_mesh_renderers :: proc(view: Render_View, out: ^[dynamic]Render_Command) {
	world := ctx_world()
	mr_it := pool_iterator(mesh_renderers(world))
	for mr, _ in pool_next(&mr_it) {
		if !mr.enabled do continue

		t := pool_get(&world.transforms, Handle(mr.owner))
		if t == nil || !transform_active_in_hierarchy(mr.owner) do continue
		if t.render_layer & view.layer_mask == 0 do continue

		_, mf := transform_get_comp(Transform_Handle(mr.owner), MeshFilter)
		if mf == nil || asset_guid_is_empty(mf.mesh.guid) do continue
		part, part_ok := mesh_filter_part(mf)
		if !part_ok do continue

		tw := transform_world(Transform_Handle(mr.owner))
		model := trs_matrix(tw.position, tw.rotation, tw.scale)
		if view.cull {
			mesh, loaded := mesh_load(mf.mesh.guid, part)
			if !loaded do continue
			lo, hi := aabb_transform(mesh.aabb_min, mesh.aabb_max, model)
			if !frustum_intersects_aabb(view.frustum, lo, hi) do continue
		}
		append(out, Render_Command{
			owner   = Transform_Handle(mr.owner),
			variant = Draw_Mesh{
				mesh      = mf.mesh.guid,
				part      = part,
				materials = mr.materials[:],
				model     = model,
			},
		})
	}
}

// Every enabled Light (up to gfx.MAX_LIGHTS, the pool max) fills `buf` in pool
// order. The ambient floor is the first enabled light's. Returns the count and
// ambient; count 0 leaves the gfx default in effect.
scene_collect_lights :: proc(buf: []gfx.Light) -> (n: int, ambient: f32) {
	world := ctx_world()
	it := pool_iterator(lights(world))
	for l, _ in pool_next(&it) {
		if n >= len(buf) do break
		if !l.enabled do continue
		if !transform_active_in_hierarchy(l.owner) do continue

		tw := transform_world(Transform_Handle(l.owner))
		if n == 0 do ambient = l.ambient
		buf[n] = light_to_gfx(l, tw)
		n += 1
	}
	return n, ambient
}

// Enabled Lights drive the pass's lit-shader uniforms; without any the gfx
// default applies (one white directional — matches the pre-Light look).
_apply_scene_light :: proc() {
	buf := make([]gfx.Light, gfx.MAX_LIGHTS, context.temp_allocator)
	n, ambient := scene_collect_lights(buf)
	if n > 0 do gfx.set_lights(buf[:n], ambient)
}

// The scene view's debug modes (core.View_Mode): what one surface draws as.
WIREFRAME_COLOR :: [4]f32{0.85, 0.85, 0.85, 1}
OVERDRAW_LAYER  :: [4]f32{1, 1, 1, 0.12} // each surface adds this much, so brighter = more overdraw

// What render_execute draws: the opaque meshes, the alpha-blended quads, or
// both. The scene steps draw one phase each (render_steps.odin).
Render_Phase :: enum u8 {
	Opaque,      // Draw_Mesh, grouped by material
	Transparent, // Draw_Quad, back to front by sort key
}
Render_Phases :: bit_set[Render_Phase; u8]
RENDER_ALL_PHASES :: Render_Phases{.Opaque, .Transparent}

// Draws the commands of `phases` with the view's mode: Shaded is the game's
// look, the other modes override every material's shader and color
// (view.mode). Sets the pass's lights, so each pass that draws calls it.
render_execute :: proc(view: Render_View, commands: []Render_Command, phases := RENDER_ALL_PHASES) {
	// A command without its owner is a collector's bug: the editor could
	// neither pick nor outline what it draws.
	for c in commands do assert(c.owner != {}, "render_execute: a render command names no owner (its collector must set Render_Command.owner)")
	_apply_scene_light()
	gfx.set_view_proj(view.view_proj, view.cam_pos)
	if .Opaque in phases do _execute_meshes(view, commands)
	if .Transparent in phases {
		_execute_transparent_meshes(view, commands)
		_execute_quads(view, commands)
	}
}

// The opaque meshes, one draw per submesh, ordered by material, then mesh,
// then submesh, then the faces culled and mirroring: equal neighbours differ only in their
// model matrix, so gfx merges each run into one instanced draw
// (gfx.draw_mesh). Each material is resolved once.
@(private = "file")
_execute_meshes :: proc(view: Render_View, commands: []Render_Command) {
	Item :: struct {
		material: Asset_GUID,
		sub:      i32,
		cull:     gfx.Cull,
		mirrored: bool,
		cmd:      ^Render_Command,
		loaded:   ^Mesh,
	}
	mats := make(map[Asset_GUID]_Mesh_Mat, context.temp_allocator)
	items := make([dynamic]Item, 0, len(commands), context.temp_allocator)
	// The order as integer keys, sorted without a comparator: the material
	// folded into the high half, the mesh, part, submesh, cull and mirroring
	// folded into the next 32 bits, the item's index in the low 32. Two groups folding
	// alike only interleave their runs, which costs merges, never a wrong draw.
	keys := make([dynamic]u128, 0, len(commands), context.temp_allocator)
	for &cmd in commands {
		d, is_mesh := cmd.variant.(Draw_Mesh)
		if !is_mesh do continue
		mesh, ok := mesh_load(d.mesh, d.part)
		if !ok do continue
		_inspect_draw(cmd)
		mirrored := render_mirrored(d.model)
		for _, i in mesh.submeshes {
			mat: Asset_GUID
			if i < len(d.materials) do mat = d.materials[i]
			m := _mesh_mat(&mats, mat)
			if m.transparent do continue // _execute_transparent_meshes
			cull := m.cull
			index := len(items)
			assert(index <= int(max(u32)), "render_execute: more mesh draws than a sort key indexes")
			group := u128(render_fold_guid(mat)) << 64 | u128(_fold_mesh_faces(d, i32(i), cull, mirrored)) << 32
			append(&keys, group | u128(index))
			append(&items, Item{material = mat, sub = i32(i), cull = cull, mirrored = mirrored, cmd = &cmd, loaded = mesh})
		}
	}
	slice.sort(keys[:])

	for key in keys {
		it := items[u32(key)]
		d := it.cmd.variant.(Draw_Mesh)
		sub := it.loaded.submeshes[it.sub]
		gpu := d.skinned != nil ? d.skinned^ : it.loaded.gpu
		m := _mesh_mat(&mats, it.material)
		switch view.mode {
		case .Shaded:
			probe := probe_for_point({d.model[0, 3], d.model[1, 3], d.model[2, 3]}) // render_probes.odin
			gfx.draw_mesh(gpu, m.tex, d.model, m.color, m.shader, sub.first_index, sub.index_count, m.data, m.extra, alpha_cutoff = m.cutoff, cull = it.cull, mirrored = it.mirrored, probe = probe)
		case .Wireframe:
			gfx.draw_mesh(gpu, nil, d.model, WIREFRAME_COLOR, gfx.DEFAULT_SHADER, sub.first_index, sub.index_count, wire = true)
		case .Unlit:
			gfx.draw_mesh(gpu, m.tex, d.model, m.color, gfx.DEFAULT_SHADER, sub.first_index, sub.index_count, alpha_cutoff = m.cutoff, cull = it.cull, mirrored = it.mirrored)
		case .Normals:
			gfx.draw_mesh(gpu, m.tex, d.model, {1, 1, 1, 1}, gfx.NORMALS_SHADER, sub.first_index, sub.index_count, alpha_cutoff = m.cutoff, cull = it.cull, mirrored = it.mirrored)
		case .Overdraw:
			gfx.draw_mesh(gpu, nil, d.model, OVERDRAW_LAYER, gfx.DEFAULT_SHADER, sub.first_index, sub.index_count, overlay = true)
		}
	}
}

// The transparent meshes' submeshes, back to front by their object's
// distance to the camera, each blended over what is there without writing
// depth. The debug modes draw them as the opaques, in their place here.
@(private = "file")
_execute_transparent_meshes :: proc(view: Render_View, commands: []Render_Command) {
	Item :: struct {
		material: Asset_GUID,
		sub:      i32,
		cmd:      ^Render_Command,
		loaded:   ^Mesh,
		dist:     f32,
	}
	mats := make(map[Asset_GUID]_Mesh_Mat, context.temp_allocator)
	items := make([dynamic]Item, 0, 16, context.temp_allocator)
	for &cmd in commands {
		d, is_mesh := cmd.variant.(Draw_Mesh)
		if !is_mesh do continue
		mesh, ok := mesh_load(d.mesh, d.part)
		if !ok do continue
		for _, i in mesh.submeshes {
			mat: Asset_GUID
			if i < len(d.materials) do mat = d.materials[i]
			if !_mesh_mat(&mats, mat).transparent do continue
			centre := [3]f32{d.model[0, 3], d.model[1, 3], d.model[2, 3]}
			append(&items, Item{material = mat, sub = i32(i), cmd = &cmd, loaded = mesh, dist = linalg.length2(centre - view.cam_pos)})
		}
	}
	if len(items) == 0 do return
	slice.sort_by(items[:], proc(a, b: Item) -> bool { return a.dist > b.dist })
	for it in items {
		_inspect_draw(it.cmd^)
		d := it.cmd.variant.(Draw_Mesh)
		sub := it.loaded.submeshes[it.sub]
		gpu := d.skinned != nil ? d.skinned^ : it.loaded.gpu
		m := _mesh_mat(&mats, it.material)
		mirrored := render_mirrored(d.model)
		switch view.mode {
		case .Shaded:
			probe := probe_for_point({d.model[0, 3], d.model[1, 3], d.model[2, 3]})
			gfx.draw_mesh(gpu, m.tex, d.model, m.color, m.shader, sub.first_index, sub.index_count, m.data, m.extra, alpha_cutoff = m.cutoff, cull = m.cull, mirrored = mirrored, blend = true, probe = probe)
		case .Wireframe:
			gfx.draw_mesh(gpu, nil, d.model, WIREFRAME_COLOR, gfx.DEFAULT_SHADER, sub.first_index, sub.index_count, wire = true)
		case .Unlit:
			gfx.draw_mesh(gpu, m.tex, d.model, m.color, gfx.DEFAULT_SHADER, sub.first_index, sub.index_count, alpha_cutoff = m.cutoff, cull = m.cull, mirrored = mirrored, blend = true)
		case .Normals:
			gfx.draw_mesh(gpu, m.tex, d.model, {1, 1, 1, 1}, gfx.NORMALS_SHADER, sub.first_index, sub.index_count, alpha_cutoff = m.cutoff, cull = m.cull, mirrored = mirrored)
		case .Overdraw:
			gfx.draw_mesh(gpu, nil, d.model, OVERDRAW_LAYER, gfx.DEFAULT_SHADER, sub.first_index, sub.index_count, overlay = true)
		}
	}
}

// A material as mesh draws use it, resolved once per pass (_mesh_mat).
@(private = "file")
_Mesh_Mat :: struct {
	shader: string,
	tex:    ^gfx.Texture,
	color:  [4]f32,
	data:   []u8,
	extra:  []^gfx.Texture,
	cutoff:      f32,      // alpha clipping threshold, 0 = none
	cull:        gfx.Cull, // the faces skipped
	transparent: bool,     // blended, drawn in the transparent phase
}

@(private = "file")
_mesh_mat :: proc(mats: ^map[Asset_GUID]_Mesh_Mat, guid: Asset_GUID) -> _Mesh_Mat {
	if m, cached := mats[guid]; cached do return m
	m: _Mesh_Mat
	m.shader, m.tex, m.color, m.data, m.extra = _resolve_material(guid, .Lit)
	m.cutoff = material_alpha_cutoff(guid)
	m.cull = material_cull(guid)
	m.transparent = material_transparent(guid)
	mats[guid] = m
	return m
}

// Draws the meshes of `commands` into the CURRENT depth-only pass (gfx
// Target_Format.Depth: the shadow map, the depth prepass), each face culled
// as its material says. A mesh none of whose materials clip, and whose
// materials all cull alike, draws whole with gfx.DEPTH_SHADER, so every copy
// of it merges into one instanced draw whatever its materials are. Otherwise
// each submesh draws on its own, and one whose material clips draws with
// that material's shader, which gfx runs as its caster (alpha clipping, no
// lighting), with its texture, color and cutoff.
render_execute_depth :: proc(commands: []Render_Command) {
	Item :: struct {
		cmd:      ^Render_Command,
		loaded:   ^Mesh,
		sub:      i32, // -1: the whole mesh
		material: Asset_GUID,
		cull:     gfx.Cull,
		mirrored: bool,
	}
	mats := make(map[Asset_GUID]_Mesh_Mat, context.temp_allocator)
	items := make([dynamic]Item, 0, len(commands), context.temp_allocator)
	// Integer keys as in _execute_meshes: the clipping material folded high
	// (zero for depth-only draws, so those come first), the mesh, part and
	// submesh next, the item's index low.
	keys := make([dynamic]u128, 0, len(commands), context.temp_allocator)
	add :: proc(items: ^[dynamic]Item, keys: ^[dynamic]u128, it: Item, material_fold: u64, d: Draw_Mesh) {
		index := len(items)
		assert(index <= int(max(u32)), "render_execute_depth: more mesh draws than a sort key indexes")
		append(keys, u128(material_fold) << 64 | u128(_fold_mesh_faces(d, it.sub, it.cull, it.mirrored)) << 32 | u128(index))
		append(items, it)
	}
	for &cmd in commands {
		d, is_mesh := cmd.variant.(Draw_Mesh)
		if !is_mesh do continue
		mesh, ok := mesh_load(d.mesh, d.part)
		if !ok do continue
		_inspect_draw(cmd)
		mirrored := render_mirrored(d.model)
		clips, mixed, transparent := false, false, false
		first_cull: gfx.Cull
		for _, i in mesh.submeshes {
			mat: Asset_GUID
			if i < len(d.materials) do mat = d.materials[i]
			m := _mesh_mat(&mats, mat)
			if m.cutoff > 0 do clips = true
			if m.transparent do transparent = true
			if i == 0 do first_cull = m.cull
			else if m.cull != first_cull do mixed = true
		}
		if !clips && !mixed && !transparent {
			add(&items, &keys, Item{cmd = &cmd, loaded = mesh, sub = -1, cull = first_cull, mirrored = mirrored}, 0, d)
			continue
		}
		for _, i in mesh.submeshes {
			mat: Asset_GUID
			if i < len(d.materials) do mat = d.materials[i]
			m := _mesh_mat(&mats, mat)
			if m.transparent do continue // no depth: it blends over what has
			clip := m.cutoff > 0
			it := Item{cmd = &cmd, loaded = mesh, sub = i32(i), material = clip ? mat : {}, cull = m.cull, mirrored = mirrored}
			add(&items, &keys, it, clip ? render_fold_guid(mat) | 1 : 0, d)
		}
	}
	slice.sort(keys[:])

	for key in keys {
		it := items[u32(key)]
		d := it.cmd.variant.(Draw_Mesh)
		gpu := d.skinned != nil ? d.skinned^ : it.loaded.gpu
		if it.sub < 0 {
			gfx.draw_mesh(gpu, nil, d.model, {1, 1, 1, 1}, gfx.DEPTH_SHADER, cull = it.cull, mirrored = it.mirrored)
			continue
		}
		sub := it.loaded.submeshes[it.sub]
		if it.material == {} {
			gfx.draw_mesh(gpu, nil, d.model, {1, 1, 1, 1}, gfx.DEPTH_SHADER, sub.first_index, sub.index_count, cull = it.cull, mirrored = it.mirrored)
			continue
		}
		m := _mesh_mat(&mats, it.material)
		gfx.draw_mesh(gpu, m.tex, d.model, m.color, m.shader, sub.first_index, sub.index_count, m.data, m.extra, alpha_cutoff = m.cutoff, cull = it.cull, mirrored = it.mirrored)
	}
}

// Whether `model` mirrors what it draws (negative scale on an odd number of
// axes): that turns its triangles' winding around (gfx.draw_mesh mirrored).
render_mirrored :: proc(model: matrix[4, 4]f32) -> bool {
	return linalg.determinant(linalg.matrix3_from_matrix4(model)) < 0
}

// The mesh fold with the cull mode in its top 2 bits and mirroring in the
// next: draws that differ in either never merge, so they sort apart.
@(private = "file")
_fold_mesh_faces :: proc(d: Draw_Mesh, sub: i32, cull: gfx.Cull, mirrored: bool) -> u32 {
	return render_fold_mesh(d.mesh, d.part, sub) & 0x1FFF_FFFF | u32(cull) << 30 | u32(mirrored) << 29
}

// Sort-key folds for grouping draws (render_execute, the shadow pass): a guid
// to 64 bits, a mesh part's submesh to 32. Equal inputs fold equal, which is
// all the grouping needs.
render_fold_guid :: proc(g: Asset_GUID) -> u64 {
	halves := transmute([2]u64)g
	return halves[0] ~ halves[1]
}

render_fold_mesh :: proc(mesh: Asset_GUID, part, sub: i32) -> u32 {
	h := render_fold_guid(mesh) ~ u64(u32(part)) * 0x9E3779B97F4A7C15 ~ u64(u32(sub)) * 0xC2B2AE3D27D4EB4F
	return u32(h ~ h >> 32)
}

// The alpha-blended quads, back to front by their sort key (lexicographic
// over levels: the sprite collector makes keys unique, so their order is
// total and deterministic regardless of sort stability).
@(private = "file")
_execute_quads :: proc(view: Render_View, commands: []Render_Command) {
	quads := make([dynamic]^Render_Command, 0, len(commands), context.temp_allocator)
	for &cmd in commands {
		if _, is_quad := cmd.variant.(Draw_Quad); is_quad do append(&quads, &cmd)
	}
	slice.sort_by(quads[:], proc(a, b: ^Render_Command) -> bool {
		return sort_key_less(a.key, b.key)
	})

	// One resolve per material guid: equal-material quads then share the
	// SAME packed property slice, which is what lets their draws merge in
	// the gfx batch (material compares by pointer).
	Quad_Mat :: struct {
		shader: string,
		color:  [4]f32,
		data:   []u8,
		extra:  []^gfx.Texture, // sampler bindings 1+ (binding 0 is the quad's own texture)
	}
	quad_mats := make(map[Asset_GUID]Quad_Mat, context.temp_allocator)

	for cmd in quads {
		d := cmd.variant.(Draw_Quad)
		tex, ok := texture_load(d.texture)
		if !ok do continue
		_inspect_draw(cmd^)
		sm, cached := quad_mats[d.material]
		if !cached {
			shader, _, mcolor, mdata, mextra := _resolve_material(d.material) // material texture ignored: quads use their own
			sm = Quad_Mat{shader = shader, color = mcolor, data = mdata, extra = mextra}
			quad_mats[d.material] = sm
		}
		// Quad facing for lighting shaders (quads are transform-
		// oriented, not billboards).
		normal := linalg.normalize0(linalg.cross(d.corners[1] - d.corners[0], d.corners[3] - d.corners[0]))
		switch view.mode {
		case .Shaded, .Wireframe:
			gfx.draw_quad(d.corners, d.uvs, d.color * sm.color, tex.gfx, sm.shader, sm.data, normal, sm.extra)
		case .Unlit:
			gfx.draw_quad(d.corners, d.uvs, d.color * sm.color, tex.gfx, gfx.DEFAULT_SHADER, nil, normal)
		case .Normals:
			gfx.draw_quad(d.corners, d.uvs, {1, 1, 1, 1}, nil, gfx.NORMALS_SHADER, nil, normal)
		case .Overdraw:
			gfx.draw_quad(d.corners, d.uvs, OVERDRAW_LAYER, nil, gfx.DEFAULT_SHADER, nil, normal, depth_test = false)
		}
	}
}

// In-app debug drawing (collider wireframes etc): when on, the app loop runs
// the DebugDraw phase (@(phase={key=DebugDraw, mode=App}) subscribers) inside
// the open world pass. Toggled with F3.
debug_draw_enabled: bool

// Renders ALL enabled cameras ascending by Camera.order into `target` (nil =
// the swapchain), each through its render pipeline slot (render_pipeline.odin).
// The lowest-order camera clears with its clear_color, later cameras draw
// over it. `overlay` draws inside the LAST camera's scene pass, over the
// scene: the editor's game-view gizmos, the app's DebugDraw phase.
//
// With no camera the target is cleared black and the overlay still runs.
// Returns false when the window is minimized and nothing could draw.
render_world_cameras :: proc(target: ^gfx.Render_Target = nil, overlay: proc() = nil) -> bool {
	world := ctx_world()
	cams := make([dynamic]^Camera, 0, 8, context.temp_allocator)
	it := pool_iterator(cameras(world))
	for cam, _ in pool_next(&it) {
		if !cam.enabled do continue
		if !transform_active_in_hierarchy(cam.owner) do continue
		append(&cams, cam)
	}
	slice.sort_by(cams[:], proc(a, b: ^Camera) -> bool {
		return a.order < b.order
	})

	width, height: f32
	if target != nil {
		width, height = f32(target.width), f32(target.height)
	} else {
		ws := gfx.window_size()
		width, height = f32(ws.x), f32(ws.y)
	}
	canvas_set_game_viewport({width, height}) // the canvas tree measures against the game viewport

	if len(cams) == 0 {
		if target != nil {
			gfx.pass_begin_target(target, [4]f32{0, 0, 0, 1})
		} else if !gfx.pass_begin_swapchain([4]f32{0, 0, 0, 1}) {
			return false
		}
		if overlay != nil do overlay()
		gfx.pass_end()
		return true
	}

	pool := render_view_pool(target)
	for cam, i in cams {
		view := camera_render_view(cam, width, height)
		commands := make([dynamic]Render_Command, 0, 64, context.temp_allocator)
		render_collect_commands(view, &commands)
		ctx := Render_Ctx{
			view     = view,
			target   = target,
			pool     = pool,
			commands = commands[:],
		}
		if i == 0 do ctx.clear = cam.clear_color
		if i == len(cams) - 1 do ctx.overlay_over = overlay
		render_pipeline_run(cam.slot != "" ? cam.slot : MAIN_SLOT, &ctx)
	}
	return true
}

// Renders one editor view of the world into `target` through the pipeline
// slot `slot` (the scene view asks for Editor and gets Main when the
// pipeline declares no such slot), with the shell's grid under the scene and
// its gizmos over it. The commands are collected here, so the caller never
// sees them.
render_scene_view :: proc(target: ^gfx.Render_Target, view: Render_View, slot: string, clear: [4]f32, overlay_under, overlay_over: proc()) {
	commands := make([dynamic]Render_Command, 0, 64, context.temp_allocator)
	render_collect_commands(view, &commands)
	ctx := Render_Ctx{
		view          = view,
		target        = target,
		pool          = render_view_pool(target),
		commands      = commands[:],
		clear         = clear,
		overlay_under = overlay_under,
		overlay_over  = overlay_over,
		scene_view    = true,
	}
	render_pipeline_run(render_pipeline_has_slot(slot) ? slot : MAIN_SLOT, &ctx)
}
