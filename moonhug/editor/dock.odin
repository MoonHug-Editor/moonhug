package editor

// Docking: the main dockspace (with a Unity-style default layout built via
// DockBuilder on first run / View->Reset Layout) and dockable view overlays
// modeled on Unity's Scene View overlays:
// - overlays dock to the view's corners/edges or float anywhere inside it
// - drag by the grip handle; drop zones highlight while dragging
// - docking to the left/right edge turns the overlay vertical
// Overlay placement persists in editor_settings (anchor + normalized float pos).

import "core:fmt"
import "core:math"
import im "moonhug:external/odin-imgui"
import "menu"
import "moonhug:editor/icons"

// ---------------------------------------------------------------------------
// Main dockspace

_dock_layout_reset: bool

// Host window under the main toolbar holding the central dockspace. Builds the
// default layout when the dockspace node has no saved state (fresh imgui.ini)
// or a reset was requested. Must run before any dockable view's Begin().
draw_dockspace :: proc() {
	vp := im.GetMainViewport()
	toolbar_h := toolbar_height()
	pos := im.Vec2{vp.WorkPos.x, vp.WorkPos.y + toolbar_h}
	size := im.Vec2{vp.WorkSize.x, vp.WorkSize.y - toolbar_h}
	im.SetNextWindowPos(pos, {}, {0, 0})
	im.SetNextWindowSize(size, {})
	flags := im.WindowFlags{.NoTitleBar, .NoResize, .NoMove, .NoScrollbar, .NoCollapse, .NoBringToFrontOnFocus, .NoNavFocus, .NoDocking}
	if im.Begin("##DockSpaceHost", nil, flags) {
		dockspace_id := im.GetID("DockSpace")
		if im.DockBuilderGetNode(dockspace_id) == nil || _dock_layout_reset {
			_dock_layout_reset = false
			_dock_build_default_layout(dockspace_id, size)
		}
		im.DockSpace(dockspace_id, im.Vec2{0, 0}, {}, nil)
	}
	im.End()
}

// ImGuiDockNodeFlagsPrivate_DockSpace — the DockBuilder docs require it on the
// root node; it's a private flag, not in the bindings' public DockNodeFlag enum.
_DOCK_NODE_FLAG_DOCKSPACE :: 1 << 10

// Unity default layout: Hierarchy left, Scene/Game tabs center, Inspector
// right, Project/Console/Output/History tabs bottom.
_dock_build_default_layout :: proc(dockspace_id: im.ID, size: im.Vec2) {
	im.DockBuilderRemoveNode(dockspace_id)
	im.DockBuilderAddNode(dockspace_id, transmute(im.DockNodeFlags)i32(_DOCK_NODE_FLAG_DOCKSPACE))
	im.DockBuilderSetNodeSize(dockspace_id, size)

	center := dockspace_id
	left, right, bottom: im.ID
	im.DockBuilderSplitNode(center, .Left, 0.18, &left, &center)
	im.DockBuilderSplitNode(center, .Right, 0.26, &right, &center)
	im.DockBuilderSplitNode(center, .Down, 0.28, &bottom, &center)

	im.DockBuilderDockWindow(icons.TITLE_HIERARCHY, left)
	im.DockBuilderDockWindow(icons.TITLE_INSPECTOR, right)
	im.DockBuilderDockWindow(icons.TITLE_PROJECT_INSPECTOR, right)
	im.DockBuilderDockWindow(icons.TITLE_SCENE, center)
	im.DockBuilderDockWindow(icons.TITLE_GAME, center)
	im.DockBuilderDockWindow(icons.TITLE_PROJECT, bottom)
	im.DockBuilderDockWindow(icons.TITLE_CONSOLE, bottom)
	im.DockBuilderDockWindow(icons.TITLE_OUTPUT, bottom)
	im.DockBuilderDockWindow(icons.TITLE_HISTORY, bottom)
	im.DockBuilderDockWindow(icons.TITLE_ANIMATION, bottom)
	im.DockBuilderDockWindow(icons.TITLE_PLAYABLE_GRAPH, bottom)
	im.DockBuilderFinish(dockspace_id)
}

// Rebuild the default layout next frame. Also shows the windows the layout
// docks, so a reset never produces empty nodes.
@(menu_item={path="Window/Reset Layout", order=20, shortcut=""})
view_reset_layout_menu :: proc() {
	_dock_layout_reset = true
	menu.show_hierarchy = true
	menu.show_inspector = true
	menu.show_project_inspector = true
	menu.show_scene = true
	menu.show_game = true
	menu.show_project = true
	menu.show_console = true
	menu.show_output = true
	menu.show_history = true
	menu.show_animation = true
	menu.show_playable_graph = true
}

// ---------------------------------------------------------------------------
// Dockable view overlays (Unity Scene View overlays)

OVERLAY_MARGIN :: f32(8)     // gap between a docked overlay and the view edge
OVERLAY_SPACING :: f32(6)    // gap between overlays stacked in one zone
OVERLAY_PAD :: f32(4)        // background padding around overlay content
OVERLAY_DROP_BAND :: f32(48) // px from an edge that counts as a floating dock drop
BAR_DROP_BAND :: f32(26)      // side px band that docks into a left/right strip
BAR_DROP_BAND_TB :: f32(40)   // taller top/bottom band: those strips take the corners
BAR_PAD :: f32(3)            // gap between a strip's items and its edges
OVERLAY_BUTTON_SIZE :: f32(24)
OVERLAY_GRIP_THICK :: f32(12)

// Float and the corners draw OVER the view image (Unity's floating overlays).
// The four Bar_* anchors are Unity's docked toolbars: a strip along that edge
// that reserves its own space, so the image shrinks instead of being covered.
Overlay_Anchor :: enum u8 {
	Float,
	Top_Left,
	Top_Right,
	Bottom_Left,
	Bottom_Right,
	Left,
	Right,
	Bar_Left,
	Bar_Right,
	Bar_Top,
	Bar_Bottom,
}

// Is this anchor one of the docked toolbar strips?
overlay_anchor_is_bar :: proc(a: Overlay_Anchor) -> bool {
	return a == .Bar_Left || a == .Bar_Right || a == .Bar_Top || a == .Bar_Bottom
}

// A strip lays its overlays out along its long axis; left/right strips stack
// their items vertically.
_bar_is_vertical :: proc(a: Overlay_Anchor) -> bool {
	return a == .Bar_Left || a == .Bar_Right
}

// Persisted slice of an overlay (see EditorSettings.scene_overlays).
Overlay_Setting :: struct {
	id:     string,
	anchor: u8,
	x, y:   f32, // normalized float position (used when anchor == Float)
}

// One contributor inside an overlay, registered via @(scene_overlay={id="...",
// order=N}) — see scene_overlays_generated.odin. The proc draws one or more
// imgui widgets (tooltips included, e.g. via overlay_tool_button); between its
// OWN widgets it calls SameLine when !vertical (the system positions the items).
Overlay_Item :: struct {
	draw:  proc(vertical: bool),
	order: int,
}

Overlay :: struct {
	id:         cstring,
	items:      [dynamic]Overlay_Item, // kept sorted by order
	anchor:     Overlay_Anchor,
	float_pos:  [2]f32,  // 0..1 inside the view rect, top-left of content
	size:       im.Vec2, // content size measured last frame ({0,0} first frame)
	items_size: im.Vec2, // the items alone, measured last frame — zero WIDTH
	                     // (all items empty) hides the overlay's chrome entirely
	grip_across: f32,    // grip extent across the overlay: matches the items so
	                     // the grip never makes a strip thicker than its buttons
	bg_min:     im.Vec2, // background rect this frame (hover test)
	bg_max:     im.Vec2,
	dragging:   bool,
	drag_off:   im.Vec2, // grab offset from content top-left, px
	// No background or border: only the grip and the items show (Unity's
	// Orientation overlay). Hover and drag work the same.
	transparent: bool,
}

_overlays: [dynamic]Overlay
_overlay_mouse_over: bool // mouse over any overlay this frame (or dragging one)

// The item currently being drawn — overlay_tool_button reads it to append the
// overlay id/order to tooltips (how-to-extend discoverability).
_overlay_item_ctx: struct {
	overlay_id: cstring,
	order:      int,
	active:     bool,
}

// Where an overlay docks before any saved placement exists (all start
// Top_Left). Call after registration and before overlays_apply_settings.
overlay_set_default_anchor :: proc(overlay_id: cstring, anchor: Overlay_Anchor) {
	for &o in _overlays {
		if o.id == overlay_id do o.anchor = anchor
	}
}

// Draw the overlay without its background panel; the grip stays.
overlay_set_transparent :: proc(overlay_id: cstring) {
	for &o in _overlays {
		if o.id == overlay_id do o.transparent = true
	}
}

// Add an item to overlay `overlay_id`, creating the overlay on first use
// (overlays stack in their dock zone in creation order). Items sort by order.
overlay_add_item :: proc(overlay_id: cstring, draw: proc(vertical: bool), order: int) {
	ov: ^Overlay
	for &o in _overlays {
		if o.id == overlay_id {
			ov = &o
			break
		}
	}
	if ov == nil {
		append(&_overlays, Overlay{id = overlay_id, anchor = .Top_Left})
		ov = &_overlays[len(_overlays) - 1]
	}
	idx := len(ov.items)
	for it, i in ov.items {
		if it.order > order {
			idx = i
			break
		}
	}
	inject_at(&ov.items, idx, Overlay_Item{draw = draw, order = order})
}

overlays_shutdown :: proc() {
	for &ov in _overlays {
		delete(ov.items)
	}
	delete(_overlays)
	_overlays = nil
}

// True while an overlay owns the mouse — the scene view's click-to-pick must
// not select through overlay buttons.
overlay_wants_mouse :: proc() -> bool {
	return _overlay_mouse_over
}

// Apply persisted anchors/positions to registered overlays. Call after all
// overlay_register calls (settings were loaded before ImGui init).
overlays_apply_settings :: proc() {
	for s in editor_settings.scene_overlays {
		for &ov in _overlays {
			if string(ov.id) != s.id do continue
			if s.anchor <= u8(max(Overlay_Anchor)) {
				ov.anchor = Overlay_Anchor(s.anchor)
			}
			ov.float_pos = {clamp(s.x, 0, 1), clamp(s.y, 0, 1)}
		}
	}
}

// Snapshot overlay placement into editor_settings (temp-allocated, mirroring
// open_scene_guids in save_editor_settings).
overlays_capture_settings :: proc() {
	delete(editor_settings.scene_overlays)
	editor_settings.scene_overlays = make([dynamic]Overlay_Setting, context.temp_allocator)
	for ov in _overlays {
		append(&editor_settings.scene_overlays, Overlay_Setting{
			id     = string(ov.id),
			anchor = u8(ov.anchor),
			x      = ov.float_pos.x,
			y      = ov.float_pos.y,
		})
	}
}

// Thickness each toolbar strip needs, measured from LAST frame's overlay
// sizes. A strip with no overlays (or whose overlays all drew nothing) is
// zero and draws nothing at all. Indexed by anchor; only the Bar_* entries
// are ever non-zero.
_bar_thickness: [Overlay_Anchor]f32

// How much room the toolbar strips take from the view, in pixels: left,
// right, top, bottom. The view subtracts these before sizing its image, so
// the strips sit beside the image instead of over it. Sizes come from the
// previous frame, so a strip that gains its first overlay costs one frame to
// settle — the same rule the overlays themselves use.
overlay_bar_insets :: proc() -> (left, right, top, bottom: f32) {
	return _bar_thickness[.Bar_Left], _bar_thickness[.Bar_Right],
	       _bar_thickness[.Bar_Top], _bar_thickness[.Bar_Bottom]
}

// Measure the strips for this frame from last frame's overlay sizes. Call
// BEFORE the view sizes its image; overlays_draw refreshes the sizes after.
// A strip is only as thick as the items themselves plus BAR_PAD, so it hugs
// the buttons instead of reserving a full overlay panel's worth of chrome.
overlays_measure_bars :: proc() {
	_bar_thickness = {}
	for &ov in _overlays {
		if !overlay_anchor_is_bar(ov.anchor) do continue
		// A dragged overlay is following the mouse, so it must not keep
		// reserving space in the strip it came from.
		if ov.dragging || ov.items_size.x < 0.5 do continue
		// The grip spans the items across the strip and is only
		// OVERLAY_GRIP_THICK deep, so it never drives the thickness — but a
		// horizontal strip puts it BESIDE the items, where it must at least
		// fit its own depth.
		// Across a vertical strip the grip spans the items, so the items set
		// the width. Across a horizontal strip the grip sits beside them and
		// is at most a button tall, so the items set the height there too.
		across := _bar_is_vertical(ov.anchor) ? ov.items_size.x : ov.items_size.y
		_bar_thickness[ov.anchor] = max(_bar_thickness[ov.anchor], across + BAR_PAD * 2)
	}
}

// Draw all overlays inside the current window over the view image rect
// [view_min, view_max]. Call after the view image item, inside the same window.
// [bar_min, bar_max] is the FULL content rect including the strip space that
// overlay_bar_insets took out of the image.
overlays_draw :: proc(view_min, view_max: im.Vec2, bar_min := im.Vec2{}, bar_max := im.Vec2{}) {
	_overlay_mouse_over = false
	if view_max.x - view_min.x < 1 || view_max.y - view_min.y < 1 do return

	mp := im.GetMousePos()

	// Zone stacking cursors: each docked overlay advances its zone's cursor
	// along the edge; corners on the right/bottom grow leftward/stay aligned.
	zone_cursor: [Overlay_Anchor]f32

	// Side zones start BELOW the top-corner overlays (last-frame sizes) so a
	// Left/Right overlay never overlaps a Top_Left/Top_Right one.
	top_left_h, top_right_h: f32
	for &ov in _overlays {
		if ov.dragging || ov.size.y <= 0 do continue
		full_y := ov.size.y + OVERLAY_PAD * 2
		#partial switch ov.anchor {
		case .Top_Left:  top_left_h = max(top_left_h, full_y)
		case .Top_Right: top_right_h = max(top_right_h, full_y)
		}
	}
	if top_left_h > 0 do zone_cursor[.Left] = top_left_h + OVERLAY_SPACING
	if top_right_h > 0 do zone_cursor[.Right] = top_right_h + OVERLAY_SPACING

	// Toolbar strips: the band between the full content rect and the image.
	// Drawn before the overlays so their buttons sit on top of the strip.
	bmin := bar_min.x == 0 && bar_min.y == 0 ? view_min : bar_min
	bmax := bar_max.x == 0 && bar_max.y == 0 ? view_max : bar_max
	// Top and bottom strips win the corners: they span the full width, and the
	// side strips run only between them.
	sides_min_y := bmin.y + _bar_thickness[.Bar_Top]
	_overlay_draw_bars(bmin, bmax, view_min, view_max)

	dragging_any := false
	for &ov in _overlays {
		vertical := ov.anchor == .Left || ov.anchor == .Right || _bar_is_vertical(ov.anchor)
		full := ov.size + {OVERLAY_PAD * 2, OVERLAY_PAD * 2}

		// How much room this overlay takes ALONG a strip: the items plus the
		// grip that precedes them (grip depth + the 3px item spacing).
		bar_run: f32
		if overlay_anchor_is_bar(ov.anchor) {
			items_run := _bar_is_vertical(ov.anchor) ? ov.items_size.y : ov.items_size.x
			bar_run = items_run + OVERLAY_GRIP_THICK + 3
		}

		// Content top-left for this frame.
		pos: im.Vec2
		if ov.dragging {
			pos = mp - ov.drag_off
			vertical = false // dragged overlays preview horizontal, Unity-like
			full = ov.size + {OVERLAY_PAD * 2, OVERLAY_PAD * 2}
		} else {
			switch ov.anchor {
			case .Top_Left:
				pos = {view_min.x + OVERLAY_MARGIN + zone_cursor[.Top_Left], view_min.y + OVERLAY_MARGIN}
				zone_cursor[.Top_Left] += full.x + OVERLAY_SPACING
			case .Top_Right:
				pos = {view_max.x - OVERLAY_MARGIN - full.x - zone_cursor[.Top_Right], view_min.y + OVERLAY_MARGIN}
				zone_cursor[.Top_Right] += full.x + OVERLAY_SPACING
			case .Bottom_Left:
				pos = {view_min.x + OVERLAY_MARGIN + zone_cursor[.Bottom_Left], view_max.y - OVERLAY_MARGIN - full.y}
				zone_cursor[.Bottom_Left] += full.x + OVERLAY_SPACING
			case .Bottom_Right:
				pos = {view_max.x - OVERLAY_MARGIN - full.x - zone_cursor[.Bottom_Right], view_max.y - OVERLAY_MARGIN - full.y}
				zone_cursor[.Bottom_Right] += full.x + OVERLAY_SPACING
			case .Left:
				pos = {view_min.x + OVERLAY_MARGIN, view_min.y + OVERLAY_MARGIN + zone_cursor[.Left]}
				zone_cursor[.Left] += full.y + OVERLAY_SPACING
			case .Right:
				pos = {view_max.x - OVERLAY_MARGIN - full.x, view_min.y + OVERLAY_MARGIN + zone_cursor[.Right]}
				zone_cursor[.Right] += full.y + OVERLAY_SPACING
			// Strips position the ITEMS directly (no panel padding, no
			// margin) so the strip stays as thin as its buttons. Side strips
			// run between the top and bottom ones, which span the full width.
			// The grip runs ALONG the strip ahead of the items, so its own
			// length plus the item spacing counts toward the next overlay.
			case .Bar_Left:
				pos = {bmin.x + BAR_PAD, sides_min_y + BAR_PAD + zone_cursor[.Bar_Left]}
				zone_cursor[.Bar_Left] += bar_run + OVERLAY_SPACING
			case .Bar_Right:
				pos = {bmax.x - BAR_PAD - ov.items_size.x, sides_min_y + BAR_PAD + zone_cursor[.Bar_Right]}
				zone_cursor[.Bar_Right] += bar_run + OVERLAY_SPACING
			case .Bar_Top:
				pos = {bmin.x + BAR_PAD + zone_cursor[.Bar_Top], bmin.y + BAR_PAD}
				zone_cursor[.Bar_Top] += bar_run + OVERLAY_SPACING
			case .Bar_Bottom:
				pos = {bmin.x + BAR_PAD + zone_cursor[.Bar_Bottom], bmax.y - BAR_PAD - ov.items_size.y}
				zone_cursor[.Bar_Bottom] += bar_run + OVERLAY_SPACING
			case .Float:
				span := view_max - view_min - full
				pos = view_min + {ov.float_pos.x * max(span.x, 0), ov.float_pos.y * max(span.y, 0)}
			}
			// pos is background top-left in zone math; shift to content.
			// Strips already positioned their content directly.
			if !overlay_anchor_is_bar(ov.anchor) {
				pos += {OVERLAY_PAD, OVERLAY_PAD}
			}
		}

		// Clamp inside the view (also keeps floaters visible after a resize),
		// on whole pixels: a floater's normalized position lands on fractions,
		// and imgui text at a fractional x renders blurred.
		// Strip overlays clamp to the whole content rect (their strip lies
		// outside the image), everything else to the image.
		cmin := overlay_anchor_is_bar(ov.anchor) && !ov.dragging ? bmin : view_min
		cmax := overlay_anchor_is_bar(ov.anchor) && !ov.dragging ? bmax : view_max
		pos.x = math.round(clamp(pos.x, cmin.x + OVERLAY_PAD, max(cmax.x - full.x + OVERLAY_PAD, cmin.x + OVERLAY_PAD)))
		pos.y = math.round(clamp(pos.y, cmin.y + OVERLAY_PAD, max(cmax.y - full.y + OVERLAY_PAD, cmin.y + OVERLAY_PAD)))

		_overlay_draw_one(&ov, pos, vertical)

		if ov.dragging {
			dragging_any = true
			if !im.IsMouseDown(.Left) {
				// Drop: dock into the zone under the cursor, else float here.
				ov.dragging = false
				ov.anchor = _overlay_zone_from_pos(mp, bmin, bmax)
				if ov.anchor == .Float {
					full = ov.size + {OVERLAY_PAD * 2, OVERLAY_PAD * 2}
					span := view_max - view_min - full
					ov.float_pos = {
						span.x > 0 ? clamp((pos.x - OVERLAY_PAD - view_min.x) / span.x, 0, 1) : 0,
						span.y > 0 ? clamp((pos.y - OVERLAY_PAD - view_min.y) / span.y, 0, 1) : 0,
					}
				}
			}
		}

		if mp.x >= ov.bg_min.x && mp.y >= ov.bg_min.y && mp.x <= ov.bg_max.x && mp.y <= ov.bg_max.y {
			_overlay_mouse_over = true
		}
	}

	if dragging_any {
		_overlay_mouse_over = true
		_overlay_draw_drop_zones(mp, bmin, bmax)
	}
}

// The strip band for `bar` between the content rect [bmin, bmax] and the
// image rect [imin, imax]. ok=false when the strip is empty.
_overlay_bar_rect :: proc(bar: Overlay_Anchor, bmin, bmax, imin, imax: im.Vec2) -> (rmin, rmax: im.Vec2, ok: bool) {
	if _bar_thickness[bar] <= 0 do return {}, {}, false
	#partial switch bar {
	case .Bar_Left:   return bmin, {imin.x, bmax.y}, true
	case .Bar_Right:  return {imax.x, bmin.y}, bmax, true
	case .Bar_Top:    return bmin, {bmax.x, imin.y}, true
	case .Bar_Bottom: return {bmin.x, imax.y}, bmax, true
	}
	return {}, {}, false
}

// Flat background behind each non-empty toolbar strip, with a single seam
// line facing the image so the strip reads as chrome rather than as part of
// the render.
_overlay_draw_bars :: proc(bmin, bmax, imin, imax: im.Vec2) {
	dl := im.GetWindowDrawList()
	bg := im.GetColorU32(.WindowBg)
	seam := im.GetColorU32(.Border)
	for bar in Overlay_Anchor {
		if !overlay_anchor_is_bar(bar) do continue
		rmin, rmax, ok := _overlay_bar_rect(bar, bmin, bmax, imin, imax)
		if !ok do continue
		im.DrawList_AddRectFilled(dl, rmin, rmax, bg)
		#partial switch bar {
		case .Bar_Left:   im.DrawList_AddLine(dl, {rmax.x, rmin.y}, rmax, seam)
		case .Bar_Right:  im.DrawList_AddLine(dl, rmin, {rmin.x, rmax.y}, seam)
		case .Bar_Top:    im.DrawList_AddLine(dl, {rmin.x, rmax.y}, rmax, seam)
		case .Bar_Bottom: im.DrawList_AddLine(dl, rmin, {rmax.x, rmin.y}, seam)
		}
	}
}

// One overlay: translucent rounded background (last frame's size), grip
// handle, then the body items in a measured group.
_overlay_draw_one :: proc(ov: ^Overlay, pos: im.Vec2, vertical: bool) {
	dl := im.GetWindowDrawList()

	// An overlay whose items drew NOTHING last frame shows no chrome at all
	// (no background, no grip, no hover) — a conditional overlay like the
	// particles Particle Effect panel vanishes with its content. The items
	// still run every frame, so it reappears the moment one draws.
	empty := ov.items_size.x < 0.5

	// A strip overlay has no panel of its own: the strip IS its background, so
	// it draws only the grip and the items (Unity's docked toolbar).
	in_bar := overlay_anchor_is_bar(ov.anchor) && !ov.dragging

	ov.bg_min = pos - {OVERLAY_PAD, OVERLAY_PAD}
	ov.bg_max = empty ? ov.bg_min : pos + ov.size + {OVERLAY_PAD, OVERLAY_PAD}
	if ov.size.x > 0 && !empty && !ov.transparent && !in_bar { // size is unknown on the very first frame
		bg := im.GetStyleColorVec4(.WindowBg)^
		bg.w = 0.85
		im.DrawList_AddRectFilled(dl, ov.bg_min, ov.bg_max, im.GetColorU32ImVec4(bg), 4)
		im.DrawList_AddRect(dl, ov.bg_min, ov.bg_max, im.GetColorU32(.Border), 4)
	}

	im.PushID(ov.id)
	defer im.PopID()
	im.PushStyleVarImVec2(.ItemSpacing, im.Vec2{3, 3})
	defer im.PopStyleVar()

	im.SetCursorScreenPos(pos)
	im.BeginGroup()

	if !empty {
		// Grip: invisible button with the drag glyph; dragging it moves the
		// overlay (drop handling in overlays_draw). A grip laid out ACROSS the
		// overlay (items stacked below it) uses the horizontal bars glyph, one
		// beside the items uses the vertical dots.
		grip_size := vertical ? im.Vec2{ov.grip_across, OVERLAY_GRIP_THICK} : im.Vec2{OVERLAY_GRIP_THICK, ov.grip_across}
		grip_min := im.GetCursorScreenPos()
		im.InvisibleButton("##grip", grip_size)
		if im.IsItemActive() && im.IsMouseDragging(.Left, 2) && !ov.dragging {
			ov.dragging = true
			ov.drag_off = im.GetMousePos() - pos
		}
		grip_col := im.GetColorU32(im.IsItemHovered({}) || ov.dragging ? .Text : .TextDisabled)
		glyph: cstring = vertical ? icons.ICON_MD_DRAG_HANDLE : icons.ICON_MD_DRAG_INDICATOR
		icon_size := im.CalcTextSize(glyph, nil, false, -1)
		im.DrawList_AddText(dl, grip_min + (grip_size - icon_size) * 0.5, grip_col, glyph)
		if !vertical do im.SameLine()
	}

	// Items in order, measured as their own group; the ctx lets their
	// widgets' tooltips show where the hovered item lives
	// (see _overlay_item_tooltip).
	im.BeginGroup()
	cursor_before := im.GetCursorScreenPos()
	for &it, idx in ov.items {
		if !vertical && idx > 0 do im.SameLine()
		_overlay_item_ctx = {overlay_id = ov.id, order = it.order, active = true}
		it.draw(vertical)
	}
	_overlay_item_ctx = {}
	// Did the items submit anything? Any item advances the cursor. The group's
	// own rect cannot tell: imgui's EndGroup folds the LAST item's rect into an
	// empty group (its #7543 workaround), so an empty group measures the width
	// out to whatever overlay drew before it — a phantom size that flickers.
	drew := im.GetCursorScreenPos() != cursor_before
	im.EndGroup()
	ov.items_size = drew ? im.GetItemRectSize() : {}
	// The grip runs the full extent of the items across the overlay, so its
	// glyph centers on them: as wide as the items when they stack below it,
	// as tall as them when they sit beside it.
	across := vertical ? ov.items_size.x : ov.items_size.y
	ov.grip_across = across > 0 ? across : OVERLAY_BUTTON_SIZE

	im.EndGroup()
	ov.size = drew ? im.GetItemRectSize() : {}
}

// Tooltip text + where the hovered item lives so anyone can see how to
// target/reorder it with @(scene_overlay). No braces: ProggyClean renders
// { } poorly at 13px.
_overlay_item_tooltip :: proc(tip: cstring) -> cstring {
	if !_overlay_item_ctx.active do return tip
	return fmt.ctprintf("%s\nid=\"%s\", order=%d", tip, _overlay_item_ctx.overlay_id, _overlay_item_ctx.order)
}

// Which zone a drop at mp lands in: edge bands split at the view's midpoint
// for top/bottom (so corners fall out naturally), left/right take the middle
// sections, everything else floats.
_overlay_zone_from_pos :: proc(mp, view_min, view_max: im.Vec2) -> Overlay_Anchor {
	if mp.x < view_min.x || mp.x > view_max.x || mp.y < view_min.y || mp.y > view_max.y do return .Float
	mid_x := (view_min.x + view_max.x) * 0.5
	b := OVERLAY_DROP_BAND
	// Outermost band on each side is the docked toolbar strip; the floating
	// corner and side zones sit just inside it. Top and bottom are tested
	// FIRST and span the full width, matching how those strips take the
	// corners when drawn; the side bands then run only between them.
	if mp.y < view_min.y + BAR_DROP_BAND_TB do return .Bar_Top
	if mp.y > view_max.y - BAR_DROP_BAND_TB do return .Bar_Bottom
	if mp.x < view_min.x + BAR_DROP_BAND do return .Bar_Left
	if mp.x > view_max.x - BAR_DROP_BAND do return .Bar_Right
	if mp.y < view_min.y + BAR_DROP_BAND_TB + b do return mp.x < mid_x ? .Top_Left : .Top_Right
	if mp.y > view_max.y - BAR_DROP_BAND_TB - b do return mp.x < mid_x ? .Bottom_Left : .Bottom_Right
	if mp.x < view_min.x + BAR_DROP_BAND + b do return .Left
	if mp.x > view_max.x - BAR_DROP_BAND - b do return .Right
	return .Float
}

_overlay_zone_rect :: proc(zone: Overlay_Anchor, view_min, view_max: im.Vec2) -> (rmin, rmax: im.Vec2, ok: bool) {
	mid_x := (view_min.x + view_max.x) * 0.5
	b := OVERLAY_DROP_BAND
	// Inner rect: everything the strip bands leave over.
	k := BAR_DROP_BAND
	ktb := BAR_DROP_BAND_TB
	imin := im.Vec2{view_min.x + k, view_min.y + ktb}
	imax := im.Vec2{view_max.x - k, view_max.y - ktb}
	switch zone {
	// Top and bottom span the full width and take the corners; the sides run
	// between them (the same split the drawn strips use).
	case .Bar_Top:      return view_min, {view_max.x, view_min.y + ktb}, true
	case .Bar_Bottom:   return {view_min.x, view_max.y - ktb}, view_max, true
	case .Bar_Left:     return {view_min.x, imin.y}, {view_min.x + k, imax.y}, true
	case .Bar_Right:    return {view_max.x - k, imin.y}, {view_max.x, imax.y}, true
	case .Top_Left:     return imin, {mid_x, imin.y + b}, true
	case .Top_Right:    return {mid_x, imin.y}, {imax.x, imin.y + b}, true
	case .Bottom_Left:  return {imin.x, imax.y - b}, {mid_x, imax.y}, true
	case .Bottom_Right: return {mid_x, imax.y - b}, imax, true
	case .Left:         return {imin.x, imin.y + b}, {imin.x + b, imax.y - b}, true
	case .Right:        return {imax.x - b, imin.y + b}, {imax.x, imax.y - b}, true
	case .Float:        return {}, {}, false
	}
	return {}, {}, false
}

// While an overlay drags: faint fill on every dock zone, accent on the one
// under the cursor (DockingPreview, same color imgui uses for window docking).
_overlay_draw_drop_zones :: proc(mp, view_min, view_max: im.Vec2) {
	dl := im.GetWindowDrawList()
	hot := _overlay_zone_from_pos(mp, view_min, view_max)
	for zone in Overlay_Anchor {
		rmin, rmax, ok := _overlay_zone_rect(zone, view_min, view_max)
		if !ok do continue
		alpha: f32 = zone == hot ? 0.5 : 0.12
		im.DrawList_AddRectFilled(dl, rmin, rmax, im.GetColorU32(.DockingPreview, alpha), 3)
		im.DrawList_AddRect(dl, rmin, rmax, im.GetColorU32(.DockingPreview, alpha + 0.2), 3)
	}
}

// ---------------------------------------------------------------------------
// Overlay button helper (shared look for overlays)

OVERLAY_ARROW_WIDTH :: f32(11)  // dropdown half, narrower than the icon half
OVERLAY_SPLIT_GAP :: f32(1)     // 1px seam between the two halves
// Full width of a split button. Single-icon buttons default to this too, so a
// overlay of plain buttons and split buttons reads as one consistent row.
OVERLAY_SPLIT_WIDTH :: OVERLAY_BUTTON_SIZE + OVERLAY_SPLIT_GAP + OVERLAY_ARROW_WIDTH

// Icon toggle button for overlays; SameLine handled by the caller's
// vertical flag via overlay body procs. width = 0 auto-sizes to the label
// (icon + word buttons); the default matches a split button's full width so
// single-icon buttons line up with them.
overlay_tool_button :: proc(icon: cstring, tooltip: cstring, active: bool, width: f32 = OVERLAY_SPLIT_WIDTH) -> bool {
	if active {
		im.PushStyleColorImVec4(.Button, im.GetStyleColorVec4(.ButtonActive)^)
	}
	clicked := im.Button(icon, im.Vec2{width, OVERLAY_BUTTON_SIZE})
	if active {
		im.PopStyleColor()
	}
	if im.IsItemHovered({}) {
		im.SetTooltip(_overlay_item_tooltip(tooltip))
	}
	return clicked
}

// Split toggle+dropdown button for overlays: the icon on the left is a
// toggle (returns toggled=true on click), the narrow arrow on the right opens
// the settings popup (returns arrow=true). A 1px seam separates the two halves.
// `active` lights the icon while the tool is on.
// `id` must be unique per split button (the arrow glyph alone is shared, so
// without it two split buttons collide on the same imgui ID).
overlay_split_button :: proc(id, icon, tooltip: cstring, active: bool) -> (toggled, arrow: bool) {
	im.PushID(id)
	defer im.PopID()

	// 1px seam between the halves. Trim frame padding so the fixed-size buttons
	// center their glyphs cleanly instead of reserving room for default padding
	// and drifting the icon.
	im.PushStyleVarImVec2(.ItemSpacing, im.Vec2{OVERLAY_SPLIT_GAP, 0})
	im.PushStyleVarImVec2(.FramePadding, im.Vec2{0, 0})
	defer im.PopStyleVar(2)

	if active {
		im.PushStyleColorImVec4(.Button, im.GetStyleColorVec4(.ButtonActive)^)
	}
	toggled = im.Button(icon, im.Vec2{OVERLAY_BUTTON_SIZE, OVERLAY_BUTTON_SIZE})
	if im.IsItemHovered({}) {
		im.SetTooltip(_overlay_item_tooltip(tooltip))
	}
	im.SameLine()
	// Arrow half: empty-label button so imgui's text centering can't drift the
	// glyph (the EXPAND_MORE glyph has left bearing that offsets it in a narrow
	// box). Draw the glyph ourselves, centered on the button rect.
	arrow = im.Button("##arrow", im.Vec2{OVERLAY_ARROW_WIDTH, OVERLAY_BUTTON_SIZE})
	_draw_centered_glyph(icons.ICON_MD_EXPAND_MORE, im.GetItemRectMin(), im.GetItemRectMax())
	if active {
		im.PopStyleColor()
	}
	if im.IsItemHovered({}) {
		im.SetTooltip(_overlay_item_tooltip("Settings"))
	}
	return
}

// Draw a glyph centered within the rect [rmin, rmax] on the current draw list,
// in the current text color.
_draw_centered_glyph :: proc(glyph: cstring, rmin, rmax: im.Vec2) {
	sz := im.CalcTextSize(glyph, nil, false, -1)
	pos := im.Vec2{
		rmin.x + (rmax.x - rmin.x - sz.x) * 0.5,
		rmin.y + (rmax.y - rmin.y - sz.y) * 0.5,
	}
	im.DrawList_AddText(im.GetWindowDrawList(), pos, im.GetColorU32(.Text), glyph)
}
