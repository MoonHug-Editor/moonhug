package scene_tools

// The Reflection Probe in the scene view (plugins/engine/component_Reflection_Probe.odin):
// a small sphere at its position always, its box when selected, and inside
// it, fainter, the box where the blend distance's fade starts. The boxes are
// world-aligned and unscaled, as the probe applies them.

import "core:math/linalg"
import "moonhug:editor/handles"
import "moonhug:libs/gizmos"
import "moonhug:packages/engine"

PROBE_GIZMO_COLOR :: [4]f32{0.85, 0.75, 0.4, 0.7}

@(comp_on_draw_gizmos={component=Reflection_Probe})
reflection_probe_gizmos :: proc(p: ^engine.Reflection_Probe, ctx: handles.Gizmo_Context) {
	pos := engine.transform_world_position(p.owner)
	gizmos.with_color(PROBE_GIZMO_COLOR)
	gizmos.wire_sphere(pos, 0.3)
	if .In_Selection not_in ctx.state do return
	gizmos.wire_box(pos, p.size)
	inner := linalg.abs(p.size) - 2 * p.blend_distance
	if p.blend_distance > 0 && inner.x > 0 && inner.y > 0 && inner.z > 0 {
		gizmos.with_color({PROBE_GIZMO_COLOR.r, PROBE_GIZMO_COLOR.g, PROBE_GIZMO_COLOR.b, 0.25})
		gizmos.wire_box(pos, inner)
	}
}
