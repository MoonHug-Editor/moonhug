package sequencer

// The tween track kind: a clip's SPAN drives its tweens' evaluate(t) —
// pose as a pure function of the playhead. That purity is the edit-mode
// story: the same evaluation serves Play, scrubbing and the preview, exact
// at any playhead position with no replay.
//
// Modes differ only in AUTHORITY:
// - Scrub / Preview_Play: the timeline owns the pose. Every clip evaluates
//   at clamped t every evaluation — before its span that is t=0 (the
//   captured start pose, so scrubbing back restores), after it t=1.
// - Play: the game owns objects outside spans. A clip evaluates inside its
//   span and once more at t=1 on the way out (exit transition or a clip
//   passed over entirely); before its span it never touches the target.
//
// Capture: to-style tweens capture `from` on first evaluation and refresh
// per their Capture_Mode (sequencer/core): .Play holds one capture per play
// session — surviving span exits and loop wraps, so a loop replays the same
// motion, while a timeline PLAYED AGAIN captures the game state it finds —
// and .Enter refreshes on every span entry, so each pass continues from
// wherever the object is now. The editor's preview ignores both (it always
// shows the first pass) and preview_end clears every capture.

import "moonhug:engine"
import core "moonhug:packages/sequencer/core"

@(component)
@(typ_guid={guid = "e45dd366-bc5b-4bb8-81e7-67b339a55680"})
TweenTrack :: struct {
	using base: engine.CompData `inspect:"-"`,

	// The track's default subject, handed to every tween as ctx.target. A
	// tween addressing something else sets its own target field.
	target: engine.Ref_Local `ref:"Transform"`,
}

@(component)
@(typ_guid={guid = "0f1d4bcc-cf05-4958-8d73-775b9e28a18e"})
TweenClip :: struct {
	using base: engine.CompData `inspect:"-"`,

	tweens: [dynamic]TweenUnion,
}

on_destroy_TweenClip :: proc(c: ^TweenClip) {
	cleanup_TweenClip(c)
}

cleanup_TweenClip :: proc(c: ^TweenClip) {
	for &tw in c.tweens do tween_destroy(&tw)
	delete(c.tweens)
	engine.comp_zero(c)
}

// Clip-normalized time. A zero-duration clip is a step: 0 before its start,
// 1 from it on (the div-by-zero case, not a special semantics).
@(private = "file")
_tween_clip_t :: proc(c: ^Timeline_Clip, time: f32) -> f32 {
	if c.duration <= 0 do return time >= c.start ? 1 : 0
	return clamp((time - c.start) / c.duration, 0, 1)
}

// Per-(director, track) state: which play session's captures we hold.
@(private = "file")
_Tween_State :: struct {
	seen_play_id: u32,
}

@(private = "file")
_tween_track_build :: proc(ctx: ^Track_Ctx) -> rawptr {
	st := new(_Tween_State)
	st.seen_play_id = ctx.play_id
	return st
}

@(private = "file")
_tween_track_destroy :: proc(state: rawptr) {
	free(state)
}

@(private = "file")
_tween_track_tick :: proc(ctx: ^Track_Ctx) {
	_, tt := get_comp(ctx.track.node, TweenTrack)
	if tt == nil do return
	tctx := core.Tween_Ctx{owner = ctx.owner, target = tt.target}

	// A new play session is a fresh performance: every capture refreshes, so
	// a timeline played twice lerps from the game state it finds each time
	// rather than teleporting to a stale first-play pose. Loop wraps are NOT
	// new sessions — play_id holds, .Play captures survive, the loop replays.
	new_play := false
	if st := cast(^_Tween_State)ctx.state; st != nil && ctx.mode == .Play && st.seen_play_id != ctx.play_id {
		st.seen_play_id = ctx.play_id
		new_play = true
	}

	for &c in ctx.track.clips {
		_, tc := get_comp(c.node, TweenClip)
		if tc == nil do continue
		tctx.clip = c.node
		t := _tween_clip_t(&c, ctx.time)

		if new_play {
			for &tw in tc.tweens {
				if base := tween_base(&tw); base != nil do base.captured = false
			}
		}

		if ctx.mode != .Play {
			// Timeline authority: clamped t for every clip, every frame. No
			// capture policy applies here — the preview always shows the
			// first pass, and preview_end clears every capture.
			for &tw in tc.tweens do tween_evaluate(&tw, t, &tctx)
			continue
		}

		end := c.start + c.duration
		inside_prev := ctx.prev_time >= c.start && ctx.prev_time < end
		inside_now := ctx.time >= c.start && ctx.time < end
		// The inside-ness transition, exactly the script track's rule
		// (component_script_track.odin) — the crossing test only covers a
		// clip passed over entirely inside one tick window.
		passed_over := !inside_prev && !inside_now && track_crossed(ctx, c.start)
		entered := (!inside_prev && inside_now) || passed_over

		if entered {
			// .Enter captures live one span visit: each loop pass continues
			// from wherever the object is now.
			for &tw in tc.tweens {
				if base := tween_base(&tw); base != nil && base.capture == .Enter {
					base.captured = false
				}
			}
		}

		if inside_now {
			for &tw in tc.tweens do tween_evaluate(&tw, t, &tctx)
		} else if (inside_prev && ctx.time >= end) || passed_over {
			// Leaving forward: land exactly on the end pose once.
			for &tw in tc.tweens do tween_evaluate(&tw, 1, &tctx)
		}
	}
}

// The editor's preview stopped: hand back the authored pose. evaluate(0) IS
// the captured start pose, so restore needs no per-variant code — then the
// capture clears so the next preview captures fresh. Clips walk in REVERSE:
// a later clip's `from` is an earlier clip's end pose, so forward order
// would restore to mid-timeline instead of the authored state.
@(private = "file")
_tween_track_preview_end :: proc(ctx: ^Track_Ctx) {
	_, tt := get_comp(ctx.track.node, TweenTrack)
	if tt == nil do return
	tctx := core.Tween_Ctx{owner = ctx.owner, target = tt.target}

	#reverse for &c in ctx.track.clips {
		_, tc := get_comp(c.node, TweenClip)
		if tc == nil do continue
		tctx.clip = c.node
		#reverse for &tw in tc.tweens {
			base := tween_base(&tw)
			if base == nil || !base.captured do continue
			tween_evaluate(&tw, 0, &tctx)
			base.captured = false
		}
	}
}

// Called from register_builtin_tracks (timeline.odin).
_tween_track_desc :: proc() -> Track_Desc {
	return Track_Desc{
		track_key   = .TweenTrack,
		clip_key    = .TweenClip,
		label       = "tween",
		build       = _tween_track_build,
		destroy     = _tween_track_destroy,
		tick        = _tween_track_tick,
		preview_end = _tween_track_preview_end,
	}
}
