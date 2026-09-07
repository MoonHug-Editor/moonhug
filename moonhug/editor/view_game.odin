package editor

import gfx "../engine/gfx"
import im "moonhug:external/odin-imgui"
import "menu"
import "../engine"
import "../engine/input"
import "moonhug:editor/icons"

game_rt: ^gfx.Render_Target

// Unity's Game view size list: Free Aspect follows the window, an aspect
// letterboxes to that ratio, a fixed resolution renders at exactly those
// pixels. w/h are 0 for Free Aspect; for an aspect they are the ratio, for a
// resolution the pixel size (fixed = true).
Game_Size :: struct {
	label: cstring,
	w, h:  f32,
	fixed: bool,
}

GAME_SIZES :: []Game_Size{
	{"Free Aspect", 0, 0, false},
	{"16:9", 16, 9, false},
	{"16:10", 16, 10, false},
	{"4:3", 4, 3, false},
	{"21:9", 21, 9, false},
	{"1920x1080 Full HD", 1920, 1080, true},
	{"1280x720 HD", 1280, 720, true},
	{"2560x1440 QHD", 2560, 1440, true},
	{"3840x2160 4K UHD", 3840, 2160, true},
	{"1080x1920 Portrait FHD", 1080, 1920, true},
	{"750x1334 iPhone", 750, 1334, true},
}

// Selected entry in GAME_SIZES, the zoom applied to the resulting rect, and
// whether the size's width and height are swapped (portrait/landscape). All
// three persist in editor_settings.
game_size_index: int
game_scale: f32 = 1
game_size_flipped: bool

GAME_TOOLBAR_PAD :: f32(4)

// Unity's Game view backdrop outside the rendered rect.
GAME_BACKDROP :: im.Vec4{0.16, 0.16, 0.16, 1}

// Last frame's zoom floor, so the toolbar can tell "the user parked the zoom
// at the floor" (follow the view) from "the user picked this value".
@(private = "file")
_game_scale_floor: f32 = 1

// Height the game toolbar occupies, including its padding.
game_toolbar_height :: proc() -> f32 {
	return im.GetFrameHeight() + GAME_TOOLBAR_PAD * 2
}

// The rect the game renders into, inside a content area of `avail` pixels:
// the chosen size fitted and centered, then scaled. A fixed resolution that
// does not fit is scaled down to fit, the way Unity clamps its own preview.
game_target_rect :: proc(avail: im.Vec2) -> (size: im.Vec2) {
	sizes := GAME_SIZES
	idx := clamp(game_size_index, 0, len(sizes) - 1)
	e := sizes[idx]
	if game_size_flipped do e.w, e.h = e.h, e.w
	if e.w <= 0 || e.h <= 0 {
		size = avail // Free Aspect: the whole content area, zoom does not apply
		return
	}
	if e.fixed {
		// A resolution at zoom 1 is exactly its pixels.
		size = {e.w, e.h}
	} else {
		// An aspect has no pixel size of its own, so zoom 1 is the largest
		// rect of that ratio fitting the view.
		fit := min(avail.x / e.w, avail.y / e.h)
		size = {e.w * fit, e.h * fit}
	}
	size *= clamp(game_scale, game_min_scale(avail), GAME_SCALE_MAX)
	return
}

GAME_SCALE_MAX :: f32(5)

// Smallest zoom the slider allows: 1, or the zoom that fits the size in the
// view when its actual pixels are larger than the view.
game_min_scale :: proc(avail: im.Vec2) -> f32 {
	sizes := GAME_SIZES
	idx := clamp(game_size_index, 0, len(sizes) - 1)
	e := sizes[idx]
	if game_size_flipped do e.w, e.h = e.h, e.w
	if !e.fixed || e.w <= 0 || e.h <= 0 do return 1
	if avail.x <= 0 || avail.y <= 0 do return 1
	return min(1, min(avail.x / e.w, avail.y / e.h))
}

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

// Game view toolbar: Unity's size dropdown and scale slider. Drawn inside the
// window above the image, taking its own height.
@(private = "file")
_draw_game_toolbar :: proc(area: im.Vec2) {
	sizes := GAME_SIZES
	game_size_index = clamp(game_size_index, 0, len(sizes) - 1)

	im.PushStyleVarImVec2(.WindowPadding, im.Vec2{GAME_TOOLBAR_PAD, GAME_TOOLBAR_PAD})
	defer im.PopStyleVar()

	// Swap width and height of the selected size (Unity's portrait toggle).
	// Free Aspect follows the view, so there is nothing to swap.
	free := sizes[game_size_index].w <= 0 || sizes[game_size_index].h <= 0
	im.BeginDisabled(free)
	// Capture the toggle BEFORE the button: clicking it flips the flag, and a
	// pop keyed off the new value would not match the push.
	flipped := game_size_flipped
	if flipped {
		im.PushStyleColorImVec4(.Button, im.GetStyleColorVec4(.ButtonActive)^)
	}
	if im.Button(icons.ICON_MD_SCREEN_ROTATION) do game_size_flipped = !game_size_flipped
	if flipped {
		im.PopStyleColor()
	}
	if im.IsItemHovered(im.HoveredFlags_AllowWhenDisabled) {
		im.SetTooltip(free ? "Flip width and height (needs a fixed aspect or resolution)" : "Flip width and height")
	}
	im.EndDisabled()

	im.SameLine()
	im.SetNextItemWidth(190)
	if im.BeginCombo("##game_size", sizes[game_size_index].label, {}) {
		for e, i in sizes {
			if im.Selectable(e.label, i == game_size_index) {
				game_size_index = i
			}
		}
		im.EndCombo()
	}
	if im.IsItemHovered({}) {
		im.SetTooltip("Game view size: Free Aspect fills the view, an aspect letterboxes, a resolution renders those pixels")
	}

	im.SameLine()
	im.TextUnformatted("Scale")
	im.SameLine()
	// Zoom 1 is the size's actual pixels. The floor drops below 1 only when
	// those pixels do not fit the view, so the game is always fully visible.
	// Free Aspect fills the view, so zoom has nothing to scale.
	free_size := sizes[game_size_index].w <= 0 || sizes[game_size_index].h <= 0
	lo := game_min_scale(area)
	// Sitting at the floor means "match the view": the zoom follows the floor
	// as the view resizes, so the game stays exactly fitted instead of
	// sticking at the old fit and cropping or leaving a gap.
	if game_scale <= _game_scale_floor + 0.0001 {
		game_scale = lo
	}
	_game_scale_floor = lo
	game_scale = clamp(game_scale, lo, GAME_SCALE_MAX)
	im.SetNextItemWidth(140)
	im.BeginDisabled(free_size)
	im.SliderFloat("##game_scale", &game_scale, lo, GAME_SCALE_MAX, "%.2fx", {})
	if im.IsItemHovered(im.HoveredFlags_AllowWhenDisabled) {
		im.SetTooltip(free_size ? "Zoom applies to a fixed aspect or resolution" : "Zoom the rendered rect. 1x is the size's actual pixels")
	}
	im.EndDisabled()
	if game_scale != 1 && !free_size {
		im.SameLine()
		if im.SmallButton("1x") do game_scale = 1
		if im.IsItemHovered({}) do im.SetTooltip("Back to actual pixels")
	}
}

draw_game_view :: proc() {
	im.PushStyleVarImVec2(.WindowPadding, im.Vec2{0, 0})
	defer im.PopStyleVar()

	if im.Begin(icons.TITLE_GAME, &menu.show_game, {.NoCollapse, .NoScrollbar, .NoScrollWithMouse}) {
		content_min := im.GetCursorScreenPos()
		full := im.GetContentRegionAvail()

		bar_h := game_toolbar_height()
		// Area under the toolbar, and the rect the game renders into inside it.
		area_min := im.Vec2{content_min.x, content_min.y + bar_h}
		area := im.Vec2{full.x, max(full.y - bar_h, 0)}
		// The area around the rendered rect (letterbox bars, zoomed-out
		// margins) is a fixed dark gray, Unity's Game view backdrop, so the
		// game's edges read against the same neutral in every theme.
		im.DrawList_AddRectFilled(im.GetWindowDrawList(), area_min, area_min + area, im.GetColorU32ImVec4(GAME_BACKDROP))

		im.SetCursorScreenPos(content_min + {GAME_TOOLBAR_PAD, GAME_TOOLBAR_PAD})
		im.BeginGroup()
		_draw_game_toolbar(area)
		im.EndGroup()

		avail := game_target_rect(area)
		w := i32(avail.x)
		h := i32(avail.y)

		if w > 0 && h > 0 {
			had_camera := render_game_rt(w, h)
			tex_id := im.TextureID(uintptr(gfx.rt_imgui_id(game_rt)))
			// Center the rect in the area; a scaled-up rect overflows equally
			// on both sides, matching Unity.
			offset := im.Vec2{max((area.x - avail.x) * 0.5, 0), max((area.y - avail.y) * 0.5, 0)}
			im.SetCursorScreenPos(area_min + offset)
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
				// Centered on the rendered rect, in screen coordinates (the
				// rect is offset by the toolbar and any letterboxing).
				msg: cstring = "No cameras rendering"
				text_size := im.CalcTextSize(msg)
				padding := im.Vec2{32, 16}
				text_pos := im.Vec2{
					img_min.x + (avail.x - text_size.x) * 0.5,
					img_min.y + (avail.y - text_size.y) * 0.5,
				}
				rect_min := text_pos - padding
				rect_max := text_pos + text_size + padding
				im.DrawList_AddRectFilled(im.GetWindowDrawList(), rect_min, rect_max, 0x99333333, 4)
				im.SetCursorScreenPos(text_pos)
				im.PushStyleColorImVec4(.Text, im.Vec4{1, 1, 1, 1})
				im.Text(msg)
				im.PopStyleColor()
			}
		}
	}
	im.End()
}
