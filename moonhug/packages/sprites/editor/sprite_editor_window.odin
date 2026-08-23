package sprites_editor

// The Sprite Editor window — Unity's Sprite Editor: a dedicated window over
// the texture with zoom/pan, a Slice popup (Automatic, Grid By Cell Size,
// Grid By Cell Count), manual rect editing (drag-create on empty space,
// drag-move, a fields panel for the selection) and its own Apply/Revert.
// Apply writes the slice list into the texture's import settings
// (meta + reimport), independent of the import-settings inspector's draft —
// which reloads if it shows the same file.

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:os"
import "core:path/filepath"
import "core:strings"
import stbi "vendor:stb/image"
import "moonhug:engine"
import gfx "moonhug:engine/gfx"
import asset_pipeline "moonhug:engine_editor/asset_pipeline"
import im "moonhug:external/odin-imgui"
import "moonhug:editor/inspector"
import wnd "moonhug:editor/window"

_SE_Mode :: enum {
	Automatic,
	Grid_By_Cell_Count,
	Grid_By_Cell_Size,
}

_SE_Pivot :: enum {
	Center,
	Bottom_Left,
	Bottom,
	Bottom_Right,
	Left,
	Right,
	Top_Left,
	Top,
	Top_Right,
}

_se_pivot_vec := [_SE_Pivot][2]f32{
	.Center       = {0.5, 0.5},
	.Bottom_Left  = {0, 0},
	.Bottom       = {0.5, 0},
	.Bottom_Right = {1, 0},
	.Left         = {0, 0.5},
	.Right        = {1, 0.5},
	.Top_Left     = {0, 1},
	.Top          = {0.5, 1},
	.Top_Right    = {1, 1},
}

_SE_Drag :: enum {
	None,
	Move,
	Create,
}

_SE_State :: struct {
	path:   string, // heap clone; "" = no target
	guid:   engine.Asset_GUID,
	slices: [dynamic]engine.Sprite_Rect, // working copy, heap-owned names
	sel:    int, // -1 = none
	dirty:  bool,

	zoom: f32,
	pan:  im.Vec2, // image px

	drag:       _SE_Drag,
	drag_from:  im.Vec2, // image px at press
	drag_rect:  [4]f32,  // Create: the rect being rubber-banded

	name_buf: [128]u8,

	// Apply runs at the TOP of the next window frame, never from the
	// toolbar: reimport evicts the texture cache, and the rest of the frame
	// would draw with the freed ^Texture2D / GPU handle.
	want_apply: bool,

	// Slice popup params.
	mode:      _SE_Mode,
	cols:      i32,
	rows:      i32,
	cell_w:    i32,
	cell_h:    i32,
	offset:    [2]i32,
	padding:   [2]i32,
	min_size:  i32, // Automatic: ignore islands smaller than this (px)
	alpha_min: i32, // Automatic: alpha above this is solid (0-255)
	pivot:     _SE_Pivot,
}

_se := _SE_State{
	sel       = -1,
	zoom      = 1,
	cols      = 4,
	rows      = 4,
	cell_w    = 32,
	cell_h    = 32,
	min_size  = 2,
	alpha_min = 0,
}

_SE_OUTLINE  :: u32(0xFF19A0FF) // ABGR orange
_SE_SELECTED :: u32(0xFF00E5FF) // ABGR yellow
_SE_CREATE   :: u32(0xFF7DE59E) // ABGR green
_SE_ZOOM_MIN :: f32(0.1)
_SE_ZOOM_MAX :: f32(32)

// Unity keeps the window reachable from the Window menu too — without a
// target it shows the "select a texture" hint.
@(menu_item={path="Window/Sprite Editor", shortcut=""})
sprite_editor_menu :: proc() {
	wnd.open("sprite_editor")
}

// Opened from the texture importer inspector's Sprite Editor button.
sprite_editor_open :: proc(path: string, guid: engine.Asset_GUID) {
	context.allocator = runtime.default_allocator()
	delete(_se.path)
	_se.path = strings.clone(path)
	_se.guid = guid
	_se.sel = -1
	_se.drag = .None
	_se.zoom = 0 // fit on first frame
	_se.pan = {}
	_se_load_slices()
	wnd.open("sprite_editor")
}

// Opened on a specific slice (a sub-asset row in the project window).
sprite_editor_open_at :: proc(path: string, guid: engine.Asset_GUID, slice_id: engine.Local_ID) {
	sprite_editor_open(path, guid)
	for s, i in _se.slices {
		if s.id == slice_id {
			_se_select(i)
			break
		}
	}
}

_se_free_slices :: proc() {
	context.allocator = runtime.default_allocator()
	for s in _se.slices do delete(s.name)
	clear(&_se.slices)
}

// Persistent slice id — Unity's fileID. Random nonzero, unique in the list.
// Persisted in the meta, so references survive renames.
_se_mint_id :: proc() -> engine.Local_ID {
	for {
		id := engine.Local_ID(rand.int63())
		if id == 0 do continue
		taken := false
		for s in _se.slices do if s.id == id { taken = true; break }
		if !taken do return id
	}
}

// Reslicing keeps identities: a regenerated slice whose name already existed
// carries the old id forward (the meta list is Unity's internalIDToNameTable).
_se_carry_id :: proc(old: []engine.Sprite_Rect, name: string) -> engine.Local_ID {
	for s in old do if s.name == name do return s.id
	return 0
}

// Working copy from the CURRENT import settings.
_se_load_slices :: proc() {
	_se_free_slices()
	context.allocator = runtime.default_allocator()
	if settings, ok := engine.asset_pipeline_get_settings(_se.path, context.temp_allocator); ok {
		if ts, is_tex := settings.(engine.TextureSettings); is_tex {
			for s in ts.sprites {
				append(&_se.slices, engine.Sprite_Rect{
					id    = s.id,
					name  = strings.clone(s.name),
					rect  = s.rect,
					pivot = s.pivot,
				})
			}
		}
	}
	_se.dirty = false
	// Heal pre-id metas: slices saved before ids existed carry 0 (= the
	// whole texture, unreferenceable). Mint here and mark dirty — Apply
	// stamps them into the meta.
	for &s in _se.slices {
		if s.id == 0 {
			s.id = _se_mint_id()
			_se.dirty = true
		}
	}
}

_se_apply :: proc() {
	settings, ok := engine.asset_pipeline_get_settings(_se.path, context.temp_allocator)
	if !ok || settings.id != typeid_of(engine.TextureSettings) do return
	ts := cast(^engine.TextureSettings)settings.data
	// Marshal only reads — the temp copy can borrow the working names.
	ts.sprites = make([dynamic]engine.Sprite_Rect, context.temp_allocator)
	append(&ts.sprites, .._se.slices[:])
	if len(_se.slices) > 0 do ts.sprite_mode = .Multiple
	if !asset_pipeline.asset_pipeline_save_settings(_se.path, settings) do return
	asset_pipeline.asset_pipeline_reimport(_se.path)
	// The import-settings inspector holds its own draft of the same meta.
	if inspector.inspectorData.filePath == _se.path {
		inspector.load_import_settings(_se.path)
	}
	_se.dirty = false
}

@(editor_window={id="sprite_editor", title="Sprite Editor", width=940, height=640})
sprite_editor_window_draw :: proc() {
	if _se.path == "" {
		im.TextDisabled("Select a texture in the Project view and press Sprite Editor.")
		return
	}
	if _se.want_apply {
		_se.want_apply = false
		_se_apply()
	}
	tex, ok := engine.texture_load(_se.guid)
	if !ok {
		im.TextDisabled("texture not loadable: %s", strings.clone_to_cstring(_se.path, context.temp_allocator))
		return
	}

	_se_toolbar(tex)
	im.Separator()

	// Selected-slice fields panel on the right, canvas takes the rest.
	panel_w := f32(240)
	avail := im.GetContentRegionAvail()
	_se_canvas(tex, im.Vec2{avail.x - panel_w - 8, avail.y})
	im.SameLine()
	_se_panel(tex)
}

_se_toolbar :: proc(tex: ^engine.Texture2D) {
	if im.Button("Slice##open") do im.OpenPopup("se_slice_popup")
	if im.BeginPopup("se_slice_popup") {
		_se_slice_popup(tex)
		im.EndPopup()
	}

	im.SameLine()
	im.BeginDisabled(!_se.dirty)
	if im.Button("Apply") do _se.want_apply = true
	im.SameLine()
	if im.Button("Revert") do _se_load_slices()
	im.EndDisabled()

	im.SameLine()
	dirty := _se.dirty ? " *" : ""
	im.TextDisabled("%s%s — %d x %d, %d slices", strings.clone_to_cstring(_se.path, context.temp_allocator),
		strings.clone_to_cstring(dirty, context.temp_allocator), tex.width, tex.height, i32(len(_se.slices)))
}

_se_slice_popup :: proc(tex: ^engine.Texture2D) {
	mode_labels := [_SE_Mode]cstring{
		.Automatic          = "Automatic",
		.Grid_By_Cell_Count = "Grid By Cell Count",
		.Grid_By_Cell_Size  = "Grid By Cell Size",
	}
	if im.BeginCombo("Type", mode_labels[_se.mode]) {
		for label, m in mode_labels {
			if im.Selectable(label, _se.mode == m) do _se.mode = m
		}
		im.EndCombo()
	}

	switch _se.mode {
	case .Automatic:
		inspector.drag_int("Min Size", &_se.min_size, 0.2, 1, 512)
		inspector.drag_int("Alpha Threshold", &_se.alpha_min, 1, 0, 254)
	case .Grid_By_Cell_Count:
		inspector.drag_int("Columns", &_se.cols, 0.1, 1, 512)
		inspector.drag_int("Rows", &_se.rows, 0.1, 1, 512)
		inspector.drag_int("Offset X", &_se.offset.x, 1, 0, tex.width)
		inspector.drag_int("Offset Y", &_se.offset.y, 1, 0, tex.height)
		inspector.drag_int("Padding X", &_se.padding.x, 1, 0, tex.width)
		inspector.drag_int("Padding Y", &_se.padding.y, 1, 0, tex.height)
	case .Grid_By_Cell_Size:
		inspector.drag_int("Cell Width", &_se.cell_w, 1, 1, tex.width)
		inspector.drag_int("Cell Height", &_se.cell_h, 1, 1, tex.height)
		inspector.drag_int("Offset X", &_se.offset.x, 1, 0, tex.width)
		inspector.drag_int("Offset Y", &_se.offset.y, 1, 0, tex.height)
		inspector.drag_int("Padding X", &_se.padding.x, 1, 0, tex.width)
		inspector.drag_int("Padding Y", &_se.padding.y, 1, 0, tex.height)
	}

	pivot_labels := [_SE_Pivot]cstring{
		.Center = "Center", .Bottom_Left = "Bottom Left", .Bottom = "Bottom",
		.Bottom_Right = "Bottom Right", .Left = "Left", .Right = "Right",
		.Top_Left = "Top Left", .Top = "Top", .Top_Right = "Top Right",
	}
	if im.BeginCombo("Pivot", pivot_labels[_se.pivot]) {
		for label, p in pivot_labels {
			if im.Selectable(label, _se.pivot == p) do _se.pivot = p
		}
		im.EndCombo()
	}

	if im.Button("Slice##run") {
		switch _se.mode {
		case .Automatic:          _se_slice_automatic(tex)
		case .Grid_By_Cell_Count: _se_slice_grid(tex, true)
		case .Grid_By_Cell_Size:  _se_slice_grid(tex, false)
		}
		im.CloseCurrentPopup()
	}
}

// --- Slicing ------------------------------------------------------------------

_se_slice_grid :: proc(tex: ^engine.Texture2D, by_count: bool) {
	cw, ch, cols, rows: i32
	if by_count {
		cols = max(_se.cols, 1)
		rows = max(_se.rows, 1)
		cw = (tex.width - _se.offset.x - (cols - 1) * _se.padding.x) / cols
		ch = (tex.height - _se.offset.y - (rows - 1) * _se.padding.y) / rows
	} else {
		cw = max(_se.cell_w, 1)
		ch = max(_se.cell_h, 1)
		cols = (tex.width - _se.offset.x + _se.padding.x) / (cw + _se.padding.x)
		rows = (tex.height - _se.offset.y + _se.padding.y) / (ch + _se.padding.y)
	}
	if cw <= 0 || ch <= 0 do return

	context.allocator = runtime.default_allocator()
	old := _se.slices
	_se.slices = {}
	base := filepath.stem(_se.path)
	i := 0
	for r in 0 ..< rows {
		y := _se.offset.y + r * (ch + _se.padding.y)
		if y + ch > tex.height do break
		for c in 0 ..< cols {
			x := _se.offset.x + c * (cw + _se.padding.x)
			if x + cw > tex.width do break
			name := fmt.aprintf("%s_%d", base, i)
			id := _se_carry_id(old[:], name)
			if id == 0 do id = _se_mint_id()
			append(&_se.slices, engine.Sprite_Rect{
				id    = id,
				name  = name,
				rect  = {f32(x), f32(y), f32(cw), f32(ch)},
				pivot = _se_pivot_vec[_se.pivot],
			})
			i += 1
		}
	}
	for s in old do delete(s.name)
	delete(old)
	_se.sel = -1
	_se.dirty = true
}

// Unity's Automatic: connected islands of non-transparent pixels, one rect
// per island's bounding box. 4-connected BFS over an alpha mask.
_se_slice_automatic :: proc(tex: ^engine.Texture2D) {
	data, read_err := os.read_entire_file(_se.path, context.temp_allocator)
	if read_err != nil do return
	w, h, channels: i32
	pixels := stbi.load_from_memory(raw_data(data), i32(len(data)), &w, &h, &channels, 4)
	if pixels == nil do return
	defer stbi.image_free(pixels)

	solid := make([]bool, int(w * h), context.temp_allocator)
	for i in 0 ..< int(w * h) {
		solid[i] = i32(pixels[i * 4 + 3]) > _se.alpha_min
	}

	context.allocator = runtime.default_allocator()
	old := _se.slices
	_se.slices = {}
	base := filepath.stem(_se.path)
	visited := make([]bool, int(w * h), context.temp_allocator)
	queue := make([dynamic]i32, context.temp_allocator)
	n := 0
	for start in 0 ..< i32(w * h) {
		if visited[start] || !solid[start] do continue
		// Flood the island, tracking its bounding box.
		min_x, min_y := w, h
		max_x, max_y := i32(-1), i32(-1)
		clear(&queue)
		append(&queue, start)
		visited[start] = true
		for len(queue) > 0 {
			p := pop(&queue)
			px, py := p % w, p / w
			min_x = min(min_x, px)
			min_y = min(min_y, py)
			max_x = max(max_x, px)
			max_y = max(max_y, py)
			neighbors := [4]i32{p - 1, p + 1, p - w, p + w}
			if px == 0 do neighbors[0] = -1
			if px == w - 1 do neighbors[1] = -1
			for q in neighbors {
				if q < 0 || q >= w * h do continue
				if visited[q] || !solid[q] do continue
				visited[q] = true
				append(&queue, q)
			}
		}
		bw, bh := max_x - min_x + 1, max_y - min_y + 1
		if bw < _se.min_size || bh < _se.min_size do continue
		name := fmt.aprintf("%s_%d", base, n)
		id := _se_carry_id(old[:], name)
		if id == 0 do id = _se_mint_id()
		append(&_se.slices, engine.Sprite_Rect{
			id    = id,
			name  = name,
			rect  = {f32(min_x), f32(min_y), f32(bw), f32(bh)},
			pivot = _se_pivot_vec[_se.pivot],
		})
		n += 1
	}
	for s in old do delete(s.name)
	delete(old)
	_se.sel = -1
	_se.dirty = true
}

// --- Canvas ---------------------------------------------------------------------

_se_screen :: proc(origin: im.Vec2, img: im.Vec2) -> im.Vec2 {
	return origin + (img + _se.pan) * _se.zoom
}

_se_canvas :: proc(tex: ^engine.Texture2D, size: im.Vec2) {
	if !im.BeginChild("se_canvas", size, {.Borders}, {.NoScrollbar, .NoScrollWithMouse}) {
		im.EndChild()
		return
	}
	origin := im.GetCursorScreenPos()
	region := im.GetContentRegionAvail()
	if region.x < 16 || region.y < 16 {
		im.EndChild()
		return
	}

	// First frame after open: fit the texture into the view.
	if _se.zoom == 0 {
		_se.zoom = clamp(min(region.x / f32(tex.width), region.y / f32(tex.height)) * 0.95, _SE_ZOOM_MIN, _SE_ZOOM_MAX)
		_se.pan = im.Vec2{
			(region.x / _se.zoom - f32(tex.width)) * 0.5,
			(region.y / _se.zoom - f32(tex.height)) * 0.5,
		}
	}

	dl := im.GetWindowDrawList()
	tex_id := im.TextureID(uintptr(gfx.texture_imgui_id(tex.gfx)))
	p0 := _se_screen(origin, {0, 0})
	p1 := _se_screen(origin, {f32(tex.width), f32(tex.height)})
	im.DrawList_AddRectFilled(dl, p0, p1, 0xFF202020)
	im.DrawList_AddImage(dl, im.TextureRef{_TexID = tex_id}, p0, p1)

	for s, i in _se.slices {
		r0 := _se_screen(origin, {s.rect.x, s.rect.y})
		r1 := _se_screen(origin, {s.rect.x + s.rect.z, s.rect.y + s.rect.w})
		im.DrawList_AddRect(dl, r0, r1, i == _se.sel ? _SE_SELECTED : _SE_OUTLINE)
	}
	if _se.drag == .Create {
		r0 := _se_screen(origin, {_se.drag_rect.x, _se.drag_rect.y})
		r1 := _se_screen(origin, {_se.drag_rect.x + _se.drag_rect.z, _se.drag_rect.y + _se.drag_rect.w})
		im.DrawList_AddRect(dl, r0, r1, _SE_CREATE)
	}

	// Interaction surface.
	im.SetCursorScreenPos(origin)
	im.InvisibleButton("##se_bg", region)
	mouse := im.GetMousePos()
	img := (mouse - origin) / _se.zoom - _se.pan // mouse in image px

	if im.IsItemActivated() { // left press: pick or start creating
		_se.drag_from = img
		hit := _se_hit_slice(img)
		_se_select(hit)
		_se.drag = hit >= 0 ? .Move : .None
	}
	if im.IsItemActive() && im.IsMouseDragging(.Left, 2) {
		if _se.drag == .None { // drag on empty space rubber-bands a new rect
			_se.drag = .Create
		}
		switch _se.drag {
		case .Move:
			if _se.sel >= 0 {
				delta := im.GetIO().MouseDelta / _se.zoom
				r := &_se.slices[_se.sel].rect
				r.x = clamp(r.x + delta.x, 0, f32(tex.width) - r.z)
				r.y = clamp(r.y + delta.y, 0, f32(tex.height) - r.w)
				_se.dirty = true
			}
		case .Create:
			lo_x, hi_x := min(_se.drag_from.x, img.x), max(_se.drag_from.x, img.x)
			lo_y, hi_y := min(_se.drag_from.y, img.y), max(_se.drag_from.y, img.y)
			lo_x = clamp(lo_x, 0, f32(tex.width))
			hi_x = clamp(hi_x, 0, f32(tex.width))
			lo_y = clamp(lo_y, 0, f32(tex.height))
			hi_y = clamp(hi_y, 0, f32(tex.height))
			_se.drag_rect = {math.floor(lo_x), math.floor(lo_y), math.ceil(hi_x - lo_x), math.ceil(hi_y - lo_y)}
		case .None:
		}
	}
	if im.IsItemDeactivated() {
		if _se.drag == .Create && _se.drag_rect.z >= 1 && _se.drag_rect.w >= 1 {
			context.allocator = runtime.default_allocator()
			append(&_se.slices, engine.Sprite_Rect{
				id    = _se_mint_id(),
				name  = fmt.aprintf("%s_%d", filepath.stem(_se.path), len(_se.slices)),
				rect  = _se.drag_rect,
				pivot = _se_pivot_vec[_se.pivot],
			})
			_se_select(len(_se.slices) - 1)
			_se.dirty = true
		}
		_se.drag = .None
	}

	// Move-drag snaps to whole pixels on release via the panel's ints; keep
	// live values fractional while dragging for smoothness.
	if im.IsWindowHovered(im.HoveredFlags_ChildWindows) {
		if im.IsMouseDragging(.Middle, 0) {
			_se.pan += im.GetIO().MouseDelta / _se.zoom
		}
		wheel := im.GetIO().MouseWheel
		if wheel != 0 {
			world := (mouse - origin) / _se.zoom - _se.pan
			_se.zoom = clamp(_se.zoom * math.pow(f32(1.15), wheel), _SE_ZOOM_MIN, _SE_ZOOM_MAX)
			_se.pan = (mouse - origin) / _se.zoom - world
		}
		if im.IsKeyPressed(.Delete) || im.IsKeyPressed(.Backspace) {
			_se_delete_selected()
		}
	}

	im.EndChild()
}

// Smallest slice containing the point wins — selects nested rects correctly.
_se_hit_slice :: proc(img: im.Vec2) -> int {
	best := -1
	best_area := f32(max(f32))
	for s, i in _se.slices {
		r := s.rect
		if img.x < r.x || img.y < r.y || img.x > r.x + r.z || img.y > r.y + r.w do continue
		area := r.z * r.w
		if area < best_area {
			best_area = area
			best = i
		}
	}
	return best
}

_se_select :: proc(i: int) {
	_se.sel = i
	_se.name_buf = {}
	if i >= 0 {
		copy(_se.name_buf[:len(_se.name_buf) - 1], _se.slices[i].name)
	}
}

_se_delete_selected :: proc() {
	if _se.sel < 0 || _se.sel >= len(_se.slices) do return
	context.allocator = runtime.default_allocator()
	delete(_se.slices[_se.sel].name)
	ordered_remove(&_se.slices, _se.sel)
	_se.sel = -1
	_se.dirty = true
}

// --- Selected-slice panel -------------------------------------------------------

_se_panel :: proc(tex: ^engine.Texture2D) {
	if !im.BeginChild("se_panel", {0, 0}, {.Borders}) {
		im.EndChild()
		return
	}
	defer im.EndChild()

	if _se.sel < 0 || _se.sel >= len(_se.slices) {
		im.TextDisabled("No slice selected.")
		im.TextWrapped("Click a rect to select. Drag on empty space to create one. Middle-drag pans, wheel zooms.")
		return
	}
	s := &_se.slices[_se.sel]

	im.Text("Sprite")
	if im.InputText("Name", cstring(raw_data(_se.name_buf[:])), len(_se.name_buf)) {
	}
	if im.IsItemDeactivatedAfterEdit() {
		new_name := string(cstring(raw_data(_se.name_buf[:])))
		if new_name != "" && new_name != s.name {
			context.allocator = runtime.default_allocator()
			delete(s.name)
			s.name = strings.clone(new_name)
			_se.dirty = true
		}
	}

	changed := false
	changed |= inspector.drag_float("X", &s.rect.x, 1, 0, f32(tex.width))
	changed |= inspector.drag_float("Y", &s.rect.y, 1, 0, f32(tex.height))
	changed |= inspector.drag_float("W", &s.rect.z, 1, 1, f32(tex.width))
	changed |= inspector.drag_float("H", &s.rect.w, 1, 1, f32(tex.height))
	changed |= inspector.drag_float("Pivot X", &s.pivot.x, 0.01, 0, 1)
	changed |= inspector.drag_float("Pivot Y", &s.pivot.y, 0.01, 0, 1)
	if changed do _se.dirty = true

	im.Separator()
	if im.Button("Delete Slice") do _se_delete_selected()
}
