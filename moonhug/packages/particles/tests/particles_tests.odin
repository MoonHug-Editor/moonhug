package particles_tests

// Headless simulation coverage for the range-based Shuriken core: emission
// rate, lifetime death, the max-particles cap, non-looping duration cutoff.
// Rendering is GPU-gated (texture loads) and stays untested here.

import "core:encoding/uuid"
import "core:fmt"
import "core:math/linalg"
import "core:os"
import "core:strings"
import "core:testing"
import "moonhug:engine"
import anim "moonhug:packages/animation"
import seq "moonhug:packages/sequencer"
import particles "moonhug:packages/particles"
import common "moonhug:tests/common"

_make_system :: proc(tc: ^common.TestCtx) -> ^particles.ParticleSystem {
	tH := engine.transform_new("Emitter")
	engine.scene_set_root(tc.scene, tH)
	_, raw := engine.transform_add_comp(tH, .ParticleSystem)
	ps := cast(^particles.ParticleSystem)raw
	ps.enabled = true
	return ps
}

@(test)
test_particles_emission_and_death :: proc(t: ^testing.T) {
	tc_mem := new(common.TestCtx)
	defer free(tc_mem)
	common.setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer common.teardown(tc_mem)

	ps := _make_system(tc_mem)
	ps.rate = 10
	ps.start_lifetime = engine.minmax_constant(1)
	ps.gravity_modifier = 0

	// One second at 10/s emits 10 particles.
	for _ in 0 ..< 10 do particles.system_tick(ps, 0.1)
	testing.expect_value(t, len(ps.particles), 10)

	// Another 1.1s: everything born in the first second has died, the
	// replacements are still alive (looping keeps emitting).
	for _ in 0 ..< 11 do particles.system_tick(ps, 0.1)
	testing.expect(t, len(ps.particles) <= 11, "dead particles must be removed")
	testing.expect(t, len(ps.particles) >= 9, "emission must continue while looping")
}

@(test)
test_particles_max_cap_and_duration :: proc(t: ^testing.T) {
	tc_mem := new(common.TestCtx)
	defer free(tc_mem)
	common.setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer common.teardown(tc_mem)

	ps := _make_system(tc_mem)
	ps.rate = 1000
	ps.start_lifetime = engine.minmax_constant(100)
	ps.max_particles = 25

	particles.system_tick(ps, 1)
	testing.expect_value(t, len(ps.particles), 25)

	// Non-looping: emission stops after `duration`, live particles remain.
	ps2 := _make_system(tc_mem)
	ps2.looping = false
	ps2.duration = 0.5
	ps2.rate = 10
	ps2.start_lifetime = engine.minmax_constant(100)
	for _ in 0 ..< 20 do particles.system_tick(ps2, 0.1)
	count := len(ps2.particles)
	testing.expect(t, count >= 4 && count <= 6, "emission must stop at duration")
	particles.system_tick(ps2, 0.1)
	testing.expect_value(t, len(ps2.particles), count)
}

@(test)
test_particles_gravity_and_integration :: proc(t: ^testing.T) {
	tc_mem := new(common.TestCtx)
	defer free(tc_mem)
	common.setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer common.teardown(tc_mem)

	ps := _make_system(tc_mem)
	ps.rate = 0
	ps.gravity_modifier = 1
	ps.sim_space = .World
	append(&ps.particles, particles.Particle{lifetime = 100, size = 1, color = {1, 1, 1, 1}})

	for _ in 0 ..< 10 do particles.system_tick(ps, 0.1)
	p := ps.particles[0]
	testing.expect(t, p.velocity.y < -9, "gravity must accelerate downward")
	testing.expect(t, p.position.y < -4, "position must integrate velocity")
}

@(test)
test_particles_bursts :: proc(t: ^testing.T) {
	tc_mem := new(common.TestCtx)
	defer free(tc_mem)
	common.setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer common.teardown(tc_mem)

	// Non-looping: two cycles of 10 at t=1 and t=1.5.
	ps := _make_system(tc_mem)
	ps.looping = false
	ps.duration = 5
	ps.rate = 0
	ps.start_lifetime = engine.minmax_constant(100)
	append(&ps.bursts, particles.Burst{
		time = 1, count_min = 10, count_max = 10, cycles = 2, interval = 0.5, probability = 1,
	})
	for _ in 0 ..< 5 do particles.system_tick(ps, 0.25) // t = 1.25
	testing.expect_value(t, len(ps.particles), 10)
	for _ in 0 ..< 2 do particles.system_tick(ps, 0.25) // t = 1.75
	testing.expect_value(t, len(ps.particles), 20)

	// Looping: a burst at cycle time 0 fires again after the wrap.
	ps2 := _make_system(tc_mem)
	ps2.duration = 2
	ps2.rate = 0
	ps2.start_lifetime = engine.minmax_constant(100)
	append(&ps2.bursts, particles.Burst{count_min = 5, count_max = 5, probability = 1})
	for _ in 0 ..< 5 do particles.system_tick(ps2, 0.5) // t = 2.5, one wrap
	testing.expect_value(t, len(ps2.particles), 10)
}

@(test)
test_particles_start_delay_and_prewarm :: proc(t: ^testing.T) {
	tc_mem := new(common.TestCtx)
	defer free(tc_mem)
	common.setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer common.teardown(tc_mem)

	ps := _make_system(tc_mem)
	ps.start_delay = 1
	ps.rate = 10
	ps.start_lifetime = engine.minmax_constant(100)
	particles.system_tick(ps, 0.5)
	particles.system_tick(ps, 0.5)
	testing.expect_value(t, len(ps.particles), 0) // still inside the delay
	particles.system_tick(ps, 0.5)
	testing.expect_value(t, len(ps.particles), 5)

	// Prewarm: the first tick behaves as if one full cycle already ran.
	ps2 := _make_system(tc_mem)
	ps2.prewarm = true
	ps2.rate = 10
	ps2.start_lifetime = engine.minmax_constant(100)
	particles.system_tick(ps2, 0.016)
	testing.expect(t, len(ps2.particles) >= 40, "prewarm must fill one cycle's worth")
}

@(test)
test_particles_rate_over_distance :: proc(t: ^testing.T) {
	tc_mem := new(common.TestCtx)
	defer free(tc_mem)
	common.setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer common.teardown(tc_mem)

	ps := _make_system(tc_mem)
	ps.rate = 0
	ps.rate_over_distance = 2
	ps.start_lifetime = engine.minmax_constant(100)
	particles.system_tick(ps, 0.1) // records the starting position
	testing.expect_value(t, len(ps.particles), 0)

	if tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(ps.owner)); tr != nil {
		tr.position = {5, 0, 0}
	}
	particles.system_tick(ps, 0.1) // moved 5 units at 2 per unit
	testing.expect_value(t, len(ps.particles), 10)
}

@(test)
test_particles_velocity_and_limit_modules :: proc(t: ^testing.T) {
	tc_mem := new(common.TestCtx)
	defer free(tc_mem)
	common.setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer common.teardown(tc_mem)

	// Velocity over lifetime adds to position without touching velocity.
	ps := _make_system(tc_mem)
	ps.rate = 0
	ps.shape = .Point
	ps.start_lifetime = engine.minmax_constant(100)
	append(&ps.velocity_x.keys, engine.Curve_Key{t = 0, value = 2}, engine.Curve_Key{t = 1, value = 2})
	append(&ps.particles, particles.Particle{lifetime = 100, size = 1})
	for _ in 0 ..< 10 do particles.system_tick(ps, 0.1)
	p := ps.particles[0]
	testing.expect(t, abs(p.position.x - 2) < 0.01, "velocity_x must move the particle")
	testing.expect_value(t, p.velocity.x, 0)

	// Force over lifetime accelerates (velocity changes, unlike velocity_x).
	psf := _make_system(tc_mem)
	psf.rate = 0
	psf.start_lifetime = engine.minmax_constant(100)
	append(&psf.force_y.keys, engine.Curve_Key{t = 0, value = 3}, engine.Curve_Key{t = 1, value = 3})
	append(&psf.particles, particles.Particle{lifetime = 100})
	for _ in 0 ..< 10 do particles.system_tick(psf, 0.1)
	testing.expect(t, abs(psf.particles[0].velocity.y - 3) < 0.01, "force_y must accelerate")

	// Limit velocity dampens speed above the limit.
	ps2 := _make_system(tc_mem)
	ps2.rate = 0
	ps2.limit_speed = 2
	ps2.limit_dampen = 1
	append(&ps2.particles, particles.Particle{lifetime = 100, velocity = {10, 0, 0}})
	for _ in 0 ..< 5 do particles.system_tick(ps2, 0.1)
	testing.expect(t, ps2.particles[0].velocity.x < 2.2, "speed must decay toward the limit")
}

@(test)
test_particles_rotation_and_sim_speed :: proc(t: ^testing.T) {
	tc_mem := new(common.TestCtx)
	defer free(tc_mem)
	common.setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer common.teardown(tc_mem)

	// Start rotation + rotation over lifetime, degrees in, radians out.
	ps := _make_system(tc_mem)
	ps.rate = 10
	ps.start_rotation = engine.minmax_constant(90)
	ps.angular_velocity_min = 90
	ps.angular_velocity_max = 90
	ps.start_lifetime = engine.minmax_constant(100)
	particles.system_tick(ps, 0.1)
	testing.expect(t, abs(ps.particles[0].rotation - 1.5708) < 0.01, "start rotation must be 90 degrees in radians")
	for _ in 0 ..< 10 do particles.system_tick(ps, 0.1)
	testing.expect(t, abs(ps.particles[0].rotation - 3.1416) < 0.01, "angular velocity must integrate")

	// Simulation speed scales the whole advance; 0 runs at 1.
	ps2 := _make_system(tc_mem)
	ps2.rate = 10
	ps2.simulation_speed = 2
	ps2.start_lifetime = engine.minmax_constant(100)
	particles.system_tick(ps2, 0.5)
	testing.expect_value(t, len(ps2.particles), 10)

	ps3 := _make_system(tc_mem)
	ps3.rate = 10
	ps3.simulation_speed = 0 // scenes saved before the field existed
	ps3.start_lifetime = engine.minmax_constant(100)
	particles.system_tick(ps3, 0.5)
	testing.expect_value(t, len(ps3.particles), 5)
}

@(test)
test_particles_shapes :: proc(t: ^testing.T) {
	tc_mem := new(common.TestCtx)
	defer free(tc_mem)
	common.setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer common.teardown(tc_mem)

	ps := _make_system(tc_mem)
	ps.rate = 100
	ps.start_lifetime = engine.minmax_constant(100)
	ps.shape_radius = 1
	ps.shape_box = {2, 4, 6}

	ps.shape = .Hemisphere
	particles.system_tick(ps, 0.5)
	for p in ps.particles {
		testing.expect(t, p.position.z >= 0, "hemisphere stays on the +Z side")
		testing.expect(t, p.velocity.z >= -0.001, "hemisphere moves outward on +Z")
	}

	clear(&ps.particles)
	ps.shape = .Circle
	particles.system_tick(ps, 0.5)
	for p in ps.particles {
		testing.expect(t, p.position.z == 0 && p.velocity.z == 0, "circle stays in the XY plane")
	}

	clear(&ps.particles)
	ps.shape = .Edge
	particles.system_tick(ps, 0.5)
	for p in ps.particles {
		testing.expect(t, p.position.y == 0 && p.position.z == 0, "edge spawns on the X line")
		testing.expect(t, p.velocity.x == 0 && p.velocity.z > 0, "edge moves along +Z")
	}

	clear(&ps.particles)
	ps.shape = .Box
	particles.system_tick(ps, 0.5)
	for p in ps.particles {
		in_box := abs(p.position.x) <= 1 && abs(p.position.y) <= 2 && abs(p.position.z) <= 3
		testing.expect(t, in_box, "box spawns inside shape_box")
	}
}

@(test)
test_particles_speed_t :: proc(t: ^testing.T) {
	testing.expect_value(t, particles.speed_t(0.5, 0, 1), 0.5)
	testing.expect_value(t, particles.speed_t(-1, 0, 1), 0)
	testing.expect_value(t, particles.speed_t(5, 0, 1), 1)
	// Degenerate range: a step at lo.
	testing.expect_value(t, particles.speed_t(0.5, 1, 1), 0)
	testing.expect_value(t, particles.speed_t(2, 1, 1), 1)
}

@(test)
test_particles_orbital_and_rotation_by_speed :: proc(t: ^testing.T) {
	tc_mem := new(common.TestCtx)
	defer free(tc_mem)
	common.setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer common.teardown(tc_mem)

	// Orbital Z at 90 deg/s carries a particle at {1,0,0} to {0,1,0} in 1s.
	ps := _make_system(tc_mem)
	ps.rate = 0
	append(&ps.orbital_z.keys, engine.Curve_Key{t = 0, value = 90}, engine.Curve_Key{t = 1, value = 90})
	append(&ps.particles, particles.Particle{lifetime = 100, position = {1, 0, 0}})
	for _ in 0 ..< 10 do particles.system_tick(ps, 0.1)
	p := ps.particles[0]
	testing.expect(t, abs(p.position.x) < 0.01 && abs(p.position.y - 1) < 0.01, "orbital_z must rotate the position")

	// Rotation by speed: speed 1 in range [0,2] evaluates the curve at 0.5.
	ps2 := _make_system(tc_mem)
	ps2.rate = 0
	ps2.rotation_by_speed_min = 0
	ps2.rotation_by_speed_max = 2
	append(&ps2.rotation_by_speed.keys, engine.Curve_Key{t = 0, value = 90}, engine.Curve_Key{t = 1, value = 90})
	append(&ps2.particles, particles.Particle{lifetime = 100, velocity = {1, 0, 0}})
	for _ in 0 ..< 10 do particles.system_tick(ps2, 0.1)
	testing.expect(t, abs(ps2.particles[0].rotation - 1.5708) < 0.01, "rotation_by_speed must integrate")
}

// Repro for the editor flow: add particles_samples.scene into another scene
// as a nested instance, then save the host.
@(test)
test_particles_nested_scene_save :: proc(t: ^testing.T) {
	PREFAB_GUID :: "aaaaaaa1-bbb2-4cc3-8dd4-eeeeeeeeeef7"
	PS_TYPE_GUID :: "e5a7c2d1-4b3f-4c89-9a16-7d02e8b5f4a3"

	dir := "moonhug/tests/_tmp_particles_nested"
	mkerr := os.make_directory(dir)
	testing.expect(t, mkerr == nil || os.exists(dir), fmt.tprintf("temp dir: %v", mkerr))

	prefab_path := strings.concatenate({dir, "/emitters.scene"}, context.temp_allocator)
	prefab_meta := strings.concatenate({dir, "/emitters.scene.meta"}, context.temp_allocator)
	host_path := strings.concatenate({dir, "/host.scene"}, context.temp_allocator)
	host_meta := strings.concatenate({dir, "/host.scene.meta"}, context.temp_allocator)
	defer {
		os.remove(prefab_path)
		os.remove(prefab_meta)
		os.remove(host_path)
		os.remove(host_meta)
		os.remove(dir)
	}

	prefab_json := fmt.tprintf(`{{
  "root": 1,
  "next_local_id": 10,
  "transforms": [
    {{
      "local_id": 1, "name": "Burst", "is_active": true,
      "position": [0,0,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1,
      "parent": {{"pptr": {{"local_id": 0, "guid": "00000000-0000-0000-0000-000000000000"}}}},
      "children": [], "components": [{{"local_id": 7}}]
    }}
  ],
  "nested_scenes": [], "breadcrumbs": [],
  "components": [
    {{"__type": "%s", "base": {{"local_id": 7, "enabled": true}},
      "duration": 2.0, "looping": true, "rate": 0.0,
      "start_lifetime": {{"mode": 1, "value_min": 0.5, "value_max": 0.9}},
      "start_speed": {{"mode": 1, "value_min": 3.0, "value_max": 5.0}},
      "start_size": {{"mode": 1, "value_min": 0.3, "value_max": 0.5}},
      "start_rotation": {{"mode": 1, "value_min": 0.0, "value_max": 360.0}},
      "angular_velocity_min": -180.0, "angular_velocity_max": 180.0,
      "color_a": [1,0.7,0.2,1], "color_b": [1,0.3,0.1,1],
      "max_particles": 1000, "shape": 1, "shape_radius": 0.1,
      "bursts": [{{"time": 0.3, "count_min": 40, "count_max": 60, "cycles": 2, "interval": 0.5, "probability": 1.0}}],
      "color_over_life": {{"keys": [{{"t": 0, "color": [1,1,1,1]}}, {{"t": 1, "color": [1,0.2,0,0]}}]}},
      "size_over_life": {{"keys": [{{"t": 0, "value": 1}}, {{"t": 1, "value": 0.1}}]}},
      "sprite": {{"guid": "4c28be89-d6a9-4827-bf2c-44e8d7c6bc34", "local_id": 0}}
    }}
  ]
}}`, PS_TYPE_GUID)
	testing.expect(t, os.write_entire_file(prefab_path, transmute([]byte)prefab_json) == nil)
	meta := fmt.tprintf(`{{"guid": "%s"}}`, PREFAB_GUID)
	testing.expect(t, os.write_entire_file(prefab_meta, transmute([]byte)meta) == nil)

	tc_mem := new(common.TestCtx)
	defer free(tc_mem)
	common.setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer common.teardown(tc_mem)

	engine.asset_db_init(dir)
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	prefab_guid, gerr := uuid.read(PREFAB_GUID)
	testing.expect(t, gerr == nil)

	root := engine.Transform_Handle(tc_mem.scene.root.handle)
	hostH := engine.scene_instantiate_guid_nested(engine.Asset_GUID(prefab_guid), root)
	testing.expect(t, hostH != {}, "particles scene should instantiate as nested")
	if hostH == {} do return

	testing.expect(t, engine.scene_save(tc_mem.scene, host_path), "host save should succeed")

	// Reload: the bursts must survive the round trip.
	loaded := engine.scene_load_single_path(host_path)
	testing.expect(t, loaded != nil, "host should reload")
	if loaded == nil do return
	tc_mem.scene = loaded

	it := engine.pool_iterator(particles.particle_systems(&tc_mem.world))
	found := false
	for ps, _ in engine.pool_next(&it) {
		found = true
		testing.expect_value(t, len(ps.bursts), 1)
		if len(ps.bursts) == 1 do testing.expect_value(t, ps.bursts[0].count_max, i32(60))
	}
	testing.expect(t, found, "ParticleSystem should exist after reload")
}

// The editor flow that crashed: simulate the museum, then nest the REAL
// particles_samples.scene into a host scene and save it.
@(test)
test_particles_museum_nested_save :: proc(t: ^testing.T) {
	tc_mem := new(common.TestCtx)
	defer free(tc_mem)
	common.setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer common.teardown(tc_mem)

	engine.asset_db_init("moonhug/packages/particles/samples/particles_sample/assets")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	host_path := "moonhug/tests/_tmp_museum_host.scene"
	defer os.remove(host_path)

	museum_guid, gerr := uuid.read("5d2e9c81-7a46-4f03-b1c8-92e05a4d7f36")
	testing.expect(t, gerr == nil)

	root := engine.Transform_Handle(tc_mem.scene.root.handle)
	hostH := engine.scene_instantiate_guid_nested(engine.Asset_GUID(museum_guid), root)
	testing.expect(t, hostH != {}, "museum should instantiate as nested")
	if hostH == {} do return

	// Simulate a while (the user played before saving).
	it := engine.pool_iterator(particles.particle_systems(&tc_mem.world))
	n := 0
	particles.mark_sub_targets(&tc_mem.world)
	rocket: ^particles.ParticleSystem
	sparks: ^particles.ParticleSystem
	for ps, _ in engine.pool_next(&it) {
		n += 1
		if len(ps.sub_emitters) > 0 do rocket = ps
		if ps.is_sub_target do sparks = ps
		for _ in 0 ..< 60 do particles.system_tick(ps, 1.0 / 60.0)
	}
	testing.expect_value(t, n, 6) // Fountain, Burst, Smoke, Snow, Fireworks, Sparks

	// The Fireworks rocket's Death sub emitter resolved through scene load:
	// a dying particle fires the Sparks bursts. A referenced sub-emitter
	// target never emits on its own timeline, so Sparks stays silent even
	// though it was ticked for a full second above.
	testing.expect(t, rocket != nil && sparks != nil, "Fireworks systems should load")
	if rocket != nil && sparks != nil {
		testing.expect_value(t, len(sparks.particles), 0)
		append(&rocket.particles, particles.Particle{position = {10, 3, 0}, lifetime = 0.001})
		particles.system_tick(rocket, 1.0 / 60.0)
		testing.expect(t, len(sparks.particles) >= 40, "rocket death must fire the sparks burst")
	}

	testing.expect(t, engine.scene_save(tc_mem.scene, host_path), "host save should succeed")

	// Tear the instance down like the editor does (delete / scene close):
	// recursive transform destroy over the whole nested subtree.
	engine.transform_destroy(hostH)

	// Add it again and save again — slot reuse after the destroy.
	hostH2 := engine.scene_instantiate_guid_nested(engine.Asset_GUID(museum_guid), root)
	testing.expect(t, hostH2 != {}, "museum should instantiate a second time")
	testing.expect(t, engine.scene_save(tc_mem.scene, host_path), "second save should succeed")

	loaded := engine.scene_load_single_path(host_path)
	testing.expect(t, loaded != nil, "host should reload")
	if loaded != nil do tc_mem.scene = loaded
}

@(test)
test_particles_lifetime_by_emitter_speed :: proc(t: ^testing.T) {
	tc_mem := new(common.TestCtx)
	defer free(tc_mem)
	common.setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer common.teardown(tc_mem)

	// Still emitter: speed 0 maps to the curve at t=0 (multiplier 0.5).
	ps := _make_system(tc_mem)
	ps.rate = 10
	ps.start_lifetime = engine.minmax_constant(10)
	ps.lifetime_by_speed_min = 0
	ps.lifetime_by_speed_max = 1
	append(&ps.lifetime_by_speed.keys, engine.Curve_Key{t = 0, value = 0.5}, engine.Curve_Key{t = 1, value = 1})
	particles.system_tick(ps, 0.1)
	particles.system_tick(ps, 0.1)
	testing.expect(t, len(ps.particles) >= 1, "emitter should spawn")
	testing.expect(t, abs(ps.particles[0].lifetime - 5) < 0.01, "still emitter halves lifetime")

	// Fast emitter: speed past the range maps to the curve at t=1 (full).
	if tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(ps.owner)); tr != nil {
		tr.position = {10, 0, 0}
	}
	clear(&ps.particles)
	particles.system_tick(ps, 0.1)
	testing.expect(t, len(ps.particles) >= 1, "moving emitter should spawn")
	testing.expect(t, abs(ps.particles[0].lifetime - 10) < 0.01, "fast emitter keeps full lifetime")
}

@(test)
test_particles_noise :: proc(t: ^testing.T) {
	tc_mem := new(common.TestCtx)
	defer free(tc_mem)
	common.setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer common.teardown(tc_mem)

	// Noise moves the particle, bounded by strength, and is deterministic:
	// two identical systems produce the same displacement.
	ps1 := _make_system(tc_mem)
	ps2 := _make_system(tc_mem)
	for ps in ([]^particles.ParticleSystem{ps1, ps2}) {
		ps.rate = 0
		ps.noise_strength = 2
		ps.noise_frequency = 0.5
		append(&ps.particles, particles.Particle{lifetime = 100, position = {3, 1, 2}})
	}
	for _ in 0 ..< 10 {
		particles.system_tick(ps1, 0.1)
		particles.system_tick(ps2, 0.1)
	}
	p1 := ps1.particles[0]
	moved := p1.position - [3]f32{3, 1, 2}
	testing.expect(t, abs(moved.x) + abs(moved.y) + abs(moved.z) > 0.001, "noise must move the particle")
	testing.expect(t, abs(moved.x) <= 2 && abs(moved.y) <= 2 && abs(moved.z) <= 2, "displacement bounded by strength")
	testing.expect(t, p1.position == ps2.particles[0].position, "noise must be deterministic")

	// Strength 0 = off.
	ps3 := _make_system(tc_mem)
	ps3.rate = 0
	append(&ps3.particles, particles.Particle{lifetime = 100, position = {3, 1, 2}})
	particles.system_tick(ps3, 0.1)
	testing.expect(t, ps3.particles[0].position == [3]f32{3, 1, 2}, "no noise when strength is 0")
}

@(test)
test_particles_system_reset :: proc(t: ^testing.T) {
	tc_mem := new(common.TestCtx)
	defer free(tc_mem)
	common.setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer common.teardown(tc_mem)

	ps := _make_system(tc_mem)
	ps.rate = 10
	ps.prewarm = true
	ps.start_lifetime = engine.minmax_constant(100)
	particles.system_tick(ps, 0.5)
	testing.expect(t, len(ps.particles) > 0 && ps.time > 0)

	particles.system_reset(ps)
	testing.expect_value(t, len(ps.particles), 0)
	testing.expect_value(t, ps.time, 0)
	testing.expect(t, !ps.prewarmed, "reset must re-arm prewarm")

	// The effect replays identically in shape: prewarm fills again.
	particles.system_tick(ps, 0.5)
	testing.expect(t, len(ps.particles) >= 40, "replay after reset must prewarm again")
}

@(test)
test_particles_random_seed :: proc(t: ^testing.T) {
	tc_mem := new(common.TestCtx)
	defer free(tc_mem)
	common.setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer common.teardown(tc_mem)

	// Two systems with the same seed produce identical particles.
	ps1 := _make_system(tc_mem)
	ps2 := _make_system(tc_mem)
	for ps in ([]^particles.ParticleSystem{ps1, ps2}) {
		ps.random_seed = 7
		ps.rate = 50
		ps.start_lifetime = engine.minmax_constant(100)
		ps.start_speed = engine.minmax_range(1, 9)
	}
	for _ in 0 ..< 5 {
		particles.system_tick(ps1, 0.1)
		particles.system_tick(ps2, 0.1)
	}
	testing.expect_value(t, len(ps1.particles), len(ps2.particles))
	same := true
	for p, i in ps1.particles {
		if p.position != ps2.particles[i].position || p.velocity != ps2.particles[i].velocity do same = false
	}
	testing.expect(t, same, "same seed must replay the same effect")

	// Reset replays the seeded system identically.
	first := make([dynamic][3]f32, context.temp_allocator)
	for p in ps1.particles do append(&first, p.position)
	particles.system_reset(ps1)
	for _ in 0 ..< 5 do particles.system_tick(ps1, 0.1)
	testing.expect_value(t, len(ps1.particles), len(first))
	replay := true
	for p, i in ps1.particles {
		if p.position != first[i] do replay = false
	}
	testing.expect(t, replay, "reset with a fixed seed must reproduce the effect")
}

@(test)
test_particles_sub_emitters :: proc(t: ^testing.T) {
	tc_mem := new(common.TestCtx)
	defer free(tc_mem)
	common.setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer common.teardown(tc_mem)

	// Parent emits one short-lived particle; its death fires the target's
	// bursts at the death position.
	parent := _make_system(tc_mem)
	parent.rate = 0
	parent.sim_space = .World
	parent.gravity_modifier = 0

	target := _make_system(tc_mem)
	target.rate = 0
	target.sim_space = .World
	target.start_lifetime = engine.minmax_constant(100)
	target.start_speed = engine.minmax_constant(0)
	target.shape = .Point
	append(&target.bursts, particles.Burst{count_min = 8, count_max = 8, probability = 1})

	target_handle: engine.Handle
	{
		it := engine.pool_iterator(particles.particle_systems(&tc_mem.world))
		for ps, h in engine.pool_next(&it) {
			if ps == target do target_handle = h
		}
	}
	target_handle.type_key = .ParticleSystem // pool iterators hand out untyped handles
	append(&parent.sub_emitters, particles.Sub_Emitter{
		target = {handle = target_handle}, trigger = .Death, probability = 1,
	})

	append(&parent.particles, particles.Particle{position = {3, 4, 5}, lifetime = 0.05})
	particles.system_tick(parent, 0.1) // the particle dies this tick
	testing.expect_value(t, len(parent.particles), 0)
	testing.expect_value(t, len(target.particles), 8)
	for p in target.particles {
		testing.expect(t, p.position == [3]f32{3, 4, 5}, "sub emission must anchor at the death position")
	}

	// Birth trigger fires on spawn; probability 0 never fires.
	clear(&target.particles)
	parent.sub_emitters[0] = particles.Sub_Emitter{
		target = {handle = target_handle}, trigger = .Birth, probability = 1,
	}
	parent.rate = 10
	particles.system_tick(parent, 0.1) // one spawn
	testing.expect_value(t, len(target.particles), 8)

	clear(&target.particles)
	parent.sub_emitters[0].probability = 0
	particles.system_tick(parent, 0.1)
	testing.expect_value(t, len(target.particles), 0)
}

@(test)
test_particles_playback_control :: proc(t: ^testing.T) {
	tc_mem := new(common.TestCtx)
	defer free(tc_mem)
	common.setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer common.teardown(tc_mem)

	// Manual start: nothing plays until system_play.
	ps := _make_system(tc_mem)
	ps.manual_start = true
	ps.rate = 10
	ps.start_lifetime = engine.minmax_constant(100)
	for _ in 0 ..< 5 do particles.system_tick(ps, 0.1)
	testing.expect_value(t, len(ps.particles), 0)
	particles.system_play(ps)
	for _ in 0 ..< 5 do particles.system_tick(ps, 0.1)
	testing.expect_value(t, len(ps.particles), 5)

	// Pause freezes aging and emission entirely.
	particles.system_pause(ps)
	frozen_time := ps.time
	for _ in 0 ..< 5 do particles.system_tick(ps, 0.1)
	testing.expect_value(t, len(ps.particles), 5)
	testing.expect_value(t, ps.time, frozen_time)

	// Stop ends emission, live particles keep aging.
	particles.system_play(ps)
	particles.system_stop(ps)
	ps.start_lifetime = engine.minmax_constant(0.3)
	for &p in ps.particles do p.lifetime = 0.3
	for _ in 0 ..< 5 do particles.system_tick(ps, 0.1)
	testing.expect_value(t, len(ps.particles), 0) // aged out, nothing new

	// Play after stop restarts from time zero.
	particles.system_play(ps)
	testing.expect_value(t, ps.time, 0)
	ps.start_lifetime = engine.minmax_constant(100)
	for _ in 0 ..< 5 do particles.system_tick(ps, 0.1)
	testing.expect_value(t, len(ps.particles), 5)

	// Stop with clear drops live particles immediately.
	particles.system_stop(ps, clear_particles = true)
	testing.expect_value(t, len(ps.particles), 0)
}

@(test)
test_particles_minmax_curve_start_values :: proc(t: ^testing.T) {
	tc_mem := new(common.TestCtx)
	defer free(tc_mem)
	common.setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer common.teardown(tc_mem)

	// Curve mode: start speed follows the cycle time — early particles slow,
	// late particles fast (duration 1, curve 1 -> 9 over the cycle).
	ps := _make_system(tc_mem)
	ps.duration = 1
	ps.looping = false // a wrap would send the last spawn back to t = 0
	ps.rate = 2
	ps.gravity_modifier = 0
	ps.shape = .Point
	ps.start_lifetime = engine.minmax_constant(100)
	ps.start_speed.mode = .Curve
	append(&ps.start_speed.curve_min.keys,
		engine.Curve_Key{t = 0, value = 1}, engine.Curve_Key{t = 1, value = 9})
	for _ in 0 ..< 4 do particles.system_tick(ps, 0.25)
	testing.expect(t, len(ps.particles) >= 2)
	first := linalg.length(ps.particles[0].velocity)
	last := linalg.length(ps.particles[len(ps.particles) - 1].velocity)
	testing.expect(t, first < last, "speed curve must rise over the cycle")
	testing.expect(t, first >= 1 && last <= 9, "speeds stay inside the curve's range")

	// Random between two constants stays inside the range.
	ps2 := _make_system(tc_mem)
	ps2.rate = 50
	ps2.shape = .Point
	ps2.start_lifetime = engine.minmax_constant(100)
	ps2.start_size = engine.minmax_range(2, 3)
	particles.system_tick(ps2, 1)
	for p in ps2.particles {
		testing.expect(t, p.size >= 2 && p.size <= 3, "sizes stay inside the range")
	}
}

@(test)
test_particles_trails :: proc(t: ^testing.T) {
	tc_mem := new(common.TestCtx)
	defer free(tc_mem)
	common.setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer common.teardown(tc_mem)

	// A moving particle records points at the min-distance spacing.
	ps := _make_system(tc_mem)
	ps.rate = 0
	ps.sim_space = .World
	ps.gravity_modifier = 0
	ps.trail_ratio = 1
	ps.trail_lifetime = 1
	ps.trail_min_distance = 0.1
	append(&ps.particles, particles.Particle{
		velocity = {5, 0, 0}, lifetime = 100, has_trail = true,
	})
	for _ in 0 ..< 10 do particles.system_tick(ps, 0.1)
	p := &ps.particles[0]
	testing.expect(t, int(p.trail_len) >= 8, "moving particle must record trail points")
	newest := p.trail[(int(p.trail_head) + int(p.trail_len) - 1) % particles.TRAIL_MAX]
	testing.expect(t, newest.position.x > 3, "points follow the particle")

	// Expiry: a short trail lifetime drops old points as time passes.
	ps2 := _make_system(tc_mem)
	ps2.rate = 0
	ps2.sim_space = .World
	ps2.gravity_modifier = 0
	ps2.trail_ratio = 1
	ps2.trail_lifetime = 0.005 // x lifetime 100 = 0.5s of trail
	ps2.trail_min_distance = 0.1
	append(&ps2.particles, particles.Particle{
		velocity = {5, 0, 0}, lifetime = 100, has_trail = true,
	})
	for _ in 0 ..< 20 do particles.system_tick(ps2, 0.1) // 2s at 0.5s trail life
	p2 := &ps2.particles[0]
	testing.expect(t, int(p2.trail_len) <= 6, "old trail points must expire")
	testing.expect(t, int(p2.trail_len) >= 3, "recent points survive")

	// Ratio 0 spawns no trails.
	ps3 := _make_system(tc_mem)
	ps3.rate = 10
	ps3.start_lifetime = engine.minmax_constant(100)
	particles.system_tick(ps3, 0.5)
	for p3 in ps3.particles do testing.expect(t, !p3.has_trail, "ratio 0 must not trail")
}

@(test)
test_particles_control_track :: proc(t: ^testing.T) {
	tc_mem := new(common.TestCtx)
	defer free(tc_mem)
	common.setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer common.teardown(tc_mem)
	anim.animation_clip_cache_init()
	defer anim.animation_clip_cache_shutdown()
	particles.particles_track_init()

	// A manual-start seeded emitter, driven by a control clip on [0.5, 1.5).
	root := engine.transform_new("Stage")
	engine.scene_set_root(tc_mem.scene, root)
	owned, raw := engine.transform_add_comp(root, .ParticleSystem)
	ps := cast(^particles.ParticleSystem)raw
	ps.enabled = true
	ps.manual_start = true
	ps.random_seed = 7
	ps.rate = 10
	ps.start_lifetime = engine.minmax_constant(100)

	_, draw_ := engine.transform_add_comp(root, .PlayableDirector)
	d := cast(^seq.PlayableDirector)draw_
	d.enabled = true
	d.wrap = .Once
	d.duration = 2
	defer seq.director_teardown(d)
	track_node := engine.transform_new("fx", root)
	_, tcc := engine.transform_get_or_add_comp(track_node, seq.TimelineTrack)
	tcc.kind = strings.clone("particles")
	tcc.target = {handle = owned.handle}
	clip_node := engine.transform_new("clip", track_node)
	_, ccc := engine.transform_get_or_add_comp(clip_node, seq.TimelineClip)
	ccc.start = 0.5
	ccc.duration = 1

	// Before the span: the system stays stopped (manual start).
	for _ in 0 ..< 3 do seq.director_tick(d, 0.1) // t = 0.3
	particles.system_tick(ps, 0.1)
	testing.expect_value(t, len(ps.particles), 0)

	// Inside the span the track plays it; the sim tick then emits.
	for _ in 0 ..< 5 do seq.director_tick(d, 0.1) // t = 0.8
	testing.expect(t, !ps.stopped, "control span must play the system")
	for _ in 0 ..< 5 do particles.system_tick(ps, 0.1)
	testing.expect(t, len(ps.particles) > 0, "playing system must emit")

	// After the span: stopped again.
	for _ in 0 ..< 10 do seq.director_tick(d, 0.1) // t = 1.8
	testing.expect(t, ps.stopped, "leaving the span must stop the system")

	// Scrub to mid-span: deterministic restart-to-time.
	seq.director_set_time(d, 1.0)
	testing.expect(t, abs(ps.time - 0.5) < 0.001, "scrub must advance the system to the clip-local time")
	first := len(ps.particles)
	testing.expect(t, first >= 4 && first <= 6, "0.5s at rate 10 is ~5 particles")
	pos0 := ps.particles[0].position
	seq.director_set_time(d, 1.0) // same playhead — the seeded replay matches
	testing.expect_value(t, len(ps.particles), first)
	testing.expect(t, ps.particles[0].position == pos0, "seeded scrub must be deterministic")
}

// The timeline_sample package end to end: the demo scene loads, the
// director's binding resolves through the scene loader, the timeline loads
// from its .timeline file, and the control track fires the rocket.
@(test)
test_timeline_sample_scene :: proc(t: ^testing.T) {
	tc_mem := new(common.TestCtx)
	defer free(tc_mem)
	common.setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer common.teardown(tc_mem)

	engine.asset_db_init("moonhug/packages/animation/samples/timeline_sample/assets")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()
	anim.animation_clip_cache_init()
	defer anim.animation_clip_cache_shutdown()
	seq.register_builtin_tracks()
	particles.particles_track_init()

	loaded := engine.scene_load_single_path("moonhug/packages/animation/samples/timeline_sample/assets/timeline_demo.scene")
	testing.expect(t, loaded != nil, "demo scene should load")
	if loaded == nil do return
	tc_mem.scene = loaded

	d: ^seq.PlayableDirector
	{
		it := engine.pool_iterator(seq.playable_directors(&tc_mem.world))
		for dd, _ in engine.pool_next(&it) do d = dd
	}
	rocket: ^particles.ParticleSystem
	{
		it := engine.pool_iterator(particles.particle_systems(&tc_mem.world))
		for ps, _ in engine.pool_next(&it) {
			if ps.manual_start do rocket = ps
		}
	}
	testing.expect(t, d != nil && rocket != nil, "director and rocket should load")
	if d == nil || rocket == nil do return

	// Before the clip span the rocket holds (manual start).
	for _ in 0 ..< 3 do seq.director_tick(d, 0.1) // t = 0.3
	particles.system_tick(rocket, 0.1)
	testing.expect_value(t, len(rocket.particles), 0)

	// Inside the span [0.5, 3.5) the track plays it — the binding resolved.
	for _ in 0 ..< 7 do seq.director_tick(d, 0.1) // t = 1.0
	testing.expect(t, !rocket.stopped && rocket.started, "control clip must play the rocket")
	for _ in 0 ..< 20 do particles.system_tick(rocket, 0.1)
	testing.expect(t, len(rocket.particles) > 0, "rocket must emit inside the span")

	// Scrub co-simulates the whole effect: the sparks system (a sub-emitter
	// target, not bound to any track) replays alongside the rocket.
	sparks: ^particles.ParticleSystem
	{
		it := engine.pool_iterator(particles.particle_systems(&tc_mem.world))
		for ps, _ in engine.pool_next(&it) {
			if !ps.manual_start do sparks = ps
		}
	}
	testing.expect(t, sparks != nil)
	if sparks != nil {
		seq.director_set_time(d, 3.0) // clip-local 2.5s of replay
		testing.expect(t, abs(sparks.time - 2.5) < 0.05, "sub-emitter target must co-simulate on scrub")
	}
}

// The edit-mode preview (packages/particles/editor) remembers which system it
// is previewing ACROSS FRAMES. It must hold the owner transform HANDLE, never
// a ^ParticleSystem: pool slots are a fixed array with a freelist, so a
// destroyed component's slot address is handed to the next component created.
// A stale pointer therefore passes any "is this still alive" scan while
// pointing at an unrelated system — which is how a preview ends up ticking
// and resetting something the user never selected after a scene reload.
//
// This pins both halves: the address DOES alias, and the handle does NOT.
@(test)
test_component_pointer_aliases_after_recycle :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	a := engine.transform_new("A")
	owned_a, raw_a := engine.transform_add_comp(a, .ParticleSystem)
	testing.expect(t, raw_a != nil, "first system created")

	// Scene reload equivalent: the component and its owner go away, then new
	// ones are created into the freed slots.
	engine.transform_destroy(a)
	b := engine.transform_new("B")
	owned_b, raw_b := engine.transform_add_comp(b, .ParticleSystem)
	testing.expect(t, raw_b != nil, "second system created")

	testing.expect(t, raw_a == raw_b,
		"pool slots recycle by address — a cached ^ParticleSystem would now alias a different system")
	testing.expect(t, owned_a.handle != owned_b.handle,
		"handles carry a generation, so they stay distinct across recycling")

	// Resolving through the handle is what the preview does: the dead one
	// yields nothing, the live one yields exactly its own component.
	w := engine.ctx_world()
	testing.expect(t, !engine.world_pool_valid(w, owned_a.handle), "the recycled handle is dead")
	testing.expect(t, engine.world_pool_valid(w, owned_b.handle), "the live handle resolves")
}
