package editor

import gfx "../engine/gfx"
import input "../engine/input"
import im "moonhug:external/odin-imgui"
import "core:math"
import "core:math/linalg"
import "../engine"

scene_rt: ^gfx.Render_Target

// Editor camera: first-person data (position + yaw/pitch about the EYE), NOT
// a Camera component — the scene view renders through the same engine
// collect/execute path as game cameras. scene_cam_target is derived: the
// look-at anchor scene_cam_dist along the forward ray. Orbit/zoom/frame pull
// toward it; fly and pan carry it along (Unity's pivot model).
scene_cam_pos: [3]f32
scene_cam_yaw: f32   // radians, atan2(fwd.z, fwd.x)
scene_cam_pitch: f32 // radians, asin(fwd.y), clamped just short of the poles
scene_cam_dist: f32
scene_cam_target: [3]f32

// Flythrough speed: wheel while flying rescales the base (kept for the whole
// session), holding movement keys ramps the current speed toward base*mult.
scene_fly_speed: f32
_fly_speed_cur: f32

// Flythrough smoothing: mouse look drives TARGET angles and the camera
// exponentially chases them; movement velocity chases the keyed direction the
// same way. Both use 1-exp(-dt/tau), so the lag feel is frame-rate independent.
_fly_yaw_target: f32
_fly_pitch_target: f32
_fly_vel: [3]f32

_orbit_active: bool
_orbit_pivot: [3]f32

scene_view_hovered: bool
scene_flythrough_active: bool

// Click-to-pick state: a click is press+release under a small drag threshold
// (so orbit/pan drags never select). Set in draw_scene_view / handle_scene_input.
_scene_img_min: im.Vec2
_scene_click_pos: im.Vec2
_scene_click_pending: bool

// Rubber-band box select (Unity): an armed LMB click that travels beyond the
// click threshold becomes a live box select. The selection updates every
// frame while the band is open; the selection-undo tracker pauses
// (scene_band_selecting) so the whole gesture records as ONE "Select" step.
_band_active: bool
_band_anchor: im.Vec2 // screen coords
_band_additive: bool  // cmd/ctrl held at band start: adds to the base set
_band_base: [dynamic]engine.Transform_Handle // selection at band start

scene_band_selecting :: proc() -> bool {
	return _band_active
}

_band_shutdown :: proc() {
	delete(_band_base)
	_band_base = nil
}

FLYTHROUGH_BASE_SPEED :: f32(8.0)
FLYTHROUGH_SHIFT_MULT :: f32(3.0)
FLYTHROUGH_RAMP_MULT :: f32(3.0) // held movement accelerates up to base*this
FLYTHROUGH_RAMP_TIME :: f32(2.0) // seconds to reach the ramp cap
FLY_SPEED_WHEEL_BASE :: f32(1.2) // wheel during fly: speed *= base^notches
FLY_LOOK_SMOOTH_TAU :: f32(0.025) // seconds for look to catch its target (~63%)
FLY_MOVE_SMOOTH_TAU :: f32(0.08) // seconds for velocity to catch its target
LOOK_SENSITIVITY :: f32(0.005) // radians per pixel (fly + orbit)
ZOOM_WHEEL_BASE :: f32(1.2) // wheel dolly: dist *= base^-notches
ZOOM_MIN_STEP :: f32(0.25) // keeps close-range dolly responsive
ZOOM_DRAG_FACTOR :: 0.01

SCENE_CAM_FOV_DEG :: f32(45)
SCENE_CAM_NEAR :: f32(0.1)
SCENE_CAM_FAR :: f32(1000)

init_scene_view :: proc() {
	scene_rt = gfx.rt_create(1, 1)
	scene_fly_speed = FLYTHROUGH_BASE_SPEED
	_fly_speed_cur = FLYTHROUGH_BASE_SPEED
	scene_cam_look_at({7, 7, 7}, {0, 0, 0})

	// Unity-style dockable overlay toolbars (dock.odin): register every
	// @(scene_toolbar) item (generated), then restore persisted placement.
	_register_scene_toolbars()
	overlays_apply_settings()
}

shutdown_scene_view :: proc() {
	gizmo_shutdown()
	_band_shutdown()
	overlays_shutdown()
	gfx.rt_destroy(scene_rt)
	scene_rt = nil
}

// Orthonormal frame from yaw/pitch. The pitch clamp in update_scene_camera
// keeps fwd off the world-up pole, so the crosses never degenerate.
_scene_cam_basis :: proc() -> (fwd, right, up: [3]f32) {
	cp := math.cos(scene_cam_pitch)
	fwd = {math.cos(scene_cam_yaw) * cp, math.sin(scene_cam_pitch), math.sin(scene_cam_yaw) * cp}
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
	scene_cam_pos = pos
	d := target - pos
	scene_cam_dist = linalg.length(d)
	if scene_cam_dist > 0.0001 {
		dir := d / scene_cam_dist
		scene_cam_pitch = math.asin(clamp(dir.y, -1, 1))
		scene_cam_yaw = math.atan2(dir.z, dir.x)
	}
	update_scene_camera()
}

PITCH_LIMIT :: f32(math.PI / 2 - 0.02)

// Clamp the angles and re-derive the look-at anchor from the eye. A NaN/inf
// guard resets the camera instead of leaving the view unrecoverably black
// (bad mesh bounds or a zero-length basis would poison every later frame).
update_scene_camera :: proc() {
	scene_cam_pitch = clamp(scene_cam_pitch, -PITCH_LIMIT, PITCH_LIMIT)
	scene_cam_dist = clamp(scene_cam_dist, 0.1, 10000)

	fwd, _, _ := _scene_cam_basis()
	scene_cam_target = scene_cam_pos + fwd * scene_cam_dist

	ok :: proc(v: [3]f32) -> bool {
		for c in v {
			if c != c || abs(c) > 1e20 do return false
		}
		return true
	}
	if !ok(scene_cam_pos) || !ok(scene_cam_target) || scene_cam_yaw != scene_cam_yaw {
		scene_cam_look_at({7, 7, 7}, {0, 0, 0})
	}
}

// Frame the current selection (Unity's F): center the orbit camera on the
// object's bounds and pull back far enough to fit them in the FOV. The move
// tweens with ease-in/out over SCENE_FRAME_TWEEN_SEC (any manual camera input
// cancels it).
SCENE_FRAME_TWEEN_SEC :: f32(0.2)

_frame_tween_active: bool
_frame_tween_t: f32
_frame_tween_from_target, _frame_tween_to_target: [3]f32
_frame_tween_from_dist, _frame_tween_to_dist: f32

scene_frame_selected :: proc() {
	// Union over ALL selected objects (Unity frames the whole selection).
	w := engine.ctx_world()
	first := true
	cmin, cmax: [3]f32
	for h in sel_scene_items() {
		if !engine.pool_valid(&w.transforms, engine.Handle(h)) do continue
		c, r := _selection_bounds(h)
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
	_frame_tween_from_target = scene_cam_target
	_frame_tween_from_dist = scene_cam_dist
	_frame_tween_to_target = center
	_frame_tween_to_dist = max(radius / math.tan(math.to_radians(SCENE_CAM_FOV_DEG) * 0.5) * 1.2, 1)
	_frame_tween_t = 0
	_frame_tween_active = true
}

_update_frame_tween :: proc(dt: f32) {
	if !_frame_tween_active do return
	_frame_tween_t = min(_frame_tween_t + dt / SCENE_FRAME_TWEEN_SEC, 1)
	t := _frame_tween_t
	k := t * t * (3 - 2 * t) // smoothstep: ease in/out
	// Framing keeps the view direction (Unity's F): the eye rides behind the
	// tweened anchor along the current forward ray.
	tgt := linalg.lerp(_frame_tween_from_target, _frame_tween_to_target, k)
	scene_cam_dist = _frame_tween_from_dist + (_frame_tween_to_dist - _frame_tween_from_dist) * k
	fwd, _, _ := _scene_cam_basis()
	scene_cam_pos = tgt - fwd * scene_cam_dist
	update_scene_camera()
	if _frame_tween_t >= 1 do _frame_tween_active = false
}

// Bounding sphere of the selection: mesh AABB through the world transform,
// sprite quad, or a default radius around the position (mirrors the shapes
// draw_selection_outline draws).
_selection_bounds :: proc(tH: engine.Transform_Handle) -> (center: [3]f32, radius: f32) {
	tw := engine.transform_world(tH)
	center = tw.position
	radius = 1.5

	vmin :: proc(a, b: [3]f32) -> [3]f32 {return {min(a.x, b.x), min(a.y, b.y), min(a.z, b.z)}}
	vmax :: proc(a, b: [3]f32) -> [3]f32 {return {max(a.x, b.x), max(a.y, b.y), max(a.z, b.z)}}

	_, mf := engine.transform_get_comp(tH, engine.MeshFilter)
	if mf != nil && mf.mesh != {} {
		if mesh, ok := engine.mesh_load(mf.mesh, mf.part); ok {
			model := engine.trs_matrix(tw.position, tw.rotation, tw.scale)
			lo, hi := mesh.aabb_min, mesh.aabb_max
			cmin, cmax: [3]f32
			for i in 0 ..< 8 {
				local := [4]f32{
					i & 1 == 0 ? lo.x : hi.x,
					i & 2 == 0 ? lo.y : hi.y,
					i & 4 == 0 ? lo.z : hi.z,
					1,
				}
				p := (model * local).xyz
				cmin = i == 0 ? p : vmin(cmin, p)
				cmax = i == 0 ? p : vmax(cmax, p)
			}
			center = (cmin + cmax) * 0.5
			radius = max(linalg.length(cmax - cmin) * 0.5, 0.1)
			return
		}
	}

	_, sr := engine.transform_get_comp(tH, engine.SpriteRenderer)
	if sr != nil && sr.texture != {} {
		if tex, ok := engine.texture_load(sr.texture); ok {
			c := engine.sprite_world_corners(tw, tex.width, tex.height)
			cmin := vmin(vmin(c[0], c[1]), vmin(c[2], c[3]))
			cmax := vmax(vmax(c[0], c[1]), vmax(c[2], c[3]))
			center = (cmin + cmax) * 0.5
			radius = max(linalg.length(cmax - cmin) * 0.5, 0.1)
			return
		}
	}
	return
}

// The scene view's Render_View — also the basis for picking rays later.
scene_render_view :: proc(w, h: f32) -> engine.Render_View {
	view := linalg.matrix4_look_at_f32(scene_cam_pos, scene_cam_target, {0, 1, 0})
	proj := gfx.matrix4_perspective_z01(math.to_radians(SCENE_CAM_FOV_DEG), w / max(h, 1), SCENE_CAM_NEAR, SCENE_CAM_FAR)
	return engine.render_view_make(view, proj, w, h, ~u32(0)) // editor sees all layers
}

render_scene_rt :: proc(w, h: i32) {
	if w < 1 || h < 1 do return
	gfx.rt_resize(scene_rt, w, h)

	gfx.pass_begin_target(scene_rt, [4]f32{0.15, 0.15, 0.15, 1})
	view := scene_render_view(f32(w), f32(h))
	gfx.set_view_proj(view.view_proj, view.cam_pos)
	draw_grid()
	draw_axis_lines()

	commands := make([dynamic]engine.Render_Command, 0, 64, context.temp_allocator)
	engine.render_collect_commands(view, &commands)
	engine.render_execute(view, commands[:])

	// @(on_draw_gizmos) / @(on_draw_gizmos_selected) hooks (generated dispatcher) —
	// the pass is open, so procs draw with the gfx line API like the grid.
	__draw_gizmos()

	// Selection visuals + gizmo (overlay lines, drawn last). Every selected
	// object gets an outline; the gizmo anchors on the ACTIVE object (or the
	// selection center — gizmo_pivot) and drags apply to every selected
	// top-level object. It handles its own mouse interaction, in the same
	// pixel space as picking.
	sel_scene_prune()
	for h in sel_scene_items() {
		draw_selection_outline(h)
	}
	sel := sel_scene_active()
	if sel != _HANDLE_NONE {
		mp := im.GetMousePos()
		gizmo_draw_and_handle(sel, view, mp.x - _scene_img_min.x, mp.y - _scene_img_min.y)
	} else {
		_gizmo_hot_axis = -1
		gizmo_end_drag_if_any()
	}
	gfx.pass_end()
}

// Unity-orange wireframe on the selected object: mesh → its local AABB edges
// through the world transform; sprite → its exact world quad; neither → a
// small axis cross at the position.
draw_selection_outline :: proc(tH: engine.Transform_Handle) {
	ORANGE :: [4]f32{1, 0.6, 0.1, 1}
	tw := engine.transform_world(tH)

	_, mf := engine.transform_get_comp(tH, engine.MeshFilter)
	if mf != nil && mf.mesh != {} {
		if mesh, ok := engine.mesh_load(mf.mesh, mf.part); ok {
			model := engine.trs_matrix(tw.position, tw.rotation, tw.scale)
			lo, hi := mesh.aabb_min, mesh.aabb_max
			corners: [8][3]f32
			for i in 0 ..< 8 {
				local := [4]f32{
					i & 1 == 0 ? lo.x : hi.x,
					i & 2 == 0 ? lo.y : hi.y,
					i & 4 == 0 ? lo.z : hi.z,
					1,
				}
				corners[i] = (model * local).xyz
			}
			edges := [12][2]int{
				{0, 1}, {2, 3}, {4, 5}, {6, 7}, // X edges
				{0, 2}, {1, 3}, {4, 6}, {5, 7}, // Y edges
				{0, 4}, {1, 5}, {2, 6}, {3, 7}, // Z edges
			}
			for e in edges {
				gfx.draw_line(corners[e[0]], corners[e[1]], ORANGE)
			}
			return
		}
	}

	_, sr := engine.transform_get_comp(tH, engine.SpriteRenderer)
	if sr != nil && sr.texture != {} {
		if tex, ok := engine.texture_load(sr.texture); ok {
			c := engine.sprite_world_corners(tw, tex.width, tex.height)
			gfx.draw_line(c[0], c[1], ORANGE)
			gfx.draw_line(c[1], c[2], ORANGE)
			gfx.draw_line(c[2], c[3], ORANGE)
			gfx.draw_line(c[3], c[0], ORANGE)
			return
		}
	}

	S :: f32(0.4)
	p := tw.position
	gfx.draw_line(p - {S, 0, 0}, p + {S, 0, 0}, ORANGE)
	gfx.draw_line(p - {0, S, 0}, p + {0, S, 0}, ORANGE)
	gfx.draw_line(p - {0, 0, S}, p + {0, 0, S}, ORANGE)
}

// Scene grid: per-plane toggles + cell layout, edited via the Grid overlay
// toolbar popup (draw_grid_overlay) and persisted in editor_settings.
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

// Gizmo drag snapping (Snap toolbar popup; Ctrl inverts enabled while held).
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

draw_scene_view :: proc() {
	im.PushStyleVarImVec2(.WindowPadding, im.Vec2{0, 0})
	defer im.PopStyleVar()

	if im.Begin("Scene", nil, {.NoCollapse}) {
		_update_frame_tween(im.GetIO().DeltaTime)

		avail := im.GetContentRegionAvail()
		w := i32(avail.x)
		h := i32(avail.y)

		if w > 0 && h > 0 {
			render_scene_rt(w, h)
			tex_id := im.TextureID(uintptr(gfx.rt_imgui_id(scene_rt)))
			im.Image(im.TextureRef{_TexID = tex_id}, avail)
			_scene_img_min = im.GetItemRectMin()
			overlays_draw(_scene_img_min, im.GetItemRectMax())
		}

		scene_view_hovered = im.IsWindowHovered({})
		// Flythrough is hover-independent once latched: the captured cursor
		// is pinned, so hover can't be trusted mid-flight.
		if scene_view_hovered || scene_flythrough_active {
			handle_scene_input()
		}
		// Band tracking is hover-independent: the drag keeps working when the
		// cursor leaves the image, like orbit/gizmo drags.
		if _band_active {
			_update_rubber_band()
		}
	}
	im.End()
}

_update_rubber_band :: proc() {
	if !im.IsMouseDown(.Left) {
		_band_active = false // released: the tracker records the final set
		return
	}
	mp := im.GetMousePos()
	rmin := im.Vec2{min(mp.x, _band_anchor.x), min(mp.y, _band_anchor.y)}
	rmax := im.Vec2{max(mp.x, _band_anchor.x), max(mp.y, _band_anchor.y)}

	if scene_rt != nil {
		view := scene_render_view(f32(scene_rt.width), f32(scene_rt.height))
		vmin := [2]f32{rmin.x - _scene_img_min.x, rmin.y - _scene_img_min.y}
		vmax := [2]f32{rmax.x - _scene_img_min.x, rmax.y - _scene_img_min.y}
		hits := scene_view_band_query(view, vmin, vmax)
		sel_scene_clear()
		if _band_additive {
			for h in _band_base do sel_scene_add(h)
		}
		for h in hits do sel_scene_add(h)
	}

	dl := im.GetWindowDrawList()
	im.DrawList_AddRectFilled(dl, rmin, rmax, im.GetColorU32ImVec4(im.Vec4{0.35, 0.55, 1, 0.12}))
	im.DrawList_AddRect(dl, rmin, rmax, im.GetColorU32ImVec4(im.Vec4{0.5, 0.7, 1, 0.9}))
}

// Unity-style Tools overlay item (dockable toolbar, dock.odin): gizmo mode
// toggles. Q/W/E/R shortcuts live in handle_scene_input (guarded against
// flythrough's WASD). Widgets set their own tooltips, so no attribute tooltip.
@(scene_toolbar={id="Tools", order=0})
draw_tools_overlay :: proc(vertical: bool) {
	mode_button :: proc(icon: cstring, tooltip: cstring, mode: Gizmo_Mode, vertical: bool, first := false) {
		if !vertical && !first do im.SameLine()
		if overlay_tool_button(icon, tooltip, gizmo_mode == mode) {
			gizmo_mode = mode
		}
	}
	mode_button(ICON_MD_ARROW_SELECTOR, "Picker (Q)", .Picker, vertical, first = true)
	mode_button(ICON_MD_OPEN_WITH, "Move (W)", .Translate, vertical)
	mode_button(ICON_MD_ROTATE_RIGHT, "Rotate (E)", .Rotate, vertical)
	mode_button(ICON_MD_OPEN_IN_FULL, "Scale (R)", .Scale, vertical)
}

// Pivot mini-toolbar: Unity's Global/Local gizmo orientation switch — a single
// icon+word button that flips the space on click. Scale always stays local
// (see Gizmo_Space).
@(scene_toolbar={id="Pivot", order=100})
draw_pivot_overlay :: proc(vertical: bool) {
	// Unity's Pivot/Center toggle: gizmo at the active object's pivot vs the
	// center of the selection.
	// Vertical dock: icon-only square buttons (the words won't fit the column).
	pivot_label: cstring
	if vertical {
		pivot_label = gizmo_pivot == .Pivot ? ICON_MD_TRIP_ORIGIN : ICON_MD_CENTER_FOCUS
	} else {
		pivot_label = gizmo_pivot == .Pivot ? ICON_MD_TRIP_ORIGIN + " Pivot" : ICON_MD_CENTER_FOCUS + "Center"
	}
	if overlay_tool_button(pivot_label, "Gizmo position: active object's pivot vs the selection center", false, width = vertical ? OVERLAY_SPLIT_WIDTH : 0) {
		gizmo_pivot = gizmo_pivot == .Pivot ? .Center : .Pivot
	}

	if !vertical do im.SameLine()
	label: cstring
	if vertical {
		label = gizmo_space == .Global ? ICON_MD_PUBLIC : ICON_MD_DEPLOYED_CODE
	} else {
		label = gizmo_space == .Global ? ICON_MD_PUBLIC + " World" : ICON_MD_DEPLOYED_CODE + " Local"
	}
	if overlay_tool_button(label, "Gizmo orientation: world axes vs the object's axes (scale is always local)", false, width = vertical ? OVERLAY_SPLIT_WIDTH : 0) {
		gizmo_space = gizmo_space == .Global ? .Local : .Global
	}
}

// Planes restored when the grid toggle is switched back on after hiding all
// planes. XZ is the sensible fallback if nothing was shown when it was hidden.
_grid_last_planes := Grid_Settings{show_xz = true}

// Grid toolbar: a split button. The icon toggles all grid planes on/off; the
// dropdown arrow opens the popup with the plane and spacing settings (see
// Grid_Settings). Button lights up while any plane shows.
@(scene_toolbar={id="Grid", order=200})
draw_grid_overlay :: proc(vertical: bool) {
	gs := &grid_settings
	any_plane := gs.show_xz || gs.show_xy || gs.show_yz
	toggled, arrow := overlay_split_button("grid", ICON_MD_GRID_ON, "Toggle grid", any_plane)
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
		im.DragFloat("Cell size", &gs.cell_size, 0.5, 0.01, 10000, "%.2f")
		if im.IsItemHovered({}) do im.SetTooltip("One cell in world units (emphasized lines)")
		im.SetNextItemWidth(110)
		im.DragInt("Subdivide", &gs.subdivide, 1, 1, 100)
		if im.IsItemHovered({}) do im.SetTooltip("Fine-line divisions inside each cell (1 = none)")
		im.SetNextItemWidth(110)
		im.DragInt("Cells count", &gs.cells_count, 1, 1, 1000)
		if im.IsItemHovered({}) do im.SetTooltip("Cells from the center to the grid's edge")
		im.EndPopup()
	}
}

// Snap split button next to the grid button. The icon toggles snapping on/off;
// the dropdown arrow opens the snap settings popup. Button lights up while
// snapping is enabled; Ctrl inverts enabled during a drag.
@(scene_toolbar={id="Grid", order=210})
draw_snap_overlay :: proc(vertical: bool) {
	if !vertical do im.SameLine()
	toggled, arrow := overlay_split_button("snap", ICON_MD_SNAP, "Toggle snap (hold Ctrl / Cmd on mac to invert while dragging)", snap_settings.enabled)
	if toggled do snap_settings.enabled = !snap_settings.enabled
	if arrow do im.OpenPopup("##snap_settings")
	if im.BeginPopup("##snap_settings") {
		ss := &snap_settings
		im.SetNextItemWidth(110)
		im.DragFloat("Angle", &ss.angle, 1, 1, 180, "%.0f deg")
		if im.IsItemHovered({}) do im.SetTooltip("Rotate gizmo snap increment")

		mode_names := [Snap_Mode]cstring{.Grid = "Grid", .SubGrid = "SubGrid", .Units = "Units"}
		im.SetNextItemWidth(110)
		if im.BeginCombo("Move step", mode_names[ss.mode], {}) {
			for m in Snap_Mode {
				if im.Selectable(mode_names[m], ss.mode == m) do ss.mode = m
			}
			im.EndCombo()
		}
		if im.IsItemHovered({}) do im.SetTooltip("Grid = one cell, SubGrid = one subdivision, Units = custom step")
		if ss.mode == .Units {
			im.SetNextItemWidth(110)
			im.DragFloat("Value", &ss.units, 0.1, 0.01, 10000, "%.2f")
			if ss.units <= 0 do ss.units = 0.01
		}
		im.EndPopup()
	}
}

handle_scene_input :: proc() {
	io := im.GetIO()
	dt := io.DeltaTime
	alt_down := io.KeyAlt

	rmb_down := im.IsMouseDown(.Right)
	rmb_dragging := im.IsMouseDragging(.Right, 1)
	mmb_dragging := im.IsMouseDragging(.Middle, 1)
	lmb_dragging := im.IsMouseDragging(.Left, 1)

	// Flythrough latches on entry (RMB pressed over the view) and holds until
	// RMB releases. Relative mouse mode hides and PINS the cursor while SDL
	// keeps streaming raw deltas — without it the visible cursor stalls the
	// rotation at every screen edge and drops the camera whenever it drifts
	// off the window (the "jaggy flythrough" bug).
	if scene_flythrough_active && (!rmb_down || alt_down) {
		scene_flythrough_active = false
		input.set_mouse_relative(false)
	}
	if !scene_flythrough_active && rmb_down && !alt_down && scene_view_hovered {
		scene_flythrough_active = true
		input.set_mouse_relative(true)
		// Smoothing state starts at rest so entry doesn't inherit stale lag.
		_fly_yaw_target = scene_cam_yaw
		_fly_pitch_target = scene_cam_pitch
		_fly_vel = {0, 0, 0}
	}

	// Any manual camera input takes over from an in-flight frame tween.
	if rmb_down || mmb_dragging || (alt_down && lmb_dragging) || io.MouseWheel != 0 {
		_frame_tween_active = false
	}

	// Fly camera FIRST and returns: while captured, the shortcut/pick/band
	// handling below must not react to the pinned cursor (and this proc runs
	// un-hovered while latched).
	if scene_flythrough_active {
		_orbit_active = false

		// First-person look — all reads below go through the input package
		// (raw SDL snapshot): imgui derives its mouse delta from the cursor
		// position, which relative mode pins.
		// Mouse moves the TARGET; the camera exponentially chases it, which
		// smooths sensor jitter into a short, frame-rate-independent glide.
		delta := input.mouse_delta()
		_fly_yaw_target += delta.x * LOOK_SENSITIVITY
		_fly_pitch_target = clamp(_fly_pitch_target - delta.y * LOOK_SENSITIVITY, -PITCH_LIMIT, PITCH_LIMIT)
		look_k := 1 - math.exp(-dt / FLY_LOOK_SMOOTH_TAU)
		scene_cam_yaw += (_fly_yaw_target - scene_cam_yaw) * look_k
		scene_cam_pitch = clamp(scene_cam_pitch + (_fly_pitch_target - scene_cam_pitch) * look_k, -PITCH_LIMIT, PITCH_LIMIT)

		// Wheel during fly rescales the base speed for the session (Unity).
		if wheel := input.wheel(); wheel != 0 {
			scene_fly_speed = clamp(scene_fly_speed * math.pow(FLY_SPEED_WHEEL_BASE, wheel), 0.5, 100)
			_fly_speed_cur = min(_fly_speed_cur, scene_fly_speed * FLYTHROUGH_RAMP_MULT)
		}

		fwd, right, _ := _scene_cam_basis()
		move := [3]f32{0, 0, 0}
		if input.key_down(.W) do move += fwd
		if input.key_down(.S) do move -= fwd
		if input.key_down(.D) do move += right
		if input.key_down(.A) do move -= right
		if input.key_down(.E) do move += [3]f32{0, 1, 0}
		if input.key_down(.Q) do move -= [3]f32{0, 1, 0}

		// Target velocity from the keys; the smoothed velocity chases it so
		// starts, stops, and direction changes ease instead of stepping.
		target_vel: [3]f32
		len := linalg.length(move)
		if len > 0 {
			// Held movement ramps toward the cap, so short taps stay precise
			// and long hauls get fast. Release resets to base.
			_fly_speed_cur = min(
				_fly_speed_cur + scene_fly_speed * (FLYTHROUGH_RAMP_MULT - 1) / FLYTHROUGH_RAMP_TIME * dt,
				scene_fly_speed * FLYTHROUGH_RAMP_MULT,
			)
			speed := _fly_speed_cur
			if input.key_down(.LSHIFT) || input.key_down(.RSHIFT) do speed *= FLYTHROUGH_SHIFT_MULT
			target_vel = move / len * speed
		} else {
			_fly_speed_cur = scene_fly_speed
		}
		move_k := 1 - math.exp(-dt / FLY_MOVE_SMOOTH_TAU)
		_fly_vel += (target_vel - _fly_vel) * move_k
		scene_cam_pos += _fly_vel * dt

		update_scene_camera()
		return
	}
	_fly_speed_cur = scene_fly_speed

	// Gizmo mode shortcuts (Unity's Q/W/E/R) — not during flythrough, whose
	// WASDQE movement owns these keys.
	if !rmb_down {
		if im.IsKeyPressed(.Q) do gizmo_mode = .Picker
		if im.IsKeyPressed(.W) do gizmo_mode = .Translate
		if im.IsKeyPressed(.E) do gizmo_mode = .Rotate
		if im.IsKeyPressed(.R) do gizmo_mode = .Scale
		if im.IsKeyPressed(.F) do scene_frame_selected()
	}

	// Escape drops the selection (not mid-gizmo-drag: the drag teardown in
	// render_scene_rt's else-branch would leave its undo step open). During a
	// band it cancels the band and restores the pre-band selection instead.
	if im.IsKeyPressed(.Escape) && !_gizmo_dragging {
		if _band_active {
			_band_active = false
			sel_scene_clear()
			for h in _band_base do sel_scene_add(h)
		} else {
			sel_scene_clear()
		}
		_scene_click_pending = false
	}

	// Click-to-pick: LMB press + release within a few pixels (and no Alt —
	// Alt+LMB orbits; not on the gizmo — grabs must not select-through; and
	// not on an overlay toolbar — button clicks must not pick behind them).
	if im.IsMouseClicked(.Left) && !alt_down && !gizmo_consumes_mouse() && !overlay_wants_mouse() {
		_scene_click_pos = im.GetMousePos()
		_scene_click_pending = true
	}
	if _scene_click_pending && (gizmo_consumes_mouse() || _gizmo_dragging) {
		_scene_click_pending = false
	}
	// An armed click that travels beyond the click threshold becomes a rubber
	// band (works in every tool mode, Unity-style).
	if _scene_click_pending && !_band_active {
		mp := im.GetMousePos()
		dx := mp.x - _scene_click_pos.x
		dy := mp.y - _scene_click_pos.y
		if dx * dx + dy * dy >= 16 {
			_scene_click_pending = false
			_band_active = true
			_band_anchor = _scene_click_pos
			_band_additive = io.KeyCtrl || io.KeySuper
			clear(&_band_base)
			for h in sel_scene_items() do append(&_band_base, h)
		}
	}
	if _scene_click_pending && im.IsMouseReleased(.Left) {
		_scene_click_pending = false
		mp := im.GetMousePos()
		dx := mp.x - _scene_click_pos.x
		dy := mp.y - _scene_click_pos.y
		if !alt_down && dx * dx + dy * dy < 16 && scene_rt != nil {
			view := scene_render_view(f32(scene_rt.width), f32(scene_rt.height))
			px := mp.x - _scene_img_min.x
			py := mp.y - _scene_img_min.y
			// cmd/ctrl-click toggles the picked object in/out of the
			// selection (no hierarchy reveal); plain click selects only it.
			// Clicking empty space clears — unless toggling, where a miss
			// shouldn't nuke the set being built.
			cmd := io.KeyCtrl || io.KeySuper
			if tH, hit := scene_view_pick(view, px, py); hit {
				if cmd {
					sel_scene_toggle(tH)
				} else {
					engine.inspector_request_select(tH)
				}
			} else if !cmd {
				sel_scene_clear()
			}
		}
	}

	if alt_down && lmb_dragging {
		// Orbit around the anchor captured when the drag started (Unity's
		// pivot model: F/pan/zoom place it, orbit revolves around it).
		if !_orbit_active {
			_orbit_active = true
			_orbit_pivot = scene_cam_target
			scene_cam_dist = max(linalg.length(scene_cam_pos - _orbit_pivot), 0.1)
		}
		delta := io.MouseDelta
		scene_cam_yaw += delta.x * LOOK_SENSITIVITY
		scene_cam_pitch = clamp(scene_cam_pitch - delta.y * LOOK_SENSITIVITY, -PITCH_LIMIT, PITCH_LIMIT)
		fwd, _, _ := _scene_cam_basis()
		scene_cam_pos = _orbit_pivot - fwd * scene_cam_dist
		update_scene_camera()
		return
	}
	_orbit_active = false

	if alt_down && rmb_dragging {
		// Zoom drag: dolly the eye toward/away from the fixed anchor.
		delta := io.MouseDelta
		zoom_delta := (delta.x + delta.y) * ZOOM_DRAG_FACTOR
		anchor := scene_cam_target
		scene_cam_dist = clamp(scene_cam_dist * (1 - zoom_delta), 0.1, 10000)
		fwd, _, _ := _scene_cam_basis()
		scene_cam_pos = anchor - fwd * scene_cam_dist
		update_scene_camera()
		return
	}

	if mmb_dragging {
		delta := io.MouseDelta
		_, r, u := _scene_cam_basis()

		// Distance/viewport scaling keeps the grabbed point under the cursor
		// at any zoom level and window size.
		units_per_px := scene_cam_dist / max(f32(scene_rt.height), 1)
		pan := r * (-delta.x * units_per_px) + u * (delta.y * units_per_px)
		scene_cam_pos += pan
		update_scene_camera()
		return
	}

	wheel := io.MouseWheel
	if wheel != 0 {
		// Logarithmic dolly toward the fixed anchor, with a minimum absolute
		// step so close-range zoom stays responsive.
		anchor := scene_cam_target
		old_dist := scene_cam_dist
		new_dist := old_dist * math.pow(ZOOM_WHEEL_BASE, -wheel)
		min_step := ZOOM_MIN_STEP * abs(wheel)
		if wheel > 0 && old_dist - new_dist < min_step do new_dist = old_dist - min_step
		if wheel < 0 && new_dist - old_dist < min_step do new_dist = old_dist + min_step
		scene_cam_dist = clamp(new_dist, 0.1, 10000)
		fwd, _, _ := _scene_cam_basis()
		scene_cam_pos = anchor - fwd * scene_cam_dist
		update_scene_camera()
	}
}
