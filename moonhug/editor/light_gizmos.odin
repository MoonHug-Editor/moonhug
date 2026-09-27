package editor

// Light gizmos and handles, for lights in the selection (docs/Handles.md):
//
// - Point: the range as a wire sphere, with a radius handle on the world
//   axes.
// - Spot: the cone out to the range (edges `range` long, the rim circle, two
//   cap arcs through the tip), with a cone handle: the tip changes the range,
//   the rim dots the spot angle.
// - Directional: a ring of rays along the light's direction. No handles: the
//   transform's rotation aims it.
//
// The handles show in every tool. The shapes follow the renderer
// (engine.light_to_gfx): the transform's scale does not change the range, the
// cone opens along the transform's forward (-Z), and its angle is
// max(spot_angle, inner_spot_angle).

import "core:math"
import "core:math/linalg"
import "../engine"
import "moonhug:engine/gizmos"
import "moonhug:editor/handles"
import "undo"

LIGHT_GIZMO_COLOR :: [4]f32{254.0 / 255, 253.0 / 255, 136.0 / 255, 0.5}
LIGHT_HANDLE_COLOR :: [4]f32{254.0 / 255, 253.0 / 255, 136.0 / 255, 1}

@(private = "file")
_FORWARD :: [3]f32{0, 0, -1}

@(private = "file")
_light_edit: undo.Edit_Session

// The full cone angle the renderer uses, in degrees.
@(private = "file")
_spot_outer :: proc(l: ^engine.Light) -> f32 {
	return max(l.spot_angle, l.inner_spot_angle)
}

@(on_draw_gizmos={component=Light})
light_gizmos :: proc(l: ^engine.Light, ctx: handles.Gizmo_Context) {
	if .In_Selection not_in ctx.state do return
	tH := engine.Transform_Handle(l.owner)
	gizmos.with_color(LIGHT_GIZMO_COLOR)
	switch l.type {
	case .Point:
		gizmos.wire_sphere(engine.transform_world_position(tH), l.range)
	case .Spot:
		gizmos.in_local_space(tH, use_scale = false)
		angle := math.to_radians(_spot_outer(l))
		h := angle * 0.5
		gizmos.wire_circle(_FORWARD * (l.range * math.cos(h)), _FORWARD, l.range * math.sin(h))
		for p in ([4][3]f32{{1, 0, 0}, {0, 1, 0}, {-1, 0, 0}, {0, -1, 0}}) {
			gizmos.line({}, (_FORWARD * math.cos(h) + p * math.sin(h)) * l.range)
		}
		// Cap arcs through the tip: the range is a distance from the light.
		for p in ([2][3]f32{{1, 0, 0}, {0, 1, 0}}) {
			gizmos.wire_arc({}, linalg.cross(p, _FORWARD), _FORWARD * math.cos(h) + p * math.sin(h), angle, l.range)
		}
	case .Directional:
		pos := engine.transform_world_position(tH)
		r := gizmos.helper_pixel(pos, 16)
		length := gizmos.helper_pixel(pos, 48)
		gizmos.in_local_space(tH, use_scale = false)
		gizmos.wire_circle({}, _FORWARD, r)
		gizmos.line({}, _FORWARD * length)
		for k in 0 ..< 8 {
			a := f32(k) * math.TAU / 8
			o := [3]f32{math.cos(a) * r, math.sin(a) * r, 0}
			gizmos.line(o, o + _FORWARD * length)
		}
	}
}

@(on_scene_handles={component=Light})
light_handles :: proc(l: ^engine.Light, ctx: handles.Gizmo_Context) {
	if l.type == .Directional do return
	h, ok := engine.comp_handle_of(&l.base)
	if !ok do return
	tH := engine.Transform_Handle(l.owner)
	range := l.range
	angle0 := math.to_radians(_spot_outer(l))
	angle := angle0
	d: handles.Drag
	switch l.type {
	case .Directional:
	case .Point:
		d = handles.radius_handle(handles.id_of(h), engine.transform_world_position(tH), &range, color = LIGHT_HANDLE_COLOR)
	case .Spot:
		gizmos.in_local_space(tH, use_scale = false)
		d = handles.cone_handle(handles.id_of(h), {}, _FORWARD, &range, &angle, LIGHT_HANDLE_COLOR)
	}
	if d.started {
		undo.edit_session_end(&_light_edit) // a drag whose release never came
		targets := [?]undo.Edit_Target{
			undo.edit_target_pooled(h, &l.range, typeid_of(f32)),
			undo.edit_target_pooled(h, &l.spot_angle, typeid_of(f32)),
		}
		_light_edit = undo.edit_session_begin(targets[:], "Edit Light")
	}
	if d.dragging || d.released {
		if range != l.range do l.range = range
		if angle != angle0 do l.spot_angle = math.to_degrees(angle)
	}
	if d.released do undo.edit_session_end(&_light_edit)
}
