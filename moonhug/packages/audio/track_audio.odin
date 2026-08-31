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

// The kind's components: the track carries what it drives, the clip carries
// its payload. `ref:`/`ext:` tags drive the inspector's pickers, so the
// sequencer window needs no per-kind knowledge.
@(component)
@(typ_guid={guid = "b6ddf9c5-02a9-4ff9-8e6d-8a64e5e1edd6"})
TrackAudio :: struct {
	using base: engine.CompData `inspect:"-"`,

	source: engine.Ref_Local `ref:"AudioSource"`,
}

@(component)
@(typ_guid={guid = "889f7ce4-b7cc-4ad1-b669-540bfb5a27ff"})
ClipAudio :: struct {
	using base: engine.CompData `inspect:"-"`,

	clip: engine.Asset_GUID `ext:"mp3,wav,ogg"`,
}

@(phase={key=ImportersInit, order=4})
audio_track_init :: proc() {
	@(static) done := false
	if done do return
	done = true
	seq.track_register(seq.Track_Desc{
		track_key   = .TrackAudio,
		clip_key    = .ClipAudio,
		label       = "audio",
		tick        = _audio_track_tick,
		preview_end = _audio_track_preview_end,
	})
}

// The AudioSource this track drives, or nil.
@(private = "file")
_audio_track_source :: proc(ctx: ^seq.Track_Ctx) -> ^AudioSource {
	_, at := get_comp(ctx.track.node, TrackAudio)
	if at == nil || at.source.handle.type_key != .AudioSource do return nil
	w := engine.ctx_world()
	if !engine.world_pool_valid(w, at.source.handle) do return nil
	return cast(^AudioSource)engine.world_pool_get(w, at.source.handle)
}

_audio_track_tick :: proc(ctx: ^seq.Track_Ctx) {
	src := _audio_track_source(ctx)
	if src == nil do return

	// A static scrub is silent. The preview's PLAY advance (.Preview_Play)
	// is live audio — Unity's Timeline preview — and falls through to the
	// crossing logic below.
	if ctx.mode == .Scrub {
		if audio_is_playing(src) do audio_stop(src)
		return
	}

	any_active := false
	for &c in ctx.track.clips {
		if seq.track_clip_active(ctx, &c) do any_active = true
		if seq.track_crossed(ctx, c.start) {
			asset: engine.Asset_GUID
			if _, cr := get_comp(c.node, ClipAudio); cr != nil do asset = cr.clip
			if !engine.asset_guid_is_empty(asset) && asset != src.clip {
				if audio_is_playing(src) do audio_stop(src)
				src.clip = asset
			}
			audio_play(src)
		}
	}
	if !any_active && audio_is_playing(src) {
		audio_stop(src)
	}
}

// The editor's preview stopped: silence the source it was driving. The
// PER-FRAME restore of an auto-advancing preview (.Preview_Play) leaves the
// voice alone — stopping it every frame is what made preview-play silent.
_audio_track_preview_end :: proc(ctx: ^seq.Track_Ctx) {
	if ctx.mode == .Preview_Play do return
	src := _audio_track_source(ctx)
	if src != nil && audio_is_playing(src) do audio_stop(src)
}
