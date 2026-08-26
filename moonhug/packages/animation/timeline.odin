package animation

// Timeline (docs/Sequencer.md): the sequencer's asset. A timeline is tracks
// of clips on a shared time axis — Unity's TimelineAsset. The asset owns
// STRUCTURE only; scene identity (which objects tracks drive) lives on the
// PlayableDirector component as bindings, so one timeline plays on any
// number of instances.
//
// Track kinds cross package boundaries through the Track_Desc registry —
// the audio and particles packages register their own tracks, this package
// never imports them. "animation" tracks are built into the director (they
// need the playable graph); registry tracks get a per-frame tick with the
// time window and their binding.

import "base:runtime"
import "core:encoding/json"
import "core:encoding/uuid"
import "core:os"
import "core:strings"
import "moonhug:engine"

// One clip on a track. `asset` is the payload most tracks need (an .anim for
// animation tracks, an audio clip for audio tracks); `name` labels markers
// and the sequencer window's blocks.
Timeline_Clip :: struct {
	start:    f32,
	duration: f32,
	ease_in:  f32, // seconds of weight ramp at the clip's start
	ease_out: f32, // seconds of weight ramp at the clip's end
	speed:    f32, // clip-local time scale, 0 behaves as 1
	asset:    engine.Asset_GUID,
	name:     string,
}

Timeline_Track :: struct {
	kind:  string, // Track_Desc registry key; "animation" is director-built
	name:  string,
	muted: bool,
	clips: [dynamic]Timeline_Clip,
}

@(typ_guid={guid = "8433ef73-93dd-4ba4-a66e-9c5f09846922", makeProcName=make_pTimeline, menu_assets_create = {menu_name = "Timeline", file_name = "New Timeline.timeline", order = -4}})
Timeline :: struct {
	duration: f32, // authored length; 0 = computed from the last clip end
	tracks:   [dynamic]Timeline_Track,
}

make_pTimeline :: proc() -> any {
	t := new(Timeline)
	t.duration = 5
	return t^
}

// The playable length: authored, or the last clip end when unauthored.
timeline_duration :: proc(tl: ^Timeline) -> f32 {
	if tl.duration > 0 do return tl.duration
	d := f32(0)
	for &track in tl.tracks {
		for &c in track.clips do d = max(d, c.start + c.duration)
	}
	return d
}

// --- Cache (mirrors clip.odin) ------------------------------------------------------

timeline_cache: map[engine.Asset_GUID]Timeline
_timeline_cache_ready: bool

timeline_cache_init :: proc() {
	timeline_cache = make(map[engine.Asset_GUID]Timeline)
	_timeline_cache_ready = true
}

timeline_cache_shutdown :: proc() {
	for _, &tl in timeline_cache {
		_timeline_destroy(&tl)
	}
	delete(timeline_cache)
	_timeline_cache_ready = false
}

_timeline_destroy :: proc(tl: ^Timeline) {
	for &track in tl.tracks {
		for &c in track.clips do delete(c.name)
		delete(track.clips)
		delete(track.kind)
		delete(track.name)
	}
	delete(tl.tracks)
	tl^ = {}
}

timeline_load :: proc(guid: engine.Asset_GUID) -> (^Timeline, bool) {
	if tl, ok := &timeline_cache[guid]; ok {
		return tl, true
	}
	if !_timeline_cache_ready do return nil, false

	path, path_ok := engine.asset_db_get_path(uuid.Identifier(guid))
	if !path_ok do return nil, false
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil do return nil, false

	tl: Timeline
	if json.unmarshal(data, &tl, .JSON, context.allocator) != nil {
		_timeline_destroy(&tl)
		return nil, false
	}
	timeline_cache[guid] = tl
	return &timeline_cache[guid], true
}

timeline_unload :: proc(guid: engine.Asset_GUID) {
	if tl, ok := &timeline_cache[guid]; ok {
		_timeline_destroy(tl)
		delete_key(&timeline_cache, guid)
	}
}

timeline_path_changed :: proc(path: string) {
	if !strings.has_suffix(path, ".timeline") do return
	if guid, ok := engine.asset_db_get_guid(path); ok {
		timeline_unload(engine.Asset_GUID(guid))
	}
}

// --- Track registry -----------------------------------------------------------------

// What a registered track's tick sees: the time window this frame moved
// through, and the track's binding from the director.
Track_Ctx :: struct {
	track:     ^Timeline_Track,
	target:    engine.Ref_Local, // handle pre-resolved by scene load
	prev_time: f32,
	time:      f32,
	wrapped:   bool, // the loop wrapped inside this tick
	duration:  f32,  // the timeline's playable length
	scrub:     bool, // time jumped — stateful tracks reset instead of crossing
}

// Wrap-aware "did playback cross `at` this tick" — the half-open [prev, time)
// window, split in two when the loop wrapped (the burst-trigger pattern).
track_crossed :: proc(ctx: ^Track_Ctx, at: f32) -> bool {
	if ctx.scrub do return false
	if !ctx.wrapped do return at >= ctx.prev_time && at < ctx.time
	return (at >= ctx.prev_time && at < ctx.duration) || (at >= 0 && at < ctx.time)
}

// Whether playback time sits inside the clip's span.
track_clip_active :: proc(ctx: ^Track_Ctx, c: ^Timeline_Clip) -> bool {
	return ctx.time >= c.start && ctx.time < c.start + c.duration
}

Track_Desc :: struct {
	kind: string,
	tick: proc(ctx: ^Track_Ctx),
}

_track_registry: map[string]Track_Desc

// Process-global registry: never borrows the caller's allocator (same rule
// as every registry — a test's tracking allocator would dangle).
track_register :: proc(desc: Track_Desc) {
	context.allocator = runtime.default_allocator()
	if _track_registry == nil do _track_registry = make(map[string]Track_Desc)
	_track_registry[strings.clone(desc.kind)] = desc
}

track_desc :: proc(kind: string) -> (Track_Desc, bool) {
	d, ok := _track_registry[kind]
	return d, ok
}

// --- Built-in registry tracks ---------------------------------------------------------

// Activation: the bound transform is active while any clip covers the time
// (Unity's activation track post-behavior "inactive outside clips").
_activation_track_tick :: proc(ctx: ^Track_Ctx) {
	w := engine.ctx_world()
	if !engine.pool_valid(&w.transforms, ctx.target.handle) do return
	t := engine.pool_get(&w.transforms, ctx.target.handle)
	if t == nil do return
	active := false
	for &c in ctx.track.clips {
		if track_clip_active(ctx, &c) do active = true
	}
	t.is_active = active
}

// Markers: zero-duration clips fire the hook when playback crosses them.
// The hook is game/editor code's to install.
timeline_marker_hook: proc(name: string, target: engine.Ref_Local)

_marker_track_tick :: proc(ctx: ^Track_Ctx) {
	if timeline_marker_hook == nil do return
	for &c in ctx.track.clips {
		if track_crossed(ctx, c.start) {
			timeline_marker_hook(c.name, ctx.target)
		}
	}
}

@(private = "file") _builtin_tracks_registered: bool

register_builtin_tracks :: proc() {
	if _builtin_tracks_registered do return
	_builtin_tracks_registered = true
	track_register(Track_Desc{kind = "activation", tick = _activation_track_tick})
	track_register(Track_Desc{kind = "marker", tick = _marker_track_tick})
}
