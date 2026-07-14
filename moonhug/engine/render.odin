package engine

// Camera + render-command pipeline on the gfx package (docs/SDL3Renderer.md).
// Cameras collect per-frame command lists (temp allocator) from the world's
// renderer pools and execute them through gfx draws. The editor scene view
// reuses the SAME collect/execute path with its own (non-component) camera,
// so game view and scene view render identically by construction.

import gfx "gfx"
import "core:math"
import "core:math/linalg"
import "core:slice"

PIXELS_PER_UNIT :: 100.0

Render_View :: struct {
	view, proj:    matrix[4, 4]f32,
	view_proj:     matrix[4, 4]f32,
	inv_view_proj: matrix[4, 4]f32,
	width, height: f32, // viewport pixels (screen->ray, gizmo sizing)
	layer_mask:    u32,
}

Draw_Sprite :: struct {
	texture:  Asset_GUID,
	material: Asset_GUID, // shader/tint/properties; texture stays the sprite's. empty = unlit
	corners:  [4][3]f32, // world-space bl, br, tr, tl — shared with picking
	color:    [4]f32,
}

Draw_Mesh :: struct {
	mesh:      Asset_GUID,
	materials: []Asset_GUID, // per-submesh; view into the renderer's array (frame lifetime). missing/empty = white unlit
	model:     matrix[4, 4]f32,
}

Render_Command :: struct {
	key:     Sprite_Sort_Key, // sprites only (sprite_sort.odin); zero for meshes
	variant: union #no_nil {
		Draw_Mesh,
		Draw_Sprite,
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
	for i in 0 ..< len(world.cameras.slots) {
		slot := &world.cameras.slots[i]
		if !slot.alive do continue
		cam := &slot.data
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
	return Render_View{
		view          = view,
		proj          = proj,
		view_proj     = vp,
		inv_view_proj = linalg.inverse(vp),
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

// The world-space quad a SpriteRenderer covers: bl, br, tr, tl. Used by BOTH
// command collection and scene picking so they can't diverge. Sprites are
// transform-oriented (not billboards), sized tex_pixels/PIXELS_PER_UNIT.
sprite_world_corners :: proc(tw: Transform_World, tex_w, tex_h: i32) -> [4][3]f32 {
	half_w := tw.scale.x * f32(tex_w) / (2.0 * PIXELS_PER_UNIT)
	half_h := tw.scale.y * f32(tex_h) / (2.0 * PIXELS_PER_UNIT)
	rot := quat_to_matrix3(tw.rotation)
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

// Appends commands for every renderer visible to `view` (enabled, active in
// hierarchy, layer mask intersecting). `out` should live on temp_allocator.
render_collect_commands :: proc(view: Render_View, out: ^[dynamic]Render_Command) {
	world := ctx_world()

	for i in 0 ..< len(world.mesh_renderers.slots) {
		slot := &world.mesh_renderers.slots[i]
		if !slot.alive do continue
		mr := &slot.data
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
				materials = mr.materials[:],
				model     = trs_matrix(tw.position, tw.rotation, tw.scale),
			},
		})
	}

	// One tree pass resolves every sprite's sort key (groups folded in).
	sort_keys := sprite_sort_build_keys(view)

	for i in 0 ..< len(world.sprite_renderers.slots) {
		slot := &world.sprite_renderers.slots[i]
		if !slot.alive do continue
		sr := &slot.data
		if !sr.enabled do continue
		if sr.texture == {} do continue

		t := pool_get(&world.transforms, Handle(sr.owner))
		if t == nil || !transform_active_in_hierarchy(sr.owner) do continue
		if t.render_layer & view.layer_mask == 0 do continue

		tex, ok := texture_load(sr.texture)
		if !ok do continue

		tw := transform_world(Transform_Handle(sr.owner))
		key, in_tree := sort_keys[Transform_Handle(sr.owner)]
		if !in_tree do key = sprite_sort_orphan_key(view, sr)
		append(out, Render_Command{
			key     = key,
			variant = Draw_Sprite{
				texture  = sr.texture,
				material = sr.material,
				corners  = sprite_world_corners(tw, tex.width, tex.height),
				color    = sr.color,
			},
		})
	}
}

// Sorts and replays commands into the CURRENT gfx pass: opaque meshes first
// (depth-write pipeline handles their ordering; grouped by material to batch
// pipeline/texture binds), then alpha-blended sprites by their sort key —
// layer, order in layer, view depth back-to-front, tree order
// (sprite_sort.odin). Sprite keys are unique, so their order is total and
// deterministic regardless of sort stability.
// First enabled Light drives the pass's lit-shader uniforms; without one the
// gfx default applies (white, baked direction — matches the pre-Light look).
_apply_scene_light :: proc() {
	world := ctx_world()
	for i in 0 ..< len(world.lights.slots) {
		slot := &world.lights.slots[i]
		if !slot.alive do continue
		l := &slot.data
		if !l.enabled do continue
		if !transform_active_in_hierarchy(l.owner) do continue

		tw := transform_world(Transform_Handle(l.owner))
		rot := quat_to_matrix3(tw.rotation)
		forward := [3]f32{-rot[0, 2], -rot[1, 2], -rot[2, 2]} // -Z, like cameras
		gfx.set_light(forward, l.color.rgb, l.intensity, l.ambient)
		return
	}
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
		return sprite_sort_key_less(a.key, b.key)
	})

	gfx.set_view_proj(view.view_proj)
	// uv origin top-left (stb rows are top-down): bl,br get v=1, tr,tl v=0.
	uvs := [4][2]f32{{0, 1}, {1, 1}, {1, 0}, {0, 0}}

	// One resolve per material guid: equal-material sprites then share the
	// SAME packed property slice, which is what lets their draws merge in
	// the gfx batch (material compares by pointer).
	Sprite_Mat :: struct {
		shader: string,
		color:  [4]f32,
		data:   []u8,
	}
	sprite_mats := make(map[Asset_GUID]Sprite_Mat, context.temp_allocator)

	for &cmd in commands {
		switch d in cmd.variant {
		case Draw_Sprite:
			tex, ok := texture_load(d.texture)
			if !ok do continue
			sm, cached := sprite_mats[d.material]
			if !cached {
				shader, _, mcolor, mdata := _resolve_material(d.material) // material texture ignored: sprites use their own
				sm = Sprite_Mat{shader = shader, color = mcolor, data = mdata}
				sprite_mats[d.material] = sm
			}
			// Quad facing for lighting shaders (sprites are transform-
			// oriented, not billboards).
			normal := linalg.normalize0(linalg.cross(d.corners[1] - d.corners[0], d.corners[3] - d.corners[0]))
			gfx.draw_quad(d.corners, uvs, d.color * sm.color, tex.gfx, sm.shader, sm.data, normal)
		case Draw_Mesh:
			mesh, ok := mesh_load(d.mesh)
			if !ok do continue
			for sub, i in mesh.submeshes {
				mat_guid: Asset_GUID
				if i < len(d.materials) do mat_guid = d.materials[i]
				shader, gpu_tex, color, mat_data := _resolve_material(mat_guid)
				gfx.draw_mesh(mesh.gpu, gpu_tex, d.model, color, shader, sub.first_index, sub.index_count, mat_data)
			}
		}
	}
}

// Renders ALL enabled cameras ascending by Camera.order into `target`
// (nil = swapchain). Begins the pass — cleared by the lowest-order camera's
// clear_color, black when no camera — and LEAVES IT OPEN so the caller can
// draw overlays (demo menu, editor grid) before gfx.pass_end().
// Returns false only when no pass could begin (window minimized).
render_world_cameras :: proc(target: ^gfx.Render_Target = nil) -> bool {
	world := ctx_world()
	cams := make([dynamic]^Camera, 0, 8, context.temp_allocator)
	for i in 0 ..< len(world.cameras.slots) {
		slot := &world.cameras.slots[i]
		if !slot.alive do continue
		cam := &slot.data
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
