package audio_editor

// AudioSource gizmos and handles, for sources in the selection
// (docs/core/Handles.md): the min and max distance as wire spheres around the
// source, each with a radius handle on the world axes, in every tool. Every
// source also gets a scene icon, a speaker.
// Dragging the min distance past the max pushes the max out with it, and the
// max below the min pulls the min in.

import "core:math"
import "moonhug:engine"
import "moonhug:engine/gizmos"
import "moonhug:editor/handles"
import "moonhug:editor/undo"
import audio "moonhug:packages/audio"

AUDIO_GIZMO_COLOR :: [4]f32{0.5, 0.7, 1, 0.5}
AUDIO_HANDLE_COLOR :: [4]f32{0.5, 0.7, 1, 1}

@(private = "file")
_edit: undo.Edit_Session

// Both distances at grab: the one not dragged goes back when the other
// retreats.
@(private = "file")
_grab_min, _grab_max: f32

// Scene icon: a speaker and two sound waves.
@(private = "file")
_icon_speaker :: proc() {
	gizmos.wire_rect({-0.52, 0, 0}, {0.3, 0.44})
	gizmos.wire_quad({{-0.37, -0.22, 0}, {0, -0.52, 0}, {0, 0.52, 0}, {-0.37, 0.22, 0}})
	from := [3]f32{math.cos(-_WAVE), math.sin(-_WAVE), 0}
	gizmos.wire_arc({0.05, 0, 0}, {0, 0, 1}, from, 2 * _WAVE, 0.35, segments = 8)
	gizmos.wire_arc({0.05, 0, 0}, {0, 0, 1}, from, 2 * _WAVE, 0.62, segments = 10)
}

@(private = "file")
_WAVE :: f32(0.7) // half the sound waves' angle, radians

@(on_draw_gizmos={component=AudioSource})
audio_source_gizmos :: proc(a: ^audio.AudioSource, ctx: handles.Gizmo_Context) {
	pos := engine.transform_world_position(a.owner)
	handles.icon(pos, a.owner, _icon_speaker)
	if .In_Selection not_in ctx.state do return
	gizmos.with_color(AUDIO_GIZMO_COLOR)
	gizmos.wire_sphere(pos, a.min_distance)
	gizmos.wire_sphere(pos, a.max_distance)
}

@(on_scene_handles={component=AudioSource})
audio_source_handles :: proc(a: ^audio.AudioSource, ctx: handles.Gizmo_Context) {
	h, ok := engine.comp_handle_of(&a.base)
	if !ok do return
	pos := engine.transform_world_position(a.owner)
	lo, hi := a.min_distance, a.max_distance
	dmin := handles.radius_handle(handles.id_of(h, 1), pos, &lo, color = AUDIO_HANDLE_COLOR)
	dmax := handles.radius_handle(handles.id_of(h, 2), pos, &hi, color = AUDIO_HANDLE_COLOR)
	if dmin.started || dmax.started {
		_grab_min, _grab_max = a.min_distance, a.max_distance
		targets := [?]undo.Edit_Target{
			undo.edit_target_pooled(h, &a.min_distance, typeid_of(f32)),
			undo.edit_target_pooled(h, &a.max_distance, typeid_of(f32)),
		}
		_edit = undo.edit_session_begin(targets[:], "Edit Audio Source")
		handles.on_drag_lost(proc(_: rawptr) { undo.edit_session_end(&_edit) })
	}
	if (dmin.dragging || dmin.released) && lo != a.min_distance {
		a.min_distance = lo
		a.max_distance = max(_grab_max, lo)
	}
	if (dmax.dragging || dmax.released) && hi != a.max_distance {
		a.max_distance = hi
		a.min_distance = min(_grab_min, hi)
	}
	if dmin.released || dmax.released do undo.edit_session_end(&_edit)
}
