package tests

// The progress API: no-op without a sink, sink receives title/info/fraction,
// begin/end nesting restores the outer title, and the reentrancy guard stops
// a report issued from inside the sink.

import "core:testing"
import "../engine"

@(private = "file")
_calls: [dynamic]string

@(private = "file")
_recording_sink :: proc(title, info: string, fraction: f32) {
	append(&_calls, title)
	append(&_calls, info)
	// A sink that reports (a redraw triggering asset work) must not recurse.
	engine.progress_report("recursed", 1)
}

@(test)
test_progress_sink_and_nesting :: proc(t: ^testing.T) {
	// Without a sink every call is a no-op — engine internals report
	// unconditionally, so this is the headless/app safety property.
	engine.progress_report("ignored", 0.5)
	engine.progress_begin("ignored")
	engine.progress_end()

	engine.progress_set_sink(_recording_sink)
	defer engine.progress_set_sink(nil)
	defer delete(_calls)

	engine.progress_begin("Outer")
	engine.progress_report("step 1", 0.5)
	engine.progress_begin("Inner")
	engine.progress_report("inner step", -1)
	engine.progress_end()
	engine.progress_report("step 2", 0.9)
	engine.progress_end()

	expected := []string{
		"Outer", "",           // begin's initial report
		"Outer", "step 1",
		"Inner", "",           // nested begin
		"Inner", "inner step",
		"Outer", "step 2",     // nesting restored the outer title
	}
	testing.expect_value(t, len(_calls), len(expected))
	for e, i in expected {
		if i < len(_calls) do testing.expect_value(t, _calls[i], e)
	}
	// The sink's own report never re-entered ("recursed" absent).
	for c in _calls do testing.expect(t, c != "recursed", "reentrancy guard holds")
}
