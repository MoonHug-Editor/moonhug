package timeline_sample

// Sample gameplay for TimelineAnimator (docs/TimelineAnimator.md).
//
// assets/timeline_animator_demo.scene has one Body with an Animation
// component, two timelines that each lean it one way, and a TimelineAnimator binding the key
// "Body" to that component. Neither timeline names a scene object: each has an
// animation track whose `key` is "Body", and the animator decides what "Body"
// means. The same timeline would drive a different character under a different
// animator.
//
// This component is the part a game writes. Press Play, then use the inspector
// buttons to switch states and watch them cross-fade. Passing no duration lets
// each state's authored `fade` decide, so retuning how a switch feels is an
// inspector edit rather than a code change.

import "core:log"
import "moonhug:engine"
import anim "moonhug:packages/animation"

@(component={menu="Demo/TimelineAnimatorDemo"})
@(typ_guid={guid = "7c7a5a92-7ea8-4409-a913-2252a0f48a21"})
TimelineAnimatorDemo :: struct {
	using base: engine.CompData `inspect:"-"`,

	// Cross-fade duration the buttons ask for. -1 means "whatever the state
	// was authored with", which is the normal call.
	fade:       f32,
	auto_start: bool, // play the first state on the first tick
	started:    bool `json:"-" inspect:"-"`,
}

reset_TimelineAnimatorDemo :: proc(d: ^TimelineAnimatorDemo) {
	d.fade = -1
	d.auto_start = true
}

// The TimelineAnimator on the same object, or nil.
@(private = "file")
_tad_animator :: proc(d: ^TimelineAnimatorDemo) -> ^anim.TimelineAnimator {
	_, a := engine.transform_get_comp(d.owner, anim.TimelineAnimator)
	return a
}

@(private = "file")
_tad_play :: proc(d: ^TimelineAnimatorDemo, name: string) {
	a := _tad_animator(d)
	if a == nil {
		log.warn("[TimelineAnimatorDemo] no TimelineAnimator on this object")
		return
	}
	id, ok := anim.animator_find(a, name)
	if !ok {
		log.warnf("[TimelineAnimatorDemo] no state named %q", name)
		return
	}
	anim.animator_play(a, id, d.fade)
}

@(inspector_button={label="Lean Left", row=0})
tad_lean_left :: proc(d: ^TimelineAnimatorDemo) {
	_tad_play(d, "LeanLeft")
}

@(inspector_button={label="Lean Right", row=0})
tad_lean_right :: proc(d: ^TimelineAnimatorDemo) {
	_tad_play(d, "LeanRight")
}

@(inspector_button={label="Stop", row=1})
tad_stop :: proc(d: ^TimelineAnimatorDemo) {
	if a := _tad_animator(d); a != nil do anim.animator_stop(a)
}

// The scene shows something without a click: the first state is CUT to, not
// faded, because there is nothing to fade from.
@(update)
timeline_animator_demo_tick :: proc(dt: f32) {
	w := engine.ctx_world()
	it := engine.pool_iterator(timeline_animator_demos(w))
	for d, _ in engine.pool_next(&it) {
		if !d.enabled || d.started do continue
		if !d.auto_start {
			d.started = true
			continue
		}
		a := _tad_animator(d)
		if a == nil do continue
		if id, ok := anim.animator_find(a, "LeanLeft"); ok {
			anim.animator_play(a, id, 0)
			d.started = true
		}
	}
}
