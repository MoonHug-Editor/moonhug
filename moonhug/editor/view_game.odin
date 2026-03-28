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

render_game_rt :: proc(w, h: i32) {
	if w < 1 || h < 1 do return
	resize_render_texture(&game_rt, w, h)
	rl.BeginTextureMode(game_rt)
	engine.render_world_cameras()
	rl.EndTextureMode()
}

draw_game_view :: proc() {
	im.PushStyleVarImVec2(.WindowPadding, im.Vec2{0, 0})
	defer im.PopStyleVar()

	if im.Begin("Game", nil, {.NoCollapse}) {
		avail := im.GetContentRegionAvail()
		w := i32(avail.x)
		h := i32(avail.y)

		if w > 0 && h > 0 {
			render_game_rt(w, h)
			tex_id := im.TextureID(game_rt.texture.id)
			im.Image(tex_id, avail, {0, 1}, {1, 0})
		}
	}
	im.End()
}
