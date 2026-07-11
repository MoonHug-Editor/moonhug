package editor

// Docking: the main dockspace (with a Unity-style default layout built via
// DockBuilder on first run / View->Reset Layout) and dockable view toolbars
// modeled on Unity's Scene View overlays:
// - toolbars dock to the view's corners/edges or float anywhere inside it
// - drag by the grip handle; drop zones highlight while dragging
// - docking to the left/right edge turns the toolbar vertical
// Overlay placement persists in editor_settings (anchor + normalized float pos).

import "core:fmt"
import im "../../external/odin-imgui"
import "menu"

// ---------------------------------------------------------------------------
// Main dockspace

_dock_layout_reset: bool

// Host window under the main toolbar holding the central dockspace. Builds the
// default layout when the dockspace node has no saved state (fresh imgui.ini)
// or a reset was requested. Must run before any dockable view's Begin().
draw_dockspace :: proc() {
	vp := im.GetMainViewport()
	pos := im.Vec2{vp.WorkPos.x, vp.WorkPos.y + f32(TOOLBAR_HEIGHT)}
	size := im.Vec2{vp.WorkSize.x, vp.WorkSize.y - f32(TOOLBAR_HEIGHT)}
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

	im.DockBuilderDockWindow("Hierarchy", left)
	im.DockBuilderDockWindow("Inspector", right)
	im.DockBuilderDockWindow("Project Inspector", right)
	im.DockBuilderDockWindow("Scene", center)
	im.DockBuilderDockWindow("Game", center)
	im.DockBuilderDockWindow("Project", bottom)
	im.DockBuilderDockWindow("Console", bottom)
	im.DockBuilderDockWindow("Output", bottom)
	im.DockBuilderDockWindow("History", bottom)
	im.DockBuilderFinish(dockspace_id)
}

// Rebuild the default layout next frame. Also shows the windows the layout
// docks, so a reset never produces empty nodes.
@(menu_item={path="View/Reset Layout", order=20, shortcut=""})
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
}

// ---------------------------------------------------------------------------
// Dockable view toolbars (Unity Scene View overlays)

OVERLAY_MARGIN :: f32(8)     // gap between a docked toolbar and the view edge
OVERLAY_SPACING :: f32(6)    // gap between toolbars stacked in one zone
OVERLAY_PAD :: f32(4)        // background padding around toolbar content
OVERLAY_DROP_BAND :: f32(48) // px from an edge that counts as a dock drop
OVERLAY_BUTTON_SIZE :: f32(24)
OVERLAY_GRIP_THICK :: f32(12)

Overlay_Anchor :: enum u8 {
	Float,
	Top_Left,
	Top_Right,
	Bottom_Left,
	Bottom_Right,
	Left,
	Right,
}

// Persisted slice of an overlay (see EditorSettings.scene_overlays).
Overlay_Setting :: struct {
	id:     string,
	anchor: u8,
	x, y:   f32, // normalized float position (used when anchor == Float)
}

// One contributor inside a toolbar, registered via @(scene_toolbar={id="...",
// order=N}) — see scene_toolbars_generated.odin. The proc draws one or more
// imgui widgets (tooltips included, e.g. via overlay_tool_button); between its
// OWN widgets it calls SameLine when !vertical (the system positions the items).
Overlay_Item :: struct {
	draw:  proc(vertical: bool),
	order: int,
}

Overlay :: struct {
	id:        cstring,
	items:     [dynamic]Overlay_Item, // kept sorted by order
	anchor:    Overlay_Anchor,
	float_pos: [2]f32,  // 0..1 inside the view rect, top-left of content
	size:      im.Vec2, // content size measured last frame ({0,0} first frame)
	bg_min:    im.Vec2, // background rect this frame (hover test)
	bg_max:    im.Vec2,
	dragging:  bool,
	drag_off:  im.Vec2, // grab offset from content top-left, px
}

_overlays: [dynamic]Overlay
_overlay_mouse_over: bool // mouse over any overlay this frame (or dragging one)

// The item currently being drawn — overlay_tool_button reads it to append the
// toolbar id/order to tooltips (how-to-extend discoverability).
_overlay_item_ctx: struct {
	toolbar_id: cstring,
	order:      int,
	active:     bool,
}

// Add an item to toolbar `toolbar_id`, creating the toolbar on first use
// (toolbars stack in their dock zone in creation order). Items sort by order.
overlay_add_item :: proc(toolbar_id: cstring, draw: proc(vertical: bool), order: int) {
	ov: ^Overlay
	for &o in _overlays {
		if o.id == toolbar_id {
			ov = &o
			break
		}
	}
	if ov == nil {
		append(&_overlays, Overlay{id = toolbar_id, anchor = .Top_Left})
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
// not select through toolbar buttons.
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

// Draw all overlays inside the current window over the view image rect
// [view_min, view_max]. Call after the view image item, inside the same window.
overlays_draw :: proc(view_min, view_max: im.Vec2) {
	_overlay_mouse_over = false
	if view_max.x - view_min.x < 1 || view_max.y - view_min.y < 1 do return

	mp := im.GetMousePos()

	// Zone stacking cursors: each docked overlay advances its zone's cursor
	// along the edge; corners on the right/bottom grow leftward/stay aligned.
	zone_cursor: [Overlay_Anchor]f32

	// Side zones start BELOW the top-corner toolbars (last-frame sizes) so a
	// Left/Right toolbar never overlaps a Top_Left/Top_Right one.
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

	dragging_any := false
	for &ov in _overlays {
		vertical := ov.anchor == .Left || ov.anchor == .Right
		full := ov.size + {OVERLAY_PAD * 2, OVERLAY_PAD * 2}

		// Content top-left for this frame.
		pos: im.Vec2
		if ov.dragging {
			pos = mp - ov.drag_off
			vertical = false // dragged toolbars preview horizontal, Unity-like
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
			case .Float:
				span := view_max - view_min - full
				pos = view_min + {ov.float_pos.x * max(span.x, 0), ov.float_pos.y * max(span.y, 0)}
			}
			// pos is background top-left in zone math; shift to content.
			pos += {OVERLAY_PAD, OVERLAY_PAD}
		}

		// Clamp inside the view (also keeps floaters visible after a resize).
		pos.x = clamp(pos.x, view_min.x + OVERLAY_PAD, max(view_max.x - full.x + OVERLAY_PAD, view_min.x + OVERLAY_PAD))
		pos.y = clamp(pos.y, view_min.y + OVERLAY_PAD, max(view_max.y - full.y + OVERLAY_PAD, view_min.y + OVERLAY_PAD))

		_overlay_draw_one(&ov, pos, vertical)

		if ov.dragging {
			dragging_any = true
			if !im.IsMouseDown(.Left) {
				// Drop: dock into the zone under the cursor, else float here.
				ov.dragging = false
				ov.anchor = _overlay_zone_from_pos(mp, view_min, view_max)
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
		_overlay_draw_drop_zones(mp, view_min, view_max)
	}
}

// One overlay: translucent rounded background (last frame's size), grip
// handle, then the body items in a measured group.
_overlay_draw_one :: proc(ov: ^Overlay, pos: im.Vec2, vertical: bool) {
	dl := im.GetWindowDrawList()

	ov.bg_min = pos - {OVERLAY_PAD, OVERLAY_PAD}
	ov.bg_max = pos + ov.size + {OVERLAY_PAD, OVERLAY_PAD}
	if ov.size.x > 0 { // size is unknown on the very first frame
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

	// Grip: invisible button with drag_indicator dots; dragging it moves the
	// toolbar (drop handling in overlays_draw).
	grip_size := vertical ? im.Vec2{OVERLAY_BUTTON_SIZE, OVERLAY_GRIP_THICK} : im.Vec2{OVERLAY_GRIP_THICK, OVERLAY_BUTTON_SIZE}
	grip_min := im.GetCursorScreenPos()
	im.InvisibleButton("##grip", grip_size)
	if im.IsItemActive() && im.IsMouseDragging(.Left, 2) && !ov.dragging {
		ov.dragging = true
		ov.drag_off = im.GetMousePos() - pos
	}
	grip_col := im.GetColorU32(im.IsItemHovered({}) || ov.dragging ? .Text : .TextDisabled)
	icon_size := im.CalcTextSize(ICON_MD_DRAG_INDICATOR, nil, false, -1)
	im.DrawList_AddText(dl, grip_min + (grip_size - icon_size) * 0.5, grip_col, ICON_MD_DRAG_INDICATOR)

	// Items in order; the ctx lets their widgets' tooltips show where the
	// hovered item lives (see _overlay_item_tooltip).
	for &it in ov.items {
		if !vertical do im.SameLine()
		_overlay_item_ctx = {toolbar_id = ov.id, order = it.order, active = true}
		it.draw(vertical)
	}
	_overlay_item_ctx = {}

	im.EndGroup()
	ov.size = im.GetItemRectSize()
}

// Tooltip text + where the hovered item lives so anyone can see how to
// target/reorder it with @(scene_toolbar). No braces: ProggyClean renders
// { } poorly at 13px.
_overlay_item_tooltip :: proc(tip: cstring) -> cstring {
	if !_overlay_item_ctx.active do return tip
	return fmt.ctprintf("%s\nid=\"%s\", order=%d", tip, _overlay_item_ctx.toolbar_id, _overlay_item_ctx.order)
}

// Which zone a drop at mp lands in: edge bands split at the view's midpoint
// for top/bottom (so corners fall out naturally), left/right take the middle
// sections, everything else floats.
_overlay_zone_from_pos :: proc(mp, view_min, view_max: im.Vec2) -> Overlay_Anchor {
	if mp.x < view_min.x || mp.x > view_max.x || mp.y < view_min.y || mp.y > view_max.y do return .Float
	mid_x := (view_min.x + view_max.x) * 0.5
	if mp.y < view_min.y + OVERLAY_DROP_BAND do return mp.x < mid_x ? .Top_Left : .Top_Right
	if mp.y > view_max.y - OVERLAY_DROP_BAND do return mp.x < mid_x ? .Bottom_Left : .Bottom_Right
	if mp.x < view_min.x + OVERLAY_DROP_BAND do return .Left
	if mp.x > view_max.x - OVERLAY_DROP_BAND do return .Right
	return .Float
}

_overlay_zone_rect :: proc(zone: Overlay_Anchor, view_min, view_max: im.Vec2) -> (rmin, rmax: im.Vec2, ok: bool) {
	mid_x := (view_min.x + view_max.x) * 0.5
	b := OVERLAY_DROP_BAND
	switch zone {
	case .Top_Left:     return view_min, {mid_x, view_min.y + b}, true
	case .Top_Right:    return {mid_x, view_min.y}, {view_max.x, view_min.y + b}, true
	case .Bottom_Left:  return {view_min.x, view_max.y - b}, {mid_x, view_max.y}, true
	case .Bottom_Right: return {mid_x, view_max.y - b}, view_max, true
	case .Left:         return {view_min.x, view_min.y + b}, {view_min.x + b, view_max.y - b}, true
	case .Right:        return {view_max.x - b, view_min.y + b}, {view_max.x, view_max.y - b}, true
	case .Float:        return {}, {}, false
	}
	return {}, {}, false
}

// While a toolbar drags: faint fill on every dock zone, accent on the one
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
// Toolbar button helper (shared look for overlay toolbars)

// Icon toggle button for overlay toolbars; SameLine handled by the caller's
// vertical flag via overlay body procs. width = 0 auto-sizes to the label
// (icon + word buttons); the default is a square icon button.
overlay_tool_button :: proc(icon: cstring, tooltip: cstring, active: bool, width: f32 = OVERLAY_BUTTON_SIZE) -> bool {
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
