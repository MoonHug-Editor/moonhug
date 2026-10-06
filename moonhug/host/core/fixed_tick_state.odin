package core

// True between fixed_tick_begin and fixed_tick_advance (plugins/engine/fixed_tick.odin
// sets it). Gizmos recorded during a fixed tick live until the next tick
// instead of the next frame, so the gizmos package reads this.
in_fixed_tick: bool

fixed_in_tick :: proc() -> bool {
	return in_fixed_tick
}
