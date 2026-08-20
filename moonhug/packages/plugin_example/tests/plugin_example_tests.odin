package plugin_example_tests

// The foreign tween variant end to end: TweenSpinnerSpeed (declared in this
// package, outside packages/tween) joins the generated union and dispatches
// through the emitted adapter to ease a Spinner's speed.

import "moonhug:engine"
import plugin_example "moonhug:packages/plugin_example"
import tween "moonhug:packages/tween"
import common "moonhug:tests/common"
import "core:testing"

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
