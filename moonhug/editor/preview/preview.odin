package preview

// Editor frame hooks for package editor windows: FRAME HOOKS and SCRUB
// PREVIEWS (plugins/animation/docs/PlayableGraph.md step 5, plugins/sequencer/docs/Sequencer.md).
//
// A package editor window may pose the world for the scene/game render only
// — the animation window's clip scrub and the sequencer's playhead both do.
// The rule is the same for every one of them: apply right before the render,
// restore right after, so every other consumer this frame (saves, undo, the
// inspector) sees authored values.
//
// The editor root owns the render order but must not know which packages
// preview, so windows register here at EditorInit and the root brackets the
// render with apply_all/restore_all. Restore runs in REVERSE registration
// order, so a later preview stacked on an earlier one unwinds correctly.
//
// An editor subpackage like menu/inspector/undo: package editor/ packages
// import it, the editor root drives it.

import "base:runtime"

Hook :: struct {
	apply:   proc(),
	restore: proc(),
}

// Work a window does once per frame whatever its copies show, before the
// views draw: the Animation window's transport runs here, so two copies do
// not advance the playhead twice.
Frame_Hook :: struct {
	frame: proc(),
}

@(private) _hooks: [dynamic]Hook
@(private) _frames: [dynamic]Frame_Hook

// Registered once per window, at EditorInit. Process-global: never borrows
// the caller's allocator.
register :: proc(hook: Hook) {
	context.allocator = runtime.default_allocator()
	append(&_hooks, hook)
}

register_frame :: proc(hook: Frame_Hook) {
	context.allocator = runtime.default_allocator()
	append(&_frames, hook)
}

// Once per frame, before the views draw and the scene/game render.
frame_all :: proc() {
	for f in _frames {
		if f.frame != nil do f.frame()
	}
}

apply_all :: proc() {
	for h in _hooks {
		if h.apply != nil do h.apply()
	}
}

restore_all :: proc() {
	for i := len(_hooks) - 1; i >= 0; i -= 1 {
		if _hooks[i].restore != nil do _hooks[i].restore()
	}
}

shutdown :: proc() {
	delete(_hooks)
	_hooks = nil
	delete(_frames)
	_frames = nil
}
