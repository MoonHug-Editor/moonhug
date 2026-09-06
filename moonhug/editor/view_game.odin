package editor

import gfx "../engine/gfx"
import im "moonhug:external/odin-imgui"
import "menu"
import "../engine"
import "../engine/input"
import "moonhug:editor/icons"

game_rt: ^gfx.Render_Target

// Whether the game receives input during a simulation (docs/Simulate.md):
// Play focuses the view, a click on its image focuses it, a click anywhere
// else unfocuses it. main.odin blocks the game's input reads while unfocused.
game_view_focused: bool

// The image was under the mouse when it last drew. The focus decision uses
// it at the START of the next frame, before the simulation ticks, so the
// click that unfocuses the view never reaches the game.
@(private = "file") _game_view_hovered: bool

game_view_focus :: proc() {
	game_view_focused = true
	im.SetWindowFocusStr(icons.TITLE_GAME)
}

// Called once per frame before the simulation tick.
game_view_frame_begin :: proc() {
	clicked := im.IsMouseClicked(.Left) || im.IsMouseClicked(.Right) || im.IsMouseClicked(.Middle)
	if clicked do game_view_focused = _game_view_hovered
}

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

	if im.Begin(icons.TITLE_GAME, &menu.show_game, {.NoCollapse}) {
		avail := im.GetContentRegionAvail()
		w := i32(avail.x)
		h := i32(avail.y)

		if w > 0 && h > 0 {
			had_camera := render_game_rt(w, h)
			tex_id := im.TextureID(uintptr(gfx.rt_imgui_id(game_rt)))
			im.Image(im.TextureRef{_TexID = tex_id}, avail)

			// The image is the game's screen: mouse coordinates are relative
			// to it and its size is what the game unprojects with. Window
			// coordinates, like SDL's mouse events.
			origin := im.GetMainViewport().Pos
			img_min := im.GetItemRectMin()
			img_max := im.GetItemRectMax()
			input.set_viewport({img_min.x - origin.x, img_min.y - origin.y}, {img_max.x - img_min.x, img_max.y - img_min.y})

			_game_view_hovered = im.IsItemHovered()

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
