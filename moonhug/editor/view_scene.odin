package editor

import rl "vendor:raylib"
import im "../../external/odin-imgui"
import "core:math"
import "core:math/linalg"
import "../engine"

scene_rt: rl.RenderTexture2D
scene_camera: rl.Camera3D

scene_cam_yaw: f32
scene_cam_pitch: f32
scene_cam_dist: f32
scene_cam_target: rl.Vector3

scene_view_hovered: bool
scene_flythrough_active: bool

FLYTHROUGH_BASE_SPEED :: 8.0
FLYTHROUGH_SHIFT_MULT :: 3.0
ORBIT_SENSITIVITY :: 0.005
PAN_SENSITIVITY :: 0.003
ZOOM_SCROLL_FACTOR :: 0.1
ZOOM_DRAG_FACTOR :: 0.01

init_scene_view :: proc() {
	scene_rt = rl.LoadRenderTexture(1, 1)
	scene_cam_yaw = 0.8
	scene_cam_pitch = 0.6
	scene_cam_dist = 12
	scene_cam_target = {0, 0, 0}
	update_scene_camera()
}

shutdown_scene_view :: proc() {
	if rl.IsRenderTextureValid(scene_rt) {
		rl.UnloadRenderTexture(scene_rt)
	}
}

scene_cam_forward :: proc() -> rl.Vector3 {
	return linalg.normalize(scene_cam_target - scene_camera.position)
}

scene_cam_right :: proc() -> rl.Vector3 {
	fwd := scene_cam_forward()
	return linalg.normalize(linalg.cross(fwd, rl.Vector3{0, 1, 0}))
}

scene_cam_up :: proc() -> rl.Vector3 {
	return linalg.normalize(linalg.cross(scene_cam_right(), scene_cam_forward()))
}

update_scene_camera :: proc() {
	scene_cam_pitch = clamp(scene_cam_pitch, 0.05, math.PI - 0.05)
	scene_cam_dist = max(scene_cam_dist, 0.1)

	sp := math.sin(scene_cam_pitch)
	cp := math.cos(scene_cam_pitch)
	sy := math.sin(scene_cam_yaw)
	cy := math.cos(scene_cam_yaw)

	scene_camera = {
		position   = scene_cam_target + rl.Vector3{sp * cy, cp, sp * sy} * scene_cam_dist,
		target     = scene_cam_target,
		up         = {0, 1, 0},
		fovy       = 45,
		projection = .PERSPECTIVE,
	}
}

render_scene_rt :: proc(w, h: i32) {
	if w < 1 || h < 1 do return
	resize_render_texture(&scene_rt, w, h)

	rl.BeginTextureMode(scene_rt)
	rl.ClearBackground({38, 38, 38, 255})

	rl.BeginMode3D(scene_camera)
	rl.DrawGrid(20, 1)
	draw_axis_lines()
	engine.render_sprite_renderers(~u32(0))
	rl.EndMode3D()

	rl.EndTextureMode()
}

draw_axis_lines :: proc() {
	rl.DrawLine3D({0, 0, 0}, {5, 0, 0}, rl.RED)
	rl.DrawLine3D({0, 0, 0}, {0, 5, 0}, rl.GREEN)
	rl.DrawLine3D({0, 0, 0}, {0, 0, 5}, rl.BLUE)
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
			tex_id := im.TextureID(scene_rt.texture.id)
			im.Image(tex_id, avail, {0, 1}, {1, 0})
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

		move := rl.Vector3{0, 0, 0}
		if im.IsKeyDown(.W) do move += scene_cam_forward()
		if im.IsKeyDown(.S) do move -= scene_cam_forward()
		if im.IsKeyDown(.D) do move += scene_cam_right()
		if im.IsKeyDown(.A) do move -= scene_cam_right()
		if im.IsKeyDown(.E) do move += rl.Vector3{0, 1, 0}
		if im.IsKeyDown(.Q) do move -= rl.Vector3{0, 1, 0}

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
