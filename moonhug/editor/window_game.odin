package editor

import "core:fmt"
import gfx "moonhug:libs/gfx"
import im "moonhug:external/odin-imgui"
import core "moonhug:libs/core"
import "moonhug:editor/viewport"
import "moonhug:libs/gizmos"
import "moonhug:libs/input"
import "moonhug:editor/icons"
import "moonhug:editor/session"
import "moonhug:editor/widgets"
import wnd "moonhug:editor/window"

GAME :: "Game"

// One Game copy's own state, saved with it (window/window_saved.odin). Each
// copy renders the game into its own target at its own size.
Game_Window :: struct {
	// The selected entry in GAME_SIZES, the zoom applied to the resulting
	// rect, and whether the size's width and height are swapped
	// (portrait/landscape).
	size_index:   int,
	scale:        f32,
	size_flipped: bool,
	// The window menu's Gizmos toggle: gizmo procs and gameplay gizmo shapes
	// in the Game window too (the Scene window always shows them).
	gizmos:       bool,
	// The render statistics panel over the game image (the toolbar's Stats
	// button): frame time, draw calls, instances, triangles and passes,
	// averaged over the last 60 rendered frames (gfx.stats_average).
	stats:        bool,

	rt: ^gfx.Render_Target `json:"-"`,
	// The image size the scroll was last centered for: a new size (a zoom
	// change, another resolution, a resized window) scrolls back to the
	// middle, so a larger image overflows equally on both sides.
	centered_for: im.Vec2 `json:"-"`,
	// Last frame's zoom floor, so the toolbar can tell "the user parked the
	// zoom at the floor" (follow the window) from "the user picked this value".
	scale_floor:  f32 `json:"-"`,
	// The image was under the mouse when it last drew. The focus decision
	// uses it at the START of the next frame, before the simulation ticks, so
	// the click that unfocuses the window never reaches the game.
	hovered:      bool `json:"-"`,
}

@(private = "file")
_GAME_INIT :: Game_Window{scale = 1, scale_floor = 1}

// The state and the target of no Game window: what `_gv` and `game_rt` are
// while none is open.
@(private = "file")
_gv_none := _GAME_INIT
@(private = "file")
_game_rt_none: ^gfx.Render_Target

// The game's screen: the Game copy clicked in or opened last. Its image is
// what the game reads the mouse against, its size what the gizmo pass builds
// for, its target what a screenshot of the game takes. Set once per frame
// (game_window_frame_begin), and to the copy being drawn during its draw.
_gv: ^Game_Window = &_gv_none
game_rt: ^gfx.Render_Target
// Whether a Game window is open, as of game_window_frame_begin.
game_shown: bool

// Unity's Game window size list: Free Aspect follows the window, an aspect
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

// The state of the Game copy `key`, nil when it is not open or never drew.
@(private = "file")
_game_state_of :: proc(key: string) -> ^Game_Window {
	w := wnd.find(key)
	if w == nil do return nil
	return (^Game_Window)(w.data)
}

// The window menu's Gizmos toggle, for the copy the menu is open on.
@(window_menu={window="Game", label="Gizmos", checked=game_gizmos_checked})
game_gizmos_toggle :: proc(window: session.Window_Ref) {
	if gv := _game_state_of(window.key); gv != nil do gv.gizmos = !gv.gizmos
}

game_gizmos_checked :: proc(window: session.Window_Ref) -> bool {
	gv := _game_state_of(window.key)
	return gv != nil && gv.gizmos
}

GAME_TOOLBAR_PAD :: f32(4)

// Unity's Game window backdrop outside the rendered rect.
GAME_BACKDROP :: im.Vec4{0.16, 0.16, 0.16, 1}

// Height the game toolbar occupies, including its padding.
game_toolbar_height :: proc() -> f32 {
	return im.GetFrameHeight() + GAME_TOOLBAR_PAD * 2
}

// The rect the game renders into, inside a content area of `avail` pixels:
// the chosen size fitted and centered, then scaled. A fixed resolution that
// does not fit is scaled down to fit, the way Unity clamps its own preview.
game_target_rect :: proc(avail: im.Vec2) -> (size: im.Vec2) {
	sizes := GAME_SIZES
	idx := clamp(_gv.size_index, 0, len(sizes) - 1)
	e := sizes[idx]
	if _gv.size_flipped do e.w, e.h = e.h, e.w
	if e.w <= 0 || e.h <= 0 {
		size = avail // Free Aspect: the whole content area, zoom does not apply
		return
	}
	if e.fixed {
		// A resolution at zoom 1 is exactly its pixels.
		size = {e.w, e.h}
	} else {
		// An aspect has no pixel size of its own, so zoom 1 is the largest
		// rect of that ratio fitting the window.
		fit := min(avail.x / e.w, avail.y / e.h)
		size = {e.w * fit, e.h * fit}
	}
	size *= clamp(_gv.scale, game_min_scale(avail), GAME_SCALE_MAX)
	return
}

GAME_SCALE_MAX :: f32(5)

// Smallest zoom the slider allows: 1, or the zoom that fits the size in the
// window when its actual pixels are larger than the window.
game_min_scale :: proc(avail: im.Vec2) -> f32 {
	sizes := GAME_SIZES
	idx := clamp(_gv.size_index, 0, len(sizes) - 1)
	e := sizes[idx]
	if _gv.size_flipped do e.w, e.h = e.h, e.w
	if !e.fixed || e.w <= 0 || e.h <= 0 do return 1
	if avail.x <= 0 || avail.y <= 0 do return 1
	return min(1, min(avail.x / e.w, avail.y / e.h))
}

// Whether the game receives input during a simulation (docs/core/Simulate.md):
// Play focuses the window, a click on its image focuses it, a click anywhere
// else unfocuses it. main.odin blocks the game's input reads while unfocused.
game_window_focused: bool

game_window_focus :: proc() {
	game_window_focused = true
	if w := wnd.last(GAME); w != nil do wnd.focus(w)
}

// Called once per frame before the simulation tick: picks the game's screen,
// then decides the focus from the click.
game_window_frame_begin :: proc() {
	w := wnd.last(GAME)
	game_shown = w != nil
	_gv, game_rt = &_gv_none, _game_rt_none
	if w != nil && w.data != nil {
		_gv = (^Game_Window)(w.data)
		if _gv.rt != nil do game_rt = _gv.rt
	}
	clicked := im.IsMouseClicked(.Left) || im.IsMouseClicked(.Right) || im.IsMouseClicked(.Middle)
	if clicked do game_window_focused = game_shown && _gv.hovered
}

init_game_window :: proc() {
	_game_rt_none = gfx.rt_create(1, 1)
	game_rt = _game_rt_none
}

shutdown_game_window :: proc() {
	gfx.rt_destroy(_game_rt_none)
	_game_rt_none = nil
	game_rt = nil
}

// A closing copy gives its render target back. Its state stays for a reopen.
game_window_closed :: proc(w: ^wnd.Window) {
	gv := (^Game_Window)(w.data)
	if gv == nil do return
	if _gv == gv do _gv, game_rt = &_gv_none, _game_rt_none
	if gv.rt != nil do gfx.rt_destroy(gv.rt)
	gv.rt = nil
	gv.hovered = false
}

// The channels the Game window draws: gizmos and icons recorded with its camera
// (.Editor_Game) with its Gizmos toggle, gameplay shapes (.Game) with the
// toggle or debug drawing on.
game_gizmo_channels :: proc() -> bit_set[core.Gizmo_Channel] {
	channels: bit_set[core.Gizmo_Channel]
	if _gv.gizmos do channels += {.Game, .Editor_Game}
	if viewport.debug_draw() do channels += {.Game}
	return channels
}

// Where a gizmo label lands on the game image: projected with the camera
// view `v` into the render target's pixels, scaled onto the image at
// `img_min` sized `img_size` (zoom and letterboxing), plus its own screen
// offset. ok=false behind the camera or off the image.
game_label_pos :: proc(v: core.Render_View, img_min, img_size: [2]f32, l: core.Gizmo_Label) -> ([2]f32, bool) {
	px, ok := gizmos.helper_project_in(v, l.pos)
	if !ok do return {}, false
	p := img_min + px * (img_size / [2]f32{max(v.width, 1), max(v.height, 1)})
	if p.x < img_min.x || p.y < img_min.y || p.x > img_min.x + img_size.x || p.y > img_min.y + img_size.y do return {}, false
	return p + l.offset_px, true
}

render_game_rt :: proc(w, h: i32) -> bool {
	if w < 1 || h < 1 do return false
	gfx.rt_resize(game_rt, w, h)
	// The engine renders its cameras in its own passes, black when no camera,
	// and draws the gizmos over the scene inside the last camera's pass.
	return viewport.render_game(game_rt, _draw_game_over)
}

// What the gizmo pass recorded this frame (gizmo_pass.odin): gizmos with
// the window menu toggle, gameplay shapes with the toggle or debug drawing on.
// Icons draw facing the game camera.
@(private = "file")
_draw_game_over :: proc() {
	channels := game_gizmo_channels()
	if v, ok := _game_gizmo_view(); ok && channels != {} {
		gizmos.with_view(v)
		gizmos.draw(channels)
	}
}

// The Stats panel: a box in the top right corner of the window's area under the
// toolbar, over the letterbox or the image, with the last 60 frames'
// averages. The editor renders the Scene window in the same frames, so its
// draws count too.
@(private = "file")
_draw_game_stats :: proc() {
	win_min := im.GetWindowPos()
	win_max := win_min + im.GetWindowSize()
	avg, n := gfx.stats_average(60)
	frame_ms := avg.cpu_ms + avg.wait_ms
	fps := frame_ms > 0 ? 1000 / frame_ms : 0
	lines := [?]cstring{
		fmt.ctprintf("%.1f ms  %.0f FPS", frame_ms, fps),
		fmt.ctprintf("CPU %.2f ms  GPU wait %.2f ms", avg.cpu_ms, avg.wait_ms),
		fmt.ctprintf("Draw calls %d  Passes %d", avg.draw_calls, avg.passes),
		fmt.ctprintf("Instances %d  Triangles %d", avg.instances, avg.triangles),
		fmt.ctprintf("%d frames", n),
	}
	pad := im.Vec2{8, 6}
	size := im.Vec2{0, 0}
	for l in lines {
		ts := im.CalcTextSize(l)
		size.x = max(size.x, ts.x)
		size.y += ts.y
	}
	rect_max := im.Vec2{win_max.x - 8, win_min.y + 8 + size.y + pad.y * 2}
	rect_min := im.Vec2{rect_max.x - size.x - pad.x * 2, win_min.y + 8}
	dl := im.GetWindowDrawList()
	im.DrawList_AddRectFilled(dl, rect_min, rect_max, 0xAA222222, 4)
	y := rect_min.y + pad.y
	for l in lines {
		im.DrawList_AddText(dl, {rect_min.x + pad.x, y}, 0xFFEEEEEE, l)
		y += im.CalcTextSize(l).y
	}
}

// Game window toolbar: Unity's size dropdown and scale slider. Drawn inside the
// window above the image, taking its own height.
@(private = "file")
_draw_game_toolbar :: proc(area: im.Vec2) {
	sizes := GAME_SIZES
	_gv.size_index = clamp(_gv.size_index, 0, len(sizes) - 1)

	im.PushStyleVarImVec2(.WindowPadding, im.Vec2{GAME_TOOLBAR_PAD, GAME_TOOLBAR_PAD})
	defer im.PopStyleVar()

	// Swap width and height of the selected size (Unity's portrait toggle).
	// Free Aspect follows the window, so there is nothing to swap.
	free := sizes[_gv.size_index].w <= 0 || sizes[_gv.size_index].h <= 0
	im.BeginDisabled(free)
	// Capture the toggle BEFORE the button: clicking it flips the flag, and a
	// pop keyed off the new value would not match the push.
	flipped := _gv.size_flipped
	if flipped {
		im.PushStyleColorImVec4(.Button, im.GetStyleColorVec4(.ButtonActive)^)
	}
	if im.Button(icons.ICON_MD_SCREEN_ROTATION) do _gv.size_flipped = !_gv.size_flipped
	if flipped {
		im.PopStyleColor()
	}
	widgets.tooltip(free ? "Flip width and height (needs a fixed aspect or resolution)" : "Flip width and height", im.HoveredFlags_AllowWhenDisabled)
	im.EndDisabled()

	im.SameLine()
	im.SetNextItemWidth(190)
	if im.BeginCombo("##game_size", sizes[_gv.size_index].label, {}) {
		for e, i in sizes {
			if im.Selectable(e.label, i == _gv.size_index) {
				_gv.size_index = i
			}
		}
		im.EndCombo()
	}
	im.SameLine()
	im.TextUnformatted("Scale")
	im.SameLine()
	// Zoom 1 is the size's actual pixels. The floor drops below 1 only when
	// those pixels do not fit the window, so the game is always fully visible.
	// Free Aspect fills the window, so zoom has nothing to scale.
	free_size := sizes[_gv.size_index].w <= 0 || sizes[_gv.size_index].h <= 0
	lo := game_min_scale(area)
	// Sitting at the floor means "match the window": the zoom follows the floor
	// as the window resizes, so the game stays exactly fitted instead of
	// sticking at the old fit and cropping or leaving a gap.
	if _gv.scale <= _gv.scale_floor + 0.0001 {
		_gv.scale = lo
	}
	_gv.scale_floor = lo
	_gv.scale = clamp(_gv.scale, lo, GAME_SCALE_MAX)
	// The slider takes the rest of the toolbar, so a wider window gives a longer
	// track (the inspector's range rows stretch the same way). The right pad
	// keeps the value box off the window edge.
	// The Stats toggle sits at the right end, so the slider leaves it room.
	stats_label: cstring = "Stats"
	stats_w := im.CalcTextSize(stats_label).x + im.GetStyle().FramePadding.x * 2
	im.BeginDisabled(free_size)
	slider_w := max(im.GetContentRegionAvail().x - GAME_TOOLBAR_PAD * 2 - stats_w - im.GetStyle().ItemSpacing.x, widgets.slider_width_for_track(40))
	widgets.slider_float("##game_scale", &_gv.scale, lo, GAME_SCALE_MAX, "%.2f", slider_w)
	widgets.tooltip(free_size ? "Zoom applies to a fixed aspect or resolution" : "Zoom the rendered rect. 1x is the size's actual pixels", im.HoveredFlags_AllowWhenDisabled)
	im.EndDisabled()

	im.SameLine()
	// Captured before the button, as the flip toggle above.
	stats_on := _gv.stats
	if stats_on do im.PushStyleColorImVec4(.Button, im.GetStyleColorVec4(.ButtonActive)^)
	if im.Button(stats_label) do _gv.stats = !_gv.stats
	if stats_on do im.PopStyleColor()
	widgets.tooltip("Render statistics over the last 60 frames")
}

@(editor_window={id="Game", title="Game", icon="SPORTS_ESPORTS", canvas=true, closed=game_window_closed})
game_window_draw :: proc(w: ^wnd.Window) {
	gv := wnd.state(w, _GAME_INIT, saved = true)
	if gv.rt == nil do gv.rt = gfx.rt_create(1, 1)
	// The copy being drawn is the one the size math, the toolbar and the
	// render read, for the length of its draw.
	prev_gv, prev_rt := _gv, game_rt
	_gv, game_rt = gv, gv.rt
	defer _gv, game_rt = prev_gv, prev_rt
	// Only the game's screen feeds the game's mouse.
	is_screen := wnd.last(GAME) == w
	{
		content_min := im.GetCursorScreenPos()
		full := im.GetContentRegionAvail()

		bar_h := game_toolbar_height()
		// Area under the toolbar, and the rect the game renders into inside it.
		area_min := im.Vec2{content_min.x, content_min.y + bar_h}
		area := im.Vec2{full.x, max(full.y - bar_h, 0)}
		// The area around the rendered rect (letterbox bars, zoomed-out
		// margins) is a fixed dark gray, Unity's Game window backdrop, so the
		// game's edges read against the same neutral in every theme.
		im.DrawList_AddRectFilled(im.GetWindowDrawList(), area_min, area_min + area, im.GetColorU32ImVec4(GAME_BACKDROP))

		im.SetCursorScreenPos(content_min + {GAME_TOOLBAR_PAD, GAME_TOOLBAR_PAD})
		im.BeginGroup()
		_draw_game_toolbar(area)
		im.EndGroup()

		avail := game_target_rect(area)
		w := i32(avail.x)
		h := i32(avail.y)

		// The area under the toolbar scrolls when the zoomed game is larger
		// than the window, with a scrollbar on each axis that overflows. The
		// wheel stays the game's input, so the bars are dragged.
		im.SetCursorScreenPos(area_min)
		im.PushStyleColorImVec4(.ChildBg, GAME_BACKDROP)
		im.PushStyleVarImVec2(.WindowPadding, im.Vec2{0, 0})
		scrolling := im.BeginChild("##game_area", area, {}, {.HorizontalScrollbar, .NoScrollWithMouse})
		im.PopStyleVar()
		im.PopStyleColor()
		if scrolling && w > 0 && h > 0 {
			visible := im.GetContentRegionAvail()
			if avail != gv.centered_for {
				im.SetScrollX(max(avail.x - visible.x, 0) * 0.5)
				im.SetScrollY(max(avail.y - visible.y, 0) * 0.5)
				gv.centered_for = avail
			}
			had_camera := render_game_rt(w, h)
			tex_id := im.TextureID(uintptr(gfx.rt_imgui_id(game_rt)))
			// Centered on an axis that fits, scrolled on one that does not.
			offset := im.Vec2{max((visible.x - avail.x) * 0.5, 0), max((visible.y - avail.y) * 0.5, 0)}
			im.SetCursorPos(im.GetCursorPos() + offset)
			im.Image(im.TextureRef{_TexID = tex_id}, avail)

			// The image is the game's screen: mouse coordinates are relative
			// to it and its size is what the game unprojects with. Window
			// coordinates, like SDL's mouse events.
			origin := im.GetMainViewport().Pos
			img_min := im.GetItemRectMin()
			img_max := im.GetItemRectMax()
			if is_screen do input.set_viewport({img_min.x - origin.x, img_min.y - origin.y}, {img_max.x - img_min.x, img_max.y - img_min.y})

			// Gizmo labels over the image, as the Scene window draws them, for
			// the channels this window shows.
			if v, vok := _game_gizmo_view(); vok {
				dl := im.GetWindowDrawList()
				for l in gizmos.labels(game_gizmo_channels()) {
					if p, pok := game_label_pos(v, img_min, img_max - img_min, l); pok do _draw_handle_label(dl, p, l)
				}
			}

			gv.hovered = im.IsItemHovered()
			if _gv.stats do _draw_game_stats()

			if !had_camera {
				// Centered on the part of the area in view.
				msg: cstring = "No cameras rendering"
				text_size := im.CalcTextSize(msg)
				padding := im.Vec2{32, 16}
				win_min := im.GetWindowPos()
				text_pos := win_min + (im.GetWindowSize() - text_size) * 0.5
				rect_min := text_pos - padding
				rect_max := text_pos + text_size + padding
				im.DrawList_AddRectFilled(im.GetWindowDrawList(), rect_min, rect_max, 0x99333333, 4)
				im.SetCursorScreenPos(text_pos)
				im.PushStyleColorImVec4(.Text, im.Vec4{1, 1, 1, 1})
				im.Text(msg)
				im.PopStyleColor()
			}
		}
		im.EndChild()
	}
}
