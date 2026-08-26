package preview

// Editor frame hooks for package editor windows: DOCKED VIEWS and SCRUB
// PREVIEWS (docs/PlayableGraph.md step 5, docs/Sequencer.md).
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

// A docked view the editor root draws every frame in view order. The window
// owns its own visibility (menu.show_*), so `draw` decides whether to draw —
// the root just calls it.
View_Hook :: struct {
	draw: proc(),
}

@(private) _hooks: [dynamic]Hook
@(private) _views: [dynamic]View_Hook

// Registered once per window, at EditorInit. Process-global: never borrows
// the caller's allocator.
register :: proc(hook: Hook) {
	context.allocator = runtime.default_allocator()
	append(&_hooks, hook)
}

register_view :: proc(hook: View_Hook) {
	context.allocator = runtime.default_allocator()
	append(&_views, hook)
}

// Drawn with the root's own views, before the scene/game render.
draw_views :: proc() {
	for v in _views {
		if v.draw != nil do v.draw()
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
	delete(_views)
	_views = nil
}
