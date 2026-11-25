package animation

// Animation events: named moments of a clip (Animation_Clip_Settings.events)
// that playback crosses. A clip only names the moment. Code that wants it
// takes every event of the Animation on its object and checks the name:
//
//   @(comp_on_animation_event={component = Footsteps})
//   comp_on_animation_event_Footsteps :: proc(f: ^Footsteps, ev: animation.Animation_Event) {
//       if ev.name == "footstep" do ...
//   }
//
// - The Animation tick collects the events its states cross, a clip state's
//   and each child of a blend, and runs the procs after every Animation has
//   ticked, so a proc may change any of them.
// - Only while the game runs: an edit-mode preview fires nothing.

import "base:runtime"
import "core:math"
import "moonhug:packages/engine"

// An event of a playing clip, as a component's proc gets it.
Animation_Event :: struct {
	name:   string, // the clip's: valid during the call
	time:   f32, // where in the clip, in seconds
	clip:   engine.PPtr,
	// How much of the pose the clip gave when it fired, 0 to 1: the state's
	// weight, times the child's weight in a blend. A clip fading in or out,
	// or barely blended in, fires with a low one.
	weight: f32,
}

// `proc(c: ^T, ev: Animation_Event)`, called through a rawptr.
Animation_Event_Proc :: proc(c: rawptr, ev: Animation_Event)

// Runs a proc on a component when the Animation on its object crosses an
// event of a playing clip. `component = T` names a @(component) type of the
// same package, and the proc is `proc(c: ^T, ev: Animation_Event)`, named
// `comp_on_animation_event_<T>`. A type has at most one. The proc gets every
// event and checks `ev.name` itself.
//
// The package's generated animation_events_generated.odin (animation/gen)
// registers it with animation_event_proc_register.
@(reserved)
@(extension_point={attribute="comp_on_animation_event", target="proc", fields="component"})
animation_event_procs: [engine.TypeKey]Animation_Event_Proc

// Called by generated code at program init.
animation_event_proc_register :: proc(key: engine.TypeKey, fn: Animation_Event_Proc) {
	assert(animation_event_procs[key] == nil, "animation: a component type has one comp_on_animation_event proc")
	animation_event_procs[key] = fn
}

// The events of `events` (sorted by time) that playback crosses going from
// clip time `from` to `to`, in the order it crosses them, appended as indices
// to `out`.
//
// - `loop`: the times wrap every `length` seconds, and `from` and `to` are
//   unwrapped, so a step over several cycles crosses an event once in each.
//   Otherwise both are clamped to the clip.
// - The moment playback leaves is not crossed again, the one it reaches is:
//   an event at `to` fires now, at `from` it fired last time. `include_from`
//   counts `from` too, for the first step of a state that starts there.
// - `to` below `from` is playing backwards: the events between are crossed in
//   reverse order.
animation_events_crossed :: proc(events: []Animation_Clip_Event, length, from, to: f32, loop, include_from: bool, out: ^[dynamic]int) {
	if len(events) == 0 || from == to && !include_from do return
	if length <= 0 do return
	crossed :: proc(t, from, to: f32, include_from: bool) -> bool {
		if to >= from do return (t > from || include_from && t == from) && t <= to
		return (t < from || include_from && t == from) && t >= to
	}
	if !loop {
		a, b := clamp(from, 0, length), clamp(to, 0, length)
		if b >= a {
			for e, i in events do if crossed(e.time, a, b, include_from) do append(out, i)
		} else {
			#reverse for e, i in events do if crossed(e.time, a, b, include_from) do append(out, i)
		}
		return
	}
	c0 := int(math.floor(from / length))
	c1 := int(math.floor(to / length))
	if to >= from {
		for c in c0 ..= c1 {
			base := f32(c) * length
			for e, i in events do if crossed(base + e.time, from, to, include_from) do append(out, i)
		}
	} else {
		for c := c0; c >= c1; c -= 1 {
			base := f32(c) * length
			#reverse for e, i in events do if crossed(base + e.time, from, to, include_from) do append(out, i)
		}
	}
}

// An event collected during the tick, run after it.
@(private)
_Pending_Animation_Event :: struct {
	object: engine.Transform_Handle,
	event:  Animation_Event,
}

// The tick's events, on the default allocator.
@(private)
_pending_animation_events: [dynamic]_Pending_Animation_Event

// Set by the tick: whether this tick collects events at all.
@(private)
_animation_events_on: bool

// The events one clip of `a` crosses, from clip time `from` to `to` (see
// animation_events_crossed), queued for the end of the tick.
@(private)
_anim_collect_events :: proc(a: ^Animation, ref: engine.PPtr, clip: ^AnimationClip, from, to: f32, loop, first: bool, weight: f32) {
	if !_animation_events_on || len(clip.events) == 0 do return
	// The clip is sampled shifted by its cycle offset (animation_clip_sample_time),
	// so a looping clip's events are met shifted too.
	shift := loop ? clip.cycle_offset * clip.length : 0
	idx := make([dynamic]int, context.temp_allocator)
	animation_events_crossed(clip.events[:], clip.length, from + shift, to + shift, loop, first, &idx)
	if len(idx) == 0 do return
	context.allocator = runtime.default_allocator()
	for i in idx {
		e := clip.events[i]
		append(&_pending_animation_events, _Pending_Animation_Event{
			object = a.owner,
			event  = {name = e.name, time = e.time, clip = ref, weight = weight},
		})
	}
}

// Runs the queued events: each on the components of its object that take
// them, in the order they were crossed.
@(private)
_anim_dispatch_events :: proc() {
	if len(_pending_animation_events) == 0 do return
	// A copy: a proc may play a clip, which never ticks before the next
	// frame, but may also destroy objects, whose events are then dropped.
	pending := make([]_Pending_Animation_Event, len(_pending_animation_events), context.temp_allocator)
	copy(pending, _pending_animation_events[:])
	clear(&_pending_animation_events)
	w := engine.ctx_world()
	for p in pending {
		t := engine.pool_get(&w.transforms, engine.Handle(p.object))
		if t == nil do continue
		// A copy: a proc may add or remove components of its own object.
		comps := make([]engine.Owned, len(t.components), context.temp_allocator)
		copy(comps, t.components[:])
		for c in comps {
			if c.handle.type_key == engine.INVALID_TYPE_KEY do continue
			fn := animation_event_procs[c.handle.type_key]
			if fn == nil do continue
			if ptr := engine.world_pool_get(w, c.handle); ptr != nil do fn(ptr, p.event)
		}
	}
}
