package editor

// The editor's gizmo pass (docs/Gizmos.md): once per frame, after the sim tick
// and the preview pose, before any view renders. It records what the scene
// and game views then draw:
//
// - The selection outline, the selection's @(on_scene_handles) procs and the
//   transform gizmo, into .Tools, while the scene view is on screen. They run
//   before the gizmo hooks, so an edit shows in this frame's gizmos and
//   render. The draw order does not depend on it:
//   .Tools always draws over .Editor.
// - Every @(on_draw_gizmos) proc, into .Editor, while the scene view is on
//   screen or the game view shows gizmos, so the game view has them with the
//   scene view closed.
//
// Pixel-sized gizmos measure against the scene view's camera while it is on
// screen, else the game view's.

import "menu"
import "../engine"
import gfx "../engine/gfx"
import im "moonhug:external/odin-imgui"
import "moonhug:editor/handles"
import "moonhug:engine/gizmos"

// The gfx frame the scene view last rendered in, and its image size then.
_scene_rendered_frame: u64
_scene_view_size: [2]f32

gizmo_pass :: proc() {
	sel_scene_prune()
	scene_live := menu.show_scene && _scene_rendered_frame + 1 == gfx.frame_index && _scene_view_size.x > 0 && _scene_view_size.y > 0
	game_live := menu.show_game && game_gizmos
	if !scene_live && !game_live do return

	gizmo_marks_rebuild()
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
		for h in sel_scene_items() do draw_selection_outline(h)
		__scene_handles()
		gizmo_tool_frame()
	} else if v, ok := _game_gizmo_view(); ok {
		gizmos.set_view(v)
	}
	gizmos.with_channel(.Editor)
	__draw_gizmos()
}

// The game view's camera view at its last size.
@(private = "file")
_game_gizmo_view :: proc() -> (engine.Render_View, bool) {
	cam := engine.camera_active()
	if cam == nil || game_rt == nil || game_rt.width < 1 || game_rt.height < 1 do return {}, false
	return engine.camera_render_view(cam, f32(game_rt.width), f32(game_rt.height)), true
}
