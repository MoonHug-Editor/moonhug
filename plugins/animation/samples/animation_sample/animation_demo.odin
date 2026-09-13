package animation_sample

// Sample gameplay for the Animation component (docs/AnimationComponent.md).
//
// assets/animation_demo.scene is the imported character: a skinned mesh posed by
// SkinnedMeshRenderer, its armature, and an Animation component whose layer holds
// the states this script plays — Idle, Jump and Death as single clips, and
// Locomotion as a Blend1D over walk and run.
//
// States are played BY NAME, so the scene decides what each button means and a
// clip can be repointed in the inspector without touching this file.

import "core:log"
import "moonhug:engine"
import anim "moonhug:packages/animation"

@(component={menu="Demo/AnimationDemo"})
@(typ_guid={guid = "b1d4c0ae-3f57-4a62-9d18-6c0e5a79f284"})
AnimationDemo :: struct {
	using base: engine.CompData `inspect:"-"`,

	// Cross-fade duration the buttons ask for, in seconds. 0 cuts.
	fade: f32,

	// Walk at 0, run at 1, pushed into the Locomotion blend — the value a
	// character controller would feed from its own speed.
	blend: f32 `decor:range(0, 1)`,

	// Start on the blend rather than on the component's own `clip`, so the
	// scene opens showing the thing it exists to show.
	auto_start: bool,
	started:    bool `json:"-" inspect:"-"`,
	pushed:     f32 `json:"-" inspect:"-"`, // last value written to the blend
}

reset_AnimationDemo :: proc(d: ^AnimationDemo) {
	d.fade = 0.25
	d.auto_start = true
}

// The Animation component this script drives. Both sit on the same object, the
// way a game puts its controller next to what it controls.
@(private = "file")
_ad_animation :: proc(d: ^AnimationDemo) -> ^anim.Animation {
	_, a := engine.transform_get_comp(d.owner, anim.Animation)
	return a
}

@(private = "file")
_ad_play :: proc(d: ^AnimationDemo, name: string) {
	a := _ad_animation(d)
	if a == nil {
		log.warn("[AnimationDemo] no Animation component on this object")
		return
	}
	id, ok := anim.animation_find(a, name)
	if !ok {
		log.warnf("[AnimationDemo] no state named %q", name)
		return
	}
	anim.animation_play_entry(a, id, d.fade)
}

@(inspector_button={label="Idle", row=0})
ad_idle :: proc(d: ^AnimationDemo) {
	_ad_play(d, "Idle")
}

@(inspector_button={label="Locomotion", row=0})
ad_locomotion :: proc(d: ^AnimationDemo) {
	_ad_play(d, "Locomotion")
}

@(inspector_button={label="Jump", row=-1})
ad_jump :: proc(d: ^AnimationDemo) {
	_ad_play(d, "Jump")
}

@(inspector_button={label="Death", row=-1})
ad_death :: proc(d: ^AnimationDemo) {
	_ad_play(d, "Death")
}

@(inspector_button={label="Stop", row=-2})
ad_stop :: proc(d: ^AnimationDemo) {
	if a := _ad_animation(d); a != nil do anim.animation_stop(a)
}

// Feed the blend. Writing it every frame rather than on change is deliberate:
// it is the shape real gameplay has, where the value comes from a speed that
// changes continuously.
@(update)
animation_demo_tick :: proc(dt: f32) {
	w := engine.ctx_world()
	it := engine.pool_iterator(animation_demos(w))
	for d, _ in engine.pool_next(&it) {
		if !d.enabled do continue
		a := _ad_animation(d)
		if a == nil do continue
		id, ok := anim.animation_find(a, "Locomotion")
		if !ok do continue
		// Only on change. A real controller writes its speed every frame, but
		// the blend's value is one field shared with the inspector, so a demo
		// that wrote unconditionally would drag the States tree slider back to
		// this one every frame and look broken.
		if d.blend != d.pushed {
			d.pushed = d.blend
			anim.animation_blend_set(a, id, d.blend)
		}
		if !d.started && d.auto_start {
			d.started = true
			anim.animation_play_entry(a, id, 0) // a cut: nothing to fade from
		}
	}
}
