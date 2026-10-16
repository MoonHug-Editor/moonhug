package scene_tools

// The Reflection Probe in the scene view (plugins/engine/component_Reflection_Probe.odin):
// a small sphere at its position always, its box when selected. The box is
// world-aligned and unscaled, as the probe applies it.

import "moonhug:editor/handles"
import "moonhug:libs/gizmos"
import "moonhug:packages/engine"

PROBE_GIZMO_COLOR :: [4]f32{0.85, 0.75, 0.4, 0.7}

@(on_draw_gizmos={component=Reflection_Probe})
reflection_probe_gizmos :: proc(p: ^engine.Reflection_Probe, ctx: handles.Gizmo_Context) {
	pos := engine.transform_world_position(p.owner)
	gizmos.with_color(PROBE_GIZMO_COLOR)
	gizmos.wire_sphere(pos, 0.3)
	if .In_Selection not_in ctx.state do return
	gizmos.wire_box(pos, p.size)
}
