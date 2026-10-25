package render_pipeline_view

// The Render Pipeline window: the editor of `.renderpipeline` assets and the
// view of what a frame does (plugins/engine/docs/RenderPipeline.md).
//
// One slot shows at a time, picked by the tabs. Its steps are the columns
// of a matrix in run order, the frame lane's left of a divider, and the
// resources they touch are the rows: the view's objects (`scene`), then every
// target in the order it first appears. A cell marks a read, a write or both,
// a bar spans each resource's lifetime (matrix.odin). Selecting a step tints
// the rows it reads and the rows it writes in two colors, selecting a row
// marks its writer and readers.
//
// The panel on the right (panel.odin) shows the selected step: its inputs and
// outputs as thumbnails from the running frame (engine.render_inspect_*),
// its settings, its port bindings, what it drew, mute, remove and jump to
// code. Below it the Resource List and the Step List, searchable, list every
// row and column with their details.
//
// Editing: drag a column header to reorder or move it to the other lane,
// the "+" columns and a header's context menu insert steps, the tabs add,
// rename and remove slots.
//
// The window edits the pipeline's shared asset document (editor/inspector,
// asset_docs.odin), the same instance the Project Inspector, File/Save, the
// tab menu and undo reach. It keeps the asset's guid and looks the document
// up at the start of each frame, since an undo, a redo or a Discard replaces
// the instance. Every edit changes it in place and sets `touched`. Once no widget is
// active, the document is serialized and compared with `baseline`, the JSON
// last recorded on the undo stack. A difference becomes one undo step on the
// asset holding both snapshots. Every change also goes to
// engine.render_pipeline_preview, so the frame follows the document while it
// is the project's active pipeline.

import "base:runtime"
import "core:encoding/json"
import "core:encoding/uuid"
import "core:fmt"
import "core:hash"
import "core:math"
import "core:reflect"
import "core:slice"
import "core:strings"
import im "moonhug:external/odin-imgui"
import asset_pipeline "moonhug:editor/assets"
import "moonhug:editor/inspector"
import "moonhug:editor/script_editor"
import "moonhug:editor/undo"
import "moonhug:editor/widgets"
import wnd "moonhug:editor/window"
import "moonhug:libs/log"
import "moonhug:packages/engine"

_RP_PAYLOAD :: "RP_STEP"

_RP_State :: struct {
	guid:     engine.Asset_GUID, // the open pipeline, {} = nothing open
	// The pipeline's shared document and its instance, looked up at the
	// start of each frame (_rp_fetch). Pointers never survive a frame.
	asset:    ^inspector.Asset_Doc,
	doc:      ^engine.Render_Pipeline,
	seen:     rawptr, // the instance the window last worked on: another one means an undo or a Discard replaced it
	baseline: string, // heap, the document as last recorded on the undo stack
	touched:  bool,   // an edit happened since the last record
	label:    string, // the pending edit's undo label (a literal)
	changed:  bool,   // the document changed this frame, the preview follows
	preview:  string, // heap, the document as last sent to the preview

	tried_guid: engine.Asset_GUID, // the active pipeline last opened on its own, not retried after a failed load

	slot:    string, // heap, the slot the tabs show
	sel:     i32,    // selected step (entry id), 0 = none
	sel_res: string, // heap, selected resource row, "" = none
	scroll_step: bool, // the lists scroll to the selection once
	scroll_res:  bool,

	// The palette: the lane and lane position it inserts at (-1 = end).
	menu_slot:  string, // heap
	menu_index: int,
	open_menu:  bool,
	ctx_id:     i32, // the step a header's context menu is for
	open_ctx:   bool,

	// Slots.
	rename_slot: string, // heap, the slot whose rename popup is open
	name_buf:    [128]u8,
	new_slot:    [128]u8,
	open_add:    bool,
	open_rename: bool,
	remove_slot: string, // heap, the slot the confirm dialog removes

	// Panel: the selected step's settings struct, typed, on the default
	// allocator, rebuilt from the entry's JSON when the selection changes or
	// the document is replaced.
	set_buf:   []u8,
	set_id:    i32,
	set_stale: bool,

	custom_buf: [128]u8, // the free-text target of a read combo
	write_edit: int,     // write row whose field is active, -1 = none
	write_buf:  [128]u8,

	res_search:  [64]u8,
	step_search: [64]u8,
}

_rp := _RP_State{write_edit = -1}

// The window's layout and filters, saved per developer.
Render_Pipeline_Prefs :: struct {
	// The right pane's three sections. The pane shows while any of them does.
	hide_step:      bool, // the selected step
	hide_resources: bool, // the Resource List
	hide_steps:    bool, // the Step List
	pane_w:         f32,  // the right pane's width, 0 = the default
	step_ratio:     f32,  // the selected step's share of the pane's height when a list shows too, 0 = the default
	hide_scratch: bool, // rows only one step touches (a step's own scratch textures)
	hide_scene:   bool, // the `scene` row
	hide_muted:   bool, // muted steps' columns
}

@(user_settings={name="Render Pipeline"})
render_pipeline_prefs: Render_Pipeline_Prefs


@(menu_item={path="Window/Rendering/Render Pipeline", shortcut=""})
render_pipeline_menu_open :: proc() {
	if _rp.guid == {} do _rp_open_active()
	wnd.open("render_pipeline")
}

// Opens the pipeline at `path` in the window. Its unsaved edits stay in its
// document, so reopening it, or opening another pipeline and coming back,
// keeps them.
render_pipeline_open :: proc(path: string, guid: engine.Asset_GUID) {
	_rp_open_guid(guid)
	wnd.open("render_pipeline")
}

// Points the window at the pipeline `guid`, its view state reset.
_rp_open_guid :: proc(guid: engine.Asset_GUID) {
	if _rp.guid == guid do return
	_rp.guid = guid
	_rp.seen = nil
	_rp.touched = false
	_rp.changed = false
	_rp.write_edit = -1
	_rp.sel = 0
	_rp_set_string(&_rp.sel_res, "")
	_rp.set_stale = true
}

// Looks up the open pipeline's shared document, loading it on first use. A
// new instance (the first frame, an undo, a redo, a Discard) rebuilds what the
// window derives from it: the recorded baseline, the settings panel, the
// selection, and the frame follows it. False when nothing is open or the file
// is not a render pipeline.
_rp_fetch :: proc() -> bool {
	context.allocator = runtime.default_allocator()
	_rp.asset = nil
	_rp.doc = nil
	if _rp.guid == {} do return false
	path, known := engine.asset_db_get_path(uuid.Identifier(_rp.guid))
	doc := inspector.asset_doc_get(path) if known else nil
	if doc == nil || doc.data.id != typeid_of(engine.Render_Pipeline) {
		log.errorf("[Render] %s is not a render pipeline", path)
		_rp.guid = {}
		return false
	}
	_rp.asset = doc
	_rp.doc = (^engine.Render_Pipeline)(doc.data.data)
	if rawptr(_rp.doc) != _rp.seen {
		replaced := _rp.seen != nil
		_rp.seen = _rp.doc
		delete(_rp.baseline)
		_rp.baseline = string(undo.capture_json(_rp.doc, typeid_of(engine.Render_Pipeline)))
		_rp.touched = false
		_rp.write_edit = -1
		_rp.set_stale = true
		if engine.pipeline_find_step(_rp.doc, _rp.sel) == nil do _rp.sel = 0
		if replaced {
			_rp_preview()
		} else {
			// Opening sends nothing: the frame already runs this pipeline as
			// it was last previewed or loaded.
			delete(_rp.preview)
			_rp.preview = _rp_snapshot()
		}
	}
	return true
}

// The project's active pipeline, when it is an asset.
_rp_open_active :: proc() {
	active := engine.render_pipeline_active()
	if active.guid == {} || active.guid == _rp.tried_guid do return
	_rp.tried_guid = active.guid
	if _, ok := engine.asset_db_get_path(uuid.Identifier(active.guid)); !ok do return
	_rp_open_guid(active.guid)
}

@(editor_window={id="render_pipeline", title="Render Pipeline", icon="HUB", width=1100, height=600})
render_pipeline_window_draw :: proc() {
	// Edits allocate into the shared document, so they use its allocator.
	// The undo stack owns what is pushed to it and frees it with the editor's
	// context allocator, so a step is built with the caller's (_rp_record).
	caller := context.allocator
	context.allocator = inspector.doc_alloc()
	if _rp.guid == {} do _rp_open_active()
	if !_rp_fetch() {
		im.TextDisabled("The built-in frame. Create a Render Pipeline asset (Assets > Create > Render Pipeline) and set it in Project Settings > Rendering.")
		return
	}
	if engine.pipeline_find_step(_rp.doc, _rp.sel) == nil do _rp.sel = 0
	if _rp.slot == "" || !engine.pipeline_find_slot(_rp.doc, _rp.slot) {
		first := len(_rp.doc.slots) > 0 ? _rp.doc.slots[0].name : engine.MAIN_SLOT
		_rp_set_string(&_rp.slot, first)
	}
	// Thumbnails come from the frames rendered while the window shows.
	engine.render_inspect_request(_rp.slot, _rp.sel)

	_rp_toolbar()
	_rp_tabs()

	m := _rp_model(_rp.slot)
	prefs := &render_pipeline_prefs
	show_pane := !prefs.hide_step || !prefs.hide_resources || !prefs.hide_steps
	if !show_pane {
		if im.BeginChild("##rp_matrix", im.Vec2{0, 0}, {}, {.HorizontalScrollbar}) do _rp_matrix(&m)
		im.EndChild()
	} else {
		// Matrix | pane, split by the shared splitter. The pane keeps its
		// width when the window resizes.
		total := im.GetContentRegionAvail().x - widgets.SPLITTER_SIZE
		pane_w := prefs.pane_w > 0 ? prefs.pane_w : _RP_PANE_W
		pane_w = clamp(pane_w, _RP_MIN_PANE, max(total - _RP_MIN_PANE, _RP_MIN_PANE))
		matrix_w := total - pane_w
		if im.BeginChild("##rp_matrix", im.Vec2{matrix_w, 0}, {}, {.HorizontalScrollbar}) do _rp_matrix(&m)
		im.EndChild()
		im.SameLine(0, 0)
		if widgets.splitter("##rp_split", true, &matrix_w, &pane_w, _RP_MIN_PANE, _RP_MIN_PANE) do prefs.pane_w = pane_w
		im.SameLine(0, 0)
		if im.BeginChild("##rp_pane", im.Vec2{0, 0}, {.Borders}) do _rp_panel(&m)
		im.EndChild()
	}

	_rp_popups()

	io := im.GetIO()
	if im.IsWindowFocused(im.FocusedFlags_RootAndChildWindows) && !io.WantTextInput && !im.IsAnyItemActive() {
		if im.IsKeyPressed(.Delete, false) || im.IsKeyPressed(.Backspace, false) do _rp_delete_step(_rp.sel)
		if im.IsKeyPressed(.Escape, false) {
			_rp.sel = 0
			_rp_set_string(&_rp.sel_res, "")
		}
	}

	if _rp.touched && !im.IsAnyItemActive() do _rp_record(caller)
	if _rp.changed {
		_rp.changed = false
		_rp_preview()
	}
}

// --- Toolbar and tabs -------------------------------------------------------------

_rp_toolbar :: proc() {
	// No Save button: the tab menu saves and discards the pipeline, File/Save
	// saves it with every other file (session/documents.odin).
	if im.Button("Filter") do im.OpenPopup("##rp_filter")
	widgets.tooltip("Which rows and columns the matrix shows")
	if im.BeginPopup("##rp_filter") {
		show_scratch := !render_pipeline_prefs.hide_scratch
		if im.Checkbox("Scratch resources", &show_scratch) do render_pipeline_prefs.hide_scratch = !show_scratch
		widgets.tooltip("Targets only one step touches, such as bloom's blur textures")
		show_scene := !render_pipeline_prefs.hide_scene
		if im.Checkbox("Scene objects row", &show_scene) do render_pipeline_prefs.hide_scene = !show_scene
		show_muted := !render_pipeline_prefs.hide_muted
		if im.Checkbox("Muted steps", &show_muted) do render_pipeline_prefs.hide_muted = !show_muted
		im.EndPopup()
	}
	im.SameLine()
	im.AlignTextToFramePadding()
	im.TextUnformatted(fmt.ctprintf("%s%s", _rp.asset.path, _rp.asset.dirty ? " *" : ""))
	if engine.render_pipeline_active().guid != _rp.guid {
		im.SameLine()
		im.TextDisabled("(not the active pipeline, edits show once Project Settings > Rendering names it)")
	}

	// The pane's sections, right-aligned.
	style := im.GetStyle()
	labels := [3]cstring{"Selected Step", "Resource List", "Step List"}
	w: f32
	for l in labels do w += im.CalcTextSize(l).x + style.FramePadding.x * 2
	w += style.ItemSpacing.x * 2
	im.SameLine()
	x := im.GetCursorPosX()
	im.SetCursorPosX(max(x + im.GetContentRegionAvail().x - w, x))
	prefs := &render_pipeline_prefs
	_rp_pane_toggle(labels[0], &prefs.hide_step, "Show the selected step: its images, settings, ports and what it drew")
	im.SameLine()
	_rp_pane_toggle(labels[1], &prefs.hide_resources, "Show every resource with its format, writers, readers and last image")
	im.SameLine()
	_rp_pane_toggle(labels[2], &prefs.hide_steps, "Show every step with what it reads and writes")
}

// A toolbar button lit while its section shows. The tint is pushed for the
// state before the click, so the pop matches it.
_rp_pane_toggle :: proc(label: cstring, hidden: ^bool, tip: cstring) {
	lit := !hidden^
	if lit do im.PushStyleColorImVec4(.Button, im.GetStyleColorVec4(.ButtonActive)^)
	if im.Button(label) do hidden^ = !hidden^
	if lit do im.PopStyleColor()
	widgets.tooltip(tip)
}

_RP_PANE_W   :: f32(360)
_RP_MIN_PANE :: f32(160)

// One tab per slot, the "+" tab adds one. A tab's context menu renames or
// removes its slot, its tooltip names who renders through it.
_rp_tabs :: proc() {
	if !im.BeginTabBar("##rp_slots") do return
	defer im.EndTabBar()
	for s in _rp.doc.slots {
		flags: im.TabItemFlags
		if _rp.slot == s.name do flags += {.SetSelected}
		if im.BeginTabItem(fmt.ctprintf("%s###slot_%s", s.name, s.name), nil, flags) {
			im.EndTabItem()
		}
		if im.IsItemClicked() && _rp.slot != s.name do _rp_select_slot(s.name)
		widgets.tooltip(fmt.ctprintf("Rendered through by %s. Right-click to rename or remove.", _rp_users(s.name)))
		if im.BeginPopupContextItem(fmt.ctprintf("##slot_ctx_%s", s.name)) {
			if im.MenuItem("Rename") {
				_rp_set_string(&_rp.rename_slot, s.name)
				_rp.name_buf = {}
				copy(_rp.name_buf[:len(_rp.name_buf) - 1], s.name)
				_rp.open_rename = true
			}
			if im.MenuItem("Remove") do _rp_ask_remove_slot(s.name)
			im.EndPopup()
		}
	}
	if im.TabItemButton("+", {.Trailing, .NoTooltip}) do _rp.open_add = true
	widgets.tooltip("Add a slot: a lane of steps that cameras naming it render through")
}

_rp_select_slot :: proc(name: string) {
	_rp_set_string(&_rp.slot, name)
	if e := engine.pipeline_find_step(_rp.doc, _rp.sel); e != nil && e.slot != "" && e.slot != name do _rp.sel = 0
}

// The pipeline the window edits, for its tab menu and the star on its tab.
@(view_document={view="render_pipeline"})
render_pipeline_view_document :: proc() -> engine.Asset_GUID {
	return _rp.guid
}

// A save reimports the pipeline.
@(provider_install)
_rp_install_document :: proc() {
	inspector.doc_saved_register(typeid_of(engine.Render_Pipeline), proc(guid: engine.Asset_GUID, path: string) {
		_ = asset_pipeline.asset_pipeline_import_asset(path)
	})
}

// --- Popups -------------------------------------------------------------------------

// The popups open here, at the window's own ID scope, wherever the control
// that asked for them sits.
_rp_popups :: proc() {
	if _rp.open_menu {
		_rp.open_menu = false
		im.OpenPopup("##rp_add_step")
	}
	if im.BeginPopup("##rp_add_step") {
		_rp_add_step_menu()
		im.EndPopup()
	}
	if _rp.open_ctx {
		_rp.open_ctx = false
		im.OpenPopup("##rp_step_ctx")
	}
	if im.BeginPopup("##rp_step_ctx") {
		_rp_step_context_menu()
		im.EndPopup()
	}
	if _rp.open_add {
		_rp.open_add = false
		_rp.new_slot = {}
		im.OpenPopup("##rp_add_slot")
	}
	if im.BeginPopup("##rp_add_slot") {
		im.TextUnformatted("New slot")
		if im.IsWindowAppearing() do im.SetKeyboardFocusHere()
		im.SetNextItemWidth(180)
		entered := im.InputText("##new_slot", cstring(&_rp.new_slot[0]), len(_rp.new_slot), {.EnterReturnsTrue})
		im.SameLine()
		if im.Button("Add") || entered {
			name := strings.trim_space(string(cstring(&_rp.new_slot[0])))
			if engine.pipeline_add_slot(_rp.doc, name) {
				_rp_select_slot(name)
				_rp_touch("Add Slot")
				im.CloseCurrentPopup()
			}
		}
		im.EndPopup()
	}
	if _rp.open_rename {
		_rp.open_rename = false
		im.OpenPopup("##rp_rename_slot")
	}
	if im.BeginPopup("##rp_rename_slot") {
		im.TextUnformatted("Rename slot")
		if im.IsWindowAppearing() do im.SetKeyboardFocusHere()
		im.SetNextItemWidth(180)
		entered := im.InputText("##rename", cstring(&_rp.name_buf[0]), len(_rp.name_buf), {.EnterReturnsTrue, .AutoSelectAll})
		im.SameLine()
		if im.Button("Rename") || entered {
			_rp_rename_slot(_rp.rename_slot, string(cstring(&_rp.name_buf[0])))
			im.CloseCurrentPopup()
		}
		im.EndPopup()
	}
}

// Opens the palette for lane `slot` ("" = the frame lane) at lane position
// `index` (-1 = the end).
_rp_open_palette :: proc(slot: string, index: int) {
	_rp_set_string(&_rp.menu_slot, slot)
	_rp.menu_index = index
	_rp.open_menu = true
}

// Every registered step by package. Per-frame steps go in the frame lane,
// per-view steps in a slot, the others show disabled.
_rp_add_step_menu :: proc() {
	frame := _rp.menu_slot == ""
	im.TextDisabled("%s", frame ? cstring("Add to the frame lane") : fmt.ctprintf("Add to slot %s", _rp.menu_slot))
	im.Separator()
	steps := engine.render_steps()
	pkgs := make([dynamic]string, context.temp_allocator)
	for n in steps do if !slice.contains(pkgs[:], n.pkg) do append(&pkgs, n.pkg)
	for pkg in pkgs {
		if !im.BeginMenu(fmt.ctprintf("%s", pkg)) do continue
		for n in steps {
			if n.pkg != pkg do continue
			label := n.frame ? fmt.ctprintf("%s (per frame)", n.name) : fmt.ctprintf("%s", n.name)
			if im.MenuItem(label, nil, false, n.frame == frame) {
				_rp.sel = engine.pipeline_add_step(_rp.doc, n.name, _rp.menu_slot, _rp.menu_index)
				_rp.scroll_step = true
				_rp_touch("Add Step")
			}
			if n.summary != "" do widgets.tooltip(fmt.ctprintf("%s", n.summary))
		}
		im.EndMenu()
	}
}

// A column header's context menu.
_rp_step_context_menu :: proc() {
	e := engine.pipeline_find_step(_rp.doc, _rp.ctx_id)
	if e == nil {
		im.CloseCurrentPopup()
		return
	}
	im.TextDisabled("%s", fmt.ctprintf("%s", e.step))
	im.Separator()
	pos := _rp_lane_position(e)
	if im.MenuItem("Insert step before") do _rp_open_palette(e.slot, pos)
	if im.MenuItem("Insert step after") do _rp_open_palette(e.slot, pos + 1)
	if im.MenuItem(e.muted ? "Unmute" : "Mute") do _rp_set_muted(e, !e.muted)
	n := engine.render_step_find(e.step)
	if im.MenuItem("Open code", nil, false, n != nil && n.file != "") do _rp_open_code(n)
	im.Separator()
	if im.MenuItem("Remove") do _rp_delete_step(e.id)
}

// --- Edits --------------------------------------------------------------------------

_rp_lane_position :: proc(e: ^engine.Pipeline_Entry) -> int {
	for other, i in engine.pipeline_lane(_rp.doc, e.slot) do if other.id == e.id do return i
	return -1
}

_rp_delete_step :: proc(id: i32) {
	if engine.pipeline_find_step(_rp.doc, id) == nil do return
	if shown, _, _ := engine.render_inspect_showing(); shown == id do engine.render_inspect_show(0, "")
	engine.pipeline_remove_step(_rp.doc, id)
	if _rp.sel == id do _rp.sel = 0
	_rp_touch("Remove Step")
}

_rp_set_muted :: proc(e: ^engine.Pipeline_Entry, muted: bool) {
	if e.muted == muted do return
	e.muted = muted
	_rp_touch(muted ? "Mute Step" : "Unmute Step")
}

// Moves step `id` into lane `slot` before lane position `index` (-1 = the
// end), refusing a per-frame step in a slot or a per-view step in the frame
// lane. Returns the refusal, "" when the move is allowed.
_rp_move_check :: proc(id: i32, slot: string) -> string {
	e := engine.pipeline_find_step(_rp.doc, id)
	if e == nil do return "the step is gone"
	n := engine.render_step_find(e.step)
	if n == nil do return ""
	if n.frame && slot != "" do return "a per-frame step runs in the frame lane only"
	if !n.frame && slot == "" do return "a per-view step runs in a slot only"
	return ""
}

_rp_move :: proc(id: i32, slot: string, index: int) {
	e := engine.pipeline_find_step(_rp.doc, id)
	if e == nil do return
	at := index
	if at >= 0 && e.slot == slot {
		// The entry leaves its place first, so a later target shifts down.
		from := _rp_lane_position(e)
		if from == at || from + 1 == at do return // dropped next to itself
		if from < at do at -= 1
	}
	engine.pipeline_move_step(_rp.doc, id, slot, at)
	_rp_touch("Move Step")
}

// A new name for a slot, carried onto every step in its lane. Empty or taken
// names are ignored.
_rp_rename_slot :: proc(old, name: string) {
	trimmed := strings.trim_space(name)
	if trimmed == "" || trimmed == old || engine.pipeline_find_slot(_rp.doc, trimmed) do return
	for &s in _rp.doc.slots {
		if s.name != old do continue
		for &e in _rp.doc.steps {
			if e.slot == old {
				delete(e.slot)
				e.slot = strings.clone(trimmed)
			}
		}
		was_shown := _rp.slot == old
		delete(s.name)
		s.name = strings.clone(trimmed)
		if was_shown do _rp_set_string(&_rp.slot, trimmed)
		_rp_touch("Rename Slot")
		return
	}
}

// Removes an empty slot at once, asks first when steps sit in its lane.
_rp_ask_remove_slot :: proc(name: string) {
	count := 0
	for e in _rp.doc.steps do if e.slot == name do count += 1
	_rp_set_string(&_rp.remove_slot, name)
	if count == 0 {
		_rp_remove_pending_slot()
		return
	}
	widgets.dialog_open(widgets.Dialog{
		title       = "Remove Slot",
		description = fmt.tprintf("Remove slot %q and the %d step(s) in its lane?", name, count),
		buttons     = {
			{label = "Remove", action = _rp_remove_pending_slot, is_default = true},
			{label = "Cancel", is_cancel = true},
		},
	})
}

// The confirm dialog's action, run outside the window's draw: the document is
// looked up again, and the edit allocates into it with its allocator.
_rp_remove_pending_slot :: proc() {
	if _rp.remove_slot == "" || !_rp_fetch() do return
	context.allocator = inspector.doc_alloc()
	engine.pipeline_remove_slot(_rp.doc, _rp.remove_slot)
	_rp_set_string(&_rp.remove_slot, "")
	if engine.pipeline_find_step(_rp.doc, _rp.sel) == nil do _rp.sel = 0
	_rp_touch("Remove Slot")
}

// Who renders through a slot: the open scene's cameras that name it (an
// empty name is Main, an undeclared one falls back to Main) and the editor's
// scene view (Editor when the pipeline declares it, Main otherwise).
_rp_users :: proc(slot: string) -> string {
	users := make([dynamic]string, context.temp_allocator)
	scene_slot := engine.pipeline_find_slot(_rp.doc, engine.EDITOR_SLOT) ? engine.EDITOR_SLOT : engine.MAIN_SLOT
	if slot == scene_slot do append(&users, "the scene view")
	if w := engine.ctx_world(); w != nil {
		it := engine.pool_iterator(engine.cameras(w))
		for cam in engine.pool_next(&it) {
			name := cam.slot != "" ? cam.slot : engine.MAIN_SLOT
			if !engine.pipeline_find_slot(_rp.doc, name) do name = engine.MAIN_SLOT
			if name != slot do continue
			label := "a camera"
			if t := engine.pool_get(&w.transforms, engine.Handle(cam.owner)); t != nil do label = t.name
			append(&users, fmt.tprintf("camera %s", label))
		}
	}
	if len(users) == 0 do return "nothing in the open scene"
	return strings.join(users[:], ", ", context.temp_allocator)
}

_rp_open_code :: proc(n: ^engine.Render_Step) {
	if n == nil || n.file == "" do return
	script_editor.open_source(n.file, n.line)
}

// --- Settings -----------------------------------------------------------------------

// The selected step's settings, drawn through the inspector from a typed
// buffer and written back to the entry's JSON when a field changed.
_rp_settings_edit :: proc(e: ^engine.Pipeline_Entry, n: ^engine.Render_Step) {
	if _rp.set_stale || _rp.set_id != e.id || len(_rp.set_buf) != n.settings_size {
		delete(_rp.set_buf)
		_rp.set_buf = nil
		_rp.set_id = e.id
		_rp.set_stale = false
		buf, err := runtime.mem_alloc_bytes(n.settings_size, 16)
		if err != nil do return
		_rp.set_buf = buf
		_rp_settings_fill(buf, e, n)
	}
	if _rp.set_buf == nil do return

	// Drawn without an undo owner: the field rows record nothing, the
	// snapshot command records the edit once it is over.
	before := slice.clone(_rp.set_buf, context.temp_allocator)
	undo.push_owner(undo.Inspector_Owner{kind = .None})
	inspector.draw_inspector(any{raw_data(_rp.set_buf), n.settings_tid})
	undo.pop_owner()
	if runtime.memory_compare(raw_data(before), raw_data(_rp.set_buf), len(before)) != 0 {
		bytes, merr := json.marshal(any{raw_data(_rp.set_buf), n.settings_tid}, {spec = .JSON, use_enum_names = true}, context.temp_allocator)
		if merr != nil {
			log.errorf("[Render] settings of %s do not marshal: %v", n.name, merr)
			return
		}
		v, perr := json.parse(bytes, .JSON, true)
		if perr != nil {
			log.errorf("[Render] settings of %s do not parse back: %v", n.name, perr)
			return
		}
		json.destroy_value(e.settings)
		e.settings = v
		_rp_touch("Edit Step Settings")
	}
	if im.Button("Reset to defaults") {
		json.destroy_value(e.settings)
		e.settings = nil
		_rp.set_stale = true
		_rp_touch("Reset Step Settings")
	}
}

// The step's defaults with the entry's JSON applied over them, the way the
// runtime builds an instance. `buf` is settings_size bytes. `warn` is off for
// the hints, which rebuild every frame.
_rp_settings_fill :: proc(buf: []u8, e: ^engine.Pipeline_Entry, n: ^engine.Render_Step, warn := true) {
	runtime.mem_copy(raw_data(buf), n.settings_default, n.settings_size)
	if e.settings == nil do return
	if _, is_null := e.settings.(json.Null); is_null do return
	bytes, merr := json.marshal(e.settings, {spec = .JSON}, context.temp_allocator)
	if merr != nil do return
	pp := raw_data(buf)
	if json.unmarshal_any(bytes, any{&pp, n.settings_ptr_tid}, .JSON, context.temp_allocator) != nil && warn {
		log.warningf("[Render] pipeline step %q: its settings do not match %v, defaults shown", n.name, n.settings_tid)
	}
}

// The first two settings fields as `name value`, for hints.
_rp_settings_hint :: proc(e: ^engine.Pipeline_Entry, n: ^engine.Render_Step) -> string {
	if n == nil || n.settings_size == 0 do return ""
	buf := make([]u8, n.settings_size, context.temp_allocator)
	_rp_settings_fill(buf, e, n, warn = false)
	b := strings.builder_make(context.temp_allocator)
	for f, i in reflect.struct_fields_zipped(n.settings_tid) {
		if i == 2 do break
		if i > 0 do strings.write_string(&b, ", ")
		fmt.sbprintf(&b, "%s %v", f.name, any{rawptr(uintptr(raw_data(buf)) + f.offset), f.type.id})
	}
	return strings.to_string(b)
}

// --- Preview and undo ---------------------------------------------------------------

// Rebuilds the active pipeline from the document when it changed since the
// last preview.
_rp_preview :: proc() {
	// The preview string is the window's own, on the default allocator,
	// whatever the caller's: the draw runs on the document allocator.
	context.allocator = runtime.default_allocator()
	now := _rp_snapshot()
	if now == _rp.preview {
		delete(now)
		return
	}
	delete(_rp.preview)
	_rp.preview = now
	engine.render_pipeline_preview(_rp.guid, _rp.doc^)
}

_rp_touch :: proc(label: string) {
	_rp.touched = true
	_rp.changed = true
	_rp.label = label
}

// The document as JSON, heap-allocated: the shape pipeline_parse reads.
_rp_snapshot :: proc() -> string {
	data, err := json.marshal(_rp.doc^, {}, runtime.default_allocator())
	if err != nil {
		log.errorf("[Render] pipeline snapshot failed: %v", err)
		return ""
	}
	return string(data)
}

// Records the edits since the last record as one undo step on the asset,
// when they changed the document. The step's two snapshots use
// `undo_allocator`, the one the undo stack frees with. The baseline stays the
// window's own (default allocator).
_rp_record :: proc(undo_allocator: runtime.Allocator) {
	_rp.touched = false
	if _rp.doc == nil do return
	tid := typeid_of(engine.Render_Pipeline)
	recorded: string
	{
		context.allocator = undo_allocator
		now := undo.capture_json(_rp.doc, tid)
		if string(now) == _rp.baseline {
			delete(now)
			return
		}
		recorded = strings.clone(string(now), runtime.default_allocator())
		before := transmute([]byte)strings.clone(_rp.baseline)
		undo.push_value(undo.get(), undo.make_asset_target(_rp.guid, tid, .File), before, now, _rp.label)
	}
	delete(_rp.baseline, runtime.default_allocator())
	_rp.baseline = recorded
	_rp.asset.dirty = true
}

// --- Helpers ------------------------------------------------------------------------

// Replaces a heap string of the window's state.
_rp_set_string :: proc(s: ^string, value: string) {
	if s^ == value do return
	delete(s^, runtime.default_allocator())
	s^ = value == "" ? "" : strings.clone(value, runtime.default_allocator())
}

// A write's declared format and size: `HDR`, `HDR @0.5`, `LDR @2048px`.
_rp_decl_info :: proc(d: engine.Render_Target_Decl) -> string {
	size := ""
	if d.px > 0 do size = fmt.tprintf(" @%dpx", d.px)
	else if d.scale != 1 do size = fmt.tprintf(" @%g", d.scale)
	return fmt.tprintf("%v%s", d.format, size)
}

_RP_ENGINE :: im.Vec4{0.30, 0.40, 0.55, 1}
_RP_DANGER :: im.Vec4{0.95, 0.38, 0.35, 1}
// What a selected step does to a row: reads it, writes it, or both in place.
_RP_IN     :: im.Vec4{0.11, 0.62, 0.46, 1}
_RP_OUT    :: im.Vec4{0.85, 0.36, 0.19, 1}
_RP_INOUT  :: im.Vec4{0.50, 0.46, 0.86, 1}

_rp_target_color :: proc(name: string) -> im.Vec4 {
	return _hue(hash.fnv32a(transmute([]u8)name), 0.55, 0.85)
}

_rp_package_color :: proc(pkg: string) -> im.Vec4 {
	if pkg == "engine" do return _RP_ENGINE
	return _hue(hash.fnv32a(transmute([]u8)pkg), 0.45, 0.62)
}

_rp_with_alpha :: proc(c: im.Vec4, a: f32) -> u32 {
	return im.GetColorU32ImVec4(im.Vec4{c.x, c.y, c.z, a})
}

_hue :: proc(h: u32, s, v: f32) -> im.Vec4 {
	hue := f32(h % 360) / 60
	c := v * s
	x := c * (1 - abs(math.mod(hue, 2) - 1))
	m := v - c
	rgb: [3]f32
	switch int(hue) {
	case 0: rgb = {c, x, 0}
	case 1: rgb = {x, c, 0}
	case 2: rgb = {0, c, x}
	case 3: rgb = {0, x, c}
	case 4: rgb = {x, 0, c}
	case:   rgb = {c, 0, x}
	}
	return im.Vec4{rgb.r + m, rgb.g + m, rgb.b + m, 1}
}
