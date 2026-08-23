package audio

// GUID-keyed clip cache, mirror of the engine's texture cache. A clip loads
// from its library ARTIFACT (float32 WAV with import settings baked in),
// never from the source file. Missing artifact: import on demand.

import "base:runtime"
import "core:encoding/uuid"
import "core:strings"
import sdl "vendor:sdl3"
import mix "vendor:sdl3/mixer"
import engine "moonhug:engine"

Audio_Clip :: struct {
	guid:        engine.Asset_GUID,
	audio:       ^mix.Audio,
	frames:      i64,
	channels:    i32,
	sample_rate: i32,
}

clip_cache: map[engine.Asset_GUID]Audio_Clip

clip_load :: proc(guid: engine.Asset_GUID) -> (^Audio_Clip, bool) {
	if guid == {} do return nil, false
	if clip, ok := &clip_cache[guid]; ok do return clip, true
	if !_mixer_ensure() do return nil, false

	path, path_ok := engine.asset_pipeline_artifact_path(guid)
	if !path_ok {
		// Self-heal is editor-only (asset_pipeline_request_import is nil in a
		// game binary — a missing artifact there is a load error).
		src, src_ok := engine.asset_db_get_path(uuid.Identifier(guid))
		if !src_ok do return nil, false
		_ = engine.asset_pipeline_request_import(src, force = false)
		path, path_ok = engine.asset_pipeline_artifact_path(guid)
		if !path_ok do return nil, false
	}

	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	audio := mix.LoadAudio(_audio_state.mixer, cpath, predecode = true)
	if audio == nil do return nil, false

	spec: sdl.AudioSpec
	_ = mix.GetAudioFormat(audio, &spec)

	// Package-global state never borrows the caller's allocator.
	context.allocator = runtime.default_allocator()
	if clip_cache == nil do clip_cache = make(map[engine.Asset_GUID]Audio_Clip)
	clip_cache[guid] = Audio_Clip{
		guid        = guid,
		audio       = audio,
		frames      = i64(mix.GetAudioDuration(audio)),
		channels    = i32(spec.channels),
		sample_rate = i32(spec.freq),
	}
	return &clip_cache[guid], true
}

// Reimport hook: a changed artifact evicts its clip so the next play loads
// the new master. Tracks may hold the dying mix.Audio — detach them first.
_clip_reimported :: proc(guid: engine.Asset_GUID) {
	if guid not_in clip_cache do return
	if _preview_track != nil {
		_ = mix.StopTrack(_preview_track, 0)
		_ = mix.SetTrackAudio(_preview_track, nil)
	}
	_one_shots_clear() // transient tracks may hold the dying mix.Audio
	if w := engine.ctx_world(); w != nil {
		if pool := audio_sources(w); pool != nil {
			it := engine.pool_iterator(pool)
			for src, _ in engine.pool_next(&it) {
				if src.track == nil do continue
				_ = mix.StopTrack(src.track, 0)
				_ = mix.SetTrackAudio(src.track, nil)
				src.started = false // play-on-awake restarts with the new master
			}
		}
	}
	clip_unload(guid)
}

clip_unload :: proc(guid: engine.Asset_GUID) {
	if clip, ok := &clip_cache[guid]; ok {
		mix.DestroyAudio(clip.audio)
		delete_key(&clip_cache, guid)
	}
}

clip_cache_shutdown :: proc() {
	for _, &clip in clip_cache {
		mix.DestroyAudio(clip.audio)
	}
	delete(clip_cache)
	clip_cache = nil
}
