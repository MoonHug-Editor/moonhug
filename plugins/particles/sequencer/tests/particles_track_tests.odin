package particles_sequencer_tests

// The particles Control Track (particles/sequencer) driven through a director.

import "core:testing"
import "moonhug:packages/engine"
import anim "moonhug:packages/animation"
import seq "moonhug:packages/sequencer"
import particles "moonhug:packages/particles"
import common "moonhug:tests/common"
import particles_seq "moonhug:packages/particles/sequencer"

@(test)
test_particles_control_track :: proc(t: ^testing.T) {
	tc_mem := new(common.TestCtx)
	defer free(tc_mem)
	common.setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer common.teardown(tc_mem)
	anim.animation_clip_cache_init()
	defer anim.animation_clip_cache_shutdown()
	particles_seq.particles_track_init()

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
	engine.transform_get_or_add_comp(track_node, seq.TimelineTrack)
	_, ptc := engine.transform_get_or_add_comp(track_node, particles_seq.TrackParticles)
	ptc.system = {handle = owned.handle}
	clip_node := engine.transform_new("clip", track_node)
	_, ccc := engine.transform_get_or_add_comp(clip_node, seq.TimelineClip)
	ccc.start = 0.5
	ccc.duration = 1
	engine.transform_get_or_add_comp(clip_node, particles_seq.ClipParticles)

	// Before the span: the system stays stopped (manual start).
	for _ in 0 ..< 3 do seq.director_tick(d, 0.1) // t = 0.3
	particles.system_tick(ps, 0.1)
	testing.expect_value(t, len(ps.particles), 0)

	// Inside the span the track plays it; the sim tick then emits.
	for _ in 0 ..< 5 do seq.director_tick(d, 0.1) // t = 0.8
	testing.expect(t, !ps.stopped, "control span must play the system")
	for _ in 0 ..< 5 do particles.system_tick(ps, 0.1)
	testing.expect(t, len(ps.particles) > 0, "playing system must emit")

	// After the span: stopped, and live particles CLEARED. start_lifetime is
	// 100s here, so a plain stop would leave every particle emitted inside the
	// span alive long past the clip end — visible in play mode only, while
	// scrubbing past the same point shows nothing.
	for _ in 0 ..< 10 do seq.director_tick(d, 0.1) // t = 1.8
	testing.expect(t, ps.stopped, "leaving the span must stop the system")
	testing.expect_value(t, len(ps.particles), 0)

	// Play and scrub agree at the same playhead: both empty past the span.
	seq.director_set_time(d, 1.8)
	testing.expect_value(t, len(ps.particles), 0)

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
	particles_seq.particles_track_init()

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
