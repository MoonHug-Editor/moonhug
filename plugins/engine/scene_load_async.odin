package engine

// Loading a scene over several frames, so the game keeps its frame rate and
// can show a loading screen.
//
//   h := scene_load_async("assets/level2.scene")
//   ...each frame: bar = scene_load_progress(h)
//   ...scene_load_done(h): the scene is loaded and awake
//
// The stages, in order:
// - read and parse the scene file on a worker thread (asset_jobs.odin)
// - list the assets the scene references, and the assets of each nested
//   prefab. Each prefab file parses on a worker thread, once per process:
//   its list is kept until an asset changes
// - load those assets (asset_preload.odin). Each asset's file is read and
//   decoded on a worker thread, all at once. The load waits until every one
//   is in its cache
// - create the objects and awake them. A load that is not additive unloads
//   the loaded scenes right before this stage, so they run until then
//
// frame_tick runs the loads at the start of each frame for a few
// milliseconds (SCENE_LOAD_FRAME_BUDGET_MS). On the main thread that is: the
// walk of the parsed file for its asset references, the short last part of
// each asset's load (a GPU upload), and the creation of the objects. Creating
// the objects is one piece of work, so a large scene can still take more than
// the budget in that frame.
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
import "core:encoding/json"
import "core:encoding/uuid"
import "core:fmt"
import "core:strings"
import "core:time"

// A load started by scene_load_async. 0 is no load.
Scene_Load_Handle :: distinct u32

// The time the loads get at the start of each frame, in milliseconds.
SCENE_LOAD_FRAME_BUDGET_MS :: 4.0

@(private = "file")
_Stage :: enum {
	Read, // start the file's parse on a worker
	Parse, // until the parse is done
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
	sf:        SceneFile,
	parsed:    bool, // `sf` holds the parsed file
	sf_allocator: runtime.Allocator, // of `sf`: the scene takes parts of it, so the scene is built on it too
	guid:      Asset_GUID,
	refs:      Scene_Asset_Refs,
	scanned:   int, // refs.scenes read so far
	loaded:    int, // refs.assets started so far
	mark:      u64, // the last asset job started by the Assets stage
	jobs:      int, // of the jobs up to `mark`, the pending ones when the Jobs stage began
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
	l: ^_Load
	{
		// The load's own state lives across frames: never on the caller's
		// allocator, which can be the temp allocator. The scene file is on
		// the allocator of the step that parses it (_advance).
		context.allocator = runtime.default_allocator()
		l = new(_Load)
		l.id = _next_load_id
		l.world = ctx_world()
		l.path = strings.clone(path)
		l.additive = additive
		l.activate = activate
		l.refs = _refs_make(runtime.default_allocator())
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
	if l.stage == .Read || l.stage == .Parse do return 0
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
// shutdown calls it. A parse still running on a worker is dropped when it
// ends.
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
	refs := _refs_make(context.temp_allocator)
	scene_file_asset_refs(sf, guid, &refs)
	_scan_all(&refs)
	for ref in refs.assets do asset_preload(ref)
	// A job started earlier can hold one of these assets: a second start of
	// an asset's load starts no job.
	asset_jobs_wait_all(asset_jobs_mark())
}

// asset_preload on a prefab: every asset the prefab references, its nested
// prefabs included. For a script that spawns a prefab it holds in a field.
@(asset_preload={ext="scene"})
asset_preload_scene :: proc(ref: PPtr) {
	if ref.local_id != 0 do return
	refs := _refs_make(context.temp_allocator)
	append(&refs.scenes, ref.guid)
	_scan_all(&refs)
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

// One piece of work of the load. False when the load waits: for a worker,
// or for scene_load_activate.
@(private = "file")
_advance :: proc(l: ^_Load) -> bool {
	switch l.stage {
	case .Read:
		if g, gok := asset_db_get_guid(l.path); gok do l.guid = Asset_GUID(g)
		l.stage = .Parse
		if !game_running() {
			// The call loads the whole scene: the parse runs here, on the
			// caller's allocator, as in scene_load.
			sf, ok := scene_file_load(l.path)
			if !ok {
				_fail(l)
				return true
			}
			if !application_is_editor() do scene_log_missing_assets(l.path)
			l.sf, l.sf_allocator, l.parsed = sf, context.allocator, true
			return true
		}
		// The worker parses on the allocator of this step: the frame's, which
		// the scene lives on. The heap and the tracking allocator are safe
		// on any thread. The load's id in the reference makes the job this
		// load's own: two loads of one scene parse it once each, since each
		// build uses up its parsed file.
		_parse_start(PPtr{guid = l.guid, local_id = Local_ID(l.id)}, l.path, _load_job_finish, context.allocator)
	case .Parse:
		if !l.parsed do return false
		scene_file_asset_refs(&l.sf, l.guid, &l.refs)
		l.stage = .Scan
	case .Scan:
		// Each listed prefab's references come from the cache, or from a
		// parse on a worker. All of them parse at once.
		waiting := false
		for g in l.refs.scenes[l.scanned:] {
			if g in _prefab_refs do continue
			_prefab_scan_start(g)
			if g not_in _prefab_refs do waiting = true
		}
		if waiting do return false
		for l.scanned < len(l.refs.scenes) {
			g := l.refs.scenes[l.scanned]
			// A prefab that a merge added: the next step starts its parse.
			if g not_in _prefab_refs do return true
			r := _prefab_refs[g]
			_refs_merge(&l.refs, r)
			l.scanned += 1
		}
		l.stage = .Assets
	case .Assets:
		if l.loaded < len(l.refs.assets) {
			asset_preload(l.refs.assets[l.loaded])
			l.loaded += 1
		} else {
			// The load waits for the jobs started up to now. A job started
			// earlier can hold one of its assets, a job started later cannot.
			l.mark = asset_jobs_mark()
			l.jobs = asset_jobs_pending(l.mark)
			l.stage = .Jobs
		}
	case .Jobs:
		pending := asset_jobs_pending(l.mark)
		l.jobs_done = max(l.jobs_done, l.jobs - min(pending, l.jobs))
		if pending > 0 do return false
		l.stage = .Wait
	case .Wait:
		if !l.activate do return false
		l.stage = .Build
	case .Build:
		context.allocator = l.sf_allocator
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
	if l.parsed {
		context.allocator = l.sf_allocator
		scene_file_destroy(&l.sf)
	}
	context.allocator = runtime.default_allocator()
	l.sf = {}
	l.parsed = false
	delete(l.refs.assets)
	delete(l.refs.scenes)
	l.refs = {}
	l.scanned = 0
	l.loaded = 0
	l.jobs = 0
	l.jobs_done = 0
}

@(private = "file")
_refs_make :: proc(allocator: runtime.Allocator) -> Scene_Asset_Refs {
	return {assets = make([dynamic]PPtr, allocator), scenes = make([dynamic]Asset_GUID, allocator)}
}

// Adds what `src` lists and `dst` does not.
@(private = "file")
_refs_merge :: proc(dst: ^Scene_Asset_Refs, src: Scene_Asset_Refs) {
	outer: for r in src.assets {
		for d in dst.assets do if d == r do continue outer
		append(&dst.assets, r)
	}
	outer2: for g in src.scenes {
		for d in dst.scenes do if d == g do continue outer2
		append(&dst.scenes, g)
	}
}

// --- Parsing on a worker -------------------------------------------------------

// A scene file a worker parses, in `job.user`.
@(private = "file")
_Parsed :: struct {
	allocator: runtime.Allocator, // of `sf`, safe on any thread
	sf:        SceneFile,
	err:       json.Unmarshal_Error,
}

// Starts the parse of the scene file at `path` on a worker, into `allocator`.
@(private = "file")
_parse_start :: proc(ref: PPtr, path: string, finish: Asset_Job_Finish, allocator: runtime.Allocator) {
	if asset_job_pending(ref, finish) do return
	p := new(_Parsed, runtime.default_allocator())
	p.allocator = allocator
	asset_job_start(ref, path, finish, _parse_job_work, user = p)
}

// Worker thread. The parse reads references with the PPtr read hook unbound
// (scene_sub_assets.odin keeps that state per thread).
@(private = "file")
_parse_job_work :: proc(job: ^Asset_Job) {
	p := cast(^_Parsed)job.user
	context.allocator = p.allocator
	p.err = scene_file_unmarshal(job.data, &p.sf)
	job.failed = p.err != nil
}

@(private = "file")
_parsed_free :: proc(p: ^_Parsed) {
	context.allocator = p.allocator
	scene_file_destroy(&p.sf)
	free(p, runtime.default_allocator())
}

// The scene file of a load: handed to the load, or dropped when the load is
// gone.
@(private = "file")
_load_job_finish :: proc(job: ^Asset_Job) {
	p := cast(^_Parsed)job.user
	l := _find(Scene_Load_Handle(job.ref.local_id))
	if l != nil && l.stage != .Parse do l = nil
	if job.discard || job.failed {
		if !job.discard {
			if job.read_failed {
				fmt.printf("[Scene] Failed to read file: %s\n", job.path)
			} else {
				fmt.printf("[Scene] Failed to unmarshal scene: %v\n", p.err)
			}
		}
		_parsed_free(p)
		if l != nil do _fail(l)
		return
	}
	if l == nil {
		_parsed_free(p)
		return
	}
	// The bytes are at hand: a game logs each reference to an asset its
	// catalog does not have.
	if !application_is_editor() do scene_log_missing_assets(job.path, job.data)
	l.sf, l.sf_allocator, l.parsed = p.sf, p.allocator, true
	free(p, runtime.default_allocator())
}

// --- The references of nested prefabs ---------------------------------------------

// The references of each prefab file, by its guid: its assets and its own
// nested prefabs. A prefab parses once per process: any asset change clears
// the list, since a change can add an asset a prefab names.
@(private = "file")
_prefab_refs: map[Asset_GUID]Scene_Asset_Refs

@(private = "file")
_prefab_refs_store :: proc(guid: Asset_GUID, refs: Scene_Asset_Refs) {
	if guid in _prefab_refs {
		delete(refs.assets)
		delete(refs.scenes)
		return
	}
	context.allocator = runtime.default_allocator()
	_prefab_refs[guid] = refs
}

@(private = "file")
_prefab_refs_clear :: proc() {
	for _, r in _prefab_refs {
		delete(r.assets)
		delete(r.scenes)
	}
	clear(&_prefab_refs)
}

// Starts the parse of the prefab `guid` on a worker, unless its references
// are known or a job parses it. A prefab with no file gets an empty list now.
@(private = "file")
_prefab_scan_start :: proc(guid: Asset_GUID) {
	if guid in _prefab_refs do return
	path, ok := asset_db_get_path(uuid.Identifier(guid))
	if !ok {
		_prefab_refs_store(guid, _refs_make(runtime.default_allocator()))
		return
	}
	// Only the reference lists stay: the file is parsed on the default
	// allocator and dropped.
	_parse_start(PPtr{guid = guid}, path, _scan_job_finish, runtime.default_allocator())
}

// The prefab's references, in the list. A prefab that does not parse gets
// an empty list: the build reports it.
@(private = "file")
_scan_job_finish :: proc(job: ^Asset_Job) {
	p := cast(^_Parsed)job.user
	defer _parsed_free(p)
	if job.discard do return
	refs := _refs_make(runtime.default_allocator())
	if !job.failed do scene_file_asset_refs(&p.sf, job.ref.guid, &refs)
	_prefab_refs_store(job.ref.guid, refs)
}

// Adds the references of every nested prefab `refs` lists, their own nested
// prefabs included, before it returns. The prefabs parse on the workers
// together.
@(private = "file")
_scan_all :: proc(refs: ^Scene_Asset_Refs) {
	for g in refs.scenes do _prefab_scan_start(g)
	for i := 0; i < len(refs.scenes); i += 1 {
		g := refs.scenes[i]
		if g not_in _prefab_refs {
			// A prefab that a merge added.
			_prefab_scan_start(g)
			asset_job_wait(PPtr{guid = g}, _scan_job_finish)
		}
		r := _prefab_refs[g]
		_refs_merge(refs, r)
	}
}

@(asset_on_changed)
asset_on_changed_prefab_refs :: proc(guid: Asset_GUID, path: string, change: Asset_Change) {
	if len(_prefab_refs) > 0 do _prefab_refs_clear()
}

@(phase={key=EngineShutdown, order=20})
engine_shutdown_prefab_refs :: proc() {
	_prefab_refs_clear()
	delete(_prefab_refs)
	_prefab_refs = nil
}
