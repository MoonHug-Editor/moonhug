package editor

// The editor's gizmo recording (docs/core/Gizmos.md), after the sim tick and
// inside the preview pose:
//
// - gizmo_pass, once per frame before any view draws: it picks the Scene copy
//   the handles run in (_scene_handles_update) and records every
//   @(comp_on_draw_gizmos) proc into .Editor_Game with the game camera, for
//   the game view when its Gizmos toggle is on.
// - scene_gizmos_record, in each Scene copy right before its render: the
//   selection outline into .Outline and the @(comp_on_draw_gizmos) procs into
//   .Editor, with that copy's camera, so pixel sizes and camera-facing parts
//   fit every copy. In the copy the handles run in, the selection's
//   @(comp_on_scene_handles) procs and the transform gizmo record into .Tools,
//   once per frame. They run before the gizmo procs, so an edit shows in this
//   frame's gizmos and render. Channels draw in order, so where shapes
//   coincide the gizmos paint over the outline and the handles over both.
//
// With several views showing gizmos the gizmo procs run once per view each
// frame. The gizmo settings apply per component type.

import "base:runtime"
import "core:math"
import "menu"
import core "moonhug:libs/core"
import im "moonhug:external/odin-imgui"
import "moonhug:editor/handles"
import "moonhug:editor/viewport"
import "moonhug:editor/session"
import "moonhug:libs/gizmos"

// Draws gizmos for every enabled instance of a component, each frame, in the
// scene view.
//
// `component` is the type. The proc takes the component and a
// handles.Gizmo_Context and draws through the gizmos API. The scene view's
// Gizmos menu shows or hides them per type. Anything that reacts to the mouse
// belongs in @(comp_on_scene_handles).
@(extension_point={attribute="comp_on_draw_gizmos", target="proc", fields="component"})
gizmo_pass :: proc() {
	sel_scene_prune()
	viewport.marks_rebuild()
	_scene_handles_update()
	// The gizmo procs with the game camera, for the game view: each view gets
	// gizmos built for its own camera, pixel sizes included. With no camera
	// the game view shows none.
	if menu.show_game && game_gizmos {
		if v, ok := _game_gizmo_view(); ok {
			gizmos.with_view(v)
			gizmos.with_channel(.Editor_Game)
			viewport.draw_gizmos()
		}
	}
}

// Picks the Scene copy the handles run in this frame: the one under the
// pointer, else the one clicked in last. It stays while a drag that began in
// it goes on (a handle, the transform gizmo, a box select, an orbit, a
// flythrough), so a drag that crosses into another copy keeps its camera.
@(private = "file")
_scene_handles_update :: proc() {
	if sv := _scene_handles; sv != nil && (handles.dragging() || viewport.tools_dragging() || sv.band_active || sv.orbit_active || sv.flythrough_active) do return
	_scene_handles = _scene_pick()
}

// The current Scene copy's gizmos, right before its render (render_scene_rt).
// The .Outline, .Editor and .Tools channels hold one copy's shapes at a time:
// each copy clears them, records them with its own camera, and renders. The
// handles record only in the copy they run in (_scene_handles), once per
// frame.
scene_gizmos_record :: proc(view: core.Render_View) {
	gizmos.clear_channels({.Outline, .Editor, .Tools})
	gizmos.set_view(view)
	{
		gizmos.with_channel(.Outline)
		viewport.outline(view)
	}
	{
		gizmos.with_channel(.Tools)
		if _sv == _scene_handles {
			// The pointer in scene-image pixels, from the image's place last frame.
			mp := im.GetMousePos()
			io := im.GetIO()
			snapping := _gizmo_snap_active()
			handles.frame_begin(view, handles.Input{
				mouse      = {mp.x - _sv.img_min.x, mp.y - _sv.img_min.y},
				hovered    = _sv.hovered,
				down       = im.IsMouseDown(.Left),
				clicked    = im.IsMouseClicked(.Left),
				alt        = io.KeyAlt,
				shift      = io.KeyShift,
				snap       = snap_translate_step() if snapping else 0,
				snap_angle = _gizmo_snap_angle() if snapping else 0,
			})
			viewport.tools_frame(view)
		}
	}
	if gizmos.scene_gizmos {
		gizmos.with_channel(.Editor)
		viewport.draw_gizmos()
	}
}

// The game view's camera view at its last size: the highest-order camera, the
// one the game view renders last.
@(private)
_game_gizmo_view :: proc() -> (core.Render_View, bool) {
	if game_rt == nil || game_rt.width < 1 || game_rt.height < 1 do return {}, false
	return viewport.game_view(f32(game_rt.width), f32(game_rt.height))
}

// Snap is the Snap popup's Enabled XOR the snap modifier: it temporarily
// snaps when the toggle is off and frees the drag when it's on. io.KeyCtrl is
// Ctrl on Windows and Linux, Cmd on macOS (imgui's ConfigMacOSXBehaviors
// remaps it there). The gizmo pass turns this into the handles' snap steps.
@(private = "file")
_gizmo_snap_active :: proc() -> bool {
	return snap_settings.enabled != im.GetIO().KeyCtrl
}

@(private = "file")
_gizmo_snap_angle :: proc() -> f32 {
	return math.to_radians(max(snap_settings.angle, 1))
}

// What the engine's tools and views read and change of the shell: the scene
// selection, the inspected objects, the project's active path and the game
// view's aspect. Set at start, so the editor and the test binary both have it.
@(init, private = "file")
_install_selection_source :: proc "contextless" () {
	context = runtime.default_context()
	session.set_selection_source({
		selection        = sel_scene_items,
		top_level        = sel_scene_top_level,
		active           = sel_scene_active,
		game_aspect      = proc() -> (f32, bool) {
			if game_rt == nil || game_rt.height <= 0 do return 0, false
			return f32(game_rt.width) / f32(game_rt.height), true
		},
		select_only      = sel_scene_only,
		select_add       = sel_scene_add,
		select_toggle    = sel_scene_toggle,
		select_clear     = sel_scene_clear,
		is_selected      = sel_scene_is,
		prune            = sel_scene_prune,
		inspected        = inspector_targets,
		inspected_active = inspector_active_target,
		frame_selected   = scene_frame_selected,
		project_active   = proc() -> string { return projectViewData.selectedFile },
		project_dir      = proc() -> string { return _pv.current_path },
	})
}
