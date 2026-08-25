package particles_tests

// Headless simulation coverage for the range-based Shuriken core: emission
// rate, lifetime death, the max-particles cap, non-looping duration cutoff.
// Rendering is GPU-gated (texture loads) and stays untested here.

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
