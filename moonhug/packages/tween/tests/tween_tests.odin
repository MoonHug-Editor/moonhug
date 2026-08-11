package tween_tests

// The runner against a TOY union: these tests compile with no engine import,
// which is the package's whole contract. Real-union behavior (GUID-keyed JSON
// round-trips, TypeKey dispatch) is covered by the app's tween tests.

import tw "moonhug:packages/tween"

import "core:testing"

_Base :: struct {
	skip:  bool,
	seen:  int,
}

_Countdown :: struct {
	using base: _Base,
	until:      int,
}

_Never :: struct {
	using base: _Base,
}

_Toy :: union #no_nil {
	_Countdown,
	_Never,
}

_Ctx :: struct {
	hits: ^int,
}

_KEY_COUNTDOWN :: 1
_KEY_NEVER :: 2

_toy_key_of :: proc(task: ^_Toy) -> (int, bool) {
	switch _ in task^ {
	case _Countdown: return _KEY_COUNTDOWN, true
	case _Never:     return _KEY_NEVER, true
	}
	return 0, false
}

_toy_skip_of :: proc(task: ^_Toy) -> bool {
	return (cast(^_Base)task).skip
}

_tick_countdown :: proc(task: ^_Toy, dt: f32, ctx: _Ctx) -> tw.Status {
	c := &task.(_Countdown)
	c.seen += 1
	if ctx.hits != nil do ctx.hits^ += 1
	return .Done if c.seen >= c.until else .Running
}

// One free counter PER TEST: the test runner is multi-threaded and package
// globals are shared, so a single counter races across concurrently running
// tests -- the failure only shows outside the central suite, which pins
// ODIN_TEST_THREADS=1.
_frees_done: int
_free_count_done :: proc(task: ^_Toy) { _frees_done += 1 }
_frees_skip: int
_free_count_skip :: proc(task: ^_Toy) { _frees_skip += 1 }

_toy_runner :: proc(free_proc: proc(task: ^_Toy) = nil) -> tw.Runner(_Toy, _Ctx, 8) {
	r: tw.Runner(_Toy, _Ctx, 8)
	tw.init(&r, _toy_key_of, _toy_skip_of)
	r.ticks[_KEY_COUNTDOWN] = _tick_countdown
	r.frees[_KEY_COUNTDOWN] = free_proc
	return r
}

// A run ticks until its tween reports Done, then unlinks and frees -- ticking
// further does nothing. The context travels to every tick.
@(test)
test_run_ticks_to_done_and_frees :: proc(t: ^testing.T) {
	r := _toy_runner(_free_count_done)
	defer tw.destroy(&r)
	_frees_done = 0

	hits := 0
	v: _Toy = _Countdown{until = 3}
	testing.expect(t, tw.run_value(&r, &v, _Ctx{hits = &hits}), "run starts")

	tw.tick_running(&r, 0.016)
	tw.tick_running(&r, 0.016)
	testing.expect(t, r.running != nil, "still running before Done")
	tw.tick_running(&r, 0.016)
	testing.expect(t, r.running == nil, "unlinked on Done")
	testing.expect_value(t, _frees_done, 1)
	testing.expect_value(t, hits, 3)

	tw.tick_running(&r, 0.016)
	testing.expect_value(t, hits, 3)
}

// A skipped tween never starts: run reports false and the value is freed
// rather than leaked.
@(test)
test_skip_never_runs :: proc(t: ^testing.T) {
	r := _toy_runner(_free_count_skip)
	defer tw.destroy(&r)
	_frees_skip = 0

	v: _Toy = _Countdown{base = {skip = true}, until = 3}
	testing.expect(t, !tw.run_value(&r, &v, _Ctx{}), "skipped run refuses")
	testing.expect(t, r.running == nil, "nothing linked")
	testing.expect_value(t, _frees_skip, 1)
}

// A variant with no registered tick completes immediately instead of running
// forever or crashing -- the same contract the old engine dispatch had.
@(test)
test_unregistered_key_is_done :: proc(t: ^testing.T) {
	r := _toy_runner()
	defer tw.destroy(&r)

	v: _Toy = _Never{}
	testing.expect(t, tw.run_value(&r, &v, _Ctx{}), "run starts")
	tw.tick_running(&r, 0.016)
	testing.expect(t, r.running == nil, "completed as Done")
}

// The prototype library: register serializes, run_key instantiates a FRESH
// copy per run, so two runs never share state.
@(test)
test_register_and_run_key :: proc(t: ^testing.T) {
	r := _toy_runner()
	defer tw.destroy(&r)

	proto: _Toy = _Countdown{until = 2}
	tw.register(&r, "anim", &proto)
	testing.expect_value(t, tw.lib_count(&r), 1)

	testing.expect(t, tw.run_key(&r, "anim", _Ctx{}), "first run")
	testing.expect(t, tw.run_key(&r, "anim", _Ctx{}), "second run")

	// Both instances count down independently.
	tw.tick_running(&r, 0.016)
	testing.expect(t, r.running != nil, "both still running")
	tw.tick_running(&r, 0.016)
	testing.expect(t, r.running == nil, "both done")

	testing.expect(t, !tw.run_key(&r, "missing", _Ctx{}), "unknown key refuses")
}
