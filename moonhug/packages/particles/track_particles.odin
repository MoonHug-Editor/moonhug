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
	anim.track_register(anim.Track_Desc{kind = "particles", binding_type = "ParticleSystem", tick = _particles_track_tick})
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
		// The whole effect co-simulates: sub-emitter targets must age the
		// particles the replay's triggers inject into them.
		list := make([dynamic]^ParticleSystem, context.temp_allocator)
		_scrub_effect(ps, &list)
		for e in list {
			system_reset(e)
			e.is_sub_target = e != ps // triggers drive targets, never their own timeline
		}
		if active != nil {
			// The explicit play overrides manual_start — the span IS the play.
			system_play(ps)
			STEP :: f32(1.0 / 60.0)
			local := ctx.time - active.start
			for t := f32(0); t < local; t += STEP {
				dt := min(STEP, local - t)
				for e in list do system_tick(e, dt)
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

// The bound system plus its transitive sub-emitter targets, depth-limited
// like _sub_emit's chain guard.
@(private = "file")
_scrub_effect :: proc(ps: ^ParticleSystem, out: ^[dynamic]^ParticleSystem) {
	for e in out^ {
		if e == ps do return
	}
	if len(out^) >= 8 do return
	append(out, ps)
	w := engine.ctx_world()
	for &sub in ps.sub_emitters {
		if sub.target.handle.type_key != .ParticleSystem do continue
		if !engine.world_pool_valid(w, sub.target.handle) do continue
		if target := cast(^ParticleSystem)engine.world_pool_get(w, sub.target.handle); target != nil {
			_scrub_effect(target, out)
		}
	}
}
