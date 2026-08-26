package audio

// The audio track (docs/Sequencer.md): a timeline clip starts the bound
// AudioSource when playback crosses its start (the clip's asset, when set,
// replaces the source's clip first); leaving every span stops the source.
// Scrubbing is silent — audio does not scrub.
//
// This file is the audio package's only animation-package dependency — the
// track registers itself, the sequencer never imports audio. Author
// track-driven sources with play_on_awake off: the track decides when they
// play.

import "moonhug:engine"
import anim "moonhug:packages/animation"

@(phase={key=ImportersInit, order=4})
audio_track_init :: proc() {
	@(static) done := false
	if done do return
	done = true
	anim.track_register(anim.Track_Desc{kind = "audio", binding_type = "AudioSource", tick = _audio_track_tick})
}

_audio_track_tick :: proc(ctx: ^anim.Track_Ctx) {
	if ctx.target.handle.type_key != .AudioSource do return
	w := engine.ctx_world()
	if !engine.world_pool_valid(w, ctx.target.handle) do return
	src := cast(^AudioSource)engine.world_pool_get(w, ctx.target.handle)
	if src == nil do return

	if ctx.scrub {
		if audio_is_playing(src) do audio_stop(src)
		return
	}

	any_active := false
	for &c in ctx.track.clips {
		if anim.track_clip_active(ctx, &c) do any_active = true
		if anim.track_crossed(ctx, c.start) {
			if !engine.asset_guid_is_empty(c.asset) && c.asset != src.clip {
				if audio_is_playing(src) do audio_stop(src)
				src.clip = c.asset
			}
			audio_play(src)
		}
	}
	if !any_active && audio_is_playing(src) {
		audio_stop(src)
	}
}
