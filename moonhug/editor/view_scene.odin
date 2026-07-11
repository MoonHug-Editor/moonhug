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
}

shutdown_scene_view :: proc() {
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
	gfx.pass_end()
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
		}

		scene_view_hovered = im.IsWindowHovered({})
		if scene_view_hovered {
			handle_scene_input()
		}
	}
	im.End()
}

handle_scene_input :: proc() {
	io := im.GetIO()
	dt := io.DeltaTime
	alt_down := io.KeyAlt

	rmb_down := im.IsMouseDown(.Right)
	rmb_dragging := im.IsMouseDragging(.Right, 1)
	mmb_dragging := im.IsMouseDragging(.Middle, 1)
	lmb_dragging := im.IsMouseDragging(.Left, 1)

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
