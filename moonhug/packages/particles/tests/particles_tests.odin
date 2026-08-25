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
