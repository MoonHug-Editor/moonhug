package progress

// Progress reporting for blocking work (Unity's DisplayProgressBar model):
// the work stays on the main thread, each report pumps a redraw through the
// registered sink. No sink registered (app builds, tests, headless tools):
// every call is a no-op.
//
// Any editor-side code can report — the pipeline and editor init use the
// same calls:
//
//	progress.begin("Importing assets")
//	for path, i in paths {
//	    progress.report(path, f32(i) / f32(len(paths)))
//	    ...
//	}
//	progress.end()
//
// fraction < 0 means "unknown" — the sink shows an indeterminate bar.
// Reports are throttled by the sink, so per-item reporting is cheap.
// begin/end nest: an inner begin/end pair restores the outer title.

Progress_Sink :: proc(title, info: string, fraction: f32)

@(private = "file")
_progress: struct {
	sink:      Progress_Sink,
	titles:    [8]string, // literals or strings outliving their begin..end
	depth:     int,
	in_report: bool,
}

set_sink :: proc(sink: Progress_Sink) {
	_progress.sink = sink
}

begin :: proc(title: string) {
	if _progress.depth < len(_progress.titles) {
		_progress.titles[_progress.depth] = title
	}
	_progress.depth += 1
	report("", -1)
}

report :: proc(info: string, fraction: f32 = -1) {
	if _progress.sink == nil || _progress.in_report do return
	_progress.in_report = true
	defer _progress.in_report = false
	title := ""
	if _progress.depth > 0 {
		title = _progress.titles[min(_progress.depth, len(_progress.titles)) - 1]
	}
	_progress.sink(title, info, fraction)
}

end :: proc() {
	if _progress.depth > 0 do _progress.depth -= 1
}
