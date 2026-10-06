package engine

import "base:runtime"
import core "moonhug:host/core"

UserContext :: struct {
    world         : ^World,
    scene_manager : SceneManager,
    // TRUE IN THE EDITOR BINARY, false in the standalone app. Unity's
    // Application.isEditor: fixed per binary, unaffected by Simulate. Set by each
    // binary's main (and by the test bootstrap, which exercises editor behaviour).
    is_editor : bool,
    // Unity's Application.isPlaying. The app sets it once at startup (true for
    // the process lifetime). The editor's Simulate sets it at Start and clears it
    // at Stop - it stays true while paused, pause being a separate condition.
    // "Is this a simulation?" is not stored anywhere: it is is_playing &&
    // is_editor.
    is_playing : bool,
    undo          : rawptr,
    // Recorded gizmo shapes for this context's views (host/gizmos).
    gizmos        : Gizmo_Buffer,
}

// Unity's Application.isEditor: true in the editor binary, false in a standalone
// build. Constant for the lifetime of the process — entering Simulate does not
// change it.
application_is_editor :: proc() -> bool {
    uc := ctx_get()
    return uc != nil && uc.is_editor
}

// Unity's Application.isPlaying - see the field. This is the one component code
// should ask. Application.isFocused is core.application_is_focused
// (re-exported here), owned by the input layer.
application_is_playing :: proc() -> bool {
    uc := ctx_get()
    return uc != nil && uc.is_playing
}

ctx_get :: proc() -> ^UserContext {
    return cast(^UserContext)context.user_ptr
}

ctx_world :: proc() -> ^World {
    return ctx_get().world
}

ctx_scene_manager :: proc() -> ^SceneManager {
    return &ctx_get().scene_manager
}

// Gizmos record into the current user context's buffer (core.gizmo_buffer).
@(init)
_install_gizmo_buffer_slot :: proc "contextless" () {
	context = runtime.default_context()
	core.set_game_clock(proc() -> f64 { return f64(fixed_tick_index()) * f64(fixed_dt()) })
	core.set_gizmo_buffer_slot(proc() -> ^core.Gizmo_Buffer {
		uc := ctx_get()
		if uc == nil do return nil
		return &uc.gizmos
	})
}
