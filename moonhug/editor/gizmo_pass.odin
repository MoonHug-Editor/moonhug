package editor

// The editor's gizmo pass (docs/core/Gizmos.md): once per frame, after the sim tick
// and the preview pose, before any view renders. It records what the scene
// and game views then draw:
//
// - The selection outline, the selection's @(on_scene_handles) procs and the
//   transform gizmo, into .Tools, while the scene view is on screen. They run
//   before the gizmo hooks, so an edit shows in this frame's gizmos and
//   render. The draw order does not depend on it:
//   .Tools always draws over .Editor.
// - Every @(on_draw_gizmos) proc, once per view that shows gizmos (its
//   Gizmos toggle, gizmos.scene_gizmos and game_gizmos): into .Editor with the scene camera,
//   into .Editor_Game with the game camera. Pixel sizes and camera-facing
//   parts fit each view, and the game view has gizmos with the scene view
//   closed. With both views showing gizmos the procs run twice a frame. The
//   gizmo settings apply per component type.

import "base:runtime"
import "core:math"
import "menu"
import core "moonhug:host/core"
import gfx "moonhug:host/gfx"
import im "moonhug:external/odin-imgui"
import "moonhug:editor/handles"
import "moonhug:editor/viewport"
import "moonhug:host/gizmos"

// The gfx frame the scene view last rendered in, and its image size then.
_scene_rendered_frame: u64
_scene_view_size: [2]f32

// Draws gizmos for every enabled instance of a component, each frame, in the
// scene view.
//
// `component` is the type. The proc takes the component and a
// handles.Gizmo_Context and draws through the gizmos API. The scene view's
// Gizmos menu shows or hides them per type. Anything that reacts to the mouse
// belongs in @(on_scene_handles).
@(extension_point={attribute="on_draw_gizmos", target="proc", fields="component"})
gizmo_pass :: proc() {
	sel_scene_prune()
	scene_live := menu.show_scene && _scene_rendered_frame + 1 == gfx.frame_index && _scene_view_size.x > 0 && _scene_view_size.y > 0
	game_live := menu.show_game && game_gizmos
	if !scene_live && !game_live do return

	viewport.marks_rebuild()
	if scene_live {
		// The camera's focus animation (F) steps first, so the handles and
		// the render see the same camera.
		_update_frame_tween(im.GetIO().DeltaTime)
		view := scene_render_view(_scene_view_size.x, _scene_view_size.y)
		// The pointer in scene-image pixels, from the image's place last frame.
		mp := im.GetMousePos()
		io := im.GetIO()
		snapping := _gizmo_snap_active()
		handles.frame_begin(view, handles.Input{
			mouse      = {mp.x - _scene_img_min.x, mp.y - _scene_img_min.y},
			hovered    = scene_view_hovered,
			down       = im.IsMouseDown(.Left),
			clicked    = im.IsMouseClicked(.Left),
			alt        = io.KeyAlt,
			shift      = io.KeyShift,
			snap       = snap_translate_step() if snapping else 0,
			snap_angle = _gizmo_snap_angle() if snapping else 0,
		})
		gizmos.set_view(view)
		gizmos.with_channel(.Tools)
		viewport.tools_frame(view)
		if gizmos.scene_gizmos {
			gizmos.with_channel(.Editor)
			viewport.draw_gizmos()
		}
	}
	// The same procs again with the game camera, for the game view: each view
	// gets gizmos built for its own camera, pixel sizes included. With no
	// camera the game view shows none.
	if game_live {
		if v, ok := _game_gizmo_view(); ok {
			gizmos.with_view(v)
			gizmos.with_channel(.Editor_Game)
			viewport.draw_gizmos()
		}
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
	viewport.set_selection_source({
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
		project_dir      = proc() -> string { return projectViewData.currentPath },
	})
}
