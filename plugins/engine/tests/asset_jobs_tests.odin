package engine_tests

// The asset job system (plugins/engine/asset_jobs.odin): a worker reads the
// file and runs `work`, the main thread runs `finish`.

import "base:runtime"
import "core:os"
import "core:testing"
import "core:time"
import "moonhug:packages/engine"

@(private = "file")
_Result :: struct {
	sum:      int, // made by work
	finished: int, // finish calls
	failed:   bool,
	bytes:    int,
}

@(private = "file")
_results: [4]_Result

@(private = "file")
_sum_work :: proc(job: ^engine.Asset_Job) {
	sum := new(int, runtime.default_allocator())
	for b in job.data do sum^ += int(b)
	job.user = sum
}

@(private = "file")
_slow_work :: proc(job: ^engine.Asset_Job) {
	time.sleep(30 * time.Millisecond)
	_sum_work(job)
}

@(private = "file")
_sum_finish :: proc(job: ^engine.Asset_Job) {
	r := &_results[job.ref.local_id]
	r.finished += 1
	r.failed = job.failed
	r.bytes = len(job.data)
	if sum := cast(^int)job.user; sum != nil {
		r.sum = sum^
		free(sum, runtime.default_allocator())
	}
}

@(private = "file")
_write :: proc(t: ^testing.T, path: string, text: string) -> bool {
	return testing.expect(t, os.write_entire_file(path, transmute([]byte)text) == nil)
}

// A job's work runs off the main thread and its finish runs when the main
// thread asks: asset_jobs_finish for the jobs that are done.
@(test)
test_asset_job_reads_and_works_on_a_worker_and_finishes_on_the_main_thread :: proc(t: ^testing.T) {
	defer engine.asset_jobs_shutdown()
	_results = {}
	path :: "moonhug/tests/fixtures/_asset_job_a_tmp.bin"
	defer os.remove(path)
	if !_write(t, path, "\x01\x02\x03") do return

	ref := engine.PPtr{local_id = 1}
	engine.asset_job_start(ref, path, _sum_finish, _slow_work)
	engine.asset_job_start(ref, path, _sum_finish, _slow_work) // the same job: nothing new
	testing.expect(t, engine.asset_jobs_pending() == 1, "one job for one asset")
	testing.expect(t, engine.asset_job_pending(ref, _sum_finish))
	testing.expect(t, _results[1].finished == 0, "finish does not run by itself")

	for _ in 0 ..< 200 {
		engine.asset_jobs_finish(1)
		if engine.asset_jobs_pending() == 0 do break
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, engine.asset_jobs_pending() == 0, "the job ends")
	r := _results[1]
	testing.expectf(t, r.finished == 1 && !r.failed && r.sum == 6 && r.bytes == 3, "finish sees the file and the work's result once, got %v", r)
}

// asset_job_wait ends one job at once, also one no worker took yet, and a
// job whose file is missing still finishes, marked failed.
@(test)
test_asset_job_wait_ends_a_job_now_and_a_missing_file_fails :: proc(t: ^testing.T) {
	defer engine.asset_jobs_shutdown()
	_results = {}
	path :: "moonhug/tests/fixtures/_asset_job_b_tmp.bin"
	defer os.remove(path)
	if !_write(t, path, "\x0a\x0b") do return

	// More jobs than workers, so some wait in the queue.
	refs: [3]engine.PPtr
	for i in 0 ..< 3 {
		refs[i] = engine.PPtr{local_id = engine.Local_ID(i + 1)}
		engine.asset_job_start(refs[i], path, _sum_finish, _slow_work)
	}
	testing.expect(t, engine.asset_job_wait(refs[2], _sum_finish), "the job is waited for")
	testing.expectf(t, _results[3].finished == 1 && _results[3].sum == 21, "and finished, got %v", _results[3])
	testing.expect(t, !engine.asset_job_wait(refs[2], _sum_finish), "a finished job is gone")
	engine.asset_jobs_wait_all()
	testing.expect(t, _results[1].finished == 1 && _results[2].finished == 1 && engine.asset_jobs_pending() == 0, "wait_all ends the rest")

	missing := engine.PPtr{local_id = 0}
	engine.asset_job_start(missing, "moonhug/tests/fixtures/_asset_job_none.bin", _sum_finish, _sum_work)
	testing.expect(t, engine.asset_job_wait(missing, _sum_finish))
	testing.expectf(t, _results[0].finished == 1 && _results[0].failed, "a missing file finishes as failed, got %v", _results[0])
}
