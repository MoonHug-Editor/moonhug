package mh_time

// The game's time: delta time, the time scale, and the clocks timed systems
// run on.
//
// - Import it as `import "moonhug:libs/time"` and call it as `time.`: an
//   import is named after its folder.
// - The package itself is `mh_time`, because a build allows one package named
//   `time` and Odin's own library has it.
// - A file that also needs Odin's time package names one of the two:
//   `import core_time "core:time"`.
//
//   dt := time.delta_time()             // this frame's step, scaled
//   time.set_time_scale(0.25)           // slow motion
//   time.set_time_scale(0)              // hold the game
//   real := time.delta_time(.Unscaled)  // for menus: ignores the scale
//   time.now(.Fixed)                    // seconds the fixed tick has simulated
//
// - The time scale is one number for the whole game. It scales the delta
//   time that per-frame update procs get, and how fast fixed ticks come: at
//   0.5 a fixed tick runs half as often, still with the full fixed step. At 0
//   no fixed tick runs and the frame's delta time is 0.
// - `Clock` names a timeline. The built-in ones:
//   - `Update` advances every frame by the scaled delta time. It is the
//     default wherever a clock is optional.
//   - `Fixed` advances every fixed tick by the fixed step.
//   - `Unscaled` advances every frame by the real delta time.
// - A package adds clocks with a `Clock_Extra` enum of its own. The generated
//   `Clock` enum (clocks_generated.odin) lists them after the built-in ones.
// - An added clock follows a built-in one, its base (`Update` unless
//   set_base says otherwise), and has a scale and a pause of its own on top:
//   its step is the base's step times its scale. One on `Update` slows down
//   with the game, one on `Unscaled` does not.
// - This package only keeps the numbers. Whoever runs the frame advances it:
//   the engine's frame_tick calls scale_frame, advance_fixed and
//   advance_frame, before the procs of each stage run.

Clock_State :: struct {
	now:    f64,   // seconds this clock has advanced
	dt:     f32,   // the last step, in seconds
	scale:  f32,
	paused: bool,
	base:   Clock, // a built-in clock. A built-in clock is its own base.
}

@(private = "file")
_clocks: [Clock]Clock_State

@(private = "file")
_frame_count: u64

@(init)
_init :: proc "contextless" () {
	for &s, id in _clocks {
		s.scale = 1
		s.base = id if is_builtin(id) else .Update
	}
}

// --- Reading time --------------------------------------------------------------------

// The clock's last step in seconds. Inside a per-frame update proc,
// delta_time() is that proc's `dt`. delta_time(.Unscaled) is the frame's real
// step, delta_time(.Fixed) the step of one fixed tick (0 before the first
// tick of a run).
delta_time :: proc "contextless" (clock := Clock.Update) -> f32 {
	return _clocks[clock].dt
}

// Seconds the clock has advanced since Play started.
now :: proc "contextless" (clock := Clock.Update) -> f64 {
	return _clocks[clock].now
}

// Frames since Play started.
frame_count :: proc "contextless" () -> u64 {
	return _frame_count
}

// --- Scale and pause -------------------------------------------------------------------

// The game's time scale, or the own scale of an added clock.
time_scale :: proc "contextless" (clock := Clock.Update) -> f32 {
	return _clocks[clock].scale
}

// Sets the game's time scale, or the own scale of an added clock. 1 is real
// speed, 0 holds everything that follows it.
set_time_scale :: proc(scale: f32, clock := Clock.Update) {
	assert(scale >= 0, "time.set_time_scale: time does not run backwards")
	assert(clock != .Fixed && clock != .Unscaled, "time.set_time_scale: Fixed follows the game's scale and Unscaled has none, add a clock based on them")
	_clocks[clock].scale = scale
}

paused :: proc "contextless" (clock := Clock.Update) -> bool {
	return _clocks[clock].paused
}

// Holds the game, or an added clock, and keeps its scale for later.
set_paused :: proc(paused: bool, clock := Clock.Update) {
	assert(clock != .Fixed && clock != .Unscaled, "time.set_paused: Fixed follows the game and Unscaled cannot pause, add a clock based on them")
	_clocks[clock].paused = paused
}

// --- Clocks ----------------------------------------------------------------------------

is_builtin :: proc "contextless" (clock: Clock) -> bool {
	return clock == .Update || clock == .Fixed || clock == .Unscaled
}

// The built-in clock a clock follows.
base :: proc "contextless" (clock: Clock) -> Clock {
	return _clocks[clock].base
}

// Sets the built-in clock an added clock follows.
set_base :: proc(clock: Clock, base: Clock) {
	assert(!is_builtin(clock), "time.set_base: a built-in clock has no base")
	assert(is_builtin(base), "time.set_base: the base is Update, Fixed or Unscaled")
	_clocks[clock].base = base
}

// True when the clock advances on the fixed tick, false when it advances
// every frame.
is_fixed :: proc "contextless" (clock: Clock) -> bool {
	return _clocks[clock].base == .Fixed
}

// --- For whoever runs the frame --------------------------------------------------------

// A frame's real delta time as the game sees it: times the time scale, 0
// while the game is held. It feeds the fixed accumulator and the frame's
// procs.
scale_frame :: proc "contextless" (real_dt: f32) -> f32 {
	s := &_clocks[Clock.Update]
	return 0 if s.paused else real_dt * s.scale
}

// One fixed tick: `Fixed` and the clocks based on it.
advance_fixed :: proc "contextless" (fixed_dt: f32) {
	_step(.Fixed, fixed_dt)
	_follow(.Fixed)
}

// One frame: `Update` by the scaled step, `Unscaled` by the real one, and
// the clocks based on them.
advance_frame :: proc "contextless" (scaled_dt, real_dt: f32) {
	_frame_count += 1
	_step(.Update, scaled_dt)
	_step(.Unscaled, real_dt)
	_follow(.Update)
	_follow(.Unscaled)
}

// Every clock back to 0, scale 1, not paused. Bases stay.
reset :: proc "contextless" () {
	_frame_count = 0
	for &s in _clocks {
		s.now = 0
		s.dt = 0
		s.scale = 1
		s.paused = false
	}
}

@(private = "file")
_step :: proc "contextless" (id: Clock, dt: f32) {
	s := &_clocks[id]
	s.dt = dt
	s.now += f64(dt)
}

@(private = "file")
_follow :: proc "contextless" (base: Clock) {
	base_dt := _clocks[base].dt
	for &s, id in _clocks {
		if is_builtin(id) || s.base != base do continue
		_step(id, 0 if s.paused else base_dt * s.scale)
	}
}
