package editor

import gfx "../engine/gfx"
import im "moonhug:external/odin-imgui"
import "../engine"

game_rt: ^gfx.Render_Target

init_game_view :: proc() {
	game_rt = gfx.rt_create(1, 1)
}

shutdown_game_view :: proc() {
	gfx.rt_destroy(game_rt)
	game_rt = nil
}

render_game_rt :: proc(w, h: i32) -> bool {
	if w < 1 || h < 1 do return false
	gfx.rt_resize(game_rt, w, h)
	had_camera := engine.camera_active() != nil
	// Begins the pass (black clear when no camera) and leaves it open.
	engine.render_world_cameras(game_rt)
	gfx.pass_end()
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
			tex_id := im.TextureID(uintptr(gfx.rt_imgui_id(game_rt)))
			im.Image(im.TextureRef{_TexID = tex_id}, avail)

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
