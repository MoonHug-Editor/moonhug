package audio

// The audio track (docs/Sequencer.md): a timeline clip starts the bound
// AudioSource when playback crosses its start (the clip's asset, when set,
// replaces the source's clip first); leaving every span stops the source.
// Scrubbing is silent — audio does not scrub.
//
// This file is the audio package's only sequencer dependency — the track
// registers itself, the sequencer never imports audio. Author
// track-driven sources with play_on_awake off: the track decides when they
// play.

import "moonhug:engine"
import seq "moonhug:packages/sequencer"

@(phase={key=ImportersInit, order=4})
audio_track_init :: proc() {
	@(static) done := false
	if done do return
	done = true
	seq.track_register(seq.Track_Desc{
		kind         = "audio",
		binding_type = "AudioSource",
		tick         = _audio_track_tick,
		preview_end  = _audio_track_preview_end,
	})
}

_audio_track_tick :: proc(ctx: ^seq.Track_Ctx) {
	if ctx.target.handle.type_key != .AudioSource do return
	w := engine.ctx_world()
	if !engine.world_pool_valid(w, ctx.target.handle) do return
	src := cast(^AudioSource)engine.world_pool_get(w, ctx.target.handle)
	if src == nil do return

	// A static scrub is silent. The preview's PLAY advance (ctx.playing) is
	// live audio — Unity's Timeline preview — and falls through to the
	// crossing logic below (track_crossed honors playing).
	if ctx.scrub && !ctx.playing {
		if audio_is_playing(src) do audio_stop(src)
		return
	}

	any_active := false
	for &c in ctx.track.clips {
		if seq.track_clip_active(ctx, &c) do any_active = true
		if seq.track_crossed(ctx, c.start) {
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

// The editor's preview stopped: silence the source it was driving. The
// PER-FRAME restore of an auto-advancing preview (ctx.playing) leaves the
// voice alone — stopping it every frame is what made preview-play silent.
_audio_track_preview_end :: proc(ctx: ^seq.Track_Ctx) {
	if ctx.playing do return
	if ctx.target.handle.type_key != .AudioSource do return
	w := engine.ctx_world()
	if !engine.world_pool_valid(w, ctx.target.handle) do return
	src := cast(^AudioSource)engine.world_pool_get(w, ctx.target.handle)
	if src != nil && audio_is_playing(src) do audio_stop(src)
}
