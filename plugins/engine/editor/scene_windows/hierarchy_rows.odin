package scene_windows

// The Hierarchy's rows: the flat list a copy of the window shows, and how one
// row is drawn and used.
//
// The list is every scene's header, and under an open one its objects, each
// open object followed by its children. It is built again each frame from the
// open rows only, so a folded subtree costs nothing. Only the rows on screen
// are drawn (im.ListClipper), each with one item and its marks drawn straight
// into the draw list. Drop places exist only while something is dragged.
//
// A row, left to right: the gutter with the pick lock, the indent, the fold
// arrow, the glyph, the name, and at the right end the ">" of a nested scene.

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:mem"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "core:encoding/uuid"
import im "moonhug:external/odin-imgui"
import engine "moonhug:packages/engine"
import core "moonhug:libs/core"
import "moonhug:editor/drag"
import "moonhug:editor/icons"
import "moonhug:editor/menu"
import "moonhug:editor/session"
import "moonhug:editor/widgets"
import "moonhug:libs/log"
import "moonhug:libs/prof"
import "moonhug:packages/engine/editor/scene_tools"

Hier_Row_Kind :: enum u8 {
	Scene,
	Object,
}

Hier_Row :: struct {
	kind:         Hier_Row_Kind,
	// The loaded scene the row is listed under, and for an object the scene
	// its transform belongs to.
	section:      ^engine.Scene,
	scene:        ^engine.Scene,
	tH:           engine.Transform_Handle,
	parent:       engine.Transform_Handle,
	// The nested scene the object hosts, nil for none.
	ns:           ^engine.NestedScene,
	depth:        i32,
	// The object's place among its parent's children.
	sibling:      i32,
	has_children: bool,
	open:         bool,
	is_root:      bool,
	// Inside a nested scene: not dragged, not a drop place.
	nested:       bool,
	// Off itself or under an object that is off.
	inactive:     bool,
	// A nested scene's host or its content: the blue rows.
	blue:         bool,
	// Added to a nested scene in this scene.
	added:        bool,
}

// What the row walk needs at every step.
@(private = "file")
_Walk :: struct {
	hv:       ^Hierarchy_Window,
	section:  ^engine.Scene,
	host_ns:  map[engine.Transform_Handle]^engine.NestedScene,
	plain:    []string, // the filter's name words, nil for no filter
	tagged:   []string,
	filtered: bool,
}

// Builds the copy's row list for this frame.
@(private)
_hierarchy_rows_build :: proc(hv: ^Hierarchy_Window, filter: []string) {
	prof.zone()
	clear(&hv.rows)
	sm := engine.ctx_scene_manager()
	walk := _Walk{hv = hv, filtered = len(filter) > 0}
	if walk.filtered do walk.plain, walk.tagged = widgets.search_split(filter)
	for i in 0 ..< sm.count {
		scene := sm.loaded[i]
		if scene == nil || !engine.sm_scene_is_valid(scene) do continue
		open := !hv.scenes_closed[scene]
		append(&hv.rows, Hier_Row{kind = .Scene, section = scene, scene = scene, open = open, has_children = true})
		if !open do continue
		walk.section = scene
		// Hosts resolved from the nested scene side, once per scene.
		walk.host_ns = engine.scene_nested_hosts_map(scene)
		_rows_add(&walk, engine.Transform_Handle(scene.root.handle), scene, {}, 0, 0, true, false, false, false)
	}
	// Handles of destroyed objects never come back: drop them once they
	// outnumber the live rows by far.
	if len(hv.open) > 4 * len(hv.rows) + 1024 {
		w := engine.ctx_world()
		dead := make([dynamic]engine.Transform_Handle, context.temp_allocator)
		for h in hv.open do if !engine.pool_valid(&w.transforms, engine.Handle(h)) do append(&dead, h)
		for h in dead do delete_key(&hv.open, h)
	}
}

@(private = "file")
_rows_add :: proc(walk: ^_Walk, tH: engine.Transform_Handle, scene: ^engine.Scene, parent: engine.Transform_Handle, depth, sibling: i32, is_root, parent_inactive, parent_nested, parent_blue: bool) {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return
	sc := t.scene if t.scene != nil else scene
	ns, is_host := walk.host_ns[tH]
	if !is_host do ns = nil
	nested := t.nested_owned || parent_nested
	inactive := parent_inactive || !t.is_active
	blue := ns != nil || t.nested_owned

	row := Hier_Row {
		kind     = .Object,
		section  = walk.section,
		scene    = sc,
		tH       = tH,
		parent   = parent,
		ns       = ns,
		sibling  = sibling,
		is_root  = is_root,
		nested   = nested,
		inactive = inactive,
		blue     = blue,
		added    = !t.nested_owned && parent_blue && ns == nil,
	}

	// With a filter the matching objects are a flat list: no indent, no
	// children under a row, and every object is looked at.
	if walk.filtered {
		if widgets.search_match(t.name, walk.plain) && scene_object_has_components(t, walk.tagged) do append(&walk.hv.rows, row)
		for child, i in t.children {
			ch, ok := engine.scene_ref_resolve_transform(sc, child, tH)
			if !ok do continue
			_rows_add(walk, ch, sc, tH, 0, i32(i), false, inactive, nested, blue)
		}
		return
	}

	row.depth = depth
	row.has_children = len(t.children) > 0
	row.open = row.has_children && _row_open(walk.hv, tH, t, sc, is_root)
	append(&walk.hv.rows, row)
	if !row.open do return
	for child, i in t.children {
		ch, ok := engine.scene_ref_resolve_transform(sc, child, tH)
		if !ok do continue
		_rows_add(walk, ch, sc, tH, depth + 1, i32(i), false, inactive, nested, blue)
	}
}

// Whether the row shows its children. The first time a copy sees a row it
// opens as the scene's saved folds say, and a scene with none saved starts
// with its root open.
@(private = "file")
_row_open :: proc(hv: ^Hierarchy_Window, tH: engine.Transform_Handle, t: ^engine.Transform, sc: ^engine.Scene, is_root: bool) -> bool {
	if open, seen := hv.open[tH]; seen do return open
	open := is_root
	if sc != nil {
		if folds := core.per_asset_get(&hierarchy_folds, sc.asset_guid); folds != nil {
			open = _fold_is_open(folds, t.local_id)
		} else if open {
			_fold_record(sc.asset_guid, t.local_id, true)
		}
	}
	hv.open[tH] = open
	return open
}

// Opens or closes a row in one copy, and keeps it in the scene's folds.
@(private)
_hierarchy_set_open :: proc(hv: ^Hierarchy_Window, tH: engine.Transform_Handle, open: bool) {
	// The spare state of no open copy holds no map.
	if hv.open.allocator.procedure == nil do return
	hv.open[tH] = open
	t := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(tH))
	if t != nil && t.scene != nil do _fold_record(t.scene.asset_guid, t.local_id, open)
}

// The same for every object under `tH`.
@(private)
_hierarchy_set_open_deep :: proc(hv: ^Hierarchy_Window, tH: engine.Transform_Handle, open: bool) {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil || t.scene == nil do return
	for child in t.children {
		ch, ok := engine.scene_ref_resolve_transform(t.scene, child, tH)
		if !ok do continue
		ct := engine.pool_get(&w.transforms, engine.Handle(ch))
		if ct == nil do continue
		if len(ct.children) > 0 {
			_hierarchy_set_open(hv, ch, open)
			_hierarchy_set_open_deep(hv, ch, open)
		}
	}
}

// The row of an object in the copy's list, -1 when it is not shown.
@(private)
_hierarchy_row_index :: proc(hv: ^Hierarchy_Window, tH: engine.Transform_Handle) -> int {
	if tH == _HANDLE_NONE do return -1
	for row, i in hv.rows do if row.kind == .Object && row.tH == tH do return i
	return -1
}

// Shift-click: the rows from the active one to `target` become the selection.
@(private = "file")
_select_range :: proc(hv: ^Hierarchy_Window, target: engine.Transform_Handle) {
	a := _hierarchy_row_index(hv, session.active())
	b := _hierarchy_row_index(hv, target)
	if a == -1 || b == -1 {
		session.select_only(target)
		return
	}
	session.select_clear()
	step := 1 if a <= b else -1
	for i := a; ; i += step {
		if hv.rows[i].kind == .Object do session.select_add(hv.rows[i].tH)
		if i == b do break
	}
}

// --- Drawing -----------------------------------------------------------------

// The theme's item spacing, kept while the rows draw with none.
@(private = "file")
_theme_spacing: im.Vec2

// The sizes and colours of a frame's rows, worked out once.
@(private = "file")
_Look :: struct {
	row_h:     f32,
	gutter_w:  f32,
	indent:    f32,
	arrow_w:   f32,
	icon_w:    f32,
	icon_size: f32,
	chevron_w: f32,
	text_pad:  f32,
	width:     f32,
	origin:    im.Vec2,
	focused:   bool,
	text:      u32,
	dim:       u32,
	blue:      u32,
	blue_dim:  u32,
	selected:  u32,
	hovered:   u32,
	gutter:    u32,
	header:    u32,
	marker:    u32,
	mouse:     im.Vec2,
	hover_ok:  bool,
}

@(private = "file")
_HIER_ICON_EXTRA :: 3

@(private = "file")
_look :: proc() -> _Look {
	style := im.GetStyle()
	text := im.GetStyleColorVec4(.Text)^
	// A blue that reads on the theme's background: light on a dark theme.
	bright := text.x + text.y + text.z > 1.5
	blue := im.Vec4{0.49, 0.71, 1.0, 1} if bright else im.Vec4{0.10, 0.33, 0.78, 1}
	half :: proc(v: im.Vec4) -> im.Vec4 { return {v.x, v.y, v.z, v.w * 0.5} }
	focused := im.IsWindowFocused(im.FocusedFlags_RootAndChildWindows)
	selected := im.GetStyleColorVec4(.Header)^
	if !focused {
		// Grey while the window is not the focused one.
		g := (selected.x + selected.y + selected.z) / 3
		selected = {g, g, g, selected.w * 0.7}
	}
	hovered := im.GetStyleColorVec4(.HeaderHovered)^
	hovered.w *= 0.35
	gutter := im.GetStyleColorVec4(.WindowBg)^
	shade := f32(-0.035) if bright else f32(-0.05)
	gutter = {gutter.x + shade, gutter.y + shade, gutter.z + shade, 1}
	header := im.GetStyleColorVec4(.TableHeaderBg)^
	header.w *= 0.6
	row_h := im.GetFontSize() + 5

	look := _Look {
		row_h     = row_h,
		gutter_w  = row_h,
		indent    = 14,
		arrow_w   = 16,
		icon_size = f32(widgets.FONT_SIZE + _HIER_ICON_EXTRA),
		text_pad  = (row_h - im.GetFontSize()) * 0.5,
		width     = im.GetContentRegionAvail().x,
		origin    = im.GetCursorScreenPos(),
		focused   = focused,
		text      = im.GetColorU32ImVec4(text),
		dim       = im.GetColorU32ImVec4(half(text)),
		blue      = im.GetColorU32ImVec4(blue),
		blue_dim  = im.GetColorU32ImVec4(half(blue)),
		selected  = im.GetColorU32ImVec4(selected),
		hovered   = im.GetColorU32ImVec4(hovered),
		gutter    = im.GetColorU32ImVec4(gutter),
		header    = im.GetColorU32ImVec4(header),
		marker    = im.GetColorU32ImVec4(im.GetStyleColorVec4(.DragDropTarget)^),
		mouse     = im.GetIO().MousePos,
		// A left press makes the window itself active for that frame, which a
		// plain hover test reads as covered.
		hover_ok  = im.IsWindowHovered(im.HoveredFlags_ChildWindows | im.HoveredFlags_AllowWhenBlockedByActiveItem),
	}
	im.PushFontFloat(widgets.icon_font_lg, look.icon_size)
	look.icon_w = im.CalcTextSize(icons.ICON_MD_STACKS).x
	im.PopFont()
	look.chevron_w = im.CalcTextSize(icons.ICON_MD_CHEVRON_RIGHT).x + style.FramePadding.x * 2
	return look
}

// Draws the copy's rows in a scrolling region that fills the window down to
// `footer_h`.
@(private)
_hierarchy_rows_draw :: proc(hv: ^Hierarchy_Window, filtered: bool, footer_h: f32) {
	prof.zone()
	// The rows touch each other and the region's edges. Both style values
	// are for the rows only: a menu or a tooltip opened from here keeps the
	// theme's own.
	_theme_spacing = im.GetStyle().ItemSpacing
	im.PushStyleVarImVec2(.WindowPadding, im.Vec2{0, 0})
	shown := im.BeginChild("##hier_rows", im.Vec2{0, -footer_h}, {}, {})
	im.PopStyleVar()
	defer im.EndChild()
	if !shown do return

	look := _look()
	dl := im.GetWindowDrawList()
	view_min := im.GetWindowPos()
	view_h := im.GetWindowHeight()

	// The gutter is shaded while the pointer is in it, behind every row and
	// the empty space under them.
	if look.hover_ok && look.mouse.x >= view_min.x && look.mouse.x < view_min.x + look.gutter_w && look.mouse.y >= view_min.y && look.mouse.y < view_min.y + view_h {
		im.DrawList_AddRectFilled(dl, view_min, im.Vec2{view_min.x + look.gutter_w, view_min.y + view_h}, look.gutter)
	}

	// A reveal: the selection, or the pinged object, comes to the middle.
	if hv.scroll_to_sel {
		hv.scroll_to_sel = false
		if i := _hierarchy_row_index(hv, session.active()); i != -1 do _scroll_to_row(i, look.row_h, view_h)
	}
	if hv.scroll_to_ping {
		hv.scroll_to_ping = false
		if i := _hierarchy_row_index(hv, hv.ping_tH); i != -1 do _scroll_to_row(i, look.row_h, view_h)
	}
	if hv.rename_scroll {
		hv.rename_scroll = false
		if i := _hierarchy_row_index(hv, hv.rename_target); i != -1 do _scroll_to_row(i, look.row_h, view_h, only_if_hidden = true)
	}
	if hv.keys_scroll {
		hv.keys_scroll = false
		if i := _hierarchy_row_index(hv, session.active()); i != -1 do _scroll_to_row(i, look.row_h, view_h, only_if_hidden = true)
	}

	dragging := im.GetDragDropPayload() != nil
	if dragging do hv.click_pending = _HANDLE_NONE

	replaced := false
	clipper: im.ListClipper
	im.PushStyleVarImVec2(.ItemSpacing, im.Vec2{0, 0})
	im.ListClipper_Begin(&clipper, i32(len(hv.rows)), look.row_h)
	rows: for im.ListClipper_Step(&clipper) {
		for i in clipper.DisplayStart ..< clipper.DisplayEnd {
			if int(i) >= len(hv.rows) do break
			row := hv.rows[i]
			switch row.kind {
			case .Scene:
				if !_draw_scene_row(hv, &look, dl, row) { replaced = true; break rows }
			case .Object:
				if !_draw_object_row(hv, &look, dl, row, filtered, dragging) { replaced = true; break rows }
			}
		}
	}
	im.ListClipper_End(&clipper)
	im.PopStyleVar()
	if replaced do return

	// A press on a selected row keeps the selection until the button goes up,
	// so the whole selection can be dragged.
	if hv.click_pending != _HANDLE_NONE && im.IsMouseReleased(.Left) {
		session.select_only(hv.click_pending)
		hv.click_pending = _HANDLE_NONE
	}

	if len(hv.rows) == 0 {
		im.SetCursorScreenPos(im.Vec2{view_min.x + look.gutter_w + 6, view_min.y + 4})
		im.TextDisabled("No loaded scenes")
	}

	if dragging {
		_draw_drop_places(hv, &look, dl, filtered, view_min, view_h)
	} else {
		hv.drag_hover = _HANDLE_NONE
	}

	// The row menu: one for the copy, on the object it was opened for. It is
	// composed from registered items (hierarchy_menu.odin and the shared
	// GameObject bands), so plugins add to every section.
	if hv.ctx_open {
		hv.ctx_open = false
		im.OpenPopup("##NodeContext")
	}
	if im.BeginPopup("##NodeContext") {
		menu.draw_menu_sections({
			menu.section("Edit", min_order = menu.EDIT_SECTION_SELECTION_MIN, max_order = menu.EDIT_SECTION_SELECTION_MAX),
			menu.section("GameObject", max_order = menu.GO_SECTION_PARENTING - 1),
			menu.section("GameObject", min_order = menu.GO_SECTION_VIEW),
		})
		im.EndPopup()
	}

	// The background's menu: the GameObject bands, which create under the
	// active scene's root.
	if im.BeginPopupContextWindow("##HierarchyContextBg", im.PopupFlags_MouseButtonRight | im.PopupFlags_NoOpenOverItems) {
		menu.draw_menu_sections({
			menu.section("GameObject", max_order = menu.GO_SECTION_PARENTING - 1),
			menu.section("GameObject", min_order = menu.GO_SECTION_VIEW),
		})
		im.EndPopup()
	}
}

@(private = "file")
_scroll_to_row :: proc(index: int, row_h, view_h: f32, only_if_hidden := false) {
	top := f32(index) * row_h
	if only_if_hidden {
		scroll := im.GetScrollY()
		if top >= scroll && top + row_h <= scroll + view_h do return
	}
	im.SetScrollY(max(top - (view_h - row_h) * 0.5, 0))
}

@(private = "file")
_in_rect :: proc(p, lo, hi: im.Vec2) -> bool {
	return p.x >= lo.x && p.x < hi.x && p.y >= lo.y && p.y < hi.y
}

// The fold arrow: right for a closed row, down for an open one.
@(private = "file")
_draw_arrow :: proc(dl: ^im.DrawList, centre: im.Vec2, open: bool, col: u32) {
	r := f32(3.5)
	if open {
		im.DrawList_AddTriangleFilled(dl, {centre.x - r, centre.y - r * 0.6}, {centre.x + r, centre.y - r * 0.6}, {centre.x, centre.y + r * 0.8}, col)
	} else {
		im.DrawList_AddTriangleFilled(dl, {centre.x - r * 0.6, centre.y - r}, {centre.x + r * 0.8, centre.y}, {centre.x - r * 0.6, centre.y + r}, col)
	}
}

@(private = "file")
_draw_icon :: proc(look: ^_Look, dl: ^im.DrawList, pos: im.Vec2, col: u32, glyph: cstring) {
	// The large icon font a little above text size: at text size the variant
	// glyph's star is lost.
	im.PushFontFloat(widgets.icon_font_lg, look.icon_size)
	im.DrawList_AddText(dl, im.Vec2{pos.x, pos.y - f32(_HIER_ICON_EXTRA) * 0.5}, col, glyph)
	im.PopFont()
}

// A scene's header row: the lock of the whole scene in the gutter, the fold
// arrow, the scene glyph, the name with a "*" while it has unsaved changes,
// and its menu at the right end. A click on the name pings the scene's asset.
// Returns false when the loaded scenes changed.
@(private = "file")
_draw_scene_row :: proc(hv: ^Hierarchy_Window, look: ^_Look, dl: ^im.DrawList, row: Hier_Row) -> bool {
	scene := row.section
	im.PushIDPtr(scene)
	defer im.PopID()

	im.SetNextItemAllowOverlap()
	im.InvisibleButton("##scene", im.Vec2{look.width, look.row_h})
	rmin := im.GetItemRectMin()
	rmax := im.Vec2{rmin.x + look.width, rmin.y + look.row_h}
	hovered := im.IsItemHovered({})
	pressed := im.IsItemClicked(.Left)
	im.DrawList_AddRectFilled(dl, rmin, rmax, look.header)
	if hovered do im.DrawList_AddRectFilled(dl, im.Vec2{rmin.x + look.gutter_w, rmin.y}, rmax, look.hovered)
	active_col := im.GetColorU32ImVec4(im.GetStyleColorVec4(.ButtonActive)^)

	// The gutter: the column's lock, always shown here, for the whole scene.
	// It is the lock of the scene's root object.
	root := engine.Transform_Handle(scene.root.handle)
	over_lock := hovered && look.mouse.x < rmin.x + look.gutter_w
	{
		locked := scene_tools.pick_lock_own(root)
		lock_col := im.GetStyleColorVec4(.Text)^
		if !locked do lock_col.w *= 0.35
		glyph := cstring(icons.ICON_MD_LOCK)
		im.DrawList_AddText(dl, im.Vec2{rmin.x + (look.gutter_w - im.CalcTextSize(glyph).x) * 0.5, rmin.y + look.text_pad}, active_col if over_lock else im.GetColorU32ImVec4(lock_col), glyph)
		if over_lock {
			widgets.tooltip_unchecked("Locked: the Scene window picks no object of this scene. Click to unlock" if locked else "Lock: the Scene window stops picking every object of this scene")
			if pressed && !scene_tools.pick_lock_set(root, !locked) do log.warning("Save the scene to keep pick locks: an unsaved scene holds none")
		}
	}

	// Inside an entered nested scene: back to the scene it was entered from,
	// left of the menu.
	back_min_x := rmax.x - look.chevron_w * 2
	over_back := len(_edit_stack) > 0 && hovered && look.mouse.x >= back_min_x && look.mouse.x < rmax.x - look.chevron_w
	if len(_edit_stack) > 0 {
		im.DrawList_AddText(dl, im.Vec2{back_min_x + (look.chevron_w - im.CalcTextSize(icons.ICON_MD_CHEVRON_LEFT).x) * 0.5, rmin.y + look.text_pad}, active_col if over_back else look.text, icons.ICON_MD_CHEVRON_LEFT)
		if over_back {
			widgets.tooltip_unchecked("Back to the scene this one was entered from")
			if pressed {
				_hierarchy_exit_scene()
				return false
			}
		}
	}

	x := rmin.x + look.gutter_w
	_draw_arrow(dl, im.Vec2{x + look.arrow_w * 0.5, rmin.y + look.row_h * 0.5}, row.open, look.text)
	icon_x := x + look.arrow_w
	_draw_icon(look, dl, im.Vec2{icon_x, rmin.y + look.text_pad}, look.text, icons.ICON_MD_LAYERS)
	name := "Untitled"
	if len(scene.path) > 0 do name = filepath.stem(scene.path)
	// The pending mark. Cleared by scene_save, set by the undo stack.
	if scene.dirty do name = fmt.tprintf("%s *", name)
	active := engine.sm_scene_get_active() == scene
	name_x := icon_x + look.icon_w + 2
	label := strings.clone_to_cstring(name, context.temp_allocator)
	im.DrawList_AddText(dl, im.Vec2{name_x, rmin.y + look.text_pad}, look.text if active else look.dim, label)
	name_w := im.CalcTextSize(label).x

	menu_w := look.chevron_w
	menu_min := im.Vec2{rmax.x - menu_w, rmin.y}
	over_menu := hovered && look.mouse.x >= menu_min.x
	menu_col := active_col if over_menu else look.text
	im.DrawList_AddText(dl, im.Vec2{menu_min.x + (menu_w - im.CalcTextSize(icons.ICON_MD_MENU).x) * 0.5, rmin.y + look.text_pad}, menu_col, icons.ICON_MD_MENU)

	if pressed {
		switch {
		case over_menu:
			im.OpenPopup("##SceneHeaderMenu")
		case look.mouse.x < icon_x && look.mouse.x >= x:
			hv.scenes_closed[scene] = row.open
		case look.mouse.x >= name_x && look.mouse.x < name_x + name_w && !over_back:
			// The same gesture as a reference field's value.
			if scene.asset_guid != (engine.Asset_GUID{}) do engine.inspector_request_ping_asset(scene.asset_guid)
		}
	}
	if hovered && im.IsMouseClicked(.Right) do im.OpenPopup("##SceneHeaderMenu")
	return _scene_menu_popup(scene)
}

// An object's row. Returns false when a click replaced the loaded scenes.
@(private = "file")
_draw_object_row :: proc(hv: ^Hierarchy_Window, look: ^_Look, dl: ^im.DrawList, row: Hier_Row, filtered, dragging: bool) -> bool {
	w := engine.ctx_world()
	tH := row.tH
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil {
		// Destroyed by a row above it this frame: its place stays empty.
		im.Dummy(im.Vec2{look.width, look.row_h})
		return true
	}

	// The whole handle: an object made where a destroyed one was is a new row.
	im.PushIDInt(c.int(engine.Handle(tH).index))
	im.PushIDInt(c.int(engine.Handle(tH).generation))
	defer im.PopID()
	defer im.PopID()

	im.SetNextItemAllowOverlap()
	im.InvisibleButton("##row", im.Vec2{look.width, look.row_h})
	rmin := im.GetItemRectMin()
	rmax := im.Vec2{rmin.x + look.width, rmin.y + look.row_h}
	body_min := im.Vec2{rmin.x + look.gutter_w, rmin.y}
	hovered := im.IsItemHovered({})
	pressed := im.IsItemClicked(.Left)
	double := hovered && im.IsMouseDoubleClicked(.Left)
	// The pointer on the row whatever is drawn over it, for its own marks.
	on_row := look.hover_ok && _in_rect(look.mouse, rmin, rmax)

	is_selected := session.is_selected(tH)
	is_renaming := hv.rename_target == tH

	// The row as a drag source: its object, or the selection when it is
	// selected. Bound here, to the row's item.
	if !row.is_root && !row.nested && im.BeginDragDropSource({}) {
		items := _hierarchy_drag_items(tH)
		label := t.name
		if len(items) > 1 do label = fmt.tprintf("%d objects", len(items))
		drag.source(items, label)
		im.EndDragDropSource()
	}

	if is_selected {
		im.DrawList_AddRectFilled(dl, body_min, rmax, look.selected)
		// In a multi-selection the active row is outlined: the one the
		// inspector shows and single-target actions work on.
		if len(session.selection()) > 1 && session.active() == tH {
			im.DrawList_AddRect(dl, body_min, rmax, im.GetColorU32ImVec4(im.Vec4{1, 0.8, 0.2, 0.6}))
		}
	} else if hovered && !dragging {
		im.DrawList_AddRectFilled(dl, body_min, rmax, look.hovered)
	}

	// The ping: a fading highlight, the selection untouched.
	if tH == hv.ping_tH {
		remaining := hv.ping_deadline_ns - time.now()._nsec
		if remaining <= 0 {
			hv.ping_tH = _HANDLE_NONE
		} else {
			alpha := 0.45 * f32(remaining) / f32(_HIER_PING_NS)
			im.DrawList_AddRectFilled(dl, body_min, rmax, im.GetColorU32ImVec4(im.Vec4{1.0, 0.8, 0.2, alpha}))
		}
	}

	x := body_min.x + f32(row.depth) * look.indent
	icon_x := x + look.arrow_w
	name_x := icon_x + look.icon_w + 2
	col := look.text
	switch {
	case row.blue && row.inactive: col = look.blue_dim
	case row.blue:                 col = look.blue
	case row.inactive:             col = look.dim
	}

	// A nested scene with values of its own in this scene: a bar at the row's
	// left edge.
	if row.ns != nil && _ns_overridden(row.ns) {
		im.DrawList_AddRectFilled(dl, body_min, im.Vec2{body_min.x + 2, rmax.y}, look.blue)
	}

	if row.has_children do _draw_arrow(dl, im.Vec2{x + look.arrow_w * 0.5, rmin.y + look.row_h * 0.5}, row.open, look.text if !row.inactive else look.dim)

	// The right end: ">" opens a nested scene's own file.
	enter_min := im.Vec2{rmax.x - look.chevron_w, rmin.y}
	can_enter := row.ns != nil && row.ns.source_prefab != (engine.Asset_GUID{})
	over_enter := can_enter && on_row && look.mouse.x >= enter_min.x
	text_max_x := enter_min.x if can_enter else rmax.x

	if is_renaming {
		im.SetCursorScreenPos(im.Vec2{name_x, rmin.y + (look.row_h - im.GetFrameHeight()) * 0.5})
		if hv.rename_focus {
			im.SetKeyboardFocusHere(0)
			hv.rename_focus = false
			hv.rename_just_opened = true
		}
		im.SetNextItemWidth(max(text_max_x - name_x, 40))
		buf := cstring(raw_data(hv.rename_buf[:]))
		if im.InputText("##rename", buf, c.size_t(len(hv.rename_buf)), {.EnterReturnsTrue, .AutoSelectAll}) {
			_apply_rename(tH, t)
		}
		if hv.rename_just_opened {
			hv.rename_just_opened = false
		} else if !im.IsItemActive() {
			if im.IsItemDeactivatedAfterEdit() {
				_apply_rename(tH, t)
			} else {
				hv.rename_target = _HANDLE_NONE
			}
		}
		// The next row starts under this one, not under the field.
		im.SetCursorScreenPos(im.Vec2{rmin.x, rmax.y})
	} else {
		glyph := hierarchy_row_icon(row.scene, tH, row.ns)
		icon_col := col
		if !row.blue && !row.inactive do icon_col = look.dim
		_draw_icon(look, dl, im.Vec2{icon_x, rmin.y + look.text_pad}, icon_col, glyph)
		if row.added {
			// Added to a nested scene here: a "+" on the glyph's corner.
			im.PushFontFloat(widgets.icon_font_lg, 10)
			im.DrawList_AddText(dl, im.Vec2{icon_x + look.icon_w - 9, rmax.y - 11}, look.blue, icons.ICON_MD_ADD)
			im.PopFont()
		}
		label := strings.clone_to_cstring(t.name, context.temp_allocator)
		clip := name_x + im.CalcTextSize(label).x > text_max_x
		if clip do im.DrawList_PushClipRect(dl, im.Vec2{name_x, rmin.y}, im.Vec2{text_max_x, rmax.y}, true)
		im.DrawList_AddText(dl, im.Vec2{name_x, rmin.y + look.text_pad}, col, label)
		if clip do im.DrawList_PopClipRect(dl)
	}

	if can_enter {
		enter_col := im.GetColorU32ImVec4(im.GetStyleColorVec4(.ButtonActive)^) if over_enter else col
		im.DrawList_AddText(dl, im.Vec2{enter_min.x + (look.chevron_w - im.CalcTextSize(icons.ICON_MD_CHEVRON_RIGHT).x) * 0.5, rmin.y + look.text_pad}, enter_col, icons.ICON_MD_CHEVRON_RIGHT)
		if over_enter && im.IsMouseClicked(.Left) {
			if src_path, ok := engine.asset_db_get_path(uuid.Identifier(row.ns.source_prefab)); ok {
				// Entering replaces the open scene: every row of this frame's
				// list is gone.
				_hierarchy_enter_scene(src_path, row.ns.source_prefab)
				return false
			}
		}
	}

	// The pick lock, in the gutter: a lock on a locked row, a dim one under a
	// locked parent, an open lock on the hovered row. Its click is not the
	// row's.
	over_lock := on_row && look.mouse.x < body_min.x
	if !is_renaming {
		own := scene_tools.pick_lock_own(tH)
		inherited := !own && scene_tools.pick_locked(tH)
		if own || inherited || on_row {
			lock_col := im.GetStyleColorVec4(.Text)^
			if !own do lock_col.w *= 0.35
			if over_lock && !inherited do lock_col = im.GetStyleColorVec4(.ButtonActive)^
			glyph := cstring(icons.ICON_MD_LOCK) if own || inherited else cstring(icons.ICON_MD_LOCK_OPEN)
			glyph_w := im.CalcTextSize(glyph).x
			im.DrawList_AddText(dl, im.Vec2{rmin.x + (look.gutter_w - glyph_w) * 0.5, rmin.y + look.text_pad}, im.GetColorU32ImVec4(lock_col), glyph)
		}
		if over_lock {
			switch {
			case inherited: widgets.tooltip_unchecked("Locked by an object above it")
			case own:       widgets.tooltip_unchecked("Locked: the Scene window does not pick it or what is under it. Click to unlock")
			case:           widgets.tooltip_unchecked("Lock: the Scene window stops picking it and what is under it")
			}
			if im.IsMouseClicked(.Left) {
				if !inherited && !scene_tools.pick_lock_set(tH, !own) do log.warning("Save the scene to keep pick locks: an unsaved scene holds none")
			}
		}
	}

	// A press left of the glyph folds the row and never selects. On the rest
	// of the row it selects.
	toggled := false
	if pressed && !over_lock && !over_enter && !is_renaming {
		io := im.GetIO()
		if row.has_children && look.mouse.x < icon_x {
			toggled = true
			_hierarchy_set_open(hv, tH, !row.open)
			if io.KeyAlt do _hierarchy_set_open_deep(hv, tH, !row.open)
		} else if io.KeyCtrl || io.KeySuper {
			session.select_toggle(tH)
		} else if io.KeyShift {
			_select_range(hv, tH)
		} else if is_selected && len(session.selection()) > 1 {
			hv.click_pending = tH
		} else {
			session.select_only(tH)
		}
	}

	// A double click frames the object in the Scene window.
	if double && !is_renaming && !toggled && !over_lock && !over_enter && look.mouse.x >= icon_x {
		session.frame_selected()
	}

	// A right click on an unselected row selects just it, on a selected row
	// keeps the selection: the menu's items work on the selection.
	if on_row && im.IsMouseClicked(.Right) {
		if !session.is_selected(tH) do session.select_only(tH)
		hv.ctx_open = true
	}
	return true
}

// Whether a nested scene carries anything of its own in the scene that holds it.
@(private = "file")
_ns_overridden :: proc(ns: ^engine.NestedScene) -> bool {
	return len(ns.overrides) > 0 || len(ns.added_components) > 0 || len(ns.removed_components) > 0 || len(ns.added_objects) > 0 || len(ns.removed_objects) > 0
}

// --- Drop places -------------------------------------------------------------

@(private = "file")
_AUTO_OPEN_SECONDS :: 0.6

// While something is dragged over the rows: the one place under the pointer,
// its mark, a folded row that opens when hovered for a moment, and scrolling
// near the top and bottom edges.
@(private = "file")
_draw_drop_places :: proc(hv: ^Hierarchy_Window, look: ^_Look, dl: ^im.DrawList, filtered: bool, view_min: im.Vec2, view_h: f32) {
	mp := look.mouse
	view_max := im.Vec2{view_min.x + im.GetWindowWidth(), view_min.y + view_h}
	if !_in_rect(mp, view_min, view_max) {
		hv.drag_hover = _HANDLE_NONE
		return
	}

	// Near an edge the list scrolls under the pointer.
	edge := look.row_h * 1.5
	dt := im.GetIO().DeltaTime
	if mp.y < view_min.y + edge {
		im.SetScrollY(max(im.GetScrollY() - 500 * dt, 0))
	} else if mp.y > view_max.y - edge {
		im.SetScrollY(min(im.GetScrollY() + 500 * dt, im.GetScrollMaxY()))
	}

	index := int((mp.y - look.origin.y) / look.row_h)
	if mp.y < look.origin.y do index = -1
	hover := _HANDLE_NONE
	defer {
		if hover != hv.drag_hover {
			hv.drag_hover = hover
			hv.drag_hover_since = im.GetTime()
		}
	}

	if index < 0 || index >= len(hv.rows) {
		// Under the last row: the last scene's root.
		if len(hv.rows) == 0 do return
		last := hv.rows[len(hv.rows) - 1].section
		top := look.origin.y + f32(len(hv.rows)) * look.row_h
		rect := im.Rect{Min = {view_min.x, max(top, view_min.y)}, Max = view_max}
		if rect.Max.y - rect.Min.y < 2 do return
		if im.BeginDragDropTargetCustom(rect, im.GetID("##drop_below")) {
			drag.target(drag.Hierarchy_Place{parent = engine.Transform_Handle(last.root.handle), index = -1})
			im.EndDragDropTarget()
		}
		return
	}

	row := hv.rows[index]
	rmin := im.Vec2{look.origin.x, look.origin.y + f32(index) * look.row_h}
	rmax := im.Vec2{rmin.x + look.width, rmin.y + look.row_h}
	body_min := im.Vec2{rmin.x + look.gutter_w, rmin.y}
	rect := im.Rect{Min = rmin, Max = rmax}
	id := im.GetID("##drop_row")

	// On a scene's header, and on its root: under the root, at the end.
	if row.kind == .Scene || row.is_root {
		root := engine.Transform_Handle(row.section.root.handle)
		if im.BeginDragDropTargetCustom(rect, id) {
			if taken, _ := drag.target(drag.Hierarchy_Place{parent = root, index = -1}, {.AcceptNoDrawDefaultRect}); taken {
				im.DrawList_AddRect(dl, body_min, rmax, look.marker, 0, 2)
			}
			im.EndDragDropTarget()
		}
		return
	}
	// A filtered list is an excerpt, and a nested scene's content is not
	// rearranged here: no places.
	if filtered || row.nested do return

	w := engine.ctx_world()
	row_parent := row.parent
	if !engine.pool_valid(&w.transforms, engine.Handle(row_parent)) do row_parent = engine.Transform_Handle(row.section.root.handle)

	zone := look.row_h * 0.25
	place: drag.Hierarchy_Place
	line_y := f32(0)
	line_depth := row.depth
	as_child := false
	switch {
	case mp.y < rmin.y + zone:
		place = {parent = row_parent, index = int(row.sibling)}
		line_y = rmin.y
	case mp.y >= rmax.y - zone:
		if row.open && row.has_children {
			// Under an open row the place after it is its first child.
			place = {parent = row.tH, index = 0}
			line_depth = row.depth + 1
		} else {
			place = {parent = row_parent, index = int(row.sibling) + 1}
		}
		line_y = rmax.y
	case:
		place = {parent = row.tH, index = -1}
		as_child = true
	}

	if as_child {
		hover = row.tH
		// A folded row hovered for a moment opens, so a place inside it can
		// be reached in the same drag.
		if row.has_children && !row.open && hv.drag_hover == row.tH && im.GetTime() - hv.drag_hover_since > _AUTO_OPEN_SECONDS {
			_hierarchy_set_open(hv, row.tH, true)
		}
	}

	if im.BeginDragDropTargetCustom(rect, id) {
		if taken, _ := drag.target(place, {.AcceptNoDrawDefaultRect}); taken {
			if as_child {
				im.DrawList_AddRect(dl, body_min, rmax, look.marker, 0, 2)
			} else {
				// The line starts where the object will sit, so its depth shows.
				x0 := body_min.x + f32(line_depth) * look.indent + look.arrow_w
				im.DrawList_AddLine(dl, im.Vec2{x0, line_y}, im.Vec2{rmax.x, line_y}, look.marker, 2)
				im.DrawList_AddCircleFilled(dl, im.Vec2{x0, line_y}, 3.5, look.marker)
			}
		}
		im.EndDragDropTarget()
	}
}

// --- Scene menu ----------------------------------------------------------------

// A scene header's menu: Save, Save As, Discard, Unload. Called under the
// scene's id, where the popup was opened. Returns false when the scene was
// unloaded.
@(private = "file")
_scene_menu_popup :: proc(scene: ^engine.Scene) -> bool {
	// Called from inside the rows, where items have no spacing.
	im.PushStyleVarImVec2(.ItemSpacing, _theme_spacing)
	defer im.PopStyleVar()
	if im.BeginPopup("##SceneHeaderMenu") {
		if im.MenuItem("Save") {
			if len(scene.path) > 0 {
				engine.scene_save(scene, scene.path)
			} else {
				_save_as_open = true
				_save_as_pending = true
				mem.zero(&_save_as_buf, len(_save_as_buf))
			}
		}
		if im.MenuItem("Save As") {
			_save_as_open = true
			_save_as_pending = true
			mem.zero(&_save_as_buf, len(_save_as_buf))
			path_bytes := transmute([]u8)scene.path
			copy_len := min(len(path_bytes), len(_save_as_buf) - 1)
			mem.copy(&_save_as_buf[0], raw_data(path_bytes), copy_len)
		}
		im.Separator()
		// Discard asks first and acts after the confirmation, the same as a
		// window's tab menu (scene_documents.odin). It is off for a scene with
		// no unsaved changes, with no path, and while a simulation runs.
		doc, has_doc := session.document_find(SCENE_DOCUMENTS, scene)
		im.BeginDisabled(!has_doc || !doc.dirty || !doc.can_discard)
		discard := im.MenuItem("Discard")
		im.EndDisabled()
		if discard do session.document_discard_ask(doc)
		// Unloading the scene a run simulates leaves Stop with nothing to
		// restore. Additive scenes stay unloadable.
		simulating := _scene_is_simulating(scene)
		im.BeginDisabled(simulating)
		unload := im.MenuItem("Unload")
		im.EndDisabled()
		if simulating {
			widgets.tooltip("This scene is simulating. Stop first, or its pre-run state is lost", im.HoveredFlags_AllowWhenDisabled)
		}
		if unload {
			_hierarchy_unload_scene(scene)
			im.EndPopup()
			return false
		}
		im.EndPopup()
	}
	if _save_as_pending {
		im.OpenPopup("Save Scene As")
		_save_as_pending = false
	}
	_draw_save_as_popup(scene)
	return true
}

// Keeps the default allocator for what a copy holds across frames.
@(private)
_hierarchy_state_make :: proc(hv: ^Hierarchy_Window) {
	context.allocator = runtime.default_allocator()
	hv.rows = make([dynamic]Hier_Row)
	hv.open = make(map[engine.Transform_Handle]bool)
	hv.scenes_closed = make(map[^engine.Scene]bool)
}
