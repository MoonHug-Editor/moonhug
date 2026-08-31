package sequencer

// The script track kind: a clip WRAPS SCRIPTS. Each script on the clip gets
// its lifecycle procs called — enter when playback crosses into the span,
// tick every tick inside it, exit when it leaves. Runtime only — scripts are
// game code with real side effects, so scrubbing and the editor preview
// never call them (the marker rule, extended to spans).
//
// A zero-duration clip is an instant: enter and exit fire together on the
// tick that passes over it; an empty span has no inside, so tick never runs.

import "moonhug:engine"
import core "moonhug:packages/sequencer/core"

@(component)
@(typ_guid={guid = "06f39202-753c-4bc9-a7c1-cfc876559f72"})
TrackScript :: struct {
	using base: engine.CompData `inspect:"-"`,

	// The track's default subject, handed to every script as ctx.target. A
	// script addressing something else carries its own ref field.
	target: engine.Ref_Local `ref:"Transform"`,
}

@(component)
@(typ_guid={guid = "bd5194a0-ff1c-4c4a-97de-512e26b7773b"})
ClipScript :: struct {
	using base: engine.CompData `inspect:"-"`,

	scripts: [dynamic]ScriptUnion,
}

on_destroy_ClipScript :: proc(c: ^ClipScript) {
	cleanup_ClipScript(c)
}

cleanup_ClipScript :: proc(c: ^ClipScript) {
	for &s in c.scripts do script_destroy(&s)
	delete(c.scripts)
	engine.comp_zero(c)
}

@(private = "file")
_script_track_tick :: proc(ctx: ^Track_Ctx) {
	// Play only. Never Scrub, never Preview_Play — a script is a side
	// effect, and posing the timeline must not perform it.
	if ctx.mode != .Play do return
	_, st := get_comp(ctx.track.node, TrackScript)
	if st == nil do return

	sctx := core.Script_Ctx{
		owner  = ctx.owner,
		target = st.target,
		time   = ctx.time,
	}
	for &c in ctx.track.clips {
		_, sc := get_comp(c.node, ClipScript)
		if sc == nil do continue
		sctx.clip = c.node

		end := c.start + c.duration
		inside_prev := ctx.prev_time >= c.start && ctx.prev_time < end
		inside_now := ctx.time >= c.start && ctx.time < end

		// The INSIDE-NESS TRANSITION is the event, not the crossing: a
		// crossing test fires on the tick after time lands exactly on a
		// boundary, while the transition fires on the landing tick — using
		// both double-fires. The transition also handles the cases crossings
		// miss for free: a Once timeline completing CLAMPED at duration
		// exits (time == duration sits outside the half-open span), and a
		// loop seam exits a clip ending at duration. track_crossed covers
		// the one gap the transition has — a clip passed over ENTIRELY
		// inside one tick window (zero-duration, or shorter than a frame):
		// enter and exit both fire on that tick.
		passed_over := !inside_prev && !inside_now && track_crossed(ctx, c.start)
		entered := (!inside_prev && inside_now) || passed_over
		exited := (inside_prev && !inside_now) || passed_over

		if entered {
			for &s in sc.scripts do script_enter(&s, &sctx)
		}
		if inside_now {
			for &s in sc.scripts do script_tick(&s, &sctx)
		}
		if exited {
			for &s in sc.scripts do script_exit(&s, &sctx)
		}
	}
}

// Called from register_builtin_tracks (timeline.odin).
_script_track_desc :: proc() -> Track_Desc {
	return Track_Desc{
		track_key = .TrackScript,
		clip_key  = .ClipScript,
		label     = "script",
		tick      = _script_track_tick,
	}
}
