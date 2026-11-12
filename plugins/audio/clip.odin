package audio

// GUID-keyed clip cache, mirror of the engine's texture cache. A clip loads
// from its library ARTIFACT (float32 WAV with import settings baked in),
// never from the source file. Missing artifact: import on demand.

import "base:runtime"
import "core:fmt"
import "core:strings"
import sdl "vendor:sdl3"
import mix "vendor:sdl3/mixer"
import engine "moonhug:packages/engine"

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
	// A job is loading it (engine/asset_jobs.odin): wait for that job.
	if engine.asset_job_wait(engine.PPtr{guid = guid}, _clip_job_finish) {
		clip, ok := &clip_cache[guid]
		return clip, ok
	}
	if !_mixer_ensure() do return nil, false

	// engine.artifact_file imports a missing artifact in the editor and
	// reports it once in a game.
	path, path_ok := engine.artifact_file(guid)
	if !path_ok do return nil, false

	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	audio := mix.LoadAudio(_audio_state.mixer, cpath, predecode = true)
	if audio == nil {
		engine.artifact_fail(guid, 0, fmt.tprintf("%s does not load as audio (%s)", path, sdl.GetError()))
		return nil, false
	}

	return _clip_store(guid, audio)
}

// Starts loading the clip on a worker thread (engine/asset_jobs.odin): the
// file read and the decode run there. A loaded clip needs no job.
clip_load_start :: proc(guid: engine.Asset_GUID) {
	if guid == {} || guid in clip_cache || !_mixer_ensure() do return
	path, ok := engine.artifact_file(guid)
	if !ok do return
	engine.asset_job_start(engine.PPtr{guid = guid}, path, _clip_job_finish, _clip_job_work, read = false, user = _audio_state.mixer)
}

// SDL_mixer reads and decodes the file itself, from any thread.
@(private = "file")
_clip_job_work :: proc(job: ^engine.Asset_Job) {
	cpath := strings.clone_to_cstring(job.path, context.temp_allocator)
	audio := mix.LoadAudio(cast(^mix.Mixer)job.user, cpath, predecode = true)
	job.user = audio
	job.failed = audio == nil
}

@(private = "file")
_clip_job_finish :: proc(job: ^engine.Asset_Job) {
	guid := job.ref.guid
	if job.failed {
		engine.artifact_fail(guid, 0, fmt.tprintf("%s does not load as audio", job.path))
		return
	}
	audio := cast(^mix.Audio)job.user
	// Loaded another way while the job ran.
	if guid in clip_cache {
		mix.DestroyAudio(audio)
		return
	}
	_clip_store(guid, audio)
}

@(private = "file")
_clip_store :: proc(guid: engine.Asset_GUID, audio: ^mix.Audio) -> (^Audio_Clip, bool) {
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

// A reimported artifact evicts its clip so the next play loads the new
// master. Tracks may hold the dying mix.Audio — detach them first.
@(asset_on_changed)
asset_on_changed_audio_clip :: proc(guid: engine.Asset_GUID, path: string, change: engine.Asset_Change) {
	if change != .Reimported do return
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

// A scene load decodes the clips the scene references, on worker threads
// (engine/asset_preload.odin).
@(asset_preload={ext="mp3,wav,ogg"})
asset_preload_audio_clip :: proc(ref: engine.PPtr) {
	clip_load_start(ref.guid)
}
