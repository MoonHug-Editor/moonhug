package plugin_example_tests

// The foreign tween variant end to end: TweenSpinnerSpeed (declared in this
// package, outside packages/tween) joins the generated union and dispatches
// through the emitted adapter to ease a Spinner's speed.

import "moonhug:packages/engine"
import plugin_example "moonhug:packages/plugin_example"
import tween "moonhug:packages/tween"
import common "moonhug:tests/common"
import "core:os"
import "core:strings"
import "core:testing"
import "moonhug:libs/serialization"

@(test)
test_foreign_tween_variant_eases_spinner_speed :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	tween.tween_init()

	owner := engine.transform_new("Spinner")
	_, s_ptr := engine.transform_add_comp(owner, .Spinner)
	testing.expect(t, s_ptr != nil, "Spinner component should be addable")
	if s_ptr == nil do return
	spinner := cast(^plugin_example.Spinner)s_ptr
	spinner.enabled = true
	spinner.speed = {0, 0, 0}

	// The foreign node authors like any stock tween: a guid-tagged blob.
	u := tween.authored(plugin_example.TweenSpinnerSpeed{
		speed    = {0, 0, 180},
		duration = 0.5,
	})
	defer tween.authored_destroy(&u)
	ok := tween.tween_run(&u, tween.TweenContext{subject = owner})
	testing.expect(t, ok, "foreign node should start")

	for _ in 0 ..< 60 {
		tween.tween_tick_running(1.0 / 60.0, {})
	}
	testing.expect_value(t, spinner.speed, [3]f32{0, 0, 180})
}

// The serialization hooks on Spawn_Table: writing the file clamps a negative
// weight (@(before_serialize)), reading it back rebuilds the total weight the
// file does not store (@(after_deserialize)).
@(test)
test_spawn_table_serialization_hooks :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	path :: "moonhug/tests/fixtures/_spawn_table_tmp.asset"
	defer os.remove(path)

	table: plugin_example.Spawn_Table
	defer plugin_example.cleanup_Spawn_Table(&table)
	plugin_example.spawn_table_add(&table, "Slime", 3)
	plugin_example.spawn_table_add(&table, "Bat", -2)
	plugin_example.spawn_table_add(&table, "Dragon", 1)
	testing.expect(t, serialization.write_asset_to_path(path, engine.get_guid_by_typeid(plugin_example.Spawn_Table), table), "the table writes")
	testing.expect_value(t, table.entries[1].weight, f32(0)) // clamped before the write

	data, err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, err == nil, "the file reads")
	testing.expect(t, !strings.contains(string(data), "total_weight"), "the total weight is not saved")

	loaded, ok := serialization.load_from_file(path)
	testing.expect(t, ok, "the table loads")
	if !ok do return
	back := cast(^plugin_example.Spawn_Table)loaded.data
	defer {
		plugin_example.cleanup_Spawn_Table(back)
		free(back)
	}
	testing.expect_value(t, len(back.entries), 3)
	testing.expect_value(t, back.total_weight, f32(4)) // rebuilt on load
	testing.expect_value(t, plugin_example.spawn_table_pick(back, 0.5), "Slime")
	testing.expect_value(t, plugin_example.spawn_table_pick(back, 0.9), "Dragon")
}
