package particles_tests

// Particle shape handles (particles_editor.particle_shape_handles) through the
// real hook: in the Handles tool (T) the cone's far rim opens the angle, in
// other tools nothing edits the shape.

import "core:math"
import "core:testing"
import "moonhug:editor/handles"
import particles "moonhug:packages/particles"
import particles_editor "moonhug:packages/particles/editor"
import common "moonhug:tests/common"

@(private = "file")
_Case :: struct {
	ps:   ^particles.ParticleSystem,
	tool: handles.Tool,
}

@(private = "file")
_body :: proc(user: rawptr) {
	c := cast(^_Case)user
	particles_editor.particle_shape_handles(c.ps, handles.Gizmo_Context{state = {.Selected}, tool = c.tool})
}

// Emission along +Z toward the camera: base radius 0.5 and 0.3 radians put the
// far +X dot at (0.809, 0, 1).
@(test)
test_particle_cone_angle_handle :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc, "")
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	ps := _make_system(tc)
	ps.shape = .Cone
	ps.shape_radius = 0.5
	ps.shape_angle = math.to_degrees(f32(0.3))
	v := common.handles_test_view()
	far := 0.5 + math.tan(f32(0.3))

	c := _Case{ps = ps, tool = .Translate}
	common.handles_drag(v, {far, 0, 1}, {1, 0, 1}, _body, &c)
	testing.expectf(t, abs(ps.shape_angle - math.to_degrees(f32(0.3))) < 1e-4, "not outside the Handles tool, got %v", ps.shape_angle)

	c.tool = .Handles
	common.handles_drag(v, {far, 0, 1}, {1, 0, 1}, _body, &c)
	testing.expectf(t, abs(ps.shape_angle - math.to_degrees(math.atan(f32(0.5)))) < 0.05 && ps.shape_radius == 0.5, "got %v %v", ps.shape_angle, ps.shape_radius)
}
