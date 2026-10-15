package engine

// The directional shadow map: a per-frame render node, run once per frame
// and read by every view (plugins/engine/docs/RenderPipeline.md).
//
// Once per frame, shadow_pass renders every mesh of the world from the first
// enabled directional Light with `shadows` on, into the frame pool's "shadow"
// target: an orthographic box fitted around the casters' bounds, looking
// along the light. The scene pass then hands the target's depth to gfx
// (set_shadow), and every shader built on the surface template compares its
// fragments against it with a 3x3 PCF (libs/gfx/shaders/surface.glsl).
//
// One map, no cascades: the box covers the whole scene, so a large world
// gets a coarse shadow. Cascades fitted to the camera frustum are per view
// and belong in a later node.

import "core:math/linalg"
import gfx "moonhug:libs/gfx"

SHADOW_MAP_SIZE :: 2048 // as shadow_pass declares its target (Depth@2048px)
SHADOW_TARGET   :: "shadow"

// The shadow pass's settings, per placed node (the pipeline asset).
Shadow_Settings :: struct {
	// Depth units (0..1 over the light box's depth): hides self-shadowing acne
	// on lit faces at the cost of a little detachment at contact points.
	bias: f32 `decor:min(0)`,
}

shadow_defaults := Shadow_Settings{bias = 0.002}

@(private = "file")
_shadow: struct {
	valid:       bool,
	vp:          matrix[4, 4]f32,
	light_index: int, // the light's index in the pass's light list (scene_collect_lights order)
	rt:          ^gfx.Render_Target,
	bias:        f32,
}

@(render_node={summary="depth from the first shadowing directional light", frame=true, reads="scene", writes="shadow:Depth@2048px", settings="shadow_defaults"})
shadow_pass :: proc(ctx: ^Render_Ctx) {
	_shadow.valid = false
	settings := (^Shadow_Settings)(ctx.settings)

	// The casting light: the first enabled directional one with shadows on,
	// counted the way scene_collect_lights fills the light list, since the
	// shader picks the light to shadow by that index.
	world := ctx_world()
	index := -1
	dir: [3]f32
	n := 0
	it := pool_iterator(lights(world))
	for l, _ in pool_next(&it) {
		if n >= gfx.MAX_LIGHTS do break
		if !l.enabled || !transform_active_in_hierarchy(l.owner) do continue
		if index < 0 && l.type == .Directional && l.shadows {
			gl := light_to_gfx(l, transform_world(Transform_Handle(l.owner)))
			dir = linalg.normalize0(gl.direction)
			index = n
		}
		n += 1
	}
	if index < 0 || dir == {} do return

	// The casters: every mesh in the world, whichever view draws it, and the
	// box around them in world space.
	probe := render_view_make(linalg.MATRIX4F32_IDENTITY, linalg.MATRIX4F32_IDENTITY, SHADOW_MAP_SIZE, SHADOW_MAP_SIZE, ~u32(0), .Game)
	commands := make([dynamic]Render_Command, 0, 64, context.temp_allocator)
	render_collect_commands(probe, &commands)
	lo := [3]f32{max(f32), max(f32), max(f32)}
	hi := [3]f32{min(f32), min(f32), min(f32)}
	casters := 0
	for cmd in commands {
		d, is_mesh := cmd.variant.(Draw_Mesh)
		if !is_mesh do continue
		mlo, mhi, ok := _caster_bounds(cmd, d)
		if !ok do continue
		lo = linalg.min(lo, mlo)
		hi = linalg.max(hi, mhi)
		casters += 1
	}
	if casters == 0 do return

	// Light space: an orthographic box of the casters' bounding sphere,
	// looking along the light from outside the sphere.
	center := (lo + hi) * 0.5
	radius := max(linalg.length(hi - lo) * 0.5, 0.01)
	up := abs(dir.y) < 0.99 ? [3]f32{0, 1, 0} : [3]f32{1, 0, 0}
	eye := center - dir * (radius * 2)
	view := linalg.matrix4_look_at_f32(eye, center, up)
	proj := gfx.matrix4_ortho_z01(-radius, radius, -radius, radius, radius * 0.5, radius * 3.5)
	vp := proj * view

	// A depth-only pass: each mesh's casters merge into one instanced draw,
	// alpha-clipped materials cut their holes (render_execute_depth).
	rt := render_target(ctx, SHADOW_TARGET)
	gfx.pass_begin_target(rt, nil)
	gfx.set_view_proj(vp, eye)
	render_execute_depth(commands[:])
	gfx.pass_end()

	_shadow = {valid = true, vp = vp, light_index = index, rt = rt, bias = settings.bias}
}

// Hands this frame's shadow map to the current pass (scene_target_begin calls it
// after pass_begin). Nothing when no light cast one this frame.
shadow_bind :: proc() {
	if !_shadow.valid do return
	gfx.set_shadow(gfx.rt_depth_texture(_shadow.rt), _shadow.vp, _shadow.light_index, _shadow.bias)
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
	lo = {max(f32), max(f32), max(f32)}
	hi = {min(f32), min(f32), min(f32)}
	for c in 0 ..< 8 {
		corner := [4]f32{
			c & 1 == 0 ? mesh.aabb_min.x : mesh.aabb_max.x,
			c & 2 == 0 ? mesh.aabb_min.y : mesh.aabb_max.y,
			c & 4 == 0 ? mesh.aabb_min.z : mesh.aabb_max.z,
			1,
		}
		p := (d.model * corner).xyz
		lo = linalg.min(lo, p)
		hi = linalg.max(hi, p)
	}
	return lo, hi, true
}
