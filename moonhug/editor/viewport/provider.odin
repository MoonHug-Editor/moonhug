package viewport

// What the viewport asks of whoever owns the world it shows. The shell owns
// the camera, navigation, grid, overlays, band selection and the tool mode.
// The installed engine renders into the view, picks, frames and runs its
// tools (plugins/engine/editor/scene_tools/viewport_provider.odin). With no
// provider the viewport is an empty space with a grid.

import core "moonhug:host/core"
import "base:runtime"
import "moonhug:editor/provider"
import gfx "moonhug:host/gfx"

Viewport_Provider :: struct {
	// Draws the world into the current pass. The grid and axes are drawn already.
	render:              proc(view: core.Render_View),
	// Framing: center and radius of one object, false when it has no bounds.
	object_bounds:       proc(view: core.Render_View, tH: core.Transform_Handle) -> (center: [3]f32, radius: f32, ok: bool),
	pick:                proc(view: core.Render_View, px, py: f32) -> (core.Transform_Handle, bool),
	pick_all:            proc(view: core.Render_View, px, py: f32) -> []core.Transform_Handle, // temp-allocated, nearest first
	band_query:          proc(view: core.Render_View, vmin, vmax: [2]f32) -> []core.Transform_Handle, // temp-allocated
	// The tools' frame, after handles.frame_begin: selection outline, scene handles, the transform tool.
	tools_frame:         proc(view: core.Render_View),
	tools_consume_mouse: proc() -> bool,
	tools_dragging:      proc() -> bool,
	tools_shutdown:      proc(),
	marks_rebuild:       proc(),
	// Every @(on_draw_gizmos) proc for the current gizmo view and channel.
	draw_gizmos:         proc(),
	// The game camera's view at this size, for the Game view's gizmos.
	game_view:           proc(width, height: f32) -> (core.Render_View, bool),
	// The open document has unsaved changes (the tab's dirty mark).
	dirty:               proc() -> bool,
	// Begins the pass on `target` and draws the world through its game
	// cameras, leaving the pass open. False when no game camera is active.
	render_game:         proc(target: ^gfx.Render_Target) -> bool,
	// Gameplay debug drawing is on: the Game view shows the .Game gizmo channel.
	debug_draw:          proc() -> bool,
}

@(private) _provider: Viewport_Provider

@(init)
_register_viewport_provider :: proc "contextless" () {
	context = runtime.default_context()
	provider.register("Viewport_Provider", &_provider)
}

set_provider :: proc(p: Viewport_Provider) {
	_provider = p
}

render :: proc(view: core.Render_View) {
	if _provider.render != nil do _provider.render(view)
}

object_bounds :: proc(view: core.Render_View, tH: core.Transform_Handle) -> (center: [3]f32, radius: f32, ok: bool) {
	if _provider.object_bounds == nil do return {}, 0, false
	return _provider.object_bounds(view, tH)
}

pick :: proc(view: core.Render_View, px, py: f32) -> (core.Transform_Handle, bool) {
	if _provider.pick == nil do return {}, false
	return _provider.pick(view, px, py)
}

pick_all :: proc(view: core.Render_View, px, py: f32) -> []core.Transform_Handle {
	if _provider.pick_all == nil do return {}
	return _provider.pick_all(view, px, py)
}

band_query :: proc(view: core.Render_View, vmin, vmax: [2]f32) -> []core.Transform_Handle {
	if _provider.band_query == nil do return {}
	return _provider.band_query(view, vmin, vmax)
}

tools_frame :: proc(view: core.Render_View) {
	if _provider.tools_frame != nil do _provider.tools_frame(view)
}

tools_consume_mouse :: proc() -> bool {
	if _provider.tools_consume_mouse == nil do return false
	return _provider.tools_consume_mouse()
}

tools_dragging :: proc() -> bool {
	if _provider.tools_dragging == nil do return false
	return _provider.tools_dragging()
}

tools_shutdown :: proc() {
	if _provider.tools_shutdown != nil do _provider.tools_shutdown()
}

marks_rebuild :: proc() {
	if _provider.marks_rebuild != nil do _provider.marks_rebuild()
}

draw_gizmos :: proc() {
	if _provider.draw_gizmos != nil do _provider.draw_gizmos()
}

game_view :: proc(width, height: f32) -> (core.Render_View, bool) {
	if _provider.game_view == nil do return {}, false
	return _provider.game_view(width, height)
}

dirty :: proc() -> bool {
	if _provider.dirty == nil do return false
	return _provider.dirty()
}

// With no provider the pass still begins, cleared to black.
render_game :: proc(target: ^gfx.Render_Target) -> bool {
	if _provider.render_game == nil {
		gfx.pass_begin_target(target, [4]f32{0, 0, 0, 1})
		return false
	}
	return _provider.render_game(target)
}

debug_draw :: proc() -> bool {
	if _provider.debug_draw == nil do return false
	return _provider.debug_draw()
}
