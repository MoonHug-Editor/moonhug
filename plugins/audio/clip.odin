package audio

// GUID-keyed clip cache, mirror of the engine's texture cache. A clip loads
// from its library ARTIFACT (float32 WAV with import settings baked in),
// never from the source file. Missing artifact: import on demand.

import "base:runtime"
import "core:encoding/uuid"
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
	streamed:    bool, // read from the file while it plays (AudioSettings.stream)
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

	stream := _clip_streams(guid)
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	audio := mix.LoadAudio(_audio_state.mixer, cpath, predecode = !stream)
	if audio == nil {
		engine.artifact_fail(guid, 0, fmt.tprintf("%s does not load as audio (%s)", path, sdl.GetError()))
		return nil, false
	}

	return _clip_store(guid, audio, stream)
}

// Whether the clip's import settings say to stream it. Read on the main
// thread: the settings lookup goes through the asset database. In a built
// game the settings come from the catalog.
@(private = "file")
_clip_streams :: proc(guid: engine.Asset_GUID) -> bool {
	path, ok := engine.asset_db_get_path(transmute(uuid.Identifier)guid)
	if !ok do return false
	settings, sok := engine.asset_pipeline_get_settings(path, context.temp_allocator)
	if !sok do return false
	s, is_audio := settings.(AudioSettings)
	return is_audio && s.stream
}

// What a load job takes to its worker and brings back. On the default
// allocator, freed by the job's finish.
@(private = "file")
_Clip_Job_Data :: struct {
	mixer:  ^mix.Mixer,
	stream: bool,
	audio:  ^mix.Audio,
}

// Starts loading the clip on a worker thread (engine/asset_jobs.odin): the
// file read and the decode run there. A loaded clip needs no job.
clip_load_start :: proc(guid: engine.Asset_GUID) {
	if guid == {} || guid in clip_cache || !_mixer_ensure() do return
	path, ok := engine.artifact_file(guid)
	if !ok do return
	data := new(_Clip_Job_Data, runtime.default_allocator())
	data^ = {mixer = _audio_state.mixer, stream = _clip_streams(guid)}
	engine.asset_job_start(engine.PPtr{guid = guid}, path, _clip_job_finish, _clip_job_work, read = false, user = data)
}

// SDL_mixer reads, and decodes unless the clip streams, from any thread.
@(private = "file")
_clip_job_work :: proc(job: ^engine.Asset_Job) {
	data := cast(^_Clip_Job_Data)job.user
	cpath := strings.clone_to_cstring(job.path, context.temp_allocator)
	data.audio = mix.LoadAudio(data.mixer, cpath, predecode = !data.stream)
	job.failed = data.audio == nil
}

@(private = "file")
_clip_job_finish :: proc(job: ^engine.Asset_Job) {
	data := cast(^_Clip_Job_Data)job.user
	defer free(data, runtime.default_allocator())
	guid := job.ref.guid
	if job.failed {
		if !job.discard do engine.artifact_fail(guid, 0, fmt.tprintf("%s does not load as audio", job.path))
		return
	}
	// Discarded, or loaded another way while the job ran.
	if job.discard || guid in clip_cache {
		mix.DestroyAudio(data.audio)
		return
	}
	_clip_store(guid, data.audio, data.stream)
}

@(private = "file")
_clip_store :: proc(guid: engine.Asset_GUID, audio: ^mix.Audio, streamed: bool) -> (^Audio_Clip, bool) {
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
		streamed    = streamed,
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
