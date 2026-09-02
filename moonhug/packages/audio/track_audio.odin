package audio

// The audio Control Track (docs/Sequencer.md): a clip span plays its asset on
// the bound AudioSource. The track owns ONE VOICE PER ACTIVE CLIP — a mixer
// track of its own, not the source's — so two clips overlapping on one track
// play at once, each at its clip weight (track_clip_weight): the overlap IS
// the crossfade, and a clip's ease_in/ease_out is a volume fade. The source
// stays a settings + position host (volume, pitch, spatial blend, mute) and
// its own track is never touched; game code keeps audio_play for that.
//
// The sound follows the PLAYHEAD: entering a span mid-way (Play pressed
// inside it, a scrub-then-play, a loop wrap landing in it) starts the voice
// at the clip-local offset, and crossing a clip's start restarts it.
//
// This file is the audio package's only sequencer dependency — the track
// registers itself, the sequencer never imports audio. Author track-driven
// sources with play_on_awake off: the span decides when they play.

import "moonhug:engine"
import mix "vendor:sdl3/mixer"
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
		build       = _audio_track_build,
		destroy     = _audio_track_destroy,
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

// Per-(director, track) state: the voice each active clip plays through,
// keyed by clip node.
Audio_Track_State :: struct {
	voices: map[engine.Transform_Handle]^mix.Track,
}

@(private = "file")
_audio_track_build :: proc(ctx: ^seq.Track_Ctx) -> rawptr {
	st := new(Audio_Track_State)
	st.voices = make(map[engine.Transform_Handle]^mix.Track)
	return st
}

@(private = "file")
_audio_track_destroy :: proc(state: rawptr) {
	st := cast(^Audio_Track_State)state
	if st == nil do return
	_voices_stop_all(st)
	delete(st.voices)
	free(st)
}

@(private = "file")
_voices_stop_all :: proc(st: ^Audio_Track_State) {
	for _, v in st.voices {
		_ = mix.StopTrack(v, 0)
		mix.DestroyTrack(v)
	}
	clear(&st.voices)
}

@(private = "file")
_voice_drop :: proc(st: ^Audio_Track_State, node: engine.Transform_Handle) {
	if v, has := st.voices[node]; has {
		_ = mix.StopTrack(v, 0)
		mix.DestroyTrack(v)
		delete_key(&st.voices, node)
	}
}

_audio_track_tick :: proc(ctx: ^seq.Track_Ctx) {
	st := cast(^Audio_Track_State)ctx.state
	if st == nil do return
	src := _audio_track_source(ctx)
	if src == nil {
		_voices_stop_all(st)
		return
	}

	// A static scrub is silent. The preview's PLAY advance (.Preview_Play)
	// is live audio — Unity's Timeline preview — and falls through.
	if ctx.mode == .Scrub {
		_voices_stop_all(st)
		return
	}

	for &c, i in ctx.track.clips {
		if !seq.track_clip_active(ctx, &c) {
			_voice_drop(st, c.node)
			continue
		}
		voice, has := st.voices[c.node]
		if !has || !mix.TrackPlaying(voice) || seq.track_crossed(ctx, c.start) {
			// Start (or restart on a start crossing) at the clip-local offset.
			asset := src.clip
			if _, cr := get_comp(c.node, ClipAudio); cr != nil && !engine.asset_guid_is_empty(cr.clip) {
				asset = cr.clip
			}
			_voice_drop(st, c.node)
			speed := c.speed if c.speed > 0 else 1
			voice = voice_start(asset, (ctx.time - c.start) * speed)
			if voice == nil do continue
			st.voices[c.node] = voice
		}
		// The clip weight is the volume multiplier: overlaps crossfade, eases
		// fade, and a lone clip plays at the source's volume.
		source_apply_gains(voice, src, seq.track_clip_weight(ctx.track.clips, i, ctx.time))
	}
}

// The editor's preview stopped: silence what it was driving. The PER-FRAME
// restore of an auto-advancing preview (.Preview_Play) leaves the voices
// alone — stopping them every frame is what made preview-play silent.
_audio_track_preview_end :: proc(ctx: ^seq.Track_Ctx) {
	if ctx.mode == .Preview_Play do return
	if st := cast(^Audio_Track_State)ctx.state; st != nil do _voices_stop_all(st)
}

// --- Test access -----------------------------------------------------------

audio_track_voice_playing :: proc(state: rawptr, clip: engine.Transform_Handle) -> bool {
	st := cast(^Audio_Track_State)state
	if st == nil do return false
	v, has := st.voices[clip]
	return has && bool(mix.TrackPlaying(v))
}

audio_track_voice_position :: proc(state: rawptr, clip: engine.Transform_Handle) -> f32 {
	st := cast(^Audio_Track_State)state
	if st == nil do return 0
	return voice_position(st.voices[clip] or_else nil)
}

audio_track_voice_gain :: proc(state: rawptr, clip: engine.Transform_Handle) -> f32 {
	st := cast(^Audio_Track_State)state
	if st == nil do return 0
	v, has := st.voices[clip]
	if !has do return 0
	return f32(mix.GetTrackGain(v))
}
