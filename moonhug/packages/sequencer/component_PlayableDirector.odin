package sequencer

// PlayableDirector: plays the timeline in its OWN SUBTREE — track nodes as
// children, clip nodes under them (component_TimelineTrack.odin). A timeline
// asset is a prefab whose root carries this component; instancing, variants
// and per-instance binding all ride the prefab system.
//
// Serialized fields are ZERO-NEUTRAL: manual_start is the inverse of Unity's
// play-on-awake, speed 0 runs at 1, duration 0 is computed from the last
// clip end.

import "moonhug:engine"

Timeline_Wrap :: enum u8 {
	Once,
	Loop,
}

@(component)
@(typ_guid={guid = "b7aaabb5-aaee-4aa9-af14-fdc8e2254d6c"})
PlayableDirector :: struct {
	using base: engine.CompData `inspect:"-"`,

	wrap:         Timeline_Wrap,
	speed:        f32,  // playback speed, 0 runs at 1
	manual_start: bool, // true = wait for director_play (inverse play-on-awake)
	duration:     f32,  // authored length; 0 = computed from the last clip end

	// Live state — never serialized, never inspected. `track_states` holds
	// one registry-owned opaque state per track (built by Track_Desc.build,
	// freed by Track_Desc.destroy); `track_state_kinds` remembers which kind
	// owns each slot so teardown can find the destroy hook after edits.
	time:              f32 `json:"-" inspect:"-"`,
	// Increments every time a play SESSION starts (director_play, the
	// auto-start, a control span entering in Play) — how tracks detect "this
	// is a new performance" and refresh per-play state (tween captures).
	play_id:           u32 `json:"-" inspect:"-"`,
	prev_time:         f32 `json:"-" inspect:"-"`,
	playing:           bool `json:"-" inspect:"-"`,
	started:           bool `json:"-" inspect:"-"`,
	built:             bool `json:"-" inspect:"-"`,
	tree_sig:          u64 `json:"-" inspect:"-"`,
	track_states:      [dynamic]rawptr `json:"-" inspect:"-"`,
	track_state_kinds: [dynamic]engine.TypeKey `json:"-" inspect:"-"`,
}

reset_PlayableDirector :: proc(d: ^PlayableDirector) {
	d.speed = 1
	d.wrap = .Loop
}

cleanup_PlayableDirector :: proc(d: ^PlayableDirector) {
	director_teardown(d)
}
