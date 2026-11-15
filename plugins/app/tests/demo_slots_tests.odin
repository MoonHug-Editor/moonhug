package app_tests

// The slots demo scene (assets/demo_slots/demo_slots.scene) is generated
// JSON. This is its guard: the scene loads, every cube carries SlotExample
// with its own connections, and each reads the value the demo is there to
// show: its inline value, the game-wide dictionary's, or its Blackboard's.
// The Blackboards are the blackboard plugin's, reached through the slots
// library's scope, so nothing here imports it.

import app "moonhug:packages/app"
import "moonhug:libs/slots"
import "moonhug:packages/engine"
import common "moonhug:tests/common"
import "core:testing"

@(private = "file")
_named :: proc(name: string) -> engine.Transform_Handle {
	it := engine.pool_iterator(&engine.ctx_world().transforms)
	for tr, h in engine.pool_next(&it) do if tr.name == name do return engine.Transform_Handle(h)
	return {}
}

@(test)
test_slots_demo_scene_loads :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	s := engine.scene_load("plugins/app/assets/demo_slots/demo_slots.scene")
	testing.expect(t, s != nil, "the demo scene parses and loads")
	if s == nil do return
	tc.scene = s

	// What each cube's size and offset slots resolve to.
	Case :: struct {
		name:   string,
		size:   f32,
		offset: [3]f32,
	}
	cases := [?]Case{
		{"Inline", 0.7, {0, 0.5, 0}},        // typed on the component
		{"A Member 1", 1.5, {0, 1, 0}},      // Squad A's Blackboard
		{"A Member 2", 1.5, {0, 1, 0}},
		{"B Member 1", 0.6, {0, 2.5, 0}},    // the same connections, Squad B's values
		{"B Member 2", 2.0, {0, 2.5, 0}},    // the Leader's `big` is nearer, `lift` is the squad's
	}
	for c in cases {
		tH := _named(c.name)
		_, ex := app.get_comp(tH, app.SlotExample)
		testing.expectf(t, ex != nil, "%s carries SlotExample", c.name)
		if ex == nil do continue
		testing.expectf(t, slots.get(ex.size, ex._size, slots.scope_of(tH)) == c.size, "%s: size %v, want %v", c.name, slots.get(ex.size, ex._size, slots.scope_of(tH)), c.size)
		testing.expectf(t, slots.get(ex.offset, ex._offset, slots.scope_of(tH)) == c.offset, "%s: offset %v, want %v", c.name, slots.get(ex.offset, ex._offset, slots.scope_of(tH)), c.offset)
	}

	// Connected to entries the game computes: there, and not the inline value.
	game := _named("From Game")
	_, ex := app.get_comp(game, app.SlotExample)
	testing.expect(t, ex != nil, "From Game carries SlotExample")
	if ex == nil do return
	testing.expect_value(t, ex.size, slots.entry("demo_pulse"))
	testing.expect_value(t, ex.offset, slots.entry("demo_bob"))
	testing.expect(t, slots.has(ex.size, slots.scope_of(game)) && slots.has(ex.offset, slots.scope_of(game)), "the game-wide dictionary has both entries")
}
