package engine

// Loading asset files on worker threads. One job loads one asset in three
// parts:
//
// - begin, main thread: the asset type finds the file and calls
//   asset_job_start. Cheap.
// - work, worker thread: the job system reads the file, then the type's
//   `work` proc decodes the bytes into plain memory. The slow part.
// - finish, main thread: the type's `finish` proc uploads to the GPU and
//   puts the result in its cache. Short.
//
// An asset type uses it from its @(asset_preload) proc (asset_preload.odin):
//
//   asset_job_start(ref, artifact_path, _texture_finish, _texture_work)
//
// and its loader starts with
//
//   if asset_job_wait(ref, _texture_finish) do <the asset is in the cache, or failed>
//
// so a draw or a sync load that needs the asset while its job runs waits for
// that one job. Nothing sees a half-loaded asset.
//
// Rules for a `work` proc. It runs on a worker thread:
// - it reads `job.data` and `job.path`, and writes `job.user` and `job.failed`
// - it allocates with runtime.default_allocator(), or with
//   context.temp_allocator for scratch memory, which the worker frees after
//   the job
// - it touches no cache, no asset database, no GPU and no engine global
// - it does not log. It sets `job.failed`, and `finish` reports
//
// `finish` always runs, on the main thread, also for a failed job: it frees
// what `work` put in `job.user`. The job system frees `job.data` after
// `finish`, unless `finish` took the bytes and set `job.data = nil`. When
// `job.discard` is set, `finish` only frees: the engine shuts down and the
// caches go next, so a GPU upload would be wasted.
//
// Jobs are numbered in the order they start. asset_jobs_mark gives the
// number of the last one, and asset_jobs_pending and asset_jobs_wait_all
// take a mark to count only the jobs started up to it. A scene load waits
// for the jobs it started this way, not for jobs that started after it.
//
// asset_jobs_finish runs the finish procs of the jobs whose work is done.
// frame_tick calls it at the start of each frame through scene_loads_step.

import "base:runtime"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

Asset_Job_Work :: proc(job: ^Asset_Job)
Asset_Job_Finish :: proc(job: ^Asset_Job)

Asset_Job :: struct {
	ref:         PPtr, // the asset
	path:        string, // the file, owned by the job
	data:        []byte, // the file's bytes when `read`, on the default allocator
	read_failed: bool, // the file could not be read
	failed:      bool, // the read or `work` failed
	user:        rawptr, // what `work` made for `finish`
	work:        Asset_Job_Work,
	finish:      Asset_Job_Finish,
	read:        bool,
	discard:     bool, // finish frees what work made and stores nothing
	order:       u64, // the job's number in the order jobs start, from 1
	state:       _Job_State, // guarded by _job_mutex
}

@(private = "file")
_Job_State :: enum {
	Queued,
	Working,
	Worked,
}

// Worker threads: enough to load in parallel, never all cores.
@(private = "file")
_JOB_THREADS_MAX :: 4

// Every job that has not finished. Main thread only.
@(private = "file")
_jobs: [dynamic]^Asset_Job

// The number of the last job started. Main thread only.
@(private = "file")
_jobs_started: u64

@(private = "file")
_job_mutex: sync.Mutex
@(private = "file")
_job_queue: [dynamic]^Asset_Job // guarded: the jobs no worker took yet
@(private = "file")
_job_wake: sync.Cond // a job was queued, or the workers quit
@(private = "file")
_job_done: sync.Cond // a job's work is done
@(private = "file")
_job_quit: bool // guarded
@(private = "file")
_job_threads: [dynamic]^thread.Thread

// Starts loading the asset `ref` from the file at `path` on a worker thread.
// The worker reads the file into `job.data` unless `read` is false, then runs
// `work`, which can be nil. `finish` runs later on the main thread. A second
// call for the same `ref` and `finish` while the first job runs does nothing.
asset_job_start :: proc(ref: PPtr, path: string, finish: Asset_Job_Finish, work: Asset_Job_Work = nil, read := true, user: rawptr = nil) {
	for j in _jobs do if j.ref == ref && j.finish == finish do return
	context.allocator = runtime.default_allocator()
	job := new(Asset_Job)
	job.ref = ref
	job.path = strings.clone(path)
	job.finish = finish
	job.work = work
	job.read = read
	job.user = user
	_jobs_started += 1
	job.order = _jobs_started
	append(&_jobs, job)
	_threads_ensure()
	sync.lock(&_job_mutex)
	append(&_job_queue, job)
	sync.cond_signal(&_job_wake)
	sync.unlock(&_job_mutex)
}

// Whether a job loads `ref` for `finish` now.
asset_job_pending :: proc(ref: PPtr, finish: Asset_Job_Finish) -> bool {
	for j in _jobs do if j.ref == ref && j.finish == finish do return true
	return false
}

// The number of the last job started: a mark for asset_jobs_pending and
// asset_jobs_wait_all.
asset_jobs_mark :: proc() -> u64 {
	return _jobs_started
}

// The jobs that have not finished. With `until`, only the jobs started up to
// that mark.
asset_jobs_pending :: proc(until := max(u64)) -> int {
	if until == max(u64) do return len(_jobs)
	n := 0
	for j in _jobs do if j.order <= until do n += 1
	return n
}

// Waits for the job that loads `ref` for `finish`, and finishes it. False
// when there is no such job. A job no worker took yet runs on this thread.
asset_job_wait :: proc(ref: PPtr, finish: Asset_Job_Finish) -> bool {
	if len(_jobs) == 0 do return false
	for j, i in _jobs {
		if j.ref != ref || j.finish != finish do continue
		unordered_remove(&_jobs, i)
		_job_complete(j)
		return true
	}
	return false
}

// Waits for every job and finishes it. With `until`, only the jobs started
// up to that mark. A finish can start a job: it ends too when it is in range.
asset_jobs_wait_all :: proc(until := max(u64)) {
	for {
		found := -1
		for j, i in _jobs do if j.order <= until {
			found = i
			break
		}
		if found < 0 do return
		j := _jobs[found]
		unordered_remove(&_jobs, found)
		_job_complete(j)
	}
}

// Waits for every job of the asset file `guid`, its sub-assets included, and
// finishes it.
asset_jobs_wait_guid :: proc(guid: Asset_GUID) {
	for i := len(_jobs) - 1; i >= 0; i -= 1 {
		// A finish proc can finish other jobs.
		if i >= len(_jobs) do continue
		j := _jobs[i]
		if j.ref.guid != guid do continue
		unordered_remove(&_jobs, i)
		_job_complete(j)
	}
}

// Finishes the jobs whose work is done, for `budget_ms`. A finish that
// started always ends, so one call can take longer than the budget.
asset_jobs_finish :: proc(budget_ms: f64) {
	if len(_jobs) == 0 do return
	start := time.tick_now()
	for {
		found: ^Asset_Job
		sync.lock(&_job_mutex)
		for j, i in _jobs {
			if j.state != .Worked do continue
			found = j
			unordered_remove(&_jobs, i)
			break
		}
		sync.unlock(&_job_mutex)
		if found == nil do return
		_job_end(found)
		if time.duration_milliseconds(time.tick_since(start)) >= budget_ms do return
	}
}

// Ends every job and stops the worker threads. The jobs' results are
// discarded: their finish procs only free. The next job starts the threads
// again.
asset_jobs_shutdown :: proc() {
	for j in _jobs do j.discard = true
	asset_jobs_wait_all()
	if len(_job_threads) == 0 do return
	sync.lock(&_job_mutex)
	_job_quit = true
	sync.cond_broadcast(&_job_wake)
	sync.unlock(&_job_mutex)
	for t in _job_threads {
		thread.join(t)
		thread.destroy(t)
	}
	delete(_job_threads)
	_job_threads = nil
	delete(_job_queue)
	_job_queue = nil
	delete(_jobs)
	_jobs = nil
	_job_quit = false
}

@(phase={key=EngineShutdown, order=20})
engine_shutdown_asset_jobs :: proc() {
	asset_jobs_shutdown()
}

// An asset that changes on disk first ends its jobs, so a job never puts an
// old file's data into a cache after the cache dropped it.
@(asset_on_changed={order=-1})
asset_on_changed_asset_jobs :: proc(guid: Asset_GUID, path: string, change: Asset_Change) {
	if len(_jobs) > 0 do asset_jobs_wait_guid(guid)
}

// Waits for the work of a job taken off `_jobs`, then finishes it.
@(private = "file")
_job_complete :: proc(j: ^Asset_Job) {
	sync.lock(&_job_mutex)
	if j.state == .Queued {
		// No worker has it: do the work here instead of waiting in line.
		for q, i in _job_queue do if q == j {
			ordered_remove(&_job_queue, i)
			break
		}
		j.state = .Working
		sync.unlock(&_job_mutex)
		_job_work(j)
	} else {
		for j.state != .Worked do sync.cond_wait(&_job_done, &_job_mutex)
		sync.unlock(&_job_mutex)
	}
	_job_end(j)
}

// The main thread's part, and the end of the job.
@(private = "file")
_job_end :: proc(j: ^Asset_Job) {
	j.finish(j)
	alloc := runtime.default_allocator()
	if j.data != nil do delete(j.data, alloc)
	delete(j.path, alloc)
	free(j, alloc)
}

// The worker's part: the file, then the type's work.
@(private = "file")
_job_work :: proc(j: ^Asset_Job) {
	if j.read {
		data, err := os.read_entire_file(j.path, runtime.default_allocator())
		if err != nil {
			j.read_failed = true
			j.failed = true
			return
		}
		j.data = data
	}
	if j.work != nil do j.work(j)
}

@(private = "file")
_job_worker :: proc() {
	for {
		sync.lock(&_job_mutex)
		for len(_job_queue) == 0 && !_job_quit do sync.cond_wait(&_job_wake, &_job_mutex)
		if _job_quit {
			sync.unlock(&_job_mutex)
			return
		}
		j := _job_queue[0]
		ordered_remove(&_job_queue, 0)
		j.state = .Working
		sync.unlock(&_job_mutex)

		_job_work(j)
		free_all(context.temp_allocator)

		sync.lock(&_job_mutex)
		j.state = .Worked
		sync.cond_broadcast(&_job_done)
		sync.unlock(&_job_mutex)
	}
}

@(private = "file")
_threads_ensure :: proc() {
	if len(_job_threads) > 0 do return
	context.allocator = runtime.default_allocator()
	count := clamp(os.get_processor_core_count() - 1, 1, _JOB_THREADS_MAX)
	for _ in 0 ..< count {
		append(&_job_threads, thread.create_and_start(_job_worker))
	}
}
