package engine

// Camera + render-command pipeline on the gfx package (docs/SDL3Renderer.md).
// Cameras collect per-frame command lists (temp allocator) from the world's
// renderer pools and execute them through gfx draws. The editor scene view
// reuses the SAME collect/execute path with its own (non-component) camera,
// so game view and scene view render identically by construction.

import gfx "gfx"
import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:slice"

PIXELS_PER_UNIT :: 100.0

Render_View :: struct {
	view, proj:    matrix[4, 4]f32,
	view_proj:     matrix[4, 4]f32,
	inv_view_proj: matrix[4, 4]f32,
	cam_pos:       [3]f32, // camera world position (specular shaders, LOD later)
	width, height: f32, // viewport pixels (screen->ray, gizmo sizing)
	layer_mask:    u32,
}

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

// A textured quad with a transparent sort key — sprites, any 2D emitter.
Draw_Quad :: struct {
	texture:  Asset_GUID,
	material: Asset_GUID, // shader/tint/properties; texture stays the quad's own. empty = unlit
	corners:  [4][3]f32, // world-space bl, br, tr, tl — shared with picking
	color:    [4]f32,
}

Draw_Mesh :: struct {
	mesh:      Asset_GUID,
	part:      i32, // MeshFilter.part: 0 = whole model, N = glTF mesh N-1
	materials: []Asset_GUID, // per-submesh; view into the renderer's array (frame lifetime). missing/empty = white unlit
	model:     matrix[4, 4]f32,
}

Render_Command :: struct {
	key:     Sort_Key, // alpha-blended quads only; zero for meshes
	variant: union #no_nil {
		Draw_Mesh,
		Draw_Quad,
	},
}

Ray :: struct {
	origin, direction: [3]f32,
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

render_view_make :: proc(view, proj: matrix[4, 4]f32, width, height: f32, layer_mask: u32) -> Render_View {
	vp := proj * view
	// Camera world position = translation column of the inverted view matrix
	// — derived here so every caller (game cameras, editor scene view) gets it
	// without extra plumbing.
	inv_view := linalg.inverse(view)
	return Render_View{
		view          = view,
		proj          = proj,
		view_proj     = vp,
		inv_view_proj = linalg.inverse(vp),
		cam_pos       = {inv_view[0, 3], inv_view[1, 3], inv_view[2, 3]},
		width         = width,
		height        = height,
		layer_mask    = layer_mask,
	}
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
	return render_view_make(view, proj, width, height, cam.render_layer_mask)
}

// Unprojects a viewport pixel (origin top-left) into a world ray. Replaces
// rl.GetScreenToWorldRay for game code (turret_aim) and feeds scene picking.
render_view_screen_ray :: proc(view: Render_View, px, py: f32) -> Ray {
	ndc_x := 2 * px / max(view.width, 1) - 1
	ndc_y := 1 - 2 * py / max(view.height, 1)
	near4 := view.inv_view_proj * [4]f32{ndc_x, ndc_y, 0, 1} // z01: near plane at 0
	far4 := view.inv_view_proj * [4]f32{ndc_x, ndc_y, 1, 1}
	near := near4.xyz / near4.w
	far := far4.xyz / far4.w
	return Ray{origin = near, direction = linalg.normalize(far - near)}
}

camera_screen_ray :: proc(cam: ^Camera, screen_pos: [2]f32, viewport: [2]f32) -> Ray {
	view := camera_render_view(cam, viewport.x, viewport.y)
	return render_view_screen_ray(view, screen_pos.x, screen_pos.y)
}

trs_matrix :: proc(position: [3]f32, rotation: [4]f32, scale: [3]f32) -> matrix[4, 4]f32 {
	q := quaternion(x = rotation.x, y = rotation.y, z = rotation.z, w = rotation.w)
	return linalg.matrix4_from_trs_f32(position, q, scale)
}

// A collector appends commands for the renderers it owns that are visible to
// `view` (enabled, active in hierarchy, layer mask intersecting). `out` lives
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
// built-in collectors, then every registered one.
render_collect_commands :: proc(view: Render_View, out: ^[dynamic]Render_Command) {
	_collect_mesh_renderers(view, out)
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
		if mf == nil || mf.mesh == {} do continue

		tw := transform_world(Transform_Handle(mr.owner))
		append(out, Render_Command{
			variant = Draw_Mesh{
				mesh      = mf.mesh,
				part      = mf.part,
				materials = mr.materials[:],
				model     = trs_matrix(tw.position, tw.rotation, tw.scale),
			},
		})
	}
}

// Sorts and replays commands into the CURRENT gfx pass: opaque meshes first
// (depth-write pipeline handles their ordering; grouped by material to batch
// pipeline/texture binds), then alpha-blended quads by their sort key
// (lexicographic over levels — the sprite collector makes keys unique, so
// their order is total and deterministic regardless of sort stability).
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
	buf: [gfx.MAX_LIGHTS]gfx.Light
	n, ambient := scene_collect_lights(buf[:])
	if n > 0 do gfx.set_lights(buf[:n], ambient)
}

render_execute :: proc(view: Render_View, commands: []Render_Command) {
	_apply_scene_light()
	slice.sort_by(commands, proc(a, b: Render_Command) -> bool {
		am, a_mesh := a.variant.(Draw_Mesh)
		bm, b_mesh := b.variant.(Draw_Mesh)
		if a_mesh != b_mesh do return a_mesh // meshes first
		if a_mesh {
			// Group by first material so same-material runs share binds.
			ak: u128 = len(am.materials) > 0 ? transmute(u128)am.materials[0] : 0
			bk: u128 = len(bm.materials) > 0 ? transmute(u128)bm.materials[0] : 0
			return ak < bk
		}
		return sort_key_less(a.key, b.key)
	})

	gfx.set_view_proj(view.view_proj, view.cam_pos)
	// uv origin top-left (stb rows are top-down): bl,br get v=1, tr,tl v=0.
	uvs := [4][2]f32{{0, 1}, {1, 1}, {1, 0}, {0, 0}}

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

	for &cmd in commands {
		switch d in cmd.variant {
		case Draw_Quad:
			tex, ok := texture_load(d.texture)
			if !ok do continue
			sm, cached := quad_mats[d.material]
			if !cached {
				shader, _, mcolor, mdata, mextra := _resolve_material(d.material) // material texture ignored: quads use their own
				sm = Quad_Mat{shader = shader, color = mcolor, data = mdata, extra = mextra}
				quad_mats[d.material] = sm
			}
			// Quad facing for lighting shaders (quads are transform-
			// oriented, not billboards).
			normal := linalg.normalize0(linalg.cross(d.corners[1] - d.corners[0], d.corners[3] - d.corners[0]))
			gfx.draw_quad(d.corners, uvs, d.color * sm.color, tex.gfx, sm.shader, sm.data, normal, sm.extra)
		case Draw_Mesh:
			mesh, ok := mesh_load(d.mesh, d.part)
			if !ok do continue
			for sub, i in mesh.submeshes {
				mat_guid: Asset_GUID
				if i < len(d.materials) do mat_guid = d.materials[i]
				shader, gpu_tex, color, mat_data, extra_tex := _resolve_material(mat_guid)
				gfx.draw_mesh(mesh.gpu, gpu_tex, d.model, color, shader, sub.first_index, sub.index_count, mat_data, extra_tex)
			}
		}
	}
}

// In-app debug drawing (collider wireframes etc): when on, the app loop runs
// the DebugDraw phase (@(phase={key=DebugDraw, mode=App}) subscribers) inside
// the open world pass. Toggled with F3.
debug_draw_enabled: bool

// Renders ALL enabled cameras ascending by Camera.order into `target`
// (nil = swapchain). Begins the pass — cleared by the lowest-order camera's
// clear_color, black when no camera — and LEAVES IT OPEN so the caller can
// draw overlays (demo menu, editor grid) before gfx.pass_end().
// Returns false only when no pass could begin (window minimized).
render_world_cameras :: proc(target: ^gfx.Render_Target = nil) -> bool {
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

	clear_color := [4]f32{0, 0, 0, 1}
	if len(cams) > 0 do clear_color = cams[0].clear_color

	width, height: f32
	if target != nil {
		gfx.pass_begin_target(target, clear_color)
		width, height = f32(target.width), f32(target.height)
	} else {
		if !gfx.pass_begin_swapchain(clear_color) do return false
		ws := gfx.window_size()
		width, height = f32(ws.x), f32(ws.y)
	}

	for cam in cams {
		view := camera_render_view(cam, width, height)
		commands := make([dynamic]Render_Command, 0, 64, context.temp_allocator)
		render_collect_commands(view, &commands)
		render_execute(view, commands[:])
	}
	return true
}
