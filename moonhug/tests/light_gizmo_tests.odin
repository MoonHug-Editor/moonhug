package tests

// Light handles (plugins/engine/editor/scene_tools/light_gizmos.odin) through the real hook: a spot
// light's cone handle changes range and spot angle in any tool, one undo step
// per drag.

import "core:math"
import "core:math/linalg"
import "core:testing"
import "moonhug:packages/engine"
import "moonhug:editor/handles"
import "moonhug:editor/undo"
import "moonhug:packages/engine/editor/scene_tools"

@(private = "file")
_light_body :: proc(user: rawptr) {
	scene_tools.light_handles(cast(^engine.Light)user, handles.Gizmo_Context{state = {.Selected, .Active, .In_Selection}, tool = .Translate})
}

// Turned so its forward (-Z) points along +X: range 2 puts the tip at
// (2, 0, 0), 60 degrees puts the +Y rim dot at (1.732, 1, 0).
@(private = "file")
_spot :: proc() -> ^engine.Light {
	tH := engine.transform_new("Spot")
	engine.transform_set_world_rotation(tH, engine.quat_from_native(linalg.quaternion_angle_axis_f32(-math.PI / 2, {0, 1, 0})))
	_, raw := engine.transform_add_comp(tH, .Light)
	l := cast(^engine.Light)raw
	l.enabled = true
	l.type = .Spot
	l.range = 2
	l.spot_angle = 60
	l.inner_spot_angle = 20
	return l
}

@(test)
test_spot_light_handles :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	s := setup_undo(tc)
	context.user_ptr = &tc.uc
	defer teardown_undo(tc, s)
	v := handles_test_view()

	l := _spot()
	steps := s.top
	handles_drag(v, {2, 0, 0}, {3, 0, 0}, _light_body, l)
	testing.expectf(t, abs(l.range - 3) < 1e-3 && l.spot_angle == 60, "the tip changes the range: %v %v", l.range, l.spot_angle)
	testing.expect_value(t, s.top, steps + 1)
	undo.apply_undo(s)
	testing.expect_value(t, l.range, f32(2))

	handles_drag(v, {1.732, 1, 0}, {1.732, 1.732, 0}, _light_body, l)
	testing.expectf(t, abs(l.spot_angle - 90) < 0.1 && l.range == 2, "the rim changes the spot angle: %v %v", l.spot_angle, l.range)
}
