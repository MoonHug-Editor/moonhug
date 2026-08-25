package particles_tests

// Headless simulation coverage for the range-based Shuriken core: emission
// rate, lifetime death, the max-particles cap, non-looping duration cutoff.
// Rendering is GPU-gated (texture loads) and stays untested here.

import "core:encoding/uuid"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "moonhug:engine"
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
	ps.lifetime_min = 1
	ps.lifetime_max = 1
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
	ps.lifetime_min = 100
	ps.lifetime_max = 100
	ps.max_particles = 25

	particles.system_tick(ps, 1)
	testing.expect_value(t, len(ps.particles), 25)

	// Non-looping: emission stops after `duration`, live particles remain.
	ps2 := _make_system(tc_mem)
	ps2.looping = false
	ps2.duration = 0.5
	ps2.rate = 10
	ps2.lifetime_min = 100
	ps2.lifetime_max = 100
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
	ps.lifetime_min = 100
	ps.lifetime_max = 100
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
	ps2.lifetime_min = 100
	ps2.lifetime_max = 100
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
	ps.lifetime_min = 100
	ps.lifetime_max = 100
	particles.system_tick(ps, 0.5)
	particles.system_tick(ps, 0.5)
	testing.expect_value(t, len(ps.particles), 0) // still inside the delay
	particles.system_tick(ps, 0.5)
	testing.expect_value(t, len(ps.particles), 5)

	// Prewarm: the first tick behaves as if one full cycle already ran.
	ps2 := _make_system(tc_mem)
	ps2.prewarm = true
	ps2.rate = 10
	ps2.lifetime_min = 100
	ps2.lifetime_max = 100
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
	ps.lifetime_min = 100
	ps.lifetime_max = 100
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
	ps.lifetime_min = 100
	ps.lifetime_max = 100
	append(&ps.velocity_x.keys, engine.Curve_Key{t = 0, value = 2}, engine.Curve_Key{t = 1, value = 2})
	append(&ps.particles, particles.Particle{lifetime = 100, size = 1})
	for _ in 0 ..< 10 do particles.system_tick(ps, 0.1)
	p := ps.particles[0]
	testing.expect(t, abs(p.position.x - 2) < 0.01, "velocity_x must move the particle")
	testing.expect_value(t, p.velocity.x, 0)

	// Force over lifetime accelerates (velocity changes, unlike velocity_x).
	psf := _make_system(tc_mem)
	psf.rate = 0
	psf.lifetime_min = 100
	psf.lifetime_max = 100
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
	ps.rotation_min = 90
	ps.rotation_max = 90
	ps.angular_velocity_min = 90
	ps.angular_velocity_max = 90
	ps.lifetime_min = 100
	ps.lifetime_max = 100
	particles.system_tick(ps, 0.1)
	testing.expect(t, abs(ps.particles[0].rotation - 1.5708) < 0.01, "start rotation must be 90 degrees in radians")
	for _ in 0 ..< 10 do particles.system_tick(ps, 0.1)
	testing.expect(t, abs(ps.particles[0].rotation - 3.1416) < 0.01, "angular velocity must integrate")

	// Simulation speed scales the whole advance; 0 runs at 1.
	ps2 := _make_system(tc_mem)
	ps2.rate = 10
	ps2.simulation_speed = 2
	ps2.lifetime_min = 100
	ps2.lifetime_max = 100
	particles.system_tick(ps2, 0.5)
	testing.expect_value(t, len(ps2.particles), 10)

	ps3 := _make_system(tc_mem)
	ps3.rate = 10
	ps3.simulation_speed = 0 // scenes saved before the field existed
	ps3.lifetime_min = 100
	ps3.lifetime_max = 100
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
	ps.lifetime_min = 100
	ps.lifetime_max = 100
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
      "lifetime_min": 0.5, "lifetime_max": 0.9,
      "speed_min": 3.0, "speed_max": 5.0,
      "size_min": 0.3, "size_max": 0.5,
      "rotation_min": 0.0, "rotation_max": 360.0,
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
	for ps, _ in engine.pool_next(&it) {
		n += 1
		for _ in 0 ..< 60 do particles.system_tick(ps, 1.0 / 60.0)
	}
	testing.expect_value(t, n, 4) // Fountain, Burst, Smoke, Snow

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
	ps.lifetime_min = 10
	ps.lifetime_max = 10
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
