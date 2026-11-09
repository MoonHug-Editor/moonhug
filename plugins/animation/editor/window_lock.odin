package animation_editor

// The Animation window's lock is the shared window lock (the editor's
// window_lock.odin): its window declares lock="shared", so the shell draws the
// padlock and every copy of the window shares one lock, as the copies share
// one preview (_pv). Locking takes the selection as it is now, whether or not
// the selected object has an Animation component yet. The window resolves
// its object as it resolves the selection: the Animation component on it or
// its nearest ancestor, so an object locked before its component is added
// shows the editor once it has one.

import engine "moonhug:packages/engine"
import "moonhug:editor/session"

// The object the window follows: the locked one, else the selection.
@(private)
_anim_lock_target :: proc() -> engine.Transform_Handle {
	return engine.Transform_Handle(session.window_object(ANIMATION_WINDOW))
}
