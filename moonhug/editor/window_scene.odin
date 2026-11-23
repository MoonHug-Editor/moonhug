package editor

import "base:runtime"
import "core:fmt"
import "core:time"
import gfx "moonhug:libs/gfx"
import input "moonhug:libs/input"
import im "moonhug:external/odin-imgui"
import "menu"
import "core:math"
import "core:math/linalg"
import "inspector"
import core "moonhug:libs/core"
import assets "moonhug:libs/assets"
import "moonhug:editor/drag"
import "moonhug:libs/gizmos"
import "moonhug:editor/viewport"
import "core:strings"
import "moonhug:editor/icons"
import "moonhug:editor/widgets"
import wnd "moonhug:editor/window"
import "moonhug:editor/keymap"
import "moonhug:editor/session"

SCENE :: "Scene"

// One Scene copy's own state. The first copy's lives in _sv_plain, which
// outlives its window and holds what editor_settings persists. A copy opened
// from Add Tab has its own in its wnd.Window, with its own render target.
Scene_Window :: struct {
	rt: ^gfx.Render_Target,

	// Editor camera: first-person data (position + yaw/pitch about the EYE),
	// NOT a Camera component: the Scene window renders through the same engine
	// collect/execute path as game cameras. cam_target is derived: the
	// look-at anchor cam_dist along the forward ray. Orbit/zoom/frame pull
	// toward it, fly and pan carry it along (the pivot model).
	cam_pos:    [3]f32,
	cam_yaw:    f32, // radians, atan2(fwd.z, fwd.x)
	cam_pitch:  f32, // radians, asin(fwd.y), clamped just short of the poles
	cam_dist:   f32,
	cam_target: [3]f32,

	// Flythrough speed: wheel while flying rescales the base (kept for the
	// whole session), holding movement keys ramps the current speed toward
	// base*mult.
	fly_speed_cur: f32,
	speed_shown_at: time.Tick, // when the wheel last changed the fly speed
	// Flythrough smoothing: mouse look drives TARGET angles and the camera
	// exponentially chases them, movement velocity chases the keyed direction
	// the same way. Both use 1-exp(-dt/tau), so the lag feel is frame-rate
	// independent.
	fly_yaw_target:   f32,
	fly_pitch_target: f32,
	fly_vel:          [3]f32,

	orbit_active: bool,
	orbit_pivot:  [3]f32,

	hovered:           bool,
	flythrough_active: bool,
	// What the flythrough keymap's held commands asked for this frame
	// (scene_fly_* below): the fly step reads and clears them.
	fly_move: [3]f32,
	// The arrow keys held this frame, as a screen direction (scene_nudge_*
	// commands), the one before it, and the hold's clock for the key repeat.
	nudge_dir:  [2]f32,
	nudge_prev: [2]f32,
	nudge_time: f32,
	nudge_next: f32,
	fly_fast: bool,

	// Projection and the 2D view. Orthographic keeps the framing of the
	// perspective view: the ortho height derives from the orbit distance and
	// the FOV, so toggling does not jump and wheel zoom keeps working. 2D
	// fixes the view along -Z (X right, Y up), orthographic, with no orbit:
	// right and middle drag both pan. Leaving 2D restores the view that was
	// active before it.
	cam_ortho:    bool,
	mode_2d:      bool,
	pre_2d_yaw:   f32,
	pre_2d_pitch: f32,
	pre_2d_ortho: bool,
	pending_2d:   bool, // settings asked for 2D before the camera existed
	// The scene this copy's camera belongs to: another active scene brings
	// its own saved camera (scene_cameras).
	cam_scene:    core.Asset_GUID,

	// Click-to-pick state: a click is press+release under a small drag
	// threshold (so orbit/pan drags never select).
	img_min:       im.Vec2,
	view_last:     core.Render_View, // the view the image was last rendered with: labels project through it
	click_pos:     im.Vec2,
	click_pending: bool,

	// Rubber-band box select: an armed LMB click that travels beyond the
	// click threshold becomes a live box select. The selection updates every
	// frame while the band is open, and the selection-undo tracker pauses
	// (scene_band_selecting) so the whole gesture records as ONE "Select" step.
	band_active:   bool,
	band_anchor:   im.Vec2, // screen coords
	band_additive: bool,    // cmd/ctrl held at band start: adds to the base set
	band_base:     [dynamic]core.Transform_Handle, // selection at band start

	// Frame Selected's camera move (scene_frame_selected).
	tween_active:      bool,
	tween_t:           f32,
	tween_from_target: [3]f32,
	tween_to_target:   [3]f32,
	tween_from_dist:   f32,
	tween_to_dist:     f32,

	view_mode: core.View_Mode, // shading mode (the Shading overlay)

	// The gfx frame the copy last rendered in, and its image size then.
	rendered_frame: u64,
	view_size:      [2]f32,
	// The gfx frame its draw last ran in, and the image size it wanted: a
	// copy in a Workspace window's frame renders from these, inside the preview
	// pose (scene_windows_render_hosted).
	drawn_frame:    u64,
	want_size:      [2]i32,

	// The right-click context menu and the Cmd+right-click pick menu.
	ctx_click_pending: bool,
	ctx_click_pos:     [2]f32, // scene-image pixels at the press
	ctx_click_travel:  f32,
	ctx_menu_point:  [3]f32, // where the context menu was opened, in the world
	ctx_menu_target:   core.Transform_Handle, // {} = empty space
	pick_menu:         [dynamic]core.Transform_Handle,
}

@(private)
_sv_plain: Scene_Window

// The copy being drawn, and outside a draw the active copy (_scene_active),
// which the gizmo pass, menu actions and the bridge act on.
_sv: ^Scene_Window = &_sv_plain

// The copy the handles run in this frame, picked once per frame by the gizmo
// pass (_scene_handles_update).
@(private)
_scene_handles: ^Scene_Window

// The copy the pointer was over last frame, else the copy clicked in last,
// else the first copy's state.
@(private)
_scene_pick :: proc() -> ^Scene_Window {
	for w in wnd.instances(SCENE) do if sv := _scene_window(w); sv.hovered do return sv
	if last := wnd.last(SCENE); last != nil do return _scene_window(last)
	return &_sv_plain
}

// The copy the handles run in, which the bridge and menu actions act on too.
@(private)
_scene_active :: proc() -> ^Scene_Window {
	return _scene_handles if _scene_handles != nil else _scene_pick()
}

@(private = "file")
_scene_window :: proc(w: ^wnd.Window) -> ^Scene_Window {
	if w.key == SCENE do return &_sv_plain
	if w.data == nil {
		sv := new(Scene_Window, runtime.default_allocator())
		_scene_window_init(sv)
		// A new copy starts where the first one looks.
		sv.cam_pos, sv.cam_yaw, sv.cam_pitch, sv.cam_dist, sv.cam_target = _sv_plain.cam_pos, _sv_plain.cam_yaw, _sv_plain.cam_pitch, _sv_plain.cam_dist, _sv_plain.cam_target
		sv.cam_ortho, sv.view_mode = _sv_plain.cam_ortho, _sv_plain.view_mode
		w.data = sv
	}
	return (^Scene_Window)(w.data)
}

@(private = "file")
_scene_window_init :: proc(sv: ^Scene_Window) {
	sv.rt = gfx.rt_create(1, 1)
	sv.fly_speed_cur = scene_camera_prefs.fly_speed
	prev := _sv
	_sv = sv
	scene_cam_look_at({7, 7, 7}, {0, 0, 0})
	_sv = prev
}

@(private = "file")
_scene_window_free :: proc(sv: ^Scene_Window) {
	context.allocator = runtime.default_allocator()
	delete(sv.band_base)
	delete(sv.pick_menu)
	gfx.rt_destroy(sv.rt)
	sv^ = {}
}

scene_window_closed :: proc(w: ^wnd.Window) {
	if w.key == SCENE do return
	sv := (^Scene_Window)(w.data)
	if sv == nil do return
	if _sv == sv do _sv = &_sv_plain
	if _scene_handles == sv do _scene_handles = nil
	_scene_window_free(sv)
	free(sv, runtime.default_allocator())
	w.data = nil
}

scene_set_2d :: proc(on: bool) {
	if on == _sv.mode_2d do return
	_sv.mode_2d = on
	if on {
		_sv.pre_2d_yaw, _sv.pre_2d_pitch, _sv.pre_2d_ortho = _sv.cam_yaw, _sv.cam_pitch, _sv.cam_ortho
		_sv.cam_ortho = true
		_sv.cam_yaw = -math.PI / 2 // forward = -Z
		_sv.cam_pitch = 0
	} else {
		_sv.cam_yaw, _sv.cam_pitch, _sv.cam_ortho = _sv.pre_2d_yaw, _sv.pre_2d_pitch, _sv.pre_2d_ortho
	}
	_sv.tween_active = false
	fwd, _, _ := _scene_cam_basis()
	_sv.cam_pos = _sv.cam_target - fwd * _sv.cam_dist
	update_scene_camera()
}

// Any copy's band is open.
scene_band_selecting :: proc() -> bool {
	if _sv_plain.band_active do return true
	for w in wnd.instances(SCENE) do if _scene_window(w).band_active do return true
	return false
}

FLYTHROUGH_BASE_SPEED :: f32(8.0)
FLYTHROUGH_SHIFT_MULT :: f32(3.0)
FLYTHROUGH_RAMP_MULT :: f32(3.0) // held movement accelerates up to base*this
FLYTHROUGH_RAMP_TIME :: f32(2.0) // seconds to reach the ramp cap
FLY_SPEED_WHEEL_BASE :: f32(1.2) // wheel during fly: speed *= base^notches
FLY_LOOK_SMOOTH_TAU :: f32(0.025) // seconds for look to catch its target (~63%)
FLY_MOVE_SMOOTH_TAU :: f32(0.08) // seconds for velocity to catch its target
// The longest step the flythrough takes: a frame that took longer (the idle
// rate's wait, a hitch) moves the camera as one frame of this length, so
// movement eases in instead of jumping.
FLY_MAX_DT :: f32(1.0 / 30)
LOOK_SENSITIVITY :: f32(0.005) // radians per pixel (fly + orbit)
ZOOM_WHEEL_BASE :: f32(1.2) // wheel dolly: dist *= base^-notches
ZOOM_MIN_STEP :: f32(0.25) // keeps close-range dolly responsive
ZOOM_DRAG_FACTOR :: 0.01

SCENE_CAM_FOV_DEG :: f32(45)
SCENE_CAM_NEAR :: f32(0.1)
SCENE_CAM_FAR :: f32(20000) // far enough to frame a whole 4K canvas (one unit per canvas pixel)

init_scene_window :: proc() {
	_scene_window_init(&_sv_plain)

	// Unity-style dockable overlays (dock.odin): register every
	// @(scene_overlay) item (generated), then restore persisted placement.
	_register_scene_overlays()
	overlay_set_default_anchor("Tools", .Bar_Left)        // Unity's left toolbar strip
	overlay_set_default_anchor("Orientation", .Top_Right) // Unity's scene gizmo corner; settings override
	overlay_set_transparent("Orientation")                // Unity's: no panel, only the grip
	overlays_apply_settings()
}

shutdown_scene_window :: proc() {
	viewport.tools_shutdown()
	overlays_shutdown()
	_scene_window_free(&_sv_plain)
}

// Orthonormal frame from yaw/pitch. The pitch clamp in update_scene_camera
// keeps fwd off the world-up pole, so the crosses never degenerate.
_scene_cam_basis :: proc() -> (fwd, right, up: [3]f32) {
	cp := math.cos(_sv.cam_pitch)
	fwd = {math.cos(_sv.cam_yaw) * cp, math.sin(_sv.cam_pitch), math.sin(_sv.cam_yaw) * cp}
	right = linalg.normalize(linalg.cross(fwd, [3]f32{0, 1, 0}))
	up = linalg.cross(right, fwd)
	return
}

scene_cam_forward :: proc() -> [3]f32 {
	fwd, _, _ := _scene_cam_basis()
	return fwd
}

scene_cam_right :: proc() -> [3]f32 {
	_, right, _ := _scene_cam_basis()
	return right
}

scene_cam_up :: proc() -> [3]f32 {
	_, _, up := _scene_cam_basis()
	return up
}

// Place the camera and derive yaw/pitch/dist so it looks at target.
scene_cam_look_at :: proc(pos, target: [3]f32) {
	_sv.cam_pos = pos
	d := target - pos
	_sv.cam_dist = linalg.length(d)
	if _sv.cam_dist > 0.0001 {
		dir := d / _sv.cam_dist
		_sv.cam_pitch = math.asin(clamp(dir.y, -1, 1))
		_sv.cam_yaw = math.atan2(dir.z, dir.x)
	}
	update_scene_camera()
}

PITCH_LIMIT :: f32(math.PI / 2 - 0.02)

// Clamp the angles and re-derive the look-at anchor from the eye. A NaN/inf
// guard resets the camera instead of leaving the view unrecoverably black
// (bad mesh bounds or a zero-length basis would poison every later frame).
update_scene_camera :: proc() {
	_sv.cam_pitch = clamp(_sv.cam_pitch, -PITCH_LIMIT, PITCH_LIMIT)
	_sv.cam_dist = clamp(_sv.cam_dist, 0.1, 10000)

	fwd, _, _ := _scene_cam_basis()
	_sv.cam_target = _sv.cam_pos + fwd * _sv.cam_dist

	ok :: proc(v: [3]f32) -> bool {
		for c in v {
			if c != c || abs(c) > 1e20 do return false
		}
		return true
	}
	if !ok(_sv.cam_pos) || !ok(_sv.cam_target) || _sv.cam_yaw != _sv.cam_yaw {
		scene_cam_look_at({7, 7, 7}, {0, 0, 0})
	}
}

// Frame the current selection (Unity's F): center the orbit camera on the
// object's bounds and pull back far enough to fit them in the FOV. The move
// tweens with ease-in/out over SCENE_FRAME_TWEEN_SEC (any manual camera input
// cancels it).
SCENE_FRAME_TWEEN_SEC :: f32(0.2)

// Unity's Edit > Frame Selected (F in the Scene window).
@(menu_item={path="Edit/Frame Selected", order=-44, shortcut="", help="Moves the Scene window's camera to show the selection"})
edit_frame_selected_menu :: proc() {
	scene_frame_selected()
}

scene_frame_selected :: proc() {
	// Union over ALL selected objects (Unity frames the whole selection).
	first := true
	cmin, cmax: [3]f32
	view := scene_render_view(max(_sv.view_size.x, 1), max(_sv.view_size.y, 1))
	for h in sel_scene_items() {
		c, r, ok := viewport.object_bounds(view, h)
		if !ok do continue
		lo := c - r
		hi := c + r
		if first {
			cmin, cmax = lo, hi
			first = false
		} else {
			cmin = {min(cmin.x, lo.x), min(cmin.y, lo.y), min(cmin.z, lo.z)}
			cmax = {max(cmax.x, hi.x), max(cmax.y, hi.y), max(cmax.z, hi.z)}
		}
	}
	if first do return
	center := (cmin + cmax) * 0.5
	radius := max(linalg.length(cmax - cmin) * 0.5, 0.1)
	_sv.tween_from_target = _sv.cam_target
	_sv.tween_from_dist = _sv.cam_dist
	_sv.tween_to_target = center
	_sv.tween_to_dist = max(radius / math.tan(math.to_radians(scene_camera_prefs.fov) * 0.5) * 1.2, 1)
	_sv.tween_t = 0
	_sv.tween_active = true
}

_update_frame_tween :: proc(dt: f32) {
	if !_sv.tween_active do return
	_sv.tween_t = min(_sv.tween_t + dt / SCENE_FRAME_TWEEN_SEC, 1)
	t := _sv.tween_t
	k := t * t * (3 - 2 * t) // smoothstep: ease in/out
	// Framing keeps the view direction (Unity's F): the eye rides behind the
	// tweened anchor along the current forward ray.
	tgt := linalg.lerp(_sv.tween_from_target, _sv.tween_to_target, k)
	_sv.cam_dist = _sv.tween_from_dist + (_sv.tween_to_dist - _sv.tween_from_dist) * k
	fwd, _, _ := _scene_cam_basis()
	_sv.cam_pos = tgt - fwd * _sv.cam_dist
	update_scene_camera()
	if _sv.tween_t >= 1 do _sv.tween_active = false
}

// A gizmo label at `p` (screen), shadowed, for the scene and Game windows. A
// rotated label is drawn glyph by glyph from the font atlas, turned 90
// degrees clockwise so it reads top to bottom with the glyph tops facing
// right: imgui has no rotated text of its own.
@(private)
_draw_handle_label :: proc(dl: ^im.DrawList, p: im.Vec2, l: core.Gizmo_Label) {
	c := strings.clone_to_cstring(l.text, context.temp_allocator)
	size := im.CalcTextSize(c)
	if !l.rotated {
		at := im.Vec2{p.x - size.x * l.align.x, p.y - size.y * l.align.y}
		im.DrawList_AddText(dl, {at.x + 1, at.y + 1}, 0xB0000000, c)
		im.DrawList_AddText(dl, at, im.ColorConvertFloat4ToU32(l.color), c)
		return
	}
	font := im.GetFont()
	baked := im.Font_GetFontBaked(font, im.GetFontSize())
	if baked == nil do return
	// The turned box is size.y wide and size.x tall; text x runs down it,
	// text y (down from the glyph tops) runs to the left.
	box := im.Vec2{size.y, size.x}
	origin := im.Vec2{p.x - box.x * l.align.x, p.y - box.y * l.align.y}
	draw :: proc(dl: ^im.DrawList, font: ^im.Font, baked: ^im.FontBaked, origin: im.Vec2, text_h: f32, text: string, col: u32) {
		pen := f32(0)
		for r in text {
			g := im.FontBaked_FindGlyph(baked, im.Wchar(r))
			if g == nil do continue
			if g.Visible != 0 {
				map_pt :: proc(origin: im.Vec2, text_h, gx, gy: f32) -> im.Vec2 { return {origin.x + text_h - gy, origin.y + gx} }
				im.DrawList_AddImageQuad(dl, font.OwnerAtlas.TexRef,
					map_pt(origin, text_h, pen + g.X0, g.Y0), map_pt(origin, text_h, pen + g.X1, g.Y0),
					map_pt(origin, text_h, pen + g.X1, g.Y1), map_pt(origin, text_h, pen + g.X0, g.Y1),
					{g.U0, g.V0}, {g.U1, g.V0}, {g.U1, g.V1}, {g.U0, g.V1}, col)
			}
			pen += g.AdvanceX
		}
	}
	draw(dl, font, baked, {origin.x + 1, origin.y + 1}, size.y, l.text, 0xB0000000)
	draw(dl, font, baked, origin, size.y, l.text, im.ColorConvertFloat4ToU32(l.color))
}

// Half the visible height at the anchor: what the perspective view shows at
// _sv.cam_dist, and the orthographic view's half height.
scene_cam_half_height :: proc() -> f32 {
	return max(_sv.cam_dist, 0.05) * math.tan(math.to_radians(scene_camera_prefs.fov) * 0.5)
}

// The Scene window's Render_View — also the basis for picking rays later.
scene_render_view :: proc(w, h: f32) -> core.Render_View {
	view := linalg.matrix4_look_at_f32(_sv.cam_pos, _sv.cam_target, {0, 1, 0})
	aspect := w / max(h, 1)
	proj: matrix[4, 4]f32
	if _sv.cam_ortho {
		half_h := scene_cam_half_height()
		half_w := half_h * aspect
		// The eye sits _sv.cam_dist before the anchor; the near plane goes
		// far behind it so an ortho view never clips what a zoom-in passes.
		proj = gfx.matrix4_ortho_z01(-half_w, half_w, -half_h, half_h, -SCENE_CAM_FAR, SCENE_CAM_FAR)
	} else {
		proj = gfx.matrix4_perspective_z01(math.to_radians(scene_camera_prefs.fov), aspect, SCENE_CAM_NEAR, SCENE_CAM_FAR)
	}
	rv := core.render_view_make(view, proj, w, h, ~u32(0), .SceneView) // editor sees all layers
	rv.mode = _sv.view_mode
	rv.cull = true
	return rv
}

// The render pipeline slot the Scene window renders through, Main when the
// pipeline declares no Editor slot (plugins/engine/render_pipeline.odin). A
// name, so the shell needs no engine type: with no engine the viewport falls
// back to an empty view.
SCENE_WINDOW_SLOT :: "Editor"

render_scene_rt :: proc(w, h: i32) {
	if w < 1 || h < 1 do return
	gfx.rt_resize(_sv.rt, w, h)

	// The camera's focus animation (F) steps first, so the handles and the
	// render see the same camera.
	_update_frame_tween(im.GetIO().DeltaTime)
	view := scene_render_view(f32(w), f32(h))
	_sv.rendered_frame = gfx.frame_index
	_sv.view_size = {f32(w), f32(h)}
	// This copy's outline, gizmos and, in the copy they run in, handles
	// (gizmo_pass.odin).
	scene_gizmos_record(view)
	_sv.view_last = view
	// The engine's render pipeline owns the passes: the grid and axes draw
	// under the scene, the gizmos over it, both from scene passes that share
	// its depth.
	viewport.render(_sv.rt, view, SCENE_WINDOW_SLOT, [4]f32{0.15, 0.15, 0.15, 1}, _draw_scene_under, _draw_scene_over)
}

@(private = "file")
_draw_scene_under :: proc() {
	draw_grid()
	draw_axis_lines()
}

// Gameplay shapes, gizmos, then tools: depth-tested first, then the rest over them.
@(private = "file")
_draw_scene_over :: proc() {
	gizmos.draw(gizmos.scene_gizmo_channels())
}

// Scene grid: per-plane toggles + cell layout, edited via the Grid overlay
// overlay popup (draw_grid_overlay) and persisted in editor_settings.
// A cell is cell_size units, drawn with emphasized lines; subdivide splits
// each cell into N fine-line divisions; cells_count is cells from center to side.
Grid_Settings :: struct {
	show_xz:     bool,
	show_xy:     bool,
	show_yz:     bool,
	cell_size:   f32, // one cell in world units (emphasized lines)
	subdivide:   i32, // fine-line divisions per cell (1 = none)
	cells_count: i32, // cells from center to side (radius)
}

GRID_DEFAULTS :: Grid_Settings{show_xz = true, cell_size = 10, subdivide = 10, cells_count = 2}

// Gizmo drag snapping (Snap overlay popup; Ctrl inverts enabled while held).
// Translate step comes from `mode`: a full grid cell, one grid subdivision,
// or a free `units` value (> 0).
Snap_Mode :: enum u8 {
	Grid,
	SubGrid,
	Units,
}

Snap_Settings :: struct {
	enabled: bool,
	angle:   f32, // rotate snap, degrees
	mode:    Snap_Mode,
	units:   f32, // translate step when mode == .Units
}

SNAP_DEFAULTS :: Snap_Settings{enabled = false, angle = 15, mode = .SubGrid, units = 1}

snap_settings := SNAP_DEFAULTS

// Translate-snap step in world units per the active snap mode.
snap_translate_step :: proc() -> f32 {
	gs := grid_settings
	switch snap_settings.mode {
	case .Grid:    return max(gs.cell_size, 0.0001)
	case .SubGrid: return max(gs.cell_size / f32(max(gs.subdivide, 1)), 0.0001)
	case .Units:   return max(snap_settings.units, 0.0001)
	}
	return 1
}

grid_settings := GRID_DEFAULTS

_GRID_CELL_COL :: [4]f32{0.46, 0.46, 0.46, 1} // cell-boundary lines
_GRID_SUB_COL :: [4]f32{0.3, 0.3, 0.3, 1}     // subdivision lines

draw_grid :: proc() {
	gs := grid_settings
	if gs.cells_count <= 0 || gs.cell_size <= 0 do return
	if _sv.mode_2d {
		// The 2D view looks along -Z: only the XY grid reads, the others are
		// edge-on lines.
		_draw_grid_plane({1, 0, 0}, {0, 1, 0})
		return
	}
	if gs.show_xz do _draw_grid_plane({1, 0, 0}, {0, 0, 1})
	if gs.show_xy do _draw_grid_plane({1, 0, 0}, {0, 1, 0})
	if gs.show_yz do _draw_grid_plane({0, 1, 0}, {0, 0, 1})
}

// One grid plane spanned by axes u,v: fine lines every cell_size/subdivide;
// every subdivide-th line is a cell boundary and draws emphasized.
_draw_grid_plane :: proc(u, v: [3]f32) {
	gs := grid_settings
	sub := max(gs.subdivide, 1)
	step := gs.cell_size / f32(sub)
	n := gs.cells_count * sub // fine steps from center to side
	half := f32(gs.cells_count) * gs.cell_size
	for i in -n ..= n {
		off := f32(i) * step
		col := i % sub == 0 ? _GRID_CELL_COL : _GRID_SUB_COL
		gfx.draw_line(u * off - v * half, u * off + v * half, col, depth_write = true)
		gfx.draw_line(v * off - u * half, v * off + u * half, col, depth_write = true)
	}
}

draw_axis_lines :: proc() {
	gfx.draw_line({0, 0, 0}, {5, 0, 0}, {0.9, 0.16, 0.22, 1}, depth_write = true) // X red
	gfx.draw_line({0, 0, 0}, {0, 5, 0}, {0, 0.89, 0.19, 1}, depth_write = true)   // Y green
	gfx.draw_line({0, 0, 0}, {0, 0, 5}, {0, 0.47, 0.95, 1}, depth_write = true)   // Z blue
}

// A copy in a Workspace window's frame draws with its Workspace window, after the
// preview pose is restored (main.odin). Its render runs here instead, inside
// the pose, right after the docked copies draw, at the size its frame gave it
// last frame, and its draw shows that render. Input lags the render by one
// frame as in a docked copy, which renders before it handles input. A copy
// whose Workspace window did not draw last frame renders nothing here.
scene_windows_render_hosted :: proc() {
	defer _sv = _scene_active()
	for w in wnd.instances(SCENE) {
		if w.host == "" do continue
		sv := _scene_window(w)
		if sv.drawn_frame + 1 != gfx.frame_index || sv.want_size.x < 1 || sv.want_size.y < 1 do continue
		_sv = sv
		render_scene_rt(sv.want_size.x, sv.want_size.y)
	}
}

// Drawn at a set point of the frame (wnd.draw in main.odin): after the gizmo
// pass, inside the preview pose. A canvas window: no padding, so the render
// target fills it edge to edge, and no scrollbar, since overlays draw ON the
// image with last-frame sizes, so a freshly appearing or resizing overlay can
// momentarily extend past the window edge. A scrollbar would shrink the
// content region, resize the RT and shift the image, oscillating for frames.
@(editor_window={id="Scene", title="Scene", icon="LANDSCAPE", canvas=true, closed=scene_window_closed})
scene_window_draw :: proc(w: ^wnd.Window) {
	_sv = _scene_window(w)
	defer _sv = _scene_active()
	{
		if _sv.pending_2d {
			_sv.pending_2d = false
			scene_set_2d(true)
		}
		_scene_camera_follow_scene()

		// Docked toolbar strips take their space first; the image gets what
		// is left, so a strip sits beside the render instead of over it.
		overlays_measure_bars()
		bar_l, bar_r, bar_t, bar_b := overlay_bar_insets()
		content_min := im.GetCursorScreenPos()
		avail := im.GetContentRegionAvail()
		content_max := content_min + avail
		avail.x = max(avail.x - bar_l - bar_r, 0)
		avail.y = max(avail.y - bar_t - bar_b, 0)
		rw := i32(avail.x)
		rh := i32(avail.y)

		_sv.drawn_frame = gfx.frame_index
		_sv.want_size = {rw, rh}
		if rw > 0 && rh > 0 {
			// Rendered already this frame when it is a copy in a frame.
			if _sv.rendered_frame != gfx.frame_index do render_scene_rt(rw, rh)
			tex_id := im.TextureID(uintptr(gfx.rt_imgui_id(_sv.rt)))
			im.SetCursorScreenPos({content_min.x + bar_l, content_min.y + bar_t})
			im.Image(im.TextureRef{_TexID = tex_id}, avail)
			_sv.img_min = im.GetItemRectMin()
			_scene_drop_target()
			// Gizmo labels (anchor percentages and such) over the image,
			// shadowed so they read on any background.
			dl := im.GetWindowDrawList()
			for l in gizmos.labels(gizmos.scene_gizmo_channels()) {
				px, ok := gizmos.helper_project_in(_sv.view_last, l.pos)
				if !ok do continue
				_draw_handle_label(dl, _sv.img_min + px + l.offset_px, l)
			}
			overlays_draw(_sv.img_min, _sv.img_min + avail, content_min, content_max)
		}

		_scene_nudge_frame()
		_sv.hovered = im.IsWindowHovered({})
		// Flythrough is hover-independent once latched: the captured cursor
		// is pinned, so hover can't be trusted mid-flight.
		if _sv.hovered || _sv.flythrough_active {
			handle_scene_input()
		}
		// Band tracking is hover-independent: the drag keeps working when the
		// cursor leaves the image, like orbit/gizmo drags.
		if _sv.band_active {
			_update_rubber_band()
		}
		_draw_fly_speed_readout()
		_draw_pick_menu()
		_draw_scene_context_menu()
	}
}

// --- Scene camera preferences ------------------------------------------------------
// How the Scene window's camera sees and flies, the same in every copy and
// every scene: the Camera overlay's popup edits them, and they are saved with
// the editor's settings.

Scene_Camera_Prefs :: struct {
	fov:       f32, // the perspective view's vertical field of view, degrees
	fly_speed: f32, // units per second while flying, before the ramp and Shift
	look:      f32, // how far a pixel of mouse travel turns the camera, 1 = the default
}

SCENE_CAMERA_DEFAULTS :: Scene_Camera_Prefs{fov = SCENE_CAM_FOV_DEG, fly_speed = FLYTHROUGH_BASE_SPEED, look = 1}

scene_camera_prefs := SCENE_CAMERA_DEFAULTS

FLY_SPEED_MIN :: f32(0.5)
FLY_SPEED_MAX :: f32(100)

// How long the fly speed shows after the wheel changed it, seconds.
FLY_SPEED_READOUT_TIME :: 1.5

// Camera overlay: a button that opens the camera's preferences.
@(scene_overlay={id="Camera", order=300})
draw_camera_overlay :: proc(vertical: bool) {
	if overlay_tool_button(icons.ICON_MD_VIDEOCAM, "Scene camera: field of view, fly speed, look sensitivity", false) do im.OpenPopup("##scene_camera_prefs")
	if im.BeginPopup("##scene_camera_prefs") {
		p := &scene_camera_prefs
		im.SeparatorText("Scene Camera")
		im.SetNextItemWidth(110)
		inspector.drag_float("Field of view", &p.fov, 0.5, 10, 120, "%.0f")
		widgets.tooltip("The perspective view's vertical field of view, in degrees")
		im.SetNextItemWidth(110)
		inspector.drag_float("Fly speed", &p.fly_speed, 0.1, FLY_SPEED_MIN, FLY_SPEED_MAX, "%.1f")
		widgets.tooltip("Units per second while flying (right mouse button and WASD). The wheel changes it while flying")
		im.SetNextItemWidth(110)
		inspector.drag_float("Look sensitivity", &p.look, 0.01, 0.1, 5, "%.2f")
		widgets.tooltip("How far the mouse turns the camera, 1 is the default")
		p.fov = clamp(p.fov, 10, 120)
		p.fly_speed = clamp(p.fly_speed, FLY_SPEED_MIN, FLY_SPEED_MAX)
		p.look = clamp(p.look, 0.1, 5)
		if im.Button("Reset") do p^ = SCENE_CAMERA_DEFAULTS
		im.EndPopup()
	}
}

// The fly speed, at the bottom of the image for a moment after the wheel
// changed it: the wheel gives no other sign of what it did.
@(private = "file")
_draw_fly_speed_readout :: proc() {
	if _sv.speed_shown_at == {} || time.duration_seconds(time.tick_since(_sv.speed_shown_at)) > FLY_SPEED_READOUT_TIME do return
	text := fmt.ctprintf("Fly speed %.1f", scene_camera_prefs.fly_speed)
	size := im.CalcTextSize(text)
	pad := im.GetStyle().FramePadding
	center := im.Vec2{_sv.img_min.x + f32(_sv.rt.width) * 0.5, _sv.img_min.y + f32(_sv.rt.height) - size.y - pad.y * 2 - 12}
	lo := im.Vec2{center.x - size.x * 0.5 - pad.x, center.y - pad.y}
	hi := im.Vec2{center.x + size.x * 0.5 + pad.x, center.y + size.y + pad.y}
	dl := im.GetWindowDrawList()
	im.DrawList_AddRectFilled(dl, lo, hi, im.GetColorU32ImVec4({0, 0, 0, 0.6}), 4)
	im.DrawList_AddText(dl, {center.x - size.x * 0.5, center.y}, im.GetColorU32ImVec4(im.GetStyleColorVec4(.Text)^), text)
}

// --- The camera per scene ----------------------------------------------------------
// Where the Scene window looked at each scene, by the scene's guid, kept per
// developer while the scene exists (core.Per_Asset). Every copy takes the
// saved camera when the active scene changes, and the copy last used keeps
// it saved. A scene never saved has no guid and keeps nothing.

Scene_Camera :: struct {
	pos:          [3]f32,
	yaw:          f32,
	pitch:        f32,
	dist:         f32,
	ortho:        bool,
	mode_2d:      bool,
	pre_2d_yaw:   f32,
	pre_2d_pitch: f32,
	pre_2d_ortho: bool,
}

@(user_settings={name="Scene Cameras"})
scene_cameras: core.Per_Asset(Scene_Camera)

// The active scene's guid, {} with none or one never saved.
@(private = "file")
_active_scene_guid :: proc() -> core.Asset_GUID {
	path, ok := session.document_active_path()
	if !ok do return {}
	guid, known := assets.asset_db_get_guid(path)
	return known ? core.Asset_GUID(guid) : {}
}

@(private = "file")
_scene_camera_follow_scene :: proc() {
	guid := _active_scene_guid()
	if guid != _sv.cam_scene {
		_sv.cam_scene = guid
		if c := core.per_asset_get(&scene_cameras, guid); c != nil {
			_sv.cam_pos, _sv.cam_yaw, _sv.cam_pitch, _sv.cam_dist = c.pos, c.yaw, c.pitch, c.dist
			_sv.cam_ortho, _sv.mode_2d = c.ortho, c.mode_2d
			_sv.pre_2d_yaw, _sv.pre_2d_pitch, _sv.pre_2d_ortho = c.pre_2d_yaw, c.pre_2d_pitch, c.pre_2d_ortho
			update_scene_camera()
		}
		return
	}
	if guid == {} || _sv != _scene_active() do return
	now := Scene_Camera{
		pos = _sv.cam_pos, yaw = _sv.cam_yaw, pitch = _sv.cam_pitch, dist = _sv.cam_dist,
		ortho = _sv.cam_ortho, mode_2d = _sv.mode_2d,
		pre_2d_yaw = _sv.pre_2d_yaw, pre_2d_pitch = _sv.pre_2d_pitch, pre_2d_ortho = _sv.pre_2d_ortho,
	}
	if saved := core.per_asset_entry(&scene_cameras, guid); saved^ != now do saved^ = now
}

// --- Drop ------------------------------------------------------------------------------
// The image is a drop target (moonhug/editor/drag): a drag's items go to the
// rules for the Scene view, at the pointer's pixel, with the grid point as
// the place over empty space.

// Right after the image: the image as the drop target.
@(private = "file")
_scene_drop_target :: proc() {
	if drag.items() == nil || !im.BeginDragDropTarget() do return
	defer im.EndDragDropTarget()
	mp := im.GetMousePos()
	px, py := mp.x - _sv.img_min.x, mp.y - _sv.img_min.y
	view := scene_render_view(f32(_sv.rt.width), f32(_sv.rt.height))
	drag.target(drag.Scene_Place{view = view, px = px, py = py, fallback = scene_drop_fallback(view, px, py)})
}

// Where a drop over empty space puts the object: where the pointer's ray
// meets the grid plane (XY in the 2D view, else the first plane the grid
// shows, XZ when it shows none), and when it meets it behind the camera or
// far off, the point of the ray nearest the camera's anchor.
scene_drop_fallback :: proc(view: core.Render_View, px, py: f32) -> [3]f32 {
	ray := core.render_view_screen_ray(view, px, py)
	anchor := ray.origin + ray.direction * linalg.dot(_sv.cam_target - ray.origin, ray.direction)
	gs := grid_settings
	normal := [3]f32{0, 1, 0}
	if _sv.mode_2d || !gs.show_xz && gs.show_xy {
		normal = {0, 0, 1}
	} else if !gs.show_xz && gs.show_yz {
		normal = {1, 0, 0}
	}
	facing := linalg.dot(ray.direction, normal)
	if abs(facing) < 1e-4 do return anchor
	t := -linalg.dot(ray.origin, normal) / facing
	hit := ray.origin + ray.direction * t
	if t < 0 || linalg.length(hit - anchor) > 100 * max(_sv.cam_dist, 1) do return anchor
	return hit
}

// --- Context menu ----------------------------------------------------------------------
// A right-click opens the object's menu, the hierarchy row's own (the Edit
// selection band and the GameObject bands, every registered item), and
// selects the object first unless it is already in the selection. On empty
// space it opens the hierarchy background's menu: create and view items.

// Pointer travel, in pixels, under which a right-click still counts as a
// click and not a look.
CONTEXT_CLICK_SLOP_PX :: f32(3)

@(private = "file")
_scene_context_menu_open :: proc(view: core.Render_View, px, py: f32) {
	tH, hit := viewport.pick(view, px, py)
	_sv.ctx_menu_target = tH if hit else {}
	// Where an object made from the menu goes: the surface under the
	// pointer, else the grid plane, as a drop does.
	if point, on_surface := viewport.surface_point(view, px, py); on_surface {
		_sv.ctx_menu_point = point
	} else {
		_sv.ctx_menu_point = scene_drop_fallback(view, px, py)
	}
	if hit && !sel_scene_is(tH) do core.inspector_request_select(tH)
	im.OpenPopup("##scene_context_menu")
}

@(private = "file")
_draw_scene_context_menu :: proc() {
	viewport.create_place_tick()
	if !im.BeginPopup("##scene_context_menu") do return
	defer im.EndPopup()
	viewport.create_place_offer(_sv.ctx_menu_point)
	if _, alive := inspector.object_owner_of(core.Handle(_sv.ctx_menu_target)); _sv.ctx_menu_target != {} && alive {
		menu.draw_menu_sections({
			menu.section("Edit", min_order = menu.EDIT_SECTION_SELECTION_MIN, max_order = menu.EDIT_SECTION_SELECTION_MAX),
			menu.section("GameObject", max_order = menu.GO_SECTION_PARENTING - 1),
			menu.section("GameObject", min_order = menu.GO_SECTION_VIEW),
		})
	} else {
		menu.draw_menu_sections({
			menu.section("GameObject", max_order = menu.GO_SECTION_PARENTING - 1),
			menu.section("GameObject", min_order = menu.GO_SECTION_VIEW),
		})
	}
}

// --- Pick menu -----------------------------------------------------------------------
// Cmd (Ctrl) + right-click lists every object under the pointer, nearest
// first, and a row selects it: the way to reach an object a nearer one
// covers. The list is taken at the click, so it stays put while the menu is
// open.

@(private = "file")
_pick_menu_open :: proc(view: core.Render_View, px, py: f32) {
	if _sv.pick_menu == nil do _sv.pick_menu = make([dynamic]core.Transform_Handle, runtime.default_allocator())
	clear(&_sv.pick_menu)
	for h in viewport.pick_all(view, px, py) do append(&_sv.pick_menu, h)
	if len(_sv.pick_menu) > 0 do im.OpenPopup("##scene_pick_menu")
}

@(private = "file")
_draw_pick_menu :: proc() {
	if !im.BeginPopup("##scene_pick_menu") do return
	for h in _sv.pick_menu {
		if _, alive := inspector.object_owner_of(core.Handle(h)); !alive do continue // gone since the click
		im.PushIDInt(i32(h.index))
		if im.MenuItem(strings.clone_to_cstring(inspector.object_name(h), context.temp_allocator)) {
			core.inspector_request_select(h)
		}
		im.PopID()
	}
	im.EndPopup()
}

_update_rubber_band :: proc() {
	if !im.IsMouseDown(.Left) {
		_sv.band_active = false // released: the tracker records the final set
		return
	}
	mp := im.GetMousePos()
	rmin := im.Vec2{min(mp.x, _sv.band_anchor.x), min(mp.y, _sv.band_anchor.y)}
	rmax := im.Vec2{max(mp.x, _sv.band_anchor.x), max(mp.y, _sv.band_anchor.y)}

	if _sv.rt != nil {
		view := scene_render_view(f32(_sv.rt.width), f32(_sv.rt.height))
		vmin := [2]f32{rmin.x - _sv.img_min.x, rmin.y - _sv.img_min.y}
		vmax := [2]f32{rmax.x - _sv.img_min.x, rmax.y - _sv.img_min.y}
		hits := viewport.band_query(view, vmin, vmax)
		sel_scene_clear()
		if _sv.band_additive {
			for h in _sv.band_base do sel_scene_add(h)
		}
		for h in hits do sel_scene_add(h)
	}

	dl := im.GetWindowDrawList()
	im.DrawList_AddRectFilled(dl, rmin, rmax, im.GetColorU32ImVec4(im.Vec4{0.35, 0.55, 1, 0.12}))
	im.DrawList_AddRect(dl, rmin, rmax, im.GetColorU32ImVec4(im.Vec4{0.5, 0.7, 1, 0.9}))
}

// Unity-style Tools overlay item (dockable, dock.odin): gizmo mode
// toggles. Q/W/E/R shortcuts live in handle_scene_input (guarded against
// flythrough's WASD). Widgets set their own tooltips, so no attribute tooltip.
@(scene_overlay={id="Tools", order=0})
draw_tools_overlay :: proc(vertical: bool) {
	mode_button :: proc(icon: cstring, tooltip: cstring, mode: viewport.Gizmo_Mode, vertical: bool, first := false) {
		if !vertical && !first do im.SameLine()
		if overlay_tool_button(icon, tooltip, viewport.gizmo_mode == mode) {
			viewport.gizmo_mode = mode
		}
	}
	// The tooltips carry the live chord of each tool's command.
	mode_button(icons.ICON_MD_ARROW_SELECTOR, keymap.labelled("Picker", "Scene/Picker Tool"), .Picker, vertical, first = true)
	mode_button(icons.ICON_MD_OPEN_WITH, keymap.labelled("Move", "Scene/Translate Tool"), .Translate, vertical)
	mode_button(icons.ICON_MD_ROTATE_RIGHT, keymap.labelled("Rotate", "Scene/Rotate Tool"), .Rotate, vertical)
	mode_button(icons.ICON_MD_OPEN_IN_FULL, keymap.labelled("Scale", "Scene/Scale Tool"), .Scale, vertical)
	mode_button(icons.ICON_MD_CROP_FREE, keymap.labelled("Handles: the selection's own handles, like the rect tool", "Scene/Handles Tool"), .Handles, vertical)
	mode_button(icons.ICON_MD_STRAIGHTEN, keymap.labelled("Measure: drag from one point to another, in pixels on a canvas", "Scene/Measure Tool"), .Measure, vertical)
}

// View overlay: Unity's 2D toggle.
@(scene_overlay={id="View", order=50})
draw_view_overlay :: proc(vertical: bool) {
	if overlay_tool_button("2D", "2D view: orthographic, looking along -Z, no orbit (right or middle drag pans)", _sv.mode_2d, width = vertical ? OVERLAY_SPLIT_WIDTH : 0) {
		scene_set_2d(!_sv.mode_2d)
	}
}

// Shading overlay: the Scene window's draw mode (core.View_Mode), Unity's
// shading dropdown. Shaded is the game's look, the rest are debug views.
@(scene_overlay={id="View", order=60})
draw_shading_overlay :: proc(vertical: bool) {
	labels := [core.View_Mode]cstring{
		.Shaded    = "Shaded",
		.Wireframe = "Wireframe",
		.Unlit     = "Unlit",
		.Normals   = "Normals",
		.Overdraw  = "Overdraw",
	}
	if !vertical do im.SameLine()
	im.SetNextItemWidth(vertical ? OVERLAY_SPLIT_WIDTH : 100)
	if im.BeginCombo("##shading", labels[_sv.view_mode]) {
		for mode in core.View_Mode {
			if im.Selectable(labels[mode], mode == _sv.view_mode) do _sv.view_mode = mode
		}
		im.EndCombo()
	}
	widgets.tooltip("Shading mode: how the Scene window draws every surface. Shaded is the game's look, the others are debug views")
}

// Pivot mini-overlay: Unity's Global/Local gizmo orientation switch — a single
// icon+word button that flips the space on click. Scale always stays local
// (see Gizmo_Space).
@(scene_overlay={id="Pivot", order=100})
draw_pivot_overlay :: proc(vertical: bool) {
	// Unity's Pivot/Center toggle: gizmo at the active object's pivot vs the
	// center of the selection.
	// Vertical dock: icon-only square buttons (the words won't fit the column).
	pivot_label: cstring
	if vertical {
		pivot_label = viewport.gizmo_prefs.pivot == .Pivot ? icons.ICON_MD_TRIP_ORIGIN : icons.ICON_MD_CENTER_FOCUS
	} else {
		pivot_label = viewport.gizmo_prefs.pivot == .Pivot ? icons.ICON_MD_TRIP_ORIGIN + " Pivot" : icons.ICON_MD_CENTER_FOCUS + "Center"
	}
	if overlay_tool_button(pivot_label, "Gizmo position: active object's pivot vs the selection center", false, width = vertical ? OVERLAY_SPLIT_WIDTH : 0) {
		viewport.gizmo_prefs.pivot = viewport.gizmo_prefs.pivot == .Pivot ? .Center : .Pivot
	}

	if !vertical do im.SameLine()
	label: cstring
	if vertical {
		label = viewport.gizmo_prefs.space == .Global ? icons.ICON_MD_PUBLIC : icons.ICON_MD_DEPLOYED_CODE
	} else {
		label = viewport.gizmo_prefs.space == .Global ? icons.ICON_MD_PUBLIC + " World" : icons.ICON_MD_DEPLOYED_CODE + " Local"
	}
	if overlay_tool_button(label, "Gizmo orientation: world axes vs the object's axes (scale is always local)", false, width = vertical ? OVERLAY_SPLIT_WIDTH : 0) {
		viewport.gizmo_prefs.space = viewport.gizmo_prefs.space == .Global ? .Local : .Global
	}
}

// Planes restored when the grid toggle is switched back on after hiding all
// planes. XZ is the sensible fallback if nothing was shown when it was hidden.
_grid_last_planes := Grid_Settings{show_xz = true}

// Grid overlay: a split button. The icon toggles all grid planes on/off; the
// dropdown arrow opens the popup with the plane and spacing settings (see
// Grid_Settings). Button lights up while any plane shows.
@(scene_overlay={id="Grid", order=200})
draw_grid_overlay :: proc(vertical: bool) {
	gs := &grid_settings
	any_plane := gs.show_xz || gs.show_xy || gs.show_yz
	toggled, arrow := overlay_split_button("grid", icons.ICON_MD_GRID_ON, "Toggle grid", any_plane)
	if toggled {
		if any_plane {
			_grid_last_planes = gs^ // remember which planes were showing
			gs.show_xz, gs.show_xy, gs.show_yz = false, false, false
		} else {
			gs.show_xz = _grid_last_planes.show_xz
			gs.show_xy = _grid_last_planes.show_xy
			gs.show_yz = _grid_last_planes.show_yz
			if !(gs.show_xz || gs.show_xy || gs.show_yz) do gs.show_xz = true
		}
	}
	if arrow do im.OpenPopup("##grid_settings")
	if im.BeginPopup("##grid_settings") {
		im.SeparatorText("Planes")
		im.Checkbox("XZ", &gs.show_xz)
		im.SameLine()
		im.Checkbox("XY", &gs.show_xy)
		im.SameLine()
		im.Checkbox("YZ", &gs.show_yz)

		im.SeparatorText("Cells")
		im.SetNextItemWidth(110)
		inspector.drag_float("Cell size", &gs.cell_size, 0.5, 0.01, 10000, "%.2f")
		widgets.tooltip("One cell in world units (emphasized lines)")
		im.SetNextItemWidth(110)
		inspector.drag_int("Subdivide", &gs.subdivide, 1, 1, 100)
		widgets.tooltip("Fine-line divisions inside each cell (1 = none)")
		im.SetNextItemWidth(110)
		inspector.drag_int("Cells count", &gs.cells_count, 1, 1, 1000)
		widgets.tooltip("Cells from the center to the grid's edge")
		im.EndPopup()
	}
}

// Snap split button next to the grid button. The icon toggles snapping on/off;
// the dropdown arrow opens the snap settings popup. Button lights up while
// snapping is enabled; Ctrl inverts enabled during a drag.
@(scene_overlay={id="Grid", order=210})
draw_snap_overlay :: proc(vertical: bool) {
	if !vertical do im.SameLine()
	toggled, arrow := overlay_split_button("snap", icons.ICON_MD_SNAP, "Toggle snap (hold Ctrl / Cmd on mac to invert while dragging)", snap_settings.enabled)
	if toggled do snap_settings.enabled = !snap_settings.enabled
	if arrow do im.OpenPopup("##snap_settings")
	if im.BeginPopup("##snap_settings") {
		ss := &snap_settings
		im.SetNextItemWidth(110)
		inspector.drag_float("Angle", &ss.angle, 1, 1, 180, "%.0f deg")
		widgets.tooltip("Rotate gizmo snap increment")

		mode_names := [Snap_Mode]cstring{.Grid = "Grid", .SubGrid = "SubGrid", .Units = "Units"}
		im.SetNextItemWidth(110)
		if im.BeginCombo("Move step", mode_names[ss.mode], {}) {
			for m in Snap_Mode {
				if im.Selectable(mode_names[m], ss.mode == m) do ss.mode = m
			}
			im.EndCombo()
		}
		widgets.tooltip("Grid = one cell, SubGrid = one subdivision, Units = custom step")
		if ss.mode == .Units {
			im.SetNextItemWidth(110)
			inspector.drag_float("Value", &ss.units, 0.1, 0.01, 10000, "%.2f")
			if ss.units <= 0 do ss.units = 0.01
		}
		im.EndPopup()
	}
}

// One frame of flythrough movement: the velocity eases toward `target_vel`
// (FLY_MOVE_SMOOTH_TAU) and the camera moves by the eased velocity, over at
// most FLY_MAX_DT.
scene_fly_move_step :: proc(vel, target_vel: [3]f32, dt: f32) -> (new_vel, step: [3]f32) {
	dt := min(dt, FLY_MAX_DT)
	k := 1 - math.exp(-dt / FLY_MOVE_SMOOTH_TAU)
	new_vel = vel + (target_vel - vel) * k
	return new_vel, new_vel * dt
}

handle_scene_input :: proc() {
	io := im.GetIO()
	dt := io.DeltaTime
	alt_down := io.KeyAlt

	rmb_down := im.IsMouseDown(.Right)
	rmb_dragging := im.IsMouseDragging(.Right, 1)
	mmb_dragging := im.IsMouseDragging(.Middle, 1)
	lmb_dragging := im.IsMouseDragging(.Left, 1)
	cmd := io.KeyCtrl || io.KeySuper

	// Cmd (Ctrl) + right-click: the pick menu, every object under the
	// pointer. It takes the click from the flythrough.
	if cmd && im.IsMouseClicked(.Right) && !alt_down && !overlay_wants_mouse() && _sv.rt != nil {
		mp := im.GetMousePos()
		view := scene_render_view(f32(_sv.rt.width), f32(_sv.rt.height))
		_pick_menu_open(view, mp.x - _sv.img_min.x, mp.y - _sv.img_min.y)
	}

	// A right-click that neither turns, flies nor pans the camera opens the
	// context menu when the button comes up. The flythrough still starts on
	// the press: moving the mouse or the camera drops the menu.
	if im.IsMouseClicked(.Right) && !cmd && !alt_down && !overlay_wants_mouse() && _sv.rt != nil {
		mp := im.GetMousePos()
		_sv.ctx_click_pos = {mp.x - _sv.img_min.x, mp.y - _sv.img_min.y}
		_sv.ctx_click_travel = 0
		_sv.ctx_click_pending = _sv.ctx_click_pos.x >= 0 && _sv.ctx_click_pos.y >= 0 && _sv.ctx_click_pos.x < f32(_sv.rt.width) && _sv.ctx_click_pos.y < f32(_sv.rt.height)
	}
	if _sv.ctx_click_pending && (rmb_dragging || alt_down || cmd) do _sv.ctx_click_pending = false
	if _sv.ctx_click_pending && im.IsMouseReleased(.Right) {
		_sv.ctx_click_pending = false
		if _sv.rt != nil {
			view := scene_render_view(f32(_sv.rt.width), f32(_sv.rt.height))
			_scene_context_menu_open(view, _sv.ctx_click_pos.x, _sv.ctx_click_pos.y)
		}
	}

	// Flythrough latches on entry (RMB pressed over the window) and holds until
	// RMB releases. Relative mouse mode hides and PINS the cursor while SDL
	// keeps streaming raw deltas — without it the visible cursor stalls the
	// rotation at every screen edge and drops the camera whenever it drifts
	// off the window (the "jaggy flythrough" bug).
	if _sv.flythrough_active && (!rmb_down || alt_down) {
		_sv.flythrough_active = false
		input.set_mouse_relative(false)
		if km := keymap.find("Scene Flythrough"); km != nil do keymap.pop(km)
	}
	if !_sv.flythrough_active && rmb_down && !alt_down && !cmd && _sv.hovered && !_sv.mode_2d {
		_sv.flythrough_active = true
		input.set_mouse_relative(true)
		// The flythrough's keymap on top: its keys alone resolve while the
		// camera flies (editor/keymap).
		if km := keymap.find("Scene Flythrough"); km != nil do keymap.push(km)
		// Smoothing state starts at rest so entry doesn't inherit stale lag.
		_sv.fly_yaw_target = _sv.cam_yaw
		_sv.fly_pitch_target = _sv.cam_pitch
		_sv.fly_vel = {0, 0, 0}
	}

	// Any manual camera input takes over from an in-flight frame tween.
	if rmb_down || mmb_dragging || (alt_down && lmb_dragging) || io.MouseWheel != 0 {
		_sv.tween_active = false
	}

	// Fly camera FIRST and returns: while captured, the shortcut/pick/band
	// handling below must not react to the pinned cursor (and this proc runs
	// un-hovered while latched).
	if _sv.flythrough_active {
		_sv.orbit_active = false
		// The full frame rate while flying: holding the button still sends
		// no input, and the idle rate's long frames would make the first key
		// press a jump.
		gfx.keep_awake(0.25)
		dt := min(dt, FLY_MAX_DT)

		// First-person look — all reads below go through the input package
		// (raw SDL snapshot): imgui derives its mouse delta from the cursor
		// position, which relative mode pins.
		// Mouse moves the TARGET; the camera exponentially chases it, which
		// smooths sensor jitter into a short, frame-rate-independent glide.
		delta := input.mouse_delta()
		// The pointer moved or the camera flew: the right-click is a look,
		// not a click for the context menu.
		_sv.ctx_click_travel += abs(delta.x) + abs(delta.y)
		if _sv.ctx_click_travel > CONTEXT_CLICK_SLOP_PX || input.wheel() != 0 do _sv.ctx_click_pending = false
		_sv.fly_yaw_target += delta.x * LOOK_SENSITIVITY * scene_camera_prefs.look
		_sv.fly_pitch_target = clamp(_sv.fly_pitch_target - delta.y * LOOK_SENSITIVITY * scene_camera_prefs.look, -PITCH_LIMIT, PITCH_LIMIT)
		look_k := 1 - math.exp(-dt / FLY_LOOK_SMOOTH_TAU)
		_sv.cam_yaw += (_sv.fly_yaw_target - _sv.cam_yaw) * look_k
		_sv.cam_pitch = clamp(_sv.cam_pitch + (_sv.fly_pitch_target - _sv.cam_pitch) * look_k, -PITCH_LIMIT, PITCH_LIMIT)

		// Wheel during fly rescales the base speed for the session (Unity).
		if wheel := input.wheel(); wheel != 0 {
			scene_camera_prefs.fly_speed = clamp(scene_camera_prefs.fly_speed * math.pow(FLY_SPEED_WHEEL_BASE, wheel), FLY_SPEED_MIN, FLY_SPEED_MAX)
			_sv.speed_shown_at = time.tick_now()
			_sv.fly_speed_cur = min(_sv.fly_speed_cur, scene_camera_prefs.fly_speed * FLYTHROUGH_RAMP_MULT)
		}

		// The movement keys came through the "Scene Flythrough" keymap
		// before this draw (scene_fly_* commands).
		move := _sv.fly_move
		fast := _sv.fly_fast
		_sv.fly_move = {}
		_sv.fly_fast = false
		if move != {} do _sv.ctx_click_pending = false

		// Target velocity from the keys; the smoothed velocity chases it so
		// starts, stops, and direction changes ease instead of stepping.
		target_vel: [3]f32
		len := linalg.length(move)
		if len > 0 {
			// Held movement ramps toward the cap, so short taps stay precise
			// and long hauls get fast. Release resets to base.
			_sv.fly_speed_cur = min(
				_sv.fly_speed_cur + scene_camera_prefs.fly_speed * (FLYTHROUGH_RAMP_MULT - 1) / FLYTHROUGH_RAMP_TIME * dt,
				scene_camera_prefs.fly_speed * FLYTHROUGH_RAMP_MULT,
			)
			speed := _sv.fly_speed_cur
			if fast do speed *= FLYTHROUGH_SHIFT_MULT
			target_vel = move / len * speed
		} else {
			_sv.fly_speed_cur = scene_camera_prefs.fly_speed
		}
		step: [3]f32
		_sv.fly_vel, step = scene_fly_move_step(_sv.fly_vel, target_vel, dt)
		_sv.cam_pos += step

		update_scene_camera()
		return
	}
	_sv.fly_speed_cur = scene_camera_prefs.fly_speed

	// The tool keys and Escape are the "Scene Tools" keymap's commands
	// (scene_tool_* and scene_clear_selection below).

	// Click-to-pick: LMB press + release within a few pixels (and no Alt —
	// Alt+LMB orbits; not on the gizmo — grabs must not select-through; and
	// not on an overlay — button clicks must not pick behind them).
	if im.IsMouseClicked(.Left) && !alt_down && !viewport.tools_consume_mouse() && !overlay_wants_mouse() {
		_sv.click_pos = im.GetMousePos()
		_sv.click_pending = true
	}
	if _sv.click_pending && viewport.tools_consume_mouse() {
		_sv.click_pending = false
	}
	// An armed click that travels beyond the click threshold becomes a rubber
	// band (works in every tool mode, Unity-style).
	if _sv.click_pending && !_sv.band_active {
		mp := im.GetMousePos()
		dx := mp.x - _sv.click_pos.x
		dy := mp.y - _sv.click_pos.y
		if dx * dx + dy * dy >= 16 {
			_sv.click_pending = false
			_sv.band_active = true
			_sv.band_anchor = _sv.click_pos
			_sv.band_additive = io.KeyCtrl || io.KeySuper
			clear(&_sv.band_base)
			for h in sel_scene_items() do append(&_sv.band_base, h)
		}
	}
	if _sv.click_pending && im.IsMouseReleased(.Left) {
		_sv.click_pending = false
		mp := im.GetMousePos()
		dx := mp.x - _sv.click_pos.x
		dy := mp.y - _sv.click_pos.y
		if !alt_down && dx * dx + dy * dy < 16 && _sv.rt != nil {
			view := scene_render_view(f32(_sv.rt.width), f32(_sv.rt.height))
			px := mp.x - _sv.img_min.x
			py := mp.y - _sv.img_min.y
			// cmd/ctrl-click toggles the picked object in/out of the
			// selection (no hierarchy reveal); plain click selects only it.
			// Clicking empty space clears — unless toggling, where a miss
			// shouldn't nuke the set being built.
			if tH, hit := viewport.pick(view, px, py); hit {
				if cmd {
					sel_scene_toggle(tH)
				} else {
					core.inspector_request_select(tH)
				}
			} else if !cmd {
				sel_scene_clear()
			}
		}
	}

	if alt_down && lmb_dragging && !_sv.mode_2d {
		// Orbit around the anchor captured when the drag started (Unity's
		// pivot model: F/pan/zoom place it, orbit revolves around it).
		if !_sv.orbit_active {
			_sv.orbit_active = true
			_sv.orbit_pivot = _sv.cam_target
			_sv.cam_dist = max(linalg.length(_sv.cam_pos - _sv.orbit_pivot), 0.1)
		}
		delta := io.MouseDelta
		_sv.cam_yaw += delta.x * LOOK_SENSITIVITY * scene_camera_prefs.look
		_sv.cam_pitch = clamp(_sv.cam_pitch - delta.y * LOOK_SENSITIVITY * scene_camera_prefs.look, -PITCH_LIMIT, PITCH_LIMIT)
		fwd, _, _ := _scene_cam_basis()
		_sv.cam_pos = _sv.orbit_pivot - fwd * _sv.cam_dist
		update_scene_camera()
		return
	}
	_sv.orbit_active = false

	if alt_down && rmb_dragging {
		// Zoom drag: toward and away from the point the drag began on.
		delta := io.MouseDelta
		zoom_delta := (delta.x + delta.y) * ZOOM_DRAG_FACTOR
		_scene_zoom_at(clamp(_sv.cam_dist * (1 - zoom_delta), 0.1, 10000), io.MouseClickedPos[im.MouseButton.Right])
		update_scene_camera()
		return
	}

	// Pan: middle drag, and in 2D also right drag and alt-drag (no orbit there).
	if mmb_dragging || (_sv.mode_2d && _sv.hovered && (rmb_dragging || (alt_down && lmb_dragging))) {
		delta := io.MouseDelta
		_, r, u := _scene_cam_basis()

		// The world height the view shows at the pivot's depth, over its
		// pixels: a point at that depth stays under the cursor at any zoom
		// level and window size, in a perspective and an orthographic view.
		units_per_px := 2 * scene_cam_half_height() / max(f32(_sv.rt.height), 1)
		pan := r * (-delta.x * units_per_px) + u * (delta.y * units_per_px)
		_sv.cam_pos += pan
		update_scene_camera()
		return
	}

	wheel := io.MouseWheel
	if wheel != 0 {
		// Logarithmic dolly toward the point under the pointer, with a
		// minimum absolute step so close-range zoom stays responsive.
		old_dist := _sv.cam_dist
		new_dist := old_dist * math.pow(ZOOM_WHEEL_BASE, -wheel)
		min_step := ZOOM_MIN_STEP * abs(wheel)
		if wheel > 0 && old_dist - new_dist < min_step do new_dist = old_dist - min_step
		if wheel < 0 && new_dist - old_dist < min_step do new_dist = old_dist + min_step
		_scene_zoom_at(clamp(new_dist, 0.1, 10000), io.MousePos)
		update_scene_camera()
	}
}

// Where the view's anchor goes when the distance to it changes from
// `old_dist` to `new_dist` with the pointer at `ndc` (-1 to 1 across the
// picture, y up), so the point of the anchor's plane under the pointer stays
// under it. `right` and `up` are the camera's, `tan_half_fov` and `aspect`
// the view's. The picture's centre keeps the anchor where it is. It holds
// for a perspective and an orthographic view: both show a height of
// distance times tan_half_fov, times two, at the anchor.
scene_zoom_anchor :: proc(anchor, right, up: [3]f32, ndc: [2]f32, old_dist, new_dist, tan_half_fov, aspect: f32) -> [3]f32 {
	shrink := (old_dist - new_dist) * tan_half_fov
	return anchor + right * (ndc.x * aspect * shrink) + up * (ndc.y * shrink)
}

// Sets the current Scene copy's distance to its anchor, zooming toward the
// point under `mouse` (imgui screen coordinates). A pointer off the picture
// zooms toward its nearest edge.
@(private = "file")
_scene_zoom_at :: proc(new_dist: f32, mouse: im.Vec2) {
	fwd, right, up := _scene_cam_basis()
	anchor := _sv.cam_target
	if _sv.rt != nil && _sv.rt.width > 0 && _sv.rt.height > 0 {
		w, h := f32(_sv.rt.width), f32(_sv.rt.height)
		ndc := [2]f32{
			clamp(2 * (mouse.x - _sv.img_min.x) / w - 1, -1, 1),
			clamp(1 - 2 * (mouse.y - _sv.img_min.y) / h, -1, 1),
		}
		anchor = scene_zoom_anchor(anchor, right, up, ndc, _sv.cam_dist, new_dist, math.tan(math.to_radians(scene_camera_prefs.fov) * 0.5), w / h)
	}
	_sv.cam_dist = new_dist
	_sv.cam_pos = anchor - fwd * new_dist
}

// --- Commands and keymaps ----------------------------------------------------
//
// The keymap resolver runs these before the windows draw (editor/keymap). They
// act on the focused Scene instance: the keymaps serve the "Scene" window, so
// the focused window is one of its instances.

@(private = "file")
_scene_focused :: proc() -> ^Scene_Window {
	if w := wnd.focused(); w != nil && w.id == SCENE do return _scene_window(w)
	return _sv
}

@(private = "file")
_scene_tool :: proc(mode: viewport.Gizmo_Mode) {
	viewport.gizmo_mode = mode
}

@(command={name="Scene/Picker Tool", help="Selects objects, with no gizmo"})
scene_tool_picker :: proc() { _scene_tool(.Picker) }
@(command={name="Scene/Translate Tool", help="Moves the selection with the gizmo"})
scene_tool_translate :: proc() { _scene_tool(.Translate) }
@(command={name="Scene/Rotate Tool", help="Rotates the selection with the gizmo"})
scene_tool_rotate :: proc() { _scene_tool(.Rotate) }
@(command={name="Scene/Scale Tool", help="Scales the selection with the gizmo"})
scene_tool_scale :: proc() { _scene_tool(.Scale) }
@(command={name="Scene/Handles Tool", help="Shows the selected components' own handles in place of the gizmo"})
scene_tool_handles :: proc() { _scene_tool(.Handles) }
@(command={name="Scene/Measure Tool", help="Measures the distance between two points with a drag"})
scene_tool_measure :: proc() { _scene_tool(.Measure) }

// Escape drops the selection. During a band it cancels the band and restores
// the pre-band selection instead. Not mid-drag: the drag teardown in
// gizmo_tool_frame would leave its undo step open.
@(command={name="Scene/Clear Selection", enabled=scene_can_clear_selection, help="Deselects everything, or cancels a box selection and restores the one before it"})
scene_clear_selection :: proc() {
	sv := _scene_focused()
	if sv.band_active {
		sv.band_active = false
		sel_scene_clear()
		for h in sv.band_base do sel_scene_add(h)
	} else {
		sel_scene_clear()
	}
	sv.click_pending = false
}

scene_can_clear_selection :: proc() -> bool {
	return !viewport.tools_dragging() || keymap.disabled("A handle is being dragged")
}

// The tool keys are editor-wide: the tool is one for every Scene window, so
// the keys work from the hierarchy or the inspector as well. The flythrough
// keymap below sits on the Scene level and consumes, so it takes them first
// while the camera flies.
@(keymap={name="Scene Tools"})
scene_tools_keymap :: proc(km: ^keymap.Keymap) {
	keymap.bind(km, "Q", "Scene/Picker Tool")
	keymap.bind(km, "W", "Scene/Translate Tool")
	keymap.bind(km, "E", "Scene/Rotate Tool")
	keymap.bind(km, "R", "Scene/Scale Tool")
	keymap.bind(km, "T", "Scene/Handles Tool")
	keymap.bind(km, "M", "Scene/Measure Tool")
}

@(keymap={name="Scene Window", window="Scene"})
scene_window_keymap :: proc(km: ^keymap.Keymap) {
	keymap.bind(km, "F", "Edit/Frame Selected")
	keymap.bind(km, "Escape", "Scene/Clear Selection")
	keymap.bind(km, "Delete", "Edit/Delete")
	keymap.bind(km, "Left", "Scene/Nudge Left", held = true)
	keymap.bind(km, "Right", "Scene/Nudge Right", held = true)
	keymap.bind(km, "Up", "Scene/Nudge Up", held = true)
	keymap.bind(km, "Down", "Scene/Nudge Down", held = true)
}

// The flythrough's keys, held: each adds to the frame's movement, which the
// fly step in handle_scene_input turns into velocity. The keymap is modal,
// so the tool keys above stay quiet while the camera flies.
Fly_Dir :: enum { Forward, Back, Right, Left, Up, Down }

@(private = "file")
_scene_fly :: proc(dir: Fly_Dir) {
	prev := _sv
	_sv = _scene_focused()
	defer _sv = prev
	fwd, right, _ := _scene_cam_basis()
	switch dir {
	case .Forward: _sv.fly_move += fwd
	case .Back:    _sv.fly_move -= fwd
	case .Right:   _sv.fly_move += right
	case .Left:    _sv.fly_move -= right
	case .Up:      _sv.fly_move += {0, 1, 0}
	case .Down:    _sv.fly_move -= {0, 1, 0}
	}
}

@(command={name="Scene/Fly Forward", help="Moves the flying camera forward while held"})
scene_fly_forward :: proc() { _scene_fly(.Forward) }
@(command={name="Scene/Fly Back", help="Moves the flying camera back while held"})
scene_fly_back :: proc() { _scene_fly(.Back) }
@(command={name="Scene/Fly Right", help="Moves the flying camera right while held"})
scene_fly_right :: proc() { _scene_fly(.Right) }
@(command={name="Scene/Fly Left", help="Moves the flying camera left while held"})
scene_fly_left :: proc() { _scene_fly(.Left) }
@(command={name="Scene/Fly Up", help="Moves the flying camera up while held"})
scene_fly_up :: proc() { _scene_fly(.Up) }
@(command={name="Scene/Fly Down", help="Moves the flying camera down while held"})
scene_fly_down :: proc() { _scene_fly(.Down) }
@(command={name="Scene/Fly Fast", help="Makes the flying camera faster while held"})
scene_fly_fast :: proc() { _scene_focused().fly_fast = true }

// --- Nudge ----------------------------------------------------------------------
// The arrow keys move the selection one step along the screen's axes, in an
// orthographic view (2D mode included). A world object's step is the snap
// move step, a UI node's is one canvas unit. Shift moves ten steps. A held
// key repeats, and one hold is one undo step.

NUDGE_SHIFT_STEPS :: 10

@(command={name="Scene/Nudge Left", enabled=scene_can_nudge, help="Moves the selection one step left while held, ten with Shift"})
scene_nudge_left :: proc() { _scene_focused().nudge_dir.x -= 1 }
@(command={name="Scene/Nudge Right", enabled=scene_can_nudge, help="Moves the selection one step right while held, ten with Shift"})
scene_nudge_right :: proc() { _scene_focused().nudge_dir.x += 1 }
@(command={name="Scene/Nudge Up", enabled=scene_can_nudge, help="Moves the selection one step up while held, ten with Shift"})
scene_nudge_up :: proc() { _scene_focused().nudge_dir.y += 1 }
@(command={name="Scene/Nudge Down", enabled=scene_can_nudge, help="Moves the selection one step down while held, ten with Shift"})
scene_nudge_down :: proc() { _scene_focused().nudge_dir.y -= 1 }

scene_can_nudge :: proc() -> bool {
	sv := _scene_focused()
	if !sv.cam_ortho do return keymap.disabled("The view is in perspective")
	if sv.flythrough_active || sv.band_active do return false
	return sel_scene_count() > 0 || keymap.disabled("Nothing is selected")
}

// How many steps this frame of a hold makes: one when the direction starts
// or changes, then one per repeat interval after the repeat delay.
scene_nudge_repeat :: proc(dir, prev: [2]f32, hold_time, next: f32, dt, delay, rate: f32) -> (steps: int, new_time, new_next: f32) {
	if dir == {} do return 0, 0, 0
	if dir != prev do return 1, 0, delay
	new_time, new_next = hold_time + dt, next
	for new_time >= new_next {
		steps += 1
		new_next += max(rate, 0.001)
	}
	return
}

// The current Scene copy's nudge for this frame, from the keys its commands
// collected. Every frame of a hold reaches the provider, a zero move between
// steps: the first frame without one closes the undo step.
@(private = "file")
_scene_nudge_frame :: proc() {
	dir := _sv.nudge_dir
	_sv.nudge_dir = {}
	defer _sv.nudge_prev = dir
	io := im.GetIO()
	steps: int
	steps, _sv.nudge_time, _sv.nudge_next = scene_nudge_repeat(dir, _sv.nudge_prev, _sv.nudge_time, _sv.nudge_next, io.DeltaTime, io.KeyRepeatDelay, io.KeyRepeatRate)
	if dir == {} do return
	if io.KeyShift do steps *= NUDGE_SHIFT_STEPS
	// The view's axes come from sines and cosines: in an axis view they are a
	// world axis up to rounding, and the rounding stays out of the position.
	_, right, up := _scene_cam_basis()
	move := right * dir.x + up * dir.y
	for &c in move do if abs(c) < 1e-5 do c = 0
	viewport.nudge(move * f32(steps), snap_translate_step())
}

// A modal keymap: the flythrough pushes it when the camera starts flying
// and pops it when it stops (handle_scene_input).
@(keymap={name="Scene Flythrough", modal=true})
scene_flythrough_keymap :: proc(km: ^keymap.Keymap) {
	keymap.bind(km, "W", "Scene/Fly Forward", held = true)
	keymap.bind(km, "S", "Scene/Fly Back", held = true)
	keymap.bind(km, "D", "Scene/Fly Right", held = true)
	keymap.bind(km, "A", "Scene/Fly Left", held = true)
	keymap.bind(km, "E", "Scene/Fly Up", held = true)
	keymap.bind(km, "Q", "Scene/Fly Down", held = true)
	keymap.bind(km, "LeftShift", "Scene/Fly Fast", held = true)
	keymap.bind(km, "RightShift", "Scene/Fly Fast", held = true)
	// What the flythrough reads itself, for the status bar's quick help.
	keymap.quick_help_add(km, "Mouse", "Look around")
	keymap.quick_help_add(km, "Wheel", "Change the speed")
	keymap.quick_help_add(km, "Right Mouse", "Release to stop flying")
}
