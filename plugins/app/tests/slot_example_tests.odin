package app_tests

// SlotExample places and sizes its object from two slots: its inline values
// while they are not connected, the entries the game fills in the game-wide
// dictionary once they are. Lookup up the tree through Blackboards is the
// blackboard plugin's tests' part.

import app "moonhug:packages/app"
import "moonhug:libs/slots"
import "moonhug:packages/engine"
import common "moonhug:tests/common"
import "core:testing"

@(test)
test_slot_example_reads_inline_and_game_entries :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	tH := engine.transform_new("Cube")
	tr := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(tH))
	tr.position = {1, 0, 0}
	_, raw := engine.transform_add_comp(tH, .SlotExample)
	ex := cast(^app.SlotExample)raw
	testing.expect(t, ex != nil, "SlotExample can be added")
	if ex == nil do return
	app.comp_awake_SlotExample(ex)

	// Not connected: the inline values.
	ex._offset = {0, 0.5, 0}
	ex._size = 0.7
	app.comp_update_SlotExample(0, ex)
	testing.expect_value(t, tr.position, [3]f32{1, 0.5, 0})
	testing.expect_value(t, tr.scale, [3]f32{0.7, 0.7, 0.7})

	// Connected: the game's entries, declared and filled by the app package.
	for name in ([?]string{"demo_bob", "demo_pulse", "demo_double"}) {
		testing.expectf(t, slots.has(slots.entry(name), slots.global()), "the game fills %s", name)
	}
	ex.size = slots.entry("demo_double")
	app.comp_update_SlotExample(0, ex)
	testing.expect_value(t, tr.scale, [3]f32{2, 2, 2})
	ex.size = slots.entry("demo_pulse")
	app.comp_update_SlotExample(0, ex)
	testing.expectf(t, tr.scale.x >= 0.5 && tr.scale.x <= 1.5, "demo_pulse is between 0.5 and 1.5, got %v", tr.scale.x)
}
