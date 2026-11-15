package engine

// Time: the game's time, its scale, and the timelines timed systems run on.
//
//   dt := engine.delta_time()             // this frame's step, scaled
//   engine.set_time_scale(0.25)           // slow motion
//   engine.set_time_scale(0)              // hold the game
//   real := engine.unscaled_delta_time()  // for menus: ignores the scale
//
// - The time scale is one number for the whole game. It scales the delta
//   time @(update) and @(late_update) procs get, and how fast fixed ticks
//   come: at 0.5 a fixed tick runs half as often, still with the full fixed
//   step. At 0 no fixed tick runs and the frame's delta time is 0.
// - `Time` names a timeline. The built-in ones:
//   - `Update` advances every frame by the scaled delta time. It is the
//     default wherever a timeline is optional.
//   - `Fixed` advances every fixed tick by the fixed step.
//   - `Unscaled` advances every frame by the real delta time.
// - A package adds timelines with a `Time_Extra` enum of its own. The
//   generated `Time` enum (time_generated.odin) lists them after the built-in
//   ones.
// - An added timeline follows a built-in one, its base (`Update` unless
//   set_time_base says otherwise), and has a scale and a pause of its own on
//   top: its step is the base's step times its scale. One on `Update` slows
//   down with the game, one on `Unscaled` does not.
// - frame_tick advances the timelines before the procs of each stage run.
// - `time` itself is the name of Odin's time package, so the seconds a
//   timeline has advanced are time_now.

Time_State :: struct {
	now:    f64,  // seconds this timeline has advanced
	dt:     f32,  // the last step, in seconds
	scale:  f32,
	paused: bool,
	base:   Time, // a built-in timeline. A built-in timeline is its own base.
}

@(private = "file")
_times: [Time]Time_State

@(private = "file")
_frame_count: u64

@(init)
_time_init :: proc "contextless" () {
	for &s, id in _times {
		s.scale = 1
		s.base = id if time_is_builtin(id) else .Update
	}
}

time_is_builtin :: proc "contextless" (t: Time) -> bool {
	return t == .Update || t == .Fixed || t == .Unscaled
}

// Seconds the timeline has advanced since Play started.
time_now :: proc "contextless" (t := Time.Update) -> f64 {
	return _times[t].now
}

// The timeline's last step in seconds. Inside an @(update) proc,
// delta_time() is that proc's `dt`.
delta_time :: proc "contextless" (t := Time.Update) -> f32 {
	return _times[t].dt
}

// Seconds since Play started, ignoring the time scale.
unscaled_time :: proc "contextless" () -> f64 {
	return _times[Time.Unscaled].now
}

// This frame's real step in seconds, ignoring the time scale.
unscaled_delta_time :: proc "contextless" () -> f32 {
	return _times[Time.Unscaled].dt
}

// Seconds the fixed tick has simulated since Play started. The step of one
// tick is fixed_dt().
fixed_time :: proc "contextless" () -> f64 {
	return _times[Time.Fixed].now
}

// Frames since Play started.
frame_count :: proc "contextless" () -> u64 {
	return _frame_count
}

// The game's time scale, or the own scale of an added timeline.
time_scale :: proc "contextless" (t := Time.Update) -> f32 {
	return _times[t].scale
}

// Sets the game's time scale, or the own scale of an added timeline. 1 is
// real speed, 0 holds everything that follows it.
set_time_scale :: proc(scale: f32, t := Time.Update) {
	assert(scale >= 0, "engine.set_time_scale: time does not run backwards")
	assert(t != .Fixed && t != .Unscaled, "engine.set_time_scale: Fixed follows the game's scale and Unscaled has none, add a timeline based on them")
	_times[t].scale = scale
}

time_paused :: proc "contextless" (t := Time.Update) -> bool {
	return _times[t].paused
}

// Holds the game, or an added timeline, and keeps its scale for later.
set_time_paused :: proc(paused: bool, t := Time.Update) {
	assert(t != .Fixed && t != .Unscaled, "engine.set_time_paused: Fixed follows the game and Unscaled cannot pause, add a timeline based on them")
	_times[t].paused = paused
}

time_base :: proc "contextless" (t: Time) -> Time {
	return _times[t].base
}

// Sets the built-in timeline an added timeline follows.
set_time_base :: proc(t: Time, base: Time) {
	assert(!time_is_builtin(t), "engine.set_time_base: a built-in timeline has no base")
	assert(time_is_builtin(base), "engine.set_time_base: the base is Update, Fixed or Unscaled")
	_times[t].base = base
}

// True when the timeline advances on the fixed tick, false when it advances
// every frame.
time_is_fixed :: proc "contextless" (t: Time) -> bool {
	return _times[t].base == .Fixed
}

// A frame's real delta time as the game sees it: times the time scale, 0
// while the game is held. frame_tick gives this to the fixed accumulator and
// to the frame's procs.
time_scale_frame :: proc "contextless" (real_dt: f32) -> f32 {
	s := &_times[Time.Update]
	return 0 if s.paused else real_dt * s.scale
}

// One fixed tick: `Fixed` and the timelines based on it.
time_advance_fixed :: proc "contextless" (fixed_dt: f32) {
	_time_step(.Fixed, fixed_dt)
	_times_follow(.Fixed)
}

// One frame: `Update` by the scaled step, `Unscaled` by the real one, and
// the timelines based on them.
time_advance_frame :: proc "contextless" (scaled_dt, real_dt: f32) {
	_frame_count += 1
	_time_step(.Update, scaled_dt)
	_time_step(.Unscaled, real_dt)
	_times_follow(.Update)
	_times_follow(.Unscaled)
}

// Every timeline back to 0, scale 1, not paused. Bases stay.
time_reset :: proc "contextless" () {
	_frame_count = 0
	for &s in _times {
		s.now = 0
		s.dt = 0
		s.scale = 1
		s.paused = false
	}
}

@(private = "file")
_time_step :: proc "contextless" (id: Time, dt: f32) {
	s := &_times[id]
	s.dt = dt
	s.now += f64(dt)
}

@(private = "file")
_times_follow :: proc "contextless" (base: Time) {
	base_dt := _times[base].dt
	for &s, id in _times {
		if time_is_builtin(id) || s.base != base do continue
		_time_step(id, 0 if s.paused else base_dt * s.scale)
	}
}

// Play ended: the next run starts every timeline from 0 at scale 1.
@(phase={key=ExitingPlayMode})
time_exiting_play_mode :: proc() {
	time_reset()
}
