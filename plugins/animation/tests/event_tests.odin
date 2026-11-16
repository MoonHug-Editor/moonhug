package animation_tests

// Animation events (plugins/animation/events.odin): which events a step of
// playback crosses, how the import settings bake them into a clip, and how a
// playing Animation hands them to the components of its object.

import "core:strings"
import "core:testing"
import "moonhug:packages/engine"
import anim "moonhug:packages/animation"
import common "moonhug:tests/common"

@(private = "file")
_events :: proc(pairs: ..struct{ time: f32, name: string }) -> [dynamic]anim.Animation_Clip_Event {
	out := make([dynamic]anim.Animation_Clip_Event)
	for p in pairs do append(&out, anim.Animation_Clip_Event{time = p.time, name = strings.clone(p.name)})
	return out
}

@(private = "file")
_crossed :: proc(events: []anim.Animation_Clip_Event, from, to: f32, loop: bool, include_from := false) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	anim.animation_events_crossed(events, 1, from, to, loop, include_from, &out)
	return out[:]
}

@(private = "file")
_same :: proc(a, b: []int) -> bool {
	if len(a) != len(b) do return false
	for x, i in a do if x != b[i] do return false
	return true
}

@(test)
test_events_crossed_by_a_step :: proc(t: ^testing.T) {
	ev := _events({0, "a"}, {0.25, "b"}, {0.5, "c"})
	defer { for e in ev do delete(e.name); delete(ev) }

	testing.expect(t, _same(_crossed(ev[:], 0, 0.3, false, include_from = true), {0, 1}), "a state's first step counts its start")
	testing.expect(t, _same(_crossed(ev[:], 0, 0.3, false), {1}), "a later step does not cross where it left again")
	testing.expect(t, _same(_crossed(ev[:], 0.3, 0.3, false), {}), "no step, no event")
	testing.expect(t, _same(_crossed(ev[:], 0.3, 2, false), {2}), "a clip played once ends at its length")
	testing.expect(t, _same(_crossed(ev[:], 0.75, 2.6, true), {0, 1, 2, 0, 1, 2}), "a loop crosses each event once a cycle")
	testing.expect(t, _same(_crossed(ev[:], 0.25, 0.4, true), {}), "the moment a step leaves is not crossed again")
	testing.expect(t, _same(_crossed(ev[:], 0.6, 0.1, true), {2, 1}), "backwards, in the order played")
}

@(test)
test_event_settings_bake_with_the_trim :: proc(t: ^testing.T) {
	clip := _const_clip(.Position, {1, 0, 0, 0}, 2)
	defer anim.type_cleanup_AnimationClip(&clip)
	s := anim.Animation_Clip_Settings{trim_start = 0.5, trim_stop = 1.6}
	s.events = _events({1.5, "c"}, {0.2, "a"}, {0.8, "b"}, {1, ""})
	defer anim.type_cleanup_Animation_Clip_Settings(&s)

	anim.animation_clip_apply_settings(&clip, s)
	testing.expect_value(t, len(clip.events), 2)
	if len(clip.events) != 2 do return
	// Sorted, in the trimmed clip's time. "a" is cut, a nameless one dropped.
	testing.expect(t, clip.events[0].name == "b" && abs(clip.events[0].time - 0.3) < 0.0001, "b at 0.3")
	testing.expect(t, clip.events[1].name == "c" && abs(clip.events[1].time - 1.0) < 0.0001, "c at 1.0")
}

// What the handlers got, in order.
@(private = "file")
_Got :: struct {
	name:   string,
	weight: f32,
}
@(private = "file")
_got: [dynamic]_Got

@(private = "file")
_record :: proc(c: rawptr, ev: anim.Animation_Event) {
	append(&_got, _Got{name = strings.clone(ev.name, context.temp_allocator), weight = ev.weight})
}

@(private = "file")
_got_names :: proc() -> string {
	names := make([dynamic]string, context.temp_allocator)
	for g in _got do append(&names, g.name)
	return strings.join(names[:], " ", context.temp_allocator)
}

@(test)
test_animation_events_reach_the_object_components :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	anim.animation_clip_cache_init()
	defer anim.animation_clip_cache_shutdown()
	_got = make([dynamic]_Got, context.temp_allocator)
	// A component type that takes events, for this test.
	anim.animation_event_procs[.MeshFilter] = _record
	defer anim.animation_event_procs[.MeshFilter] = nil

	guid := _clip_guid(70)
	clip := _const_clip(.Position, {1, 0, 0, 0}, 1, .Loop)
	clip.events = _events({0, "start"}, {0.5, "mid"})
	anim.animation_clip_cache[engine.PPtr{guid = guid}] = clip

	owner := engine.transform_new("Walker")
	engine.transform_add_comp(owner, .MeshFilter)
	_, ptr := engine.transform_add_comp(owner, .Animation)
	a := cast(^anim.Animation)ptr
	a.enabled = true
	a.speed = 1
	a.started = true

	engine.application_set_playing(true)
	anim.animation_play_clip(a, engine.PPtr{guid = guid})
	anim.animation_tick(0.1)
	testing.expect_value(t, _got_names(), "start")
	anim.animation_tick(0.5)
	testing.expect_value(t, _got_names(), "start mid")
	anim.animation_tick(0.5) // past the end: the loop starts again
	testing.expect_value(t, _got_names(), "start mid start")
	testing.expect(t, _got[0].weight == 1, "a clip playing alone fires at full weight")

	// Edit mode: the clip plays on, and no event reaches game code.
	engine.application_set_playing(false)
	anim.animation_tick(1)
	testing.expect_value(t, len(_got), 3)
}

@(test)
test_animation_events_from_blend_children :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	anim.animation_clip_cache_init()
	defer anim.animation_clip_cache_shutdown()
	_got = make([dynamic]_Got, context.temp_allocator)
	anim.animation_event_procs[.MeshFilter] = _record
	defer anim.animation_event_procs[.MeshFilter] = nil

	walk, run := _clip_guid(71), _clip_guid(72)
	wc := _const_clip(.Position, {1, 0, 0, 0}, 1, .Loop)
	wc.events = _events({0, "walk_step"})
	rc := _const_clip(.Position, {2, 0, 0, 0}, 1, .Loop)
	rc.events = _events({0, "run_step"})
	anim.animation_clip_cache[engine.PPtr{guid = walk}] = wc
	anim.animation_clip_cache[engine.PPtr{guid = run}] = rc

	owner := engine.transform_new("Walker")
	engine.transform_add_comp(owner, .MeshFilter)
	_, ptr := engine.transform_add_comp(owner, .Animation)
	a := cast(^anim.Animation)ptr
	a.enabled = true
	a.speed = 1
	a.started = true
	entries := make([dynamic]anim.Animation_Entry)
	append(&entries, anim.Animation_Entry{id = 1, name = strings.clone("Locomotion"), kind = anim.Animation_Entry_Blend1D{value = 0.25}})
	append(&entries, anim.Animation_Entry{id = 2, parent = 1, pos = {0, 0}, kind = anim.Animation_Entry_Clip{clip = engine.PPtr{guid = walk}}})
	append(&entries, anim.Animation_Entry{id = 3, parent = 1, pos = {1, 0}, kind = anim.Animation_Entry_Clip{clip = engine.PPtr{guid = run}}})
	a.layers = make([dynamic]anim.Animation_Layer)
	append(&a.layers, anim.Animation_Layer{entries = entries})

	engine.application_set_playing(true)
	defer engine.application_set_playing(false)
	anim.animation_play_entry(a, 1)
	anim.animation_tick(0.1)
	testing.expect_value(t, _got_names(), "walk_step run_step")
	if len(_got) == 2 {
		testing.expectf(t, abs(_got[0].weight - 0.75) < 0.001 && abs(_got[1].weight - 0.25) < 0.001, "each child at its share of the blend, got %v and %v", _got[0].weight, _got[1].weight)
	}
}
