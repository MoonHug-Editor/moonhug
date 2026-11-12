package engine

// Loading a scene over several frames, so the game keeps its frame rate and
// can show a loading screen.
//
//   h := scene_load_async("assets/level2.scene")
//   ...each frame: bar = scene_load_progress(h)
//   ...scene_load_done(h): the scene is loaded and awake
//
// The stages, in order:
// - read and parse the scene file
// - list the assets the scene references, and open each nested prefab to list
//   the assets it references
// - load those assets (asset_preload.odin). Each asset's file is read and
//   decoded on a worker thread (asset_jobs.odin), all at once. The load waits
//   until every one is in its cache
// - create the objects and awake them. A load that is not additive unloads
//   the loaded scenes right before this stage, so they run until then
//
// frame_tick runs the loads at the start of each frame for a few
// milliseconds (SCENE_LOAD_FRAME_BUDGET_MS). On the main thread that is: the
// file parses, the short last part of each asset's load (a GPU upload), and
// the creation of the objects. Parsing one file and creating the objects are
// one piece of work each, so a large scene can still take more than the
// budget in those two frames.
//
// - `activate = false` stops before the last stage, with the assets loaded,
//   until scene_load_activate: for "press a key to continue", or to finish a
//   fade first.
// - Outside a running game no frame runs the loads, so the call loads the
//   whole scene before it returns.
// - An asset the scene does not reference still loads on first use. So do
//   the assets of a prefab that a field names and a script spawns: only
//   nested prefabs are opened. asset_preload loads either by hand.
// - scene_load is the same load in one call, with the same `additive`
//   parameter. The editor and the boot scene use it. In a game it loads the
//   scene's assets too.

import "base:runtime"
import "core:strings"
import "core:time"

// A load started by scene_load_async. 0 is no load.
Scene_Load_Handle :: distinct u32

// The time the loads get at the start of each frame, in milliseconds.
SCENE_LOAD_FRAME_BUDGET_MS :: 4.0

@(private = "file")
_Stage :: enum {
	Parse,
	Scan, // nested prefabs
	Assets, // start each asset's load
	Jobs, // until the asset jobs are done
	Wait, // for scene_load_activate
	Build,
	Done,
	Failed,
}

@(private = "file")
_Load :: struct {
	id:        Scene_Load_Handle,
	world:     ^World,
	path:      string, // owned
	additive:  bool,
	activate:  bool,
	stage:     _Stage,
	allocator: runtime.Allocator, // of `sf` and `refs`
	sf:        SceneFile,
	guid:      Asset_GUID,
	refs:      Scene_Asset_Refs,
	scanned:   int, // refs.scenes read so far
	loaded:    int, // refs.assets started so far
	jobs:      int, // the asset jobs pending when the Jobs stage began
	jobs_done: int, // of those, the most seen done
	progress:  f32, // the highest value scene_load_progress gave out
	scene:     u32, // session id of the result
}

// Every load of every world. A finished load keeps its record, without the
// file and the lists, until its world shuts down, so its handle answers.
@(private = "file")
_loads: [dynamic]^_Load

@(private = "file")
_next_load_id: Scene_Load_Handle

// Starts loading the scene file at `path`. `additive` keeps the loaded
// scenes, else the load unloads them when it creates the new scene's objects.
// `activate = false` holds the load before that stage until
// scene_load_activate. Outside a running game the scene is loaded when the
// call returns.
scene_load_async :: proc(path: string, additive := false, activate := true) -> Scene_Load_Handle {
	_next_load_id += 1
	l := new(_Load, runtime.default_allocator())
	l.id = _next_load_id
	l.world = ctx_world()
	l.path = strings.clone(path, runtime.default_allocator())
	l.additive = additive
	l.activate = activate
	l.allocator = context.allocator
	l.refs.assets = make([dynamic]PPtr, l.allocator)
	l.refs.scenes = make([dynamic]Asset_GUID, l.allocator)
	{
		context.allocator = runtime.default_allocator()
		append(&_loads, l)
	}
	if !game_running() {
		l.activate = true
		for !_finished(l) {
			if !_advance(l) do asset_jobs_wait_all()
		}
	}
	return l.id
}

// How far the load is, 0 to 1. A load on hold stops just below 1.
scene_load_progress :: proc(h: Scene_Load_Handle) -> f32 {
	l := _find(h)
	if l == nil do return 0
	if l.stage == .Done || l.stage == .Failed do return 1
	if l.stage == .Parse do return 0
	// The file, each nested prefab and the objects are one piece each. An
	// asset is two: its load started, its load done.
	assets := len(l.refs.assets)
	total := 2 + len(l.refs.scenes) + 2 * assets
	done := 1 + l.scanned + l.loaded
	if l.stage == .Wait || l.stage == .Build {
		done += assets
	} else if l.stage == .Jobs && l.jobs > 0 {
		done += assets * l.jobs_done / l.jobs
	}
	// Opening a nested prefab adds its assets to the total: the value given
	// out never goes back.
	l.progress = max(l.progress, f32(done) / f32(total))
	return l.progress
}

// The load ended: the scene is loaded and awake, or the load failed.
scene_load_done :: proc(h: Scene_Load_Handle) -> bool {
	l := _find(h)
	return l == nil || _finished(l)
}

// The load is on hold with its assets loaded: scene_load_activate finishes it.
scene_load_ready :: proc(h: Scene_Load_Handle) -> bool {
	l := _find(h)
	return l != nil && l.stage == .Wait
}

// Lets a load started with `activate = false` create its scene. The scene
// exists after the next frame's load step.
scene_load_activate :: proc(h: Scene_Load_Handle) {
	if l := _find(h); l != nil do l.activate = true
}

// The scene a finished load made. nil before that, after a failed load, and
// once the scene is unloaded.
scene_load_scene :: proc(h: Scene_Load_Handle) -> ^Scene {
	l := _find(h)
	if l == nil || l.stage != .Done do return nil
	return sm_scene_find_by_session_id(l.scene)
}

// Finishes the asset jobs whose work is done, then runs the loads of the
// current world, for `budget_ms` in all. frame_tick calls it at the start of
// each frame. A piece of work that started always finishes, so one call can
// take longer than the budget.
scene_loads_step :: proc(budget_ms := SCENE_LOAD_FRAME_BUDGET_MS) {
	start := time.tick_now()
	asset_jobs_finish(budget_ms)
	if len(_loads) == 0 do return
	if time.duration_milliseconds(time.tick_since(start)) >= budget_ms && asset_jobs_pending() > 0 do return
	w := ctx_world()
	// By index: a load's awake procs can start another load.
	for i := 0; i < len(_loads); i += 1 {
		l := _loads[i]
		if l.world != w || _finished(l) do continue
		for !_finished(l) {
			if !_advance(l) do break
			if time.duration_milliseconds(time.tick_since(start)) >= budget_ms do return
		}
	}
}

// Drops every load of the current world, finished or not. The world's
// shutdown calls it.
scene_loads_cancel :: proc() {
	w := ctx_world()
	for i := len(_loads) - 1; i >= 0; i -= 1 {
		l := _loads[i]
		if l.world != w do continue
		_release(l)
		delete(l.path, runtime.default_allocator())
		free(l, runtime.default_allocator())
		ordered_remove(&_loads, i)
	}
}

// Loads every asset the scene file references, nested prefabs included,
// before the call returns. scene_load calls it in a game.
scene_file_preload_assets :: proc(sf: ^SceneFile, guid: Asset_GUID) {
	refs: Scene_Asset_Refs
	refs.assets = make([dynamic]PPtr, context.temp_allocator)
	refs.scenes = make([dynamic]Asset_GUID, context.temp_allocator)
	scene_file_asset_refs(sf, guid, &refs)
	for i := 0; i < len(refs.scenes); i += 1 do _scan_prefab(refs.scenes[i], &refs)
	for ref in refs.assets do asset_preload(ref)
	asset_jobs_wait_all()
}

// asset_preload on a prefab: every asset the prefab references, its nested
// prefabs included. For a script that spawns a prefab it holds in a field.
@(asset_preload={ext="scene"})
asset_preload_scene :: proc(ref: PPtr) {
	if ref.local_id != 0 do return
	refs: Scene_Asset_Refs
	refs.assets = make([dynamic]PPtr, context.temp_allocator)
	refs.scenes = make([dynamic]Asset_GUID, context.temp_allocator)
	append(&refs.scenes, ref.guid)
	for i := 0; i < len(refs.scenes); i += 1 do _scan_prefab(refs.scenes[i], &refs)
	for r in refs.assets do asset_preload(r)
}

@(private = "file")
_find :: proc(h: Scene_Load_Handle) -> ^_Load {
	for l in _loads do if l.id == h do return l
	return nil
}

@(private = "file")
_finished :: proc(l: ^_Load) -> bool {
	return l.stage == .Done || l.stage == .Failed
}

// One piece of work of the load. False when the load waits: for the asset
// jobs, or for scene_load_activate.
@(private = "file")
_advance :: proc(l: ^_Load) -> bool {
	context.allocator = l.allocator
	switch l.stage {
	case .Parse:
		sf, ok := scene_file_load(l.path)
		if !ok {
			_fail(l)
			return true
		}
		l.sf = sf
		if !application_is_editor() do scene_log_missing_assets(l.path)
		if g, gok := asset_db_get_guid(l.path); gok do l.guid = Asset_GUID(g)
		scene_file_asset_refs(&l.sf, l.guid, &l.refs)
		l.stage = .Scan
	case .Scan:
		if l.scanned < len(l.refs.scenes) {
			_scan_prefab(l.refs.scenes[l.scanned], &l.refs)
			l.scanned += 1
		} else {
			l.stage = .Assets
		}
	case .Assets:
		if l.loaded < len(l.refs.assets) {
			asset_preload(l.refs.assets[l.loaded])
			l.loaded += 1
		} else {
			l.jobs = asset_jobs_pending()
			l.stage = .Jobs
		}
	case .Jobs:
		// Every pending job counts, another load's too: this load's assets
		// are in their caches when none is left.
		pending := asset_jobs_pending()
		l.jobs_done = max(l.jobs_done, l.jobs - min(pending, l.jobs))
		if pending > 0 do return false
		l.stage = .Wait
	case .Wait:
		if !l.activate do return false
		l.stage = .Build
	case .Build:
		s := _scene_load_additive(&l.sf, l.guid) if l.additive else _scene_load_single(&l.sf, l.guid)
		if s == nil {
			_fail(l)
			return true
		}
		s.path = strings.clone(l.path)
		l.scene = s.session_id
		_release(l)
		l.stage = .Done
	case .Done, .Failed:
	}
	return true
}

@(private = "file")
_fail :: proc(l: ^_Load) {
	_release(l)
	l.stage = .Failed
}

// Frees the file and the lists: a finished load keeps only its result.
@(private = "file")
_release :: proc(l: ^_Load) {
	context.allocator = l.allocator
	scene_file_destroy(&l.sf)
	l.sf = {}
	delete(l.refs.assets)
	delete(l.refs.scenes)
	l.refs = {}
	l.scanned = 0
	l.loaded = 0
	l.jobs = 0
	l.jobs_done = 0
}

// Adds the asset references of the nested prefab `guid` to `refs`.
@(private = "file")
_scan_prefab :: proc(guid: Asset_GUID, refs: ^Scene_Asset_Refs) {
	if !scene_lib_register(guid) do return
	raw := scene_lib[guid]
	// The parse gets a copy, as in _prefab_resolved_bytes.
	bytes := make([]byte, len(raw), context.temp_allocator)
	copy(bytes, raw)
	sf: SceneFile
	if scene_file_unmarshal(bytes, &sf) != nil do return
	defer scene_file_destroy(&sf)
	scene_file_asset_refs(&sf, guid, refs)
}
