package editor

import rl "vendor:raylib"
import im "../../external/odin-imgui"
import "../engine"

game_rt: rl.RenderTexture2D

init_game_view :: proc() {
	game_rt = rl.LoadRenderTexture(1, 1)
}

shutdown_game_view :: proc() {
	if rl.IsRenderTextureValid(game_rt) {
		rl.UnloadRenderTexture(game_rt)
	}
}

resize_render_texture :: proc(rt: ^rl.RenderTexture2D, w, h: i32) {
	if i32(rt.texture.width) != w || i32(rt.texture.height) != h {
		if rl.IsRenderTextureValid(rt^) {
			rl.UnloadRenderTexture(rt^)
		}
		rt^ = rl.LoadRenderTexture(w, h)
	}
}

render_game_rt :: proc(w, h: i32) -> bool {
	if w < 1 || h < 1 do return false
	resize_render_texture(&game_rt, w, h)
	rl.BeginTextureMode(game_rt)
	had_camera := engine.render_world_cameras()
	if !had_camera {
		rl.ClearBackground(rl.BLACK)
	}
	rl.EndTextureMode()
	return had_camera
}

draw_game_view :: proc() {
	im.PushStyleVarImVec2(.WindowPadding, im.Vec2{0, 0})
	defer im.PopStyleVar()

	if im.Begin("Game", nil, {.NoCollapse}) {
		avail := im.GetContentRegionAvail()
		w := i32(avail.x)
		h := i32(avail.y)

		if w > 0 && h > 0 {
			had_camera := render_game_rt(w, h)
			tex_id := im.TextureID(game_rt.texture.id)
			im.Image(tex_id, avail, {0, 1}, {1, 0})

			if !had_camera {
				msg: cstring = "No cameras rendering"
				text_size := im.CalcTextSize(msg)
				padding := im.Vec2{32, 16}
				cursor_pos := im.Vec2{
					(avail.x - text_size.x) * 0.5,
					(avail.y - text_size.y) * 0.5,
				}
				win_pos := im.GetWindowPos()
				rect_min := im.Vec2{win_pos.x + cursor_pos.x - padding.x, win_pos.y + cursor_pos.y - padding.y}
				rect_max := im.Vec2{rect_min.x + text_size.x + padding.x * 2, rect_min.y + text_size.y + padding.y * 2}
				im.DrawList_AddRectFilled(im.GetWindowDrawList(), rect_min, rect_max, 0x99333333, 4)
				im.SetCursorPos(cursor_pos)
				im.PushStyleColorImVec4(.Text, im.Vec4{1, 1, 1, 1})
				im.Text(msg)
				im.PopStyleColor()
			}
		}
	}
	im.End()
}
