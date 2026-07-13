package editor

import gfx "../engine/gfx"
import im "../../external/odin-imgui"
import "core:math"
import "core:math/linalg"
import "../engine"

scene_rt: ^gfx.Render_Target

// Editor camera: plain orbit data, NOT a Camera component — the scene view
// renders through the same engine collect/execute path as game cameras.
scene_cam_pos: [3]f32
scene_cam_yaw: f32
scene_cam_pitch: f32
scene_cam_dist: f32
scene_cam_target: [3]f32

scene_view_hovered: bool
scene_flythrough_active: bool

// Click-to-pick state: a click is press+release under a small drag threshold
// (so orbit/pan drags never select). Set in draw_scene_view / handle_scene_input.
_scene_img_min: im.Vec2
_scene_click_pos: im.Vec2
_scene_click_pending: bool

FLYTHROUGH_BASE_SPEED :: 8.0
FLYTHROUGH_SHIFT_MULT :: 3.0
ORBIT_SENSITIVITY :: 0.005
PAN_SENSITIVITY :: 0.003
ZOOM_SCROLL_FACTOR :: 0.1
ZOOM_DRAG_FACTOR :: 0.01

SCENE_CAM_FOV_DEG :: f32(45)
SCENE_CAM_NEAR :: f32(0.1)
SCENE_CAM_FAR :: f32(1000)

init_scene_view :: proc() {
	scene_rt = gfx.rt_create(1, 1)
	scene_cam_yaw = 0.8
	scene_cam_pitch = 0.6
	scene_cam_dist = 12
	scene_cam_target = {0, 0, 0}
	update_scene_camera()

	// Unity-style dockable overlay toolbars (dock.odin): register every
	// @(scene_toolbar) item (generated), then restore persisted placement.
	_register_scene_toolbars()
	overlays_apply_settings()
}

shutdown_scene_view :: proc() {
	overlays_shutdown()
	gfx.rt_destroy(scene_rt)
	scene_rt = nil
}

scene_cam_forward :: proc() -> [3]f32 {
	return linalg.normalize(scene_cam_target - scene_cam_pos)
}

scene_cam_right :: proc() -> [3]f32 {
	fwd := scene_cam_forward()
	return linalg.normalize(linalg.cross(fwd, [3]f32{0, 1, 0}))
}

scene_cam_up :: proc() -> [3]f32 {
	return linalg.normalize(linalg.cross(scene_cam_right(), scene_cam_forward()))
}

update_scene_camera :: proc() {
	scene_cam_pitch = clamp(scene_cam_pitch, 0.05, math.PI - 0.05)
	scene_cam_dist = max(scene_cam_dist, 0.1)

	sp := math.sin(scene_cam_pitch)
	cp := math.cos(scene_cam_pitch)
	sy := math.sin(scene_cam_yaw)
	cy := math.cos(scene_cam_yaw)

	scene_cam_pos = scene_cam_target + [3]f32{sp * cy, cp, sp * sy} * scene_cam_dist
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
	sel := _hierarchy_selected
	if sel == _HANDLE_NONE || !engine.pool_valid(&engine.ctx_world().transforms, engine.Handle(sel)) do return
	center, radius := _selection_bounds(sel)
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
	scene_cam_target = linalg.lerp(_frame_tween_from_target, _frame_tween_to_target, k)
	scene_cam_dist = _frame_tween_from_dist + (_frame_tween_to_dist - _frame_tween_from_dist) * k
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
		if mesh, ok := engine.mesh_load(mf.mesh); ok {
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
	gfx.set_view_proj(view.view_proj)
	draw_grid()
	draw_axis_lines()

	commands := make([dynamic]engine.Render_Command, 0, 64, context.temp_allocator)
	engine.render_collect_commands(view, &commands)
	engine.render_execute(view, commands[:])

	// Selection visuals + gizmo (overlay lines, drawn last). The gizmo also
	// handles its own mouse interaction, in the same pixel space as picking.
	sel := _hierarchy_selected
	if sel != _HANDLE_NONE && engine.pool_valid(&engine.ctx_world().transforms, engine.Handle(sel)) {
		draw_selection_outline(sel)
		mp := im.GetMousePos()
		gizmo_draw_and_handle(sel, view, mp.x - _scene_img_min.x, mp.y - _scene_img_min.y)
	} else {
		_gizmo_hot_axis = -1
		_gizmo_dragging = false
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
		if mesh, ok := engine.mesh_load(mf.mesh); ok {
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
		if scene_view_hovered {
			handle_scene_input()
		}
	}
	im.End()
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
	// Vertical dock: icon-only square button (the word won't fit the column).
	label: cstring
	if vertical {
		label = gizmo_space == .Global ? ICON_MD_PUBLIC : ICON_MD_DEPLOYED_CODE
	} else {
		label = gizmo_space == .Global ? ICON_MD_PUBLIC + " World" : ICON_MD_DEPLOYED_CODE + " Local"
	}
	if overlay_tool_button(label, "Gizmo orientation: world axes vs the object's axes (scale is always local)", false, width = vertical ? OVERLAY_BUTTON_SIZE : 0) {
		gizmo_space = gizmo_space == .Global ? .Local : .Global
	}
}

// Grid toolbar: one button opening a popup with the plane toggles and line
// spacing settings (see Grid_Settings). Button lights up while any plane shows.
@(scene_toolbar={id="Grid", order=200})
draw_grid_overlay :: proc(vertical: bool) {
	gs := &grid_settings
	any_plane := gs.show_xz || gs.show_xy || gs.show_yz
	if overlay_tool_button(ICON_MD_GRID_ON, "Grid settings", any_plane) {
		im.OpenPopup("##grid_settings")
	}
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

// Snap button next to the grid button: popup with the snap settings. Button
// lights up while snapping is enabled; Ctrl inverts enabled during a drag.
@(scene_toolbar={id="Grid", order=210})
draw_snap_overlay :: proc(vertical: bool) {
	if !vertical do im.SameLine()
	if overlay_tool_button(ICON_MD_SNAP, "Snap settings (hold Ctrl / Cmd on mac to invert while dragging)", snap_settings.enabled) {
		im.OpenPopup("##snap_settings")
	}
	if im.BeginPopup("##snap_settings") {
		ss := &snap_settings
		im.Checkbox("Enabled", &ss.enabled)
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
	// render_scene_rt's else-branch would leave its undo step open).
	if im.IsKeyPressed(.Escape) && !_gizmo_dragging {
		_hierarchy_selected = _HANDLE_NONE
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
	if _scene_click_pending && im.IsMouseReleased(.Left) {
		_scene_click_pending = false
		mp := im.GetMousePos()
		dx := mp.x - _scene_click_pos.x
		dy := mp.y - _scene_click_pos.y
		if !alt_down && dx * dx + dy * dy < 16 && scene_rt != nil {
			view := scene_render_view(f32(scene_rt.width), f32(scene_rt.height))
			px := mp.x - _scene_img_min.x
			py := mp.y - _scene_img_min.y
			if tH, hit := scene_view_pick(view, px, py); hit {
				engine.inspector_request_select(tH)
			} else {
				_hierarchy_selected = _HANDLE_NONE
			}
		}
	}

	// Any manual camera input takes over from an in-flight frame tween.
	if rmb_down || mmb_dragging || (alt_down && lmb_dragging) || io.MouseWheel != 0 {
		_frame_tween_active = false
	}

	if rmb_down && !alt_down {
		scene_flythrough_active = true

		delta := io.MouseDelta
		scene_cam_yaw += delta.x * ORBIT_SENSITIVITY
		scene_cam_pitch -= delta.y * ORBIT_SENSITIVITY

		speed: f32 = FLYTHROUGH_BASE_SPEED * dt
		if io.KeyShift do speed *= FLYTHROUGH_SHIFT_MULT

		move := [3]f32{0, 0, 0}
		if im.IsKeyDown(.W) do move += scene_cam_forward()
		if im.IsKeyDown(.S) do move -= scene_cam_forward()
		if im.IsKeyDown(.D) do move += scene_cam_right()
		if im.IsKeyDown(.A) do move -= scene_cam_right()
		if im.IsKeyDown(.E) do move += [3]f32{0, 1, 0}
		if im.IsKeyDown(.Q) do move -= [3]f32{0, 1, 0}

		len := linalg.length(move)
		if len > 0 {
			move = move / len * speed
			scene_cam_target += move
		}

		update_scene_camera()
		return
	}

	scene_flythrough_active = false

	if alt_down && lmb_dragging {
		delta := io.MouseDelta
		scene_cam_yaw += delta.x * ORBIT_SENSITIVITY
		scene_cam_pitch -= delta.y * ORBIT_SENSITIVITY
		update_scene_camera()
		return
	}

	if alt_down && rmb_dragging {
		delta := io.MouseDelta
		zoom_delta := (delta.x + delta.y) * ZOOM_DRAG_FACTOR
		scene_cam_dist *= 1 - zoom_delta
		update_scene_camera()
		return
	}

	if mmb_dragging {
		delta := io.MouseDelta
		r := scene_cam_right()
		u := scene_cam_up()

		pan_speed: f32 = scene_cam_dist * PAN_SENSITIVITY
		scene_cam_target -= r * delta.x * pan_speed
		scene_cam_target += u * delta.y * pan_speed
		update_scene_camera()
		return
	}

	wheel := io.MouseWheel
	if wheel != 0 {
		scene_cam_dist *= 1 - wheel * ZOOM_SCROLL_FACTOR
		update_scene_camera()
	}
}
