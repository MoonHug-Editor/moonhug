package tests

import "../engine"
import sim "../editor/simulate"

import "core:testing"

// The Simulate state machine (docs/Simulate.md), reachable because the logic lives
// in editor/simulate, a subpackage with no imgui or view dependencies.

// A host whose ticks only count, so tests can assert what advanced.
_sim_ticks: int
_sim_fixed_ticks: int

@(private="file")
_count_update :: proc(dt: f32) { _sim_ticks += 1 }

@(private="file")
_count_fixed :: proc(dt: f32) { _sim_fixed_ticks += 1 }

// Fixed storage: a dynamic array here reads stale once teardown frees the
// per-test allocator.
@(private="file")
_phase_buf: [16]sim.Phase
@(private="file")
_phase_n: int

@(private="file")
_record_phase :: proc(p: sim.Phase) {
	if _phase_n < len(_phase_buf) {
		_phase_buf[_phase_n] = p
		_phase_n += 1
	}
}

@(private="file")
_phases_seen :: proc() -> []sim.Phase { return _phase_buf[:_phase_n] }

// Installs a counting host and a phase recorder. Selection and settings hooks stay
// nil, exercising the unset-hook no-op path.
@(private="file")
_sim_install :: proc(hosts: []sim.Host) {
	_sim_ticks = 0
	_sim_fixed_ticks = 0
	_phase_n = 0
	sim.install(sim.Hooks{phase = _record_phase}, hosts)
}

// Drops the phase recorder before shutdown, whose stop() would record
// transitions belonging to no test.
@(private="file")
_sim_uninstall :: proc() {
	sim.install(sim.Hooks{}, sim.hosts())
	sim.shutdown()
}

@(private="file")
_one_host_storage: [1]sim.Host

@(private="file")
_one_host :: proc() -> []sim.Host {
	_one_host_storage[0] = sim.Host{
		name = "app", update = _count_update, fixed_update = _count_fixed,
	}
	return _one_host_storage[:]
}

@(test)
test_sim_start_stop_round_trip :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_sim_sm.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)
	_sim_install(_one_host())
	defer _sim_uninstall()

	s := tc_mem.scene
	tH := engine.transform_new("Mover", engine.Transform_Handle(s.root.handle))
	lid: engine.Local_ID
	if tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH)); tr != nil {
		tr.position = {1, 2, 3}
		lid = tr.local_id
	}

	testing.expect(t, sim.state() == .Stopped, "starts Stopped")
	testing.expect(t, !engine.application_is_playing(), "not playing before start")

	testing.expect(t, sim.start(), "start succeeds")
	testing.expect(t, sim.state() == .Running)
	testing.expect(t, sim.is_ticking())
	testing.expect(t, engine.application_is_playing(), "playing while running")

	// A second start is refused rather than re-capturing over the snapshot.
	testing.expect(t, !sim.start(), "start is refused while active")

	if tr := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH)); tr != nil {
		tr.position = {99, 99, 99}
	}

	sim.stop()
	testing.expect(t, sim.state() == .Stopped)
	testing.expect(t, !engine.application_is_playing(), "not playing after stop")

	restored := engine.sm_scene_get_active()
	tc_mem.scene = restored
	rH, found := engine.scene_find_selectable_transform_local_id(restored, lid)
	testing.expect(t, found, "object survives the round trip")
	if !found do return
	rt := engine.pool_get(&tc_mem.world.transforms, engine.Handle(rH))
	testing.expect(t, rt != nil)
	if rt == nil do return
	testing.expectf(t, rt.position == [3]f32{1, 2, 3},
		"stop reverts the run's changes, got %v", rt.position)
}

// Pause holds the world without leaving the simulation: isPlaying stays true,
// ticking stops.
@(test)
test_sim_pause_holds_without_leaving :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_sim_pause.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)
	_sim_install(_one_host())
	defer _sim_uninstall()

	testing.expect(t, sim.start())
	sim.tick(1.0 / 60.0)
	ticks_running := _sim_ticks
	testing.expect(t, ticks_running > 0, "running advances the frame tick")

	sim.set_paused(true)
	testing.expect(t, sim.state() == .Paused)
	testing.expect(t, sim.is_active(), "paused is still active")
	testing.expect(t, !sim.is_ticking(), "paused does not tick")
	testing.expect(t, engine.application_is_playing(),
		"isPlaying stays true while paused")

	sim.tick(1.0 / 60.0)
	testing.expectf(t, _sim_ticks == ticks_running,
		"a paused tick advances nothing, got %d", _sim_ticks - ticks_running)

	sim.toggle_pause()
	testing.expect(t, sim.state() == .Running, "toggle resumes")
	sim.stop()
}

// Step advances exactly one fixed and one frame tick from either state, and leaves
// the simulation held.
@(test)
test_sim_step_advances_one_tick :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_sim_step.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)
	_sim_install(_one_host())
	defer _sim_uninstall()

	// Step from Stopped enters a held simulation.
	sim.step()
	testing.expect(t, sim.state() == .Paused, "step from stopped enters paused")
	testing.expect(t, sim.is_active())

	sim.tick(10.0) // large dt: a step must ignore the accumulator
	testing.expectf(t, _sim_fixed_ticks == 1,
		"step advances exactly one fixed tick, got %d", _sim_fixed_ticks)
	testing.expectf(t, _sim_ticks == 1,
		"step advances exactly one frame tick, got %d", _sim_ticks)

	// The step is consumed: the next tick advances nothing.
	sim.tick(10.0)
	testing.expectf(t, _sim_fixed_ticks == 1,
		"the step latch is consumed once, got %d", _sim_fixed_ticks)
	testing.expect(t, sim.state() == .Paused, "still held after stepping")

	sim.stop()
}

// Transitions fire in Unity's order, and a failed start emits none.
@(test)
test_sim_phase_order :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_sim_phase.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)
	_sim_install(_one_host())
	defer _sim_uninstall()

	testing.expect(t, sim.start())
	testing.expectf(t, _phase_n == 2, "start fires 2 phases, got %d", _phase_n)
	if _phase_n >= 2 {
		testing.expect(t, _phase_buf[0] == .ExitingEditMode)
		testing.expect(t, _phase_buf[1] == .EnteredPlayMode)
	}

	// Pause is not a mode change.
	sim.set_paused(true)
	testing.expectf(t, _phase_n == 2, "pause fires nothing, got %d", _phase_n)

	sim.stop()
	testing.expectf(t, _phase_n == 4, "stop fires 2 more, got %d", _phase_n)
	if _phase_n >= 4 {
		testing.expectf(t, _phase_buf[2] == .ExitingPlayMode, "phases: %v", _phases_seen())
		testing.expectf(t, _phase_buf[3] == .EnteredEditMode, "phases: %v", _phases_seen())
	}
}

// With no host there is nothing to tick: start refuses and emits no phases.
@(test)
test_sim_refuses_without_host :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_sim_nohost.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)
	_sim_install([]sim.Host{})
	defer _sim_uninstall()

	testing.expect(t, !sim.available(), "no hosts means unavailable")
	testing.expect(t, !sim.start(), "start refuses without a host")
	testing.expect(t, sim.state() == .Stopped)
	testing.expectf(t, _phase_n == 0,
		"a refused start fires no transitions, got %d", _phase_n)
}

// Host selection: guards by name, and stops a running simulation rather than
// swapping update sets mid-run.
@(test)
test_sim_host_selection :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_sim_hosts.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)
	_sim_install([]sim.Host{
		{name = "app", update = _count_update, fixed_update = _count_fixed},
		{name = "game2", update = _count_update, fixed_update = _count_fixed},
	})
	defer _sim_uninstall()

	// Row 0 is the default, so one game needs no setting.
	h, ok := sim.active_host()
	testing.expect(t, ok && h.name == "app", "defaults to the first host")
	testing.expect(t, sim.host_is("app"))
	testing.expect(t, !sim.host_is("game2"))

	testing.expect(t, sim.start())
	sim.set_host(1)
	testing.expect(t, sim.state() == .Stopped,
		"changing host stops the running simulation")
	h2, ok2 := sim.active_host()
	testing.expect(t, ok2 && h2.name == "game2", "host switched")
	testing.expect(t, sim.host_is("game2"))

	// Out-of-range selections are ignored rather than clamped.
	sim.set_host(99)
	h3, _ := sim.active_host()
	testing.expect(t, h3.name == "game2", "out-of-range host index is ignored")
}
