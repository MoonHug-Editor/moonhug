package particles

// The particles Control Track (docs/Sequencer.md): a timeline clip span
// plays the bound ParticleSystem, leaving the span stops it (particles play
// out). Scrubbing rides the restart-to-time contract: system_reset + fixed
// seed + fixed-step advance to the clip-local time, so a seeded system shows
// the exact same frame at the same playhead position every scrub.
//
// This file is the particles package's only animation-package dependency —
// the track registers itself, the sequencer never imports particles. Author
// track-driven systems with manual_start (and a random_seed for stable
// scrubbing): the span decides when they play.

import "moonhug:engine"
import anim "moonhug:packages/animation"

@(phase={key=ImportersInit, order=4})
particles_track_init :: proc() {
	@(static) done := false
	if done do return
	done = true
	anim.track_register(anim.Track_Desc{kind = "particles", tick = _particles_track_tick})
}

_particles_track_tick :: proc(ctx: ^anim.Track_Ctx) {
	if ctx.target.handle.type_key != .ParticleSystem do return
	w := engine.ctx_world()
	if !engine.world_pool_valid(w, ctx.target.handle) do return
	ps := cast(^ParticleSystem)engine.world_pool_get(w, ctx.target.handle)
	if ps == nil do return

	active: ^anim.Timeline_Clip
	for &c in ctx.track.clips {
		if anim.track_clip_active(ctx, &c) {
			active = &c
			break
		}
	}

	if ctx.scrub {
		// Deterministic restart-to-time: replay the clip-local window in
		// fixed steps. Editor scrubs only — play mode never sets scrub.
		// The explicit play overrides manual_start — the span IS the play.
		system_reset(ps)
		if active != nil {
			system_play(ps)
			STEP :: f32(1.0 / 60.0)
			local := ctx.time - active.start
			for t := f32(0); t < local; t += STEP {
				system_tick(ps, min(STEP, local - t))
			}
		}
		return
	}

	if active != nil {
		if ps.stopped || !ps.started do system_play(ps)
	} else if ps.started && !ps.stopped {
		system_stop(ps)
	}
}
