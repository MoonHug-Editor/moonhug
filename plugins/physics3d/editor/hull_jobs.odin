package physics3d_editor

// The convex decompositions models list in their import settings
// (engine.Mesh_Hull_Set), computed by CoACD (plugins/physics3d/external/CoACD,
// MIT) after an import and saved beside the model's artifact
// (packages/physics3d/mesh_hulls.odin).
//
// - Only what changed is computed. Each set's hulls are kept twice: in the
//   library beside the model's artifact, for the game, and in the model's
//   .meta (key "hulls", base64 of the same bytes), which is committed. Both
//   record a hash of the mesh and settings they came from, so a fresh clone
//   or a reimport restores every set whose hash matches from the meta, and
//   only the others queue.
// - CoACD runs as child processes, which `mh setup` builds into
//   plugins/physics3d/external/bin, at most the Physics 3D settings'
//   Decompositions At Once at a time. The editor never waits for them: the
//   status bar shows each running decomposition, its stage and a Cancel
//   button (editor/tasks), and physics holds still for a collider whose set
//   is not ready (physics3d.mesh_hulls_pending).
// - A failed or cancelled set stays without hulls until its Compute button
//   (the model's Convex Decompositions section) queues it again.

import "base:runtime"
import "core:encoding/base64"
import "core:encoding/json"
import "core:encoding/uuid"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "moonhug:packages/engine"
import "moonhug:editor/tasks"
import asset_pipeline "moonhug:editor/assets"
import assets "moonhug:libs/assets"
import "moonhug:libs/log"
import physics3d "moonhug:packages/physics3d"

COACD_EXE :: #directory + "/../external/bin/" + ODIN_OS_STRING + "-" + ("arm64" when ODIN_ARCH == .arm64 else "x86_64") + "/coacd"

// The tool a decomposition runs: CoACD, or in tests of the job handling a
// stand-in that writes fixed hulls at once (tests/fake_coacd.sh), so the
// suite does not wait for real decompositions.
coacd_exe := COACD_EXE

// CoACD's random sampling seed. Fixed, so a mesh gives the same hulls on
// every machine.
@(private = "file") _SEED :: "0"

Hull_Set_State :: enum {
	// The hulls are saved for the set's current mesh and settings.
	Ready,
	Queued,
	Running,
	Failed,
	Cancelled,
	// The model's mesh for the set cannot be loaded, or the set is unknown.
	Unavailable,
}

@(private = "file")
_Key :: struct {
	guid: engine.Asset_GUID,
	set:  engine.Local_ID,
}

@(private = "file")
_Job :: struct {
	key:         _Key,
	set:         engine.Mesh_Hull_Set,
	source_hash: u64,
	name:        string,
	process:     os.Process,
	dir:         string,
	started:     time.Tick,
	stage:       string,
	log_read:    int,
	last_read:   time.Tick,
}

@(private = "file")
_Outcome :: struct {
	source_hash: u64,
	state:       Hull_Set_State,
	error:       string,
}

@(private = "file")
_jobs: struct {
	queue:    [dynamic]^_Job, // in order: the first starts next
	running:  [dynamic]^_Job,
	// The last failure or cancel per set, for the hash it was computed for.
	outcomes: map[_Key]_Outcome,
	// Each model's applied sets and their source hashes, as the last
	// reconcile saw them.
	known:    map[engine.Asset_GUID]_Model,
}

@(private = "file")
_Model :: struct {
	sets:   [dynamic]engine.Mesh_Hull_Set,
	hashes: map[engine.Local_ID]u64,
}

// The .meta key of the computed hulls: [{"set": id, "data": base64}].
META_HULLS_KEY :: "hulls"

@(private = "file")
_Meta_Hulls :: struct {
	set:  engine.Local_ID,
	data: string,
}

@(provider_install)
_install_hull_jobs :: proc() {
	physics3d.mesh_hulls_pending = proc(guid: engine.Asset_GUID, set: engine.Local_ID) -> bool {
		key := _Key{guid, set}
		for j in _jobs.running do if j.key == key do return true
		for j in _jobs.queue do if j.key == key do return true
		return false
	}
	engine.asset_pipeline_add_reimport_hook(proc(guid: engine.Asset_GUID) { hull_sets_reconcile(guid) })
	tasks.register(_task_source)
}

// Every model's sets, once the editor has imported its assets: queues what
// has no hulls yet and records where each model's hulls live.
@(phase={key=engine.Phase.EditorInit, order=5, mode=Editor})
hull_sets_reconcile_all :: proc() {
	for path, guid in assets.asset_db.path_to_guid {
		ext := strings.to_lower(filepath.ext(path), context.temp_allocator)
		if ext == ".glb" || ext == ".gltf" do hull_sets_reconcile(engine.Asset_GUID(guid))
	}
}

// Brings a model's hull files in line with its applied sets: a file whose
// source hash matches stays, a match in the model's .meta is restored, the
// rest queue. Jobs for sets that changed or went are cancelled, and the
// meta drops the hulls of sets that went. Cheap when nothing changed: one
// header read per set.
hull_sets_reconcile :: proc(guid: engine.Asset_GUID) {
	context.allocator = runtime.default_allocator()
	source, sok := engine.asset_db_get_path(uuid.Identifier(guid))
	if !sok do return
	settings, gok := engine.asset_pipeline_get_settings(source, context.temp_allocator)
	if !gok || settings.id != typeid_of(engine.MeshSettings) do return
	ms := cast(^engine.MeshSettings)settings.data
	if _, aok := engine.asset_pipeline_artifact_path(guid); !aok do return

	model := &_jobs.known[guid]
	if model == nil {
		_jobs.known[guid] = {}
		model = &_jobs.known[guid]
	}
	saved := _meta_hulls_read(source)
	if len(ms.hull_sets) == 0 && len(model.sets) == 0 && len(saved) == 0 do return

	listed :: proc(ms: ^engine.MeshSettings, id: engine.Local_ID) -> bool {
		for s in ms.hull_sets do if s.id == id do return true
		return false
	}
	// Jobs and saved hulls of sets no longer listed go.
	for i := len(_jobs.queue) - 1; i >= 0; i -= 1 {
		j := _jobs.queue[i]
		if j.key.guid == guid && !listed(ms, j.key.set) do _job_drop(i)
	}
	for i := len(_jobs.running) - 1; i >= 0; i -= 1 {
		r := _jobs.running[i]
		if r.key.guid == guid && !listed(ms, r.key.set) do _job_cancel_running(i, record = false)
	}
	kept := make([dynamic]_Meta_Hulls, context.temp_allocator)
	for m in saved do if listed(ms, m.set) do append(&kept, m)
	if len(kept) != len(saved) do _meta_hulls_write(source, kept[:])

	clear(&model.sets)
	clear(&model.hashes)
	for s in ms.hull_sets {
		append(&model.sets, s)
		// A set shares the model's sub-asset ids with its parts and clips, so
		// a reference to the id would mean two things.
		clash := false
		for p in ms.parts do if p.id == s.id do clash = true
		for c in ms.clips do if c.id == s.id do clash = true
		if clash {
			log.errorf("[Physics3D] %s: convex decomposition %d has the id of a part or clip, remove it and add it again", source, s.id)
			continue
		}
		geom, ok := engine.mesh_geometry_of(engine.PPtr{guid = guid, local_id = s.part})
		if !ok do continue
		h := physics3d.mesh_hulls_source_hash(geom.positions, geom.indices, s)
		model.hashes[s.id] = h
		key := _Key{guid, s.id}
		target, _ := physics3d.mesh_hulls_path(guid, s.id)
		if fh, fok := physics3d.mesh_hulls_file_hash(target); fok && fh == h do continue
		if _restore_from_meta(kept[:], s.id, h, target) do continue
		if o, has := _jobs.outcomes[key]; has && o.source_hash == h do continue
		if _job_index(key, h) >= 0 do continue
		_job_cancel_key(key)
		_job_enqueue(key, s, h, source)
	}
}

// The hulls saved in the meta for a set, written to the library when they
// came from this mesh and these settings.
@(private = "file")
_restore_from_meta :: proc(saved: []_Meta_Hulls, set: engine.Local_ID, source_hash: u64, target: string) -> bool {
	for m in saved {
		if m.set != set do continue
		data, derr := base64.decode(m.data, allocator = context.temp_allocator)
		if derr != nil do return false
		if h, ok := physics3d.mesh_hulls_data_hash(data); !ok || h != source_hash do return false
		return physics3d.mesh_hulls_write(target, data)
	}
	return false
}

// The hulls a model's .meta keeps, temp-allocated.
@(private = "file")
_meta_hulls_read :: proc(source: string) -> []_Meta_Hulls {
	v, ok := asset_pipeline.asset_meta_value(source, META_HULLS_KEY, context.temp_allocator)
	if !ok do return nil
	arr, is_arr := v.(json.Array)
	if !is_arr do return nil
	out := make([dynamic]_Meta_Hulls, 0, len(arr), context.temp_allocator)
	for e in arr {
		obj, is_obj := e.(json.Object)
		if !is_obj do continue
		set, sok := obj["set"].(json.Integer)
		data, dok := obj["data"].(json.String)
		if !sok || !dok do continue
		append(&out, _Meta_Hulls{engine.Local_ID(set), string(data)})
	}
	return out[:]
}

// Writes the meta's hulls, ordered by set id, or drops the key when none.
@(private = "file")
_meta_hulls_write :: proc(source: string, entries: []_Meta_Hulls) {
	if len(entries) == 0 {
		asset_pipeline.asset_meta_set_value(source, META_HULLS_KEY, nil)
		return
	}
	sorted := slice.clone(entries, context.temp_allocator)
	slice.sort_by(sorted, proc(a, b: _Meta_Hulls) -> bool { return a.set < b.set })
	arr := make(json.Array, 0, len(sorted), context.temp_allocator)
	for e in sorted {
		obj := make(json.Object, context.temp_allocator)
		obj["set"] = json.Integer(e.set)
		obj["data"] = json.String(e.data)
		append(&arr, obj)
	}
	if !asset_pipeline.asset_meta_set_value(source, META_HULLS_KEY, arr) {
		log.errorf("[Physics3D] cannot save the hulls into %s.meta", source)
	}
}

// One set's hulls into the meta, replacing what it had for the set.
@(private = "file")
_meta_hulls_put :: proc(source: string, set: engine.Local_ID, data: []byte) {
	entries := make([dynamic]_Meta_Hulls, context.temp_allocator)
	for m in _meta_hulls_read(source) do if m.set != set do append(&entries, m)
	append(&entries, _Meta_Hulls{set, base64.encode(data, allocator = context.temp_allocator)})
	_meta_hulls_write(source, entries[:])
}

// A set's state for the inspector, with a line saying more (temp-allocated).
hull_set_state :: proc(guid: engine.Asset_GUID, set: engine.Local_ID) -> (state: Hull_Set_State, detail: string) {
	key := _Key{guid, set}
	for r in _jobs.running do if r.key == key do return .Running, _running_detail(r)
	for j, i in _jobs.queue do if j.key == key do return .Queued, fmt.tprintf("queued, %d ahead", i)
	model, known := _jobs.known[guid]
	if !known do return .Unavailable, "not imported yet"
	h, hashed := model.hashes[set]
	if !hashed do return .Unavailable, "the mesh cannot be loaded"
	if o, has := _jobs.outcomes[key]; has && o.source_hash == h {
		return o.state, o.error if o.state == .Failed else "cancelled"
	}
	if hulls, st := physics3d.mesh_hulls(guid, set); st == .Ready do return .Ready, fmt.tprintf("%d hulls", len(hulls))
	return .Unavailable, "no hulls"
}

// The sets a model has applied, as the last reconcile saw them.
hull_sets_applied :: proc(guid: engine.Asset_GUID) -> []engine.Mesh_Hull_Set {
	if model, ok := _jobs.known[guid]; ok do return model.sets[:]
	return nil
}

// Queues a failed or cancelled set again.
hull_set_compute :: proc(guid: engine.Asset_GUID, set: engine.Local_ID) {
	context.allocator = runtime.default_allocator()
	if o, has := _jobs.outcomes[_Key{guid, set}]; has {
		delete(o.error)
		delete_key(&_jobs.outcomes, _Key{guid, set})
	}
	hull_sets_reconcile(guid)
}

// Cancels a set's queued or running decomposition.
hull_set_cancel :: proc(guid: engine.Asset_GUID, set: engine.Local_ID) {
	_job_cancel_key(_Key{guid, set}, record = true)
}

// Blocks until no decomposition is queued or running. For tests and tools:
// the editor polls from its status bar instead.
hull_jobs_wait :: proc() {
	for len(_jobs.running) > 0 || len(_jobs.queue) > 0 {
		_poll()
		time.sleep(10 * time.Millisecond)
	}
}

// Kills the running decompositions when the editor quits.
@(phase={key=engine.Phase.EditorShutdown, mode=Editor})
hull_jobs_shutdown :: proc() {
	for len(_jobs.running) > 0 do _job_cancel_running(len(_jobs.running) - 1, record = false)
}

// --- Jobs ------------------------------------------------------------------------

@(private = "file")
_job_enqueue :: proc(key: _Key, set: engine.Mesh_Hull_Set, source_hash: u64, source: string) {
	context.allocator = runtime.default_allocator()
	j := new(_Job)
	j^ = {key = key, set = set, source_hash = source_hash, name = strings.clone(filepath.stem(source))}
	append(&_jobs.queue, j)
}

@(private = "file")
_job_index :: proc(key: _Key, source_hash: u64) -> int {
	for r, i in _jobs.running do if r.key == key && r.source_hash == source_hash do return i
	for j, i in _jobs.queue do if j.key == key && j.source_hash == source_hash do return i
	return -1
}

@(private = "file")
_job_free :: proc(j: ^_Job) {
	context.allocator = runtime.default_allocator()
	if j.dir != "" do _remove_dir(j.dir)
	delete(j.dir)
	delete(j.name)
	delete(j.stage)
	free(j)
}

@(private = "file")
_job_drop :: proc(i: int) {
	j := _jobs.queue[i]
	ordered_remove(&_jobs.queue, i)
	_job_free(j)
}

@(private = "file")
_job_cancel_key :: proc(key: _Key, record := false) {
	for r, i in _jobs.running do if r.key == key {
		_job_cancel_running(i, record)
		return
	}
	for j, i in _jobs.queue do if j.key == key {
		if record do _outcome_set(j.key, j.source_hash, .Cancelled, "")
		_job_drop(i)
		return
	}
}

@(private = "file")
_job_cancel_running :: proc(i: int, record: bool) {
	j := _jobs.running[i]
	ordered_remove(&_jobs.running, i)
	_ = os.process_kill(j.process)
	_, _ = os.process_wait(j.process)
	if record {
		_outcome_set(j.key, j.source_hash, .Cancelled, "")
		log.infof("[Physics3D] the convex decomposition of %s (%d hulls) is cancelled", j.name, j.set.max_hulls)
	}
	_job_free(j)
}

@(private = "file")
_outcome_set :: proc(key: _Key, source_hash: u64, state: Hull_Set_State, error: string) {
	context.allocator = runtime.default_allocator()
	if o, has := _jobs.outcomes[key]; has do delete(o.error)
	_jobs.outcomes[key] = {source_hash, state, strings.clone(error)}
}

// Takes in the finished jobs, reads the running ones' stages and starts
// queued ones up to the settings' limit. Called every frame from the status
// bar.
@(private = "file")
_poll :: proc() {
	context.allocator = runtime.default_allocator()
	for i := len(_jobs.running) - 1; i >= 0; i -= 1 {
		j := _jobs.running[i]
		state, werr := os.process_wait(j.process, 0)
		if werr == nil && state.exited {
			ordered_remove(&_jobs.running, i)
			_job_finish(j, state.exit_code)
			_job_free(j)
		} else {
			_read_stage(j)
		}
	}
	limit := physics3d.decompositions_at_once()
	for len(_jobs.running) < limit && len(_jobs.queue) > 0 {
		j := _jobs.queue[0]
		ordered_remove(&_jobs.queue, 0)
		if _job_start(j) {
			append(&_jobs.running, j)
		} else {
			_job_free(j)
		}
	}
}

// Writes the mesh as OBJ into a work folder in the library and starts CoACD
// on it. False, with an outcome recorded, when it cannot start.
@(private = "file")
_job_start :: proc(j: ^_Job) -> bool {
	context.allocator = runtime.default_allocator()
	geom, ok := engine.mesh_geometry_of(engine.PPtr{guid = j.key.guid, local_id = j.set.part})
	if !ok {
		_outcome_set(j.key, j.source_hash, .Failed, "the mesh cannot be loaded")
		return false
	}
	// The mesh changed since the job queued: the reimport's reconcile queues
	// the current one.
	if physics3d.mesh_hulls_source_hash(geom.positions, geom.indices, j.set) != j.source_hash do return false
	if !os.exists(coacd_exe) {
		_outcome_set(j.key, j.source_hash, .Failed, "CoACD is not built, run mh setup")
		log.errorf("[Physics3D] the convex decomposition needs CoACD, which mh setup builds: %s is missing", coacd_exe)
		return false
	}

	j.dir = fmt.aprintf("%s/hull_jobs/%v_%d", engine.library_dir(), j.key.guid, j.key.set)
	_remove_dir(j.dir)
	engine._ensure_artifact_dir(strings.concatenate({j.dir, "/in.obj"}, context.temp_allocator))
	obj := strings.builder_make(context.temp_allocator)
	for p in geom.positions do fmt.sbprintf(&obj, "v %v %v %v\n", p.x, p.y, p.z)
	for t := 0; t + 2 < len(geom.indices); t += 3 {
		fmt.sbprintf(&obj, "f %d %d %d\n", geom.indices[t] + 1, geom.indices[t + 1] + 1, geom.indices[t + 2] + 1)
	}
	in_path := strings.concatenate({j.dir, "/in.obj"}, context.temp_allocator)
	if os.write_entire_file(in_path, transmute([]byte)strings.to_string(obj)) != nil {
		_outcome_set(j.key, j.source_hash, .Failed, "cannot write the mesh for CoACD")
		return false
	}
	log_file, lerr := os.open(strings.concatenate({j.dir, "/log.txt"}, context.temp_allocator), {.Write, .Create, .Trunc})
	if lerr != nil {
		_outcome_set(j.key, j.source_hash, .Failed, "cannot write CoACD's log")
		return false
	}
	defer os.close(log_file)
	exe, _ := filepath.abs(coacd_exe, context.temp_allocator)
	command := []string{
		exe,
		"-i", "in.obj",
		"-o", "out.obj",
		"-ro", "remesh.obj",
		"-c", fmt.tprintf("%d", j.set.max_hulls),
		"-t", fmt.tprintf("%v", j.set.concavity),
		"-pr", fmt.tprintf("%d", j.set.remesh_resolution),
		"-d", "--max-ch-vertex", fmt.tprintf("%d", physics3d.HULL_MAX_VERTICES),
		"--seed", _SEED,
	}
	p, serr := os.process_start({command = command, working_dir = j.dir, stdout = log_file, stderr = log_file})
	if serr != nil {
		_outcome_set(j.key, j.source_hash, .Failed, fmt.tprintf("cannot start CoACD: %v", serr))
		return false
	}
	j.process = p
	j.started = time.tick_now()
	j.stage = strings.clone("starting")
	log.infof("[Physics3D] decomposing %s into at most %d hulls", j.name, j.set.max_hulls)
	return true
}

// Saves a finished job's hulls under the model's current artifact, or
// records why it failed.
@(private = "file")
_job_finish :: proc(j: ^_Job, exit_code: int) {
	elapsed := time.tick_since(j.started)
	if exit_code != 0 {
		_outcome_set(j.key, j.source_hash, .Failed, fmt.tprintf("CoACD exited with %d, see %s/log.txt", exit_code, j.dir))
		log.errorf("[Physics3D] the convex decomposition of %s failed: CoACD exited with %d", j.name, exit_code)
		// The log stays for reading.
		delete(j.dir)
		j.dir = ""
		return
	}
	hulls, ok := _read_obj_hulls(strings.concatenate({j.dir, "/out.obj"}, context.temp_allocator))
	if !ok || len(hulls) == 0 {
		_outcome_set(j.key, j.source_hash, .Failed, "CoACD wrote no hulls")
		log.errorf("[Physics3D] the convex decomposition of %s wrote no hulls", j.name)
		return
	}
	data := physics3d.mesh_hulls_encode(j.source_hash, hulls)
	target, tok := physics3d.mesh_hulls_path(j.key.guid, j.key.set)
	if !tok || !physics3d.mesh_hulls_write(target, data) {
		_outcome_set(j.key, j.source_hash, .Failed, "cannot save the hulls")
		log.errorf("[Physics3D] cannot save the convex decomposition of %s", j.name)
		return
	}
	if source, sok := engine.asset_db_get_path(uuid.Identifier(j.key.guid)); sok do _meta_hulls_put(source, j.key.set, data)
	log.infof("[Physics3D] %s decomposed into %d hulls in %.0f s", j.name, len(hulls), time.duration_seconds(elapsed))
}

// The vertices of each "o" block of CoACD's OBJ output, temp-allocated.
@(private = "file")
_read_obj_hulls :: proc(path: string) -> ([][][3]f32, bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return nil, false
	out := make([dynamic][][3]f32, context.temp_allocator)
	cur: [dynamic][3]f32
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		if strings.has_prefix(line, "o ") {
			if cur != nil do append(&out, cur[:])
			cur = make([dynamic][3]f32, context.temp_allocator)
		} else if strings.has_prefix(line, "v ") {
			if cur == nil do cur = make([dynamic][3]f32, context.temp_allocator)
			fields := strings.fields(line[2:], context.temp_allocator)
			if len(fields) < 3 do return nil, false
			p: [3]f32
			for k in 0 ..< 3 {
				v, vok := strconv.parse_f32(fields[k])
				if !vok do return nil, false
				p[k] = v
			}
			append(&cur, p)
		}
	}
	if cur != nil do append(&out, cur[:])
	return out[:], true
}

// The running job's stage from the new lines of CoACD's log, read four
// times a second. CoACD knows no total, so this is a stage, not a fraction.
@(private = "file")
_read_stage :: proc(j: ^_Job) {
	now := time.tick_now()
	if time.tick_diff(j.last_read, now) < 250 * time.Millisecond do return
	j.last_read = now
	data, err := os.read_entire_file(strings.concatenate({j.dir, "/log.txt"}, context.temp_allocator), context.temp_allocator)
	if err != nil || len(data) <= j.log_read do return
	text := string(data[j.log_read:])
	// Whole lines only: the last one may still be written.
	last_nl := strings.last_index_byte(text, '\n')
	if last_nl < 0 do return
	j.log_read += last_nl + 1
	text = text[:last_nl]
	stage := ""
	for line in strings.split_lines_iterator(&text) {
		if strings.contains(line, "Manifold Check") {
			stage = "checking the mesh"
		} else if strings.contains(line, " - Preprocess") {
			stage = "remeshing"
		} else if i := strings.index(line, "iter "); i >= 0 && strings.contains(line, "waiting pool") {
			parts := strings.fields(line[i:], context.temp_allocator)
			// "iter N ---- waiting pool: K"
			if len(parts) >= 6 do stage = fmt.tprintf("cutting, round %s, %s pieces open", parts[1], parts[5])
		} else if strings.contains(line, "Merge Convex Hulls") {
			stage = "merging"
		} else if strings.contains(line, "Simplify Convex Hulls") {
			stage = "simplifying"
		}
	}
	if stage != "" {
		context.allocator = runtime.default_allocator()
		delete(j.stage)
		j.stage = strings.clone(stage)
	}
}

@(private = "file")
_running_detail :: proc(j: ^_Job) -> string {
	return fmt.tprintf("%s, %.0f s", j.stage, time.duration_seconds(time.tick_since(j.started)))
}

// The status bar's lines: polls the jobs, then one line per running job,
// whose Cancel cancels that job.
@(private = "file")
_task_source :: proc() -> []tasks.Status {
	_poll()
	if len(_jobs.running) == 0 do return nil
	out := make([]tasks.Status, len(_jobs.running), context.temp_allocator)
	for j, i in _jobs.running {
		detail := fmt.tprintf("%s, %d hulls, %s", j.name, j.set.max_hulls, _running_detail(j))
		if i == 0 && len(_jobs.queue) > 0 do detail = fmt.tprintf("%s (%d queued)", detail, len(_jobs.queue))
		out[i] = {
			title    = "Convex decomposition",
			detail   = detail,
			fraction = -1,
			cancel   = proc(data: rawptr) {
				for r, k in _jobs.running do if rawptr(r) == data {
					_job_cancel_running(k, record = true)
					return
				}
			},
			data     = j,
		}
	}
	return out
}

@(private = "file")
_remove_dir :: proc(dir: string) {
	handle, err := os.open(dir)
	if err != nil do return
	files, _ := os.read_dir(handle, -1, context.temp_allocator)
	os.close(handle)
	for f in files {
		path, _ := filepath.join({dir, f.name}, context.temp_allocator)
		os.remove(path)
	}
	os.remove(dir)
}
