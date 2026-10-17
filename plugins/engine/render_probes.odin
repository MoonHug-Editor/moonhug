package engine

// Reflection probes (component_Reflection_Probe.odin): the frame lane's
// reflection_probes_pass step captures each probe that needs it, six faces of
// the scene from its position through a lane of the engine's own scene
// steps (the sun's cascades, the opaque meshes, the sky, the transparents:
// no anti-aliasing, no post, no reflections of reflections), into a source
// cube whose mips the GPU fills, then GGX-prefiltered along the mips of
// the probe's cube like the Environment's (render_environment.odin), and,
// for a probe that lights diffusely, its diffuse light into an irradiance
// cube. The mesh draws take the probe whose box holds their centre
// (probe_for_point), the smallest when several do, and gfx binds its cubes
// in place of the environment's for that draw (gfx.Probe), the reflection
// box projected when the probe says so. Within the probe's blend distance
// of its box's edge the draw fades into the next smaller box holding it, or
// the environment (gfx.Probe_Blend). A capture draws without probes, so
// one probe's capture never depends on another's.

import "base:runtime"
import "core:math"
import "core:math/linalg"
import gfx "moonhug:libs/gfx"

PROBE_SLOT :: "Probe"

@(private = "file")
_Probe_Key :: struct {
	position:   [3]f32,
	resolution: Probe_Resolution,
}

@(private = "file")
_Probe_State :: struct {
	source, specular, irradiance: ^gfx.Cubemap,
	key:              _Probe_Key,
	built:            bool,
	seen:             u64, // gfx.frame_index + 1 when the step last saw the probe
}

// A probe a draw may take this frame: the box and the cube, for the pick.
Probe_Candidate :: struct {
	owner:     Transform_Handle,
	min, max:  [3]f32,
	volume:    f32,
	blend:     f32, // the blend distance
	probe:     gfx.Probe,
}

@(private = "file")
_probes: struct {
	states:     map[Transform_Handle]_Probe_State,
	candidates: [dynamic]Probe_Candidate, // this frame's, rebuilt by the step
	world:      ^World,                   // whose candidates they are
	pool:       ^gfx.Target_Pool,         // the capture's targets
	lane:       Pipeline_Runtime,         // the capture's steps
	lane_built: bool,
	capturing:  bool,
}

@(render_step={summary="captures the scene into each Reflection Probe's cube when it needs it: the first time, when the probe moved, or every frame", frame=true, reads="scene"})
reflection_probes_pass :: proc(ctx: ^Render_Ctx) {
	if ctx_get() == nil || _probes.capturing do return
	world := ctx_world()
	if world == nil do return
	context.allocator = runtime.default_allocator() // cross-frame state
	if _probes.states == nil do _probes.states = make(map[Transform_Handle]_Probe_State)
	clear(&_probes.candidates)
	_probes.world = world

	it := pool_iterator(reflection__probes(world))
	for p in pool_next(&it) {
		if !p.enabled || !transform_active_in_hierarchy(p.owner) do continue
		owner := Transform_Handle(p.owner)
		tw := transform_world(owner)
		key := _Probe_Key{tw.position, p.resolution}
		st, found := &_probes.states[owner]
		if !found {
			_probes.states[owner] = {}
			st = &_probes.states[owner]
		}
		st.seen = gfx.frame_index + 1
		if p.refresh == .Every_Frame || !st.built || st.key != key || (p.diffuse && st.irradiance == nil) {
			if _probe_capture(p, st, key) {
				st.key = key
				st.built = true
			}
		}
		if !st.built do continue
		half := linalg.abs(p.size) * 0.5
		append(&_probes.candidates, Probe_Candidate{
			owner  = owner,
			min    = tw.position - half,
			max    = tw.position + half,
			volume = p.size.x * p.size.y * p.size.z,
			blend  = max(p.blend_distance, 0),
			probe  = {cube = st.specular, irradiance = p.diffuse ? st.irradiance : nil, pos = tw.position, min = tw.position - half, max = tw.position + half, box = p.box_projection, intensity = max(p.intensity, 0)},
		})
	}
	// A probe gone (removed, its scene closed) frees its cubes.
	for owner, &st in _probes.states {
		if st.seen == gfx.frame_index + 1 do continue
		gfx.cubemap_destroy(st.source)
		gfx.cubemap_destroy(st.specular)
		gfx.cubemap_destroy(st.irradiance)
		delete_key(&_probes.states, owner)
	}
}

// The probes a mesh centred at `point` takes this frame (probe_pick). None
// (probe.cube nil) when no probe's box holds it, the frame's probes are
// another world's, or a probe is being captured.
probe_for_point :: proc(point: [3]f32) -> gfx.Probe_Blend {
	if ctx_get() == nil || _probes.capturing || _probes.world != ctx_world() do return {}
	return probe_pick(_probes.candidates[:], point)
}

// The smallest of `candidates` whose box holds `point`, weighted by how far
// inside its edge the point lies over its blend distance, blending with the
// next smallest box holding the point, or the environment (other's cube
// nil). None when no box holds it.
probe_pick :: proc(candidates: []Probe_Candidate, point: [3]f32) -> gfx.Probe_Blend {
	best, next: ^Probe_Candidate
	for &c in candidates {
		if point.x < c.min.x || point.x > c.max.x || point.y < c.min.y || point.y > c.max.y || point.z < c.min.z || point.z > c.max.z do continue
		if best == nil || c.volume < best.volume {
			next = best
			best = &c
		} else if next == nil || c.volume < next.volume {
			next = &c
		}
	}
	if best == nil do return {}
	lo, hi := point - best.min, best.max - point
	inside := min(lo.x, lo.y, lo.z, hi.x, hi.y, hi.z)
	weight := best.blend > 0 ? clamp(inside / best.blend, 0, 1) : 1
	out := gfx.Probe_Blend{probe = best.probe, weight = weight}
	if weight < 1 && next != nil do out.other = next.probe
	return out
}

// The six faces: a camera at the probe looking along each axis. Rendered
// through a plain camera a face comes out mirrored against the cube's
// convention, which the blit undoes (gfx.cubemap_blit_face).
@(private = "file")
_FACES := [6]struct {
	forward, up: [3]f32,
}{
	{{1, 0, 0}, {0, 1, 0}},
	{{-1, 0, 0}, {0, 1, 0}},
	{{0, 1, 0}, {0, 0, -1}},
	{{0, -1, 0}, {0, 0, 1}},
	{{0, 0, 1}, {0, 1, 0}},
	{{0, 0, -1}, {0, 1, 0}},
}

@(private = "file")
_probe_resolution :: proc(r: Probe_Resolution) -> i32 {
	switch r {
	case .Res_64:  return 64
	case .Res_128: return 128
	case .Res_256: return 256
	}
	return 128
}

// Renders the scene around `p` into its cubes. False when a cube could not
// be made.
@(private = "file")
_probe_capture :: proc(p: ^Reflection_Probe, st: ^_Probe_State, key: _Probe_Key) -> bool {
	size := _probe_resolution(key.resolution)
	if st.source == nil || st.source.size != size {
		gfx.cubemap_destroy(st.source)
		gfx.cubemap_destroy(st.specular)
		st.source = gfx.cubemap_create(size, i32(math.log2(f32(size))) + 1)
		st.specular = gfx.cubemap_create(ENV_SPECULAR_SIZE, ENV_SPECULAR_MIPS)
	}
	if p.diffuse && st.irradiance == nil do st.irradiance = gfx.cubemap_create(ENV_IRRADIANCE_SIZE, 1)
	if st.source == nil || st.specular == nil || (p.diffuse && st.irradiance == nil) do return false
	if !_probes.lane_built {
		src: Render_Pipeline
		pipeline_add_slot(&src, PROBE_SLOT)
		for name in ([]string{"shadow_cascades", "scene_opaque", "scene_sky", "scene_transparent"}) do pipeline_add_step(&src, name, PROBE_SLOT)
		_probes.lane = _pipeline_runtime_build(src, {})
		_probes.lane_built = true
	}
	if _probes.pool == nil do _probes.pool = new(gfx.Target_Pool)
	lane := _probes.lane.slots[PROBE_SLOT]

	_probes.capturing = true
	defer _probes.capturing = false
	proj := gfx.matrix4_perspective_z01(math.PI / 2, 1, 0.1, 1000)
	for f, face in _FACES {
		view := linalg.matrix4_look_at_f32(key.position, key.position + f.forward, f.up)
		rv := render_view_make(view, proj, f32(size), f32(size), max(u32))
		rv.cull = true
		commands := make([dynamic]Render_Command, 0, 64, context.temp_allocator)
		render_collect_commands(rv, &commands)
		ctx := Render_Ctx{view = rv, pool = _probes.pool, commands = commands[:], clear = {0, 0, 0, 1}}
		_lane_run(PROBE_SLOT, lane[:], &ctx, inspect = false)
		if hdr := gfx.pool_find(_probes.pool, HDR_TARGET); hdr != nil do gfx.cubemap_blit_face(st.source, i32(face), hdr)
	}
	gfx.cubemap_generate_mips(st.source)
	_env_prefilter(st.source, st.specular)
	if p.diffuse do _env_irradiance(st.source, st.irradiance)
	return true
}

// Frees every probe's cubes and the capture's targets (engine shutdown).
_render_probes_shutdown :: proc() {
	for _, &st in _probes.states {
		gfx.cubemap_destroy(st.source)
		gfx.cubemap_destroy(st.specular)
		gfx.cubemap_destroy(st.irradiance)
	}
	delete(_probes.states)
	delete(_probes.candidates)
	if _probes.pool != nil {
		gfx.pool_destroy(_probes.pool)
		free(_probes.pool, runtime.default_allocator())
	}
	if _probes.lane_built do _pipeline_runtime_destroy(&_probes.lane)
	_probes = {}
}
