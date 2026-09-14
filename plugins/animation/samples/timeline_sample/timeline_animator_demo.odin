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
	fade: f32,

	// Start on Idle at the first tick, so the scene is alive when it opens.
	auto_start: bool,
	started:    bool `json:"-" inspect:"-"`,
	// True while the hand-back to Idle is in flight, so it starts one fade
	// instead of restarting it every frame.
	returning:  bool `json:"-" inspect:"-"`,
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

@(inspector_button={label="Idle", row=0})
tad_idle :: proc(d: ^TimelineAnimatorDemo) {
	_tad_play(d, "Idle")
}

@(inspector_button={label="Swing", row=0})
tad_swing :: proc(d: ^TimelineAnimatorDemo) {
	d.returning = false
	_tad_play(d, "Swing")
}

@(inspector_button={label="Stop", row=-1})
tad_stop :: proc(d: ^TimelineAnimatorDemo) {
	if a := _tad_animator(d); a != nil do anim.animator_stop(a)
}

// Idle loops and keeps running until a button says otherwise. Swing plays ONCE,
// reports done, and hands back to Idle.
//
// The state machine has no transitions. What follows what is ordinary gameplay
// code polling `animator_state`, which is the whole point of the design.
@(update)
timeline_animator_demo_tick :: proc(dt: f32) {
	w := engine.ctx_world()
	it := engine.pool_iterator(timeline_animator_demos(w))
	for d, _ in engine.pool_next(&it) {
		if !d.enabled do continue
		a := _tad_animator(d)
		if a == nil do continue

		idle, has_idle := anim.animator_find(a, "Idle")
		if !has_idle do continue

		if !d.started && d.auto_start {
			anim.animator_play(a, idle, 0) // a cut: nothing to fade from
			d.started = true
			continue
		}

		cur, _, done := anim.animator_state(a)
		if cur == idle {
			d.returning = false
			continue
		}
		// A Once state that has finished hands back to Idle.
		if done && !d.returning {
			d.returning = true
			anim.animator_play(a, idle)
		}
	}
}
