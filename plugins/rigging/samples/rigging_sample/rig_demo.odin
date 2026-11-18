package rigging_sample

// The scripts of the rigging demo scene: one moves an object along a
// circle or a line, one starts a looping animation state.

import "core:math"
import "moonhug:packages/engine"
import anim "moonhug:packages/animation"

// Moves its object around where it starts: start + a * cos + b * sin. Two
// axes across each other make a circle, one alone a line back and forth.
@(component={menu="Demo/RigDemoMover"})
@(typ_guid={guid = "12b3d679-457f-4193-bb35-5a2ee52f97ff"})
RigDemoMover :: struct {
	using base: engine.CompData `inspect:"-"`,
	a, b:       [3]f32,
	speed:      f32, // turns per second
	start:      [3]f32 `json:"-" inspect:"-"`,
	started:    bool `json:"-" inspect:"-"`,
	angle:      f32 `json:"-" inspect:"-"`,
}

type_reset_RigDemoMover :: proc(m: ^RigDemoMover) {
	engine.comp_zero(m)
	m.a = {0.5, 0, 0}
	m.speed = 0.5
}

// Before the late update, where the rigging components read the pose.
@(update)
rig_demo_mover_tick :: proc(dt: f32) {
	w := engine.ctx_world()
	it := engine.pool_iterator(rig_demo_movers(w))
	for m, _ in engine.pool_next(&it) {
		if !m.enabled do continue
		t := engine.pool_get(&w.transforms, engine.Handle(m.owner))
		if t == nil do continue
		if !m.started {
			m.started = true
			m.start = t.position
		}
		m.angle += dt * m.speed * math.TAU
		t.position = m.start + m.a * math.cos(m.angle) + m.b * math.sin(m.angle)
	}
}

// Starts the named state of the Animation on its object, once. The
// character's clips play once on their own, a state can loop.
@(component={menu="Demo/RigDemoPlay"})
@(typ_guid={guid = "b867ef3c-d29f-4a20-95e3-ad1d3e7877e4"})
RigDemoPlay :: struct {
	using base: engine.CompData `inspect:"-"`,
	state:      string,
	started:    bool `json:"-" inspect:"-"`,
}

type_reset_RigDemoPlay :: proc(p: ^RigDemoPlay) {
	type_cleanup_RigDemoPlay(p)
}

// The state name is the component's own string.
type_cleanup_RigDemoPlay :: proc(p: ^RigDemoPlay) {
	delete(p.state)
	engine.comp_zero(p)
}

@(update)
rig_demo_play_tick :: proc(dt: f32) {
	w := engine.ctx_world()
	it := engine.pool_iterator(rig_demo_plays(w))
	for p, _ in engine.pool_next(&it) {
		if !p.enabled || p.started do continue
		_, a := engine.transform_get_comp(p.owner, anim.Animation)
		if a == nil do continue
		p.started = true
		if id, ok := anim.animation_find(a, p.state); ok do anim.animation_play_entry(a, id, 0)
	}
}
