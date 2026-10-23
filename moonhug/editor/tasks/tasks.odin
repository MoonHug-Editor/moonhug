package tasks

// Background work the editor shows at the right end of its status bar: what
// runs, how far it is, and a button that cancels it. A package registers a
// source, and the status bar calls every source once per frame, so a source
// also polls its work there (a child process, a worker thread).
//
//	tasks.register(proc() -> []tasks.Status {
//		poll_my_jobs()
//		if !my_job_running do return nil
//		out := make([]tasks.Status, 1, context.temp_allocator)
//		out[0] = {title = "Baking", detail = "step 3", fraction = -1, cancel = cancel_my_job}
//		return out
//	})

import "base:runtime"

// One running task, temp-allocated by its source for the frame.
Status :: struct {
	title:    string,
	detail:   string,
	// 0..1, or below 0 when the total is unknown.
	fraction: f32,
	// nil when the task cannot be cancelled.
	cancel:   proc(data: rawptr),
	data:     rawptr,
}

Source :: proc() -> []Status

@(private = "file") _sources: [dynamic]Source

register :: proc(source: Source) {
	context.allocator = runtime.default_allocator()
	append(&_sources, source)
}

// Every source's tasks this frame, temp-allocated. The status bar calls this
// once per frame.
collect :: proc() -> []Status {
	out := make([dynamic]Status, context.temp_allocator)
	for source in _sources do append(&out, ..source())
	return out[:]
}
