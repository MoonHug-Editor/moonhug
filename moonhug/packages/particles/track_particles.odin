package particles

// The particles Control Track (docs/Sequencer.md): a timeline clip span
// plays the bound ParticleSystem, leaving the span stops it and clears live
// particles. Scrubbing rides the restart-to-time contract: system_reset +
// fixed seed + fixed-step advance to the clip-local time, so a seeded system
// shows the exact same frame at the same playhead position every scrub — and
// play mode shows that same frame, which is why the span clears rather than
// letting particles age out past the clip end.
//
// This file is the particles package's only sequencer dependency — the
// track registers itself, the sequencer never imports particles. Author
// track-driven systems with manual_start (and a random_seed for stable
// scrubbing): the span decides when they play.

import "moonhug:engine"
import seq "moonhug:packages/sequencer"

// The kind's components: the track carries what it drives; the clip needs no
// payload (the span itself is the instruction).
@(component)
@(typ_guid={guid = "e4302a74-3eae-4bce-93c0-b3cc8eba2661"})
TrackParticles :: struct {
	using base: engine.CompData `inspect:"-"`,

	system: engine.Ref_Local `ref:"ParticleSystem"`,
}

@(component)
@(typ_guid={guid = "8ab6c411-bcd5-4f71-8e0d-ff13b17dc52f"})
ClipParticles :: struct {
	using base: engine.CompData `inspect:"-"`,
}

@(phase={key=ImportersInit, order=4})
particles_track_init :: proc() {
	@(static) done := false
	if done do return
	done = true
	seq.track_register(seq.Track_Desc{
		track_key   = .TrackParticles,
		clip_key    = .ClipParticles,
		label       = "particles",
		tick        = _particles_track_tick,
		preview_end = _particles_track_preview_end,
	})
}

// The ParticleSystem this track drives, or nil.
@(private = "file")
_particles_track_system :: proc(ctx: ^seq.Track_Ctx) -> ^ParticleSystem {
	_, pt := get_comp(ctx.track.node, TrackParticles)
	if pt == nil || pt.system.handle.type_key != .ParticleSystem do return nil
	w := engine.ctx_world()
	if !engine.world_pool_valid(w, pt.system.handle) do return nil
	return cast(^ParticleSystem)engine.world_pool_get(w, pt.system.handle)
}

_particles_track_tick :: proc(ctx: ^seq.Track_Ctx) {
	ps := _particles_track_system(ctx)
	if ps == nil do return

	active: ^seq.Clip_View
	for &c in ctx.track.clips {
		if seq.track_clip_active(ctx, &c) {
			active = &c
			break
		}
	}

	if ctx.mode != .Play {
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
		// Leaving the span CLEARS live particles, matching what scrubbing and
		// the editor preview show at the same playhead position. The span is
		// the effect's existence: a plain system_stop would let particles age
		// out past the clip end in play mode only, so the same timeline looked
		// different depending on how you watched it.
		system_stop(ps, clear_particles = true)
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

// The editor's preview stopped: clear the effect it was driving (the bound
// system and its sub-emitter targets).
_particles_track_preview_end :: proc(ctx: ^seq.Track_Ctx) {
	ps := _particles_track_system(ctx)
	if ps == nil do return
	list := make([dynamic]^ParticleSystem, context.temp_allocator)
	_scrub_effect(ps, &list)
	for e in list do system_reset(e)
}
