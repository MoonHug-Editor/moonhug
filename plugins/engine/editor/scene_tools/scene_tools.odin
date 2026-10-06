package scene_tools

// The engine's scene tools: the transform gizmo, picking, the selection
// outline and the engine's own gizmo hooks. They read the shell's selection
// through session.Selection_Source. This file holds the per-frame entry
// points the viewport provider (viewport_provider.odin) hands the shell.

import "moonhug:editor/session"
import "moonhug:packages/engine"
import "moonhug:host/gizmos"

// The scene view's tool layer for this frame, into the gizmo channel the
// caller set (.Tools): the selection outline, the selection's
// @(on_scene_handles) procs, then the transform tool. The handles frame
// (handles.frame_begin) must already be open with `view`.
scene_tools_frame :: proc(view: engine.Render_View) {
	if sel := session.selection(); len(sel) > 0 {
		quads := drawn_quads(view)
		for h in sel do draw_selection_outline(h, quads)
	}
	__scene_handles()
	gizmo_tool_frame()
}

// Every @(on_draw_gizmos) proc once, into the gizmo channel and view the
// caller set. Call gizmo_marks_rebuild first in the frame.
draw_gizmos :: proc() {
	__draw_gizmos()
}

// The Gizmo Settings rows: the component types the generated dispatcher knows.
@(init, private)
_publish_gizmo_types :: proc "contextless" () {
	gizmos.gizmo_types = __gizmo_types[:]
}
