package engine

// Unity's LEGACY Animation component: plays one AnimationClip on this
// transform's hierarchy — no state machine, no blending (that's Mecanim's
// Animator, not this). Scripts drive it with animation_play/animation_stop;
// play_automatically starts the clip on the first tick (Unity default).
//
// The editor never simulates: clips advance only in the app, per-frame
// (animation_tick, hooked as @(update) in app.odin — Unity animates in
// Update, not FixedUpdate).

// Unity's component-level WrapMode: Default defers to the clip's own wrap.
Animation_Wrap_Mode :: enum u8 {
	Default,
	Once,
	Loop,
}

@(component)
@(typ_guid={guid = "5b8c2f4e-1d3a-4e6b-8f90-7a2c4d6e8b13"})
Animation :: struct {
	using base:         CompData `inspect:"-"`,
	clip:               Asset_GUID `ext:"anim"`,
	play_automatically: bool,
	wrap_mode:          Animation_Wrap_Mode,
	speed:              f32,

	time:    f32 `json:"-" inspect:"-"`,
	playing: bool `json:"-" inspect:"-"`,
	started: bool `json:"-" inspect:"-"`, // play_automatically consumed on first tick
}

reset_Animation :: proc(comp: ^Animation) {
	comp.play_automatically = true
	comp.speed = 1
}

// Restart the clip from t=0 (Unity Animation.Play rewinds a stopped clip).
animation_play :: proc(a: ^Animation) {
	a.time = 0
	a.playing = true
	a.started = true
}

// Stop and rewind (Unity Animation.Stop).
animation_stop :: proc(a: ^Animation) {
	a.time = 0
	a.playing = false
	a.started = true
}

// Per-frame clip advance + sample for every enabled Animation component.
animation_tick :: proc(dt: f32) {
	w := ctx_world()
	for i in 0 ..< len(w.animations.slots) {
		slot := &w.animations.slots[i]
		if !slot.alive do continue
		a := &slot.data
		if !a.enabled do continue
		if !pool_valid(&w.transforms, Handle(a.owner)) do continue
		if !a.started {
			a.started = true
			a.playing = a.play_automatically
		}
		if !a.playing || a.clip == {} do continue
		clip, ok := animation_clip_load(a.clip)
		if !ok do continue

		a.time += dt * a.speed
		wrap := clip.wrap
		#partial switch a.wrap_mode {
		case .Once: wrap = .Once
		case .Loop: wrap = .Loop
		}
		t, done := animation_wrap_time(a.time, clip.length, wrap)
		animation_clip_apply(clip, a.owner, t)
		if done do a.playing = false
	}
}
