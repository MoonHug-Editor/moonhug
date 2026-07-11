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

	// Unity-style dockable overlay toolbars (dock.odin): register defaults,
	// then restore persisted anchors/positions.
	overlay_register("Tools", draw_tools_overlay, .Top_Left)
	overlay_register("Pivot", draw_pivot_overlay, .Top_Left)
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

draw_grid :: proc() {
	GRID_HALF :: 10
	col := [4]f32{0.35, 0.35, 0.35, 1}
	for i in -GRID_HALF ..= GRID_HALF {
		f := f32(i)
		gfx.draw_line({f, 0, -GRID_HALF}, {f, 0, GRID_HALF}, col)
		gfx.draw_line({-GRID_HALF, 0, f}, {GRID_HALF, 0, f}, col)
	}
}

draw_axis_lines :: proc() {
	gfx.draw_line({0, 0, 0}, {5, 0, 0}, {0.9, 0.16, 0.22, 1}) // X red
	gfx.draw_line({0, 0, 0}, {0, 5, 0}, {0, 0.89, 0.19, 1})   // Y green
	gfx.draw_line({0, 0, 0}, {0, 0, 5}, {0, 0.47, 0.95, 1})   // Z blue
}

draw_scene_view :: proc() {
	im.PushStyleVarImVec2(.WindowPadding, im.Vec2{0, 0})
	defer im.PopStyleVar()

	if im.Begin("Scene", nil, {.NoCollapse}) {
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

// Unity-style Tools overlay (dockable toolbar, dock.odin): gizmo mode toggles.
// Q/W/E/R shortcuts live in handle_scene_input (guarded against flythrough's WASD).
draw_tools_overlay :: proc(vertical: bool) {
	mode_button :: proc(icon: cstring, tooltip: cstring, mode: Gizmo_Mode, vertical: bool) {
		if !vertical do im.SameLine()
		if overlay_tool_button(icon, tooltip, gizmo_mode == mode) {
			gizmo_mode = mode
		}
	}
	mode_button(ICON_MD_ARROW_SELECTOR, "Picker (Q)", .Picker, vertical)
	mode_button(ICON_MD_OPEN_WITH, "Move (W)", .Translate, vertical)
	mode_button(ICON_MD_ROTATE_RIGHT, "Rotate (E)", .Rotate, vertical)
	mode_button(ICON_MD_OPEN_IN_FULL, "Scale (R)", .Scale, vertical)
}

// Pivot mini-toolbar: Unity's Global/Local gizmo orientation switch — a single
// icon+word button that flips the space on click. Scale always stays local
// (see Gizmo_Space).
draw_pivot_overlay :: proc(vertical: bool) {
	if !vertical do im.SameLine()
	label: cstring = gizmo_space == .Global ? ICON_MD_PUBLIC + " Global" : ICON_MD_DEPLOYED_CODE + " Local"
	if overlay_tool_button(label, "Gizmo orientation: world axes vs the object's axes (scale is always local)", false, width = 0) {
		gizmo_space = gizmo_space == .Global ? .Local : .Global
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
