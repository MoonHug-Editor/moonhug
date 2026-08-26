package sequencer

// PlayableDirector: plays a Timeline on scene objects — Unity's component of
// the same name. The ASSET owns structure; the director owns the instance
// surface: per-track bindings and playback state. The timeline reference is
// a PPtr so a timeline can later live embedded in another asset as a
// sub-asset (local_id 0 = a standalone .timeline file).
//
// Serialized fields are ZERO-NEUTRAL: manual_start is the inverse of Unity's
// play-on-awake, speed 0 runs at 1.

import "moonhug:engine"

// One track's scene target. A track kind declares what it binds through its
// Track_Desc.binding_type ("" = none — the animation track resolves channel
// paths under the director's owner instead).
Track_Binding :: struct {
	track:  i32, // index into the timeline's tracks
	target: engine.Ref_Local,
}

Timeline_Wrap :: enum u8 {
	Once,
	Loop,
}

@(component)
@(typ_guid={guid = "b7aaabb5-aaee-4aa9-af14-fdc8e2254d6c"})
PlayableDirector :: struct {
	using base: engine.CompData `inspect:"-"`,

	timeline:     engine.PPtr `inspect:"-"`,
	wrap:         Timeline_Wrap,
	speed:        f32,  // playback speed, 0 runs at 1
	manual_start: bool, // true = wait for director_play (inverse play-on-awake)
	bindings:     [dynamic]Track_Binding,

	// Live state — never serialized, never inspected. `track_states` holds
	// one registry-owned opaque state per track (built by Track_Desc.build,
	// freed by Track_Desc.destroy).
	time:         f32 `json:"-" inspect:"-"`,
	prev_time:    f32 `json:"-" inspect:"-"`,
	playing:      bool `json:"-" inspect:"-"`,
	started:      bool `json:"-" inspect:"-"`,
	built:        bool `json:"-" inspect:"-"`,
	track_states: [dynamic]rawptr `json:"-" inspect:"-"`,
}

reset_PlayableDirector :: proc(d: ^PlayableDirector) {
	d.speed = 1
	d.wrap = .Loop
}

cleanup_PlayableDirector :: proc(d: ^PlayableDirector) {
	delete(d.bindings)
	director_teardown(d)
}
