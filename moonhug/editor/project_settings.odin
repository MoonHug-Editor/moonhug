package editor

// Project Settings window — Unity's Edit ▸ Project Settings: left pane lists
// sections, right pane draws the selected one through the inspector.
//
// A section is a package-level struct var marked
// @(project_settings={name="..."}) — the data IS the registration
// (project_settings_gen emits settings_add_tab calls). The window owns what
// every tab would otherwise hand-roll:
//   - drawing: inspector reflection, so decorators, custom property drawers
//     and collection editing all apply. A fully custom pane is a
//     @(property_drawer) registered for the settings type.
//   - undo: the tab's struct is a Raw owner, so field edits and array ops land
//     in the global undo history like any inspector edit.
//   - persistence: the selected tab diff-saves to ProjectSettings/<slug>.json
//     when no widget is active; everything saves again at editor shutdown.
// Owners consume their vars by polling, so an edit — typed, undone or redone —
// reaches the runtime with no editor coupling.

import "core:c"
import "core:slice"
import "core:strings"
import im "moonhug:external/odin-imgui"
import engine "../engine"
import "inspector"
import "undo"
import wnd "moonhug:editor/window"

@(private = "file")
_Settings_Tab :: struct {
	name:      string,
	ptr:       rawptr,
	tid:       typeid,
	last_json: []byte, // last persisted state, so saves happen only on change
}

@(private = "file")
_settings_tabs: [dynamic]_Settings_Tab

@(private = "file")
_settings_filter: [64]byte

// Left pane's share of the window width, dragged via the pane splitter.
@(private = "file")
_settings_split_ratio: f32 = 0.28

// Registers one tab. The generated _register_project_settings loads the var's
// persisted values (a typed engine.project_settings_load) right before this
// call, so the editor session starts from the file.
settings_add_tab :: proc(name: string, ptr: rawptr, tid: typeid) {
	append(&_settings_tabs, _Settings_Tab{
		name = name, ptr = ptr, tid = tid,
		last_json = undo.capture_json(ptr, tid),
	})
	slice.sort_by(_settings_tabs[:], proc(a, b: _Settings_Tab) -> bool {
		return a.name < b.name
	})
}

// Persists every tab that differs from its last saved state. Called at editor
// shutdown, so changes made outside the window's diff-save (an undo after the
// window closed) still land on disk.
settings_save_all :: proc() {
	for &tab in _settings_tabs {
		_settings_persist(&tab)
	}
}

settings_shutdown :: proc() {
	for &tab in _settings_tabs {
		delete(tab.last_json)
	}
	delete(_settings_tabs)
	_settings_tabs = nil
}

@(private = "file")
_settings_persist :: proc(tab: ^_Settings_Tab) {
	cur := undo.capture_json(tab.ptr, tab.tid)
	if cur == nil do return
	if slice.equal(cur, tab.last_json) {
		delete(cur)
		return
	}
	engine.project_settings_save(tab.name, tab.ptr, tab.tid)
	delete(tab.last_json)
	tab.last_json = cur
}

@(editor_window={id="project_settings", title="Project Settings", width=720, height=440})
project_settings_window_draw :: proc() {
	if len(_settings_tabs) == 0 {
		im.TextDisabled("No project settings registered")
		return
	}

	// Draggable pane split (the console/history splitter pattern, vertical).
	avail := im.GetContentRegionAvail()
	splitter_w: f32 = 4
	left_w := (avail.x - splitter_w) * _settings_split_ratio
	if left_w < 120 do left_w = 120
	if left_w > avail.x - splitter_w - 160 do left_w = avail.x - splitter_w - 160

	im.BeginChild("##ps_sections", im.Vec2{left_w, 0}, {}, {})
	im.SetNextItemWidth(-1)
	im.InputTextWithHint("##ps_filter", "Filter", cstring(raw_data(_settings_filter[:])), c.size_t(len(_settings_filter)), {})
	filter := strings.to_lower(string(cstring(raw_data(_settings_filter[:]))), context.temp_allocator)
	im.Separator()

	selected := _settings_selected_tab()
	for &tab in _settings_tabs {
		if filter != "" && !strings.contains(strings.to_lower(tab.name, context.temp_allocator), filter) {
			continue
		}
		if im.Selectable(
			strings.clone_to_cstring(tab.name, context.temp_allocator),
			selected != nil && selected.name == tab.name,
		) {
			editor_settings.project_settings_tab = tab.name
			selected = &tab
		}
	}
	im.EndChild()

	im.SameLine(0, 0)
	splitter_pos := im.GetCursorScreenPos()
	im.InvisibleButton("##ps_split", im.Vec2{splitter_w, -1})
	if im.IsItemActive() {
		delta := im.GetIO().MouseDelta.x
		total := avail.x - splitter_w
		_settings_split_ratio = clamp((left_w + delta) / total, 120 / total, (total - 160) / total)
	}
	if im.IsItemHovered() || im.IsItemActive() {
		im.SetMouseCursor(.ResizeEW)
	}
	dl := im.GetWindowDrawList()
	col := im.IsItemActive() ? im.GetColorU32ImVec4(im.Vec4{0.8, 0.8, 0.8, 0.9}) : im.GetColorU32ImVec4(im.Vec4{0.5, 0.5, 0.5, 0.5})
	line_x := splitter_pos.x + splitter_w * 0.5
	im.DrawList_AddLine(dl, im.Vec2{line_x, splitter_pos.y}, im.Vec2{line_x, splitter_pos.y + avail.y}, col, 1)

	im.SameLine(0, 0)
	im.BeginChild("##ps_section", im.Vec2{0, 0}, {}, {})
	if selected != nil {
		im.SeparatorText(strings.clone_to_cstring(selected.name, context.temp_allocator))
		undo.push_raw_owner(selected.ptr, selected.tid)
		inspector.draw_inspector(any{selected.ptr, selected.tid})
		undo.pop_owner()
		// Diff-save once the edit is over — not per keystroke or drag frame.
		if !im.IsAnyItemActive() {
			_settings_persist(selected)
		}
	}
	im.EndChild()
}

// The persisted selection when it still exists, the first tab otherwise.
@(private = "file")
_settings_selected_tab :: proc() -> ^_Settings_Tab {
	for &tab in _settings_tabs {
		if tab.name == editor_settings.project_settings_tab do return &tab
	}
	if len(_settings_tabs) > 0 do return &_settings_tabs[0]
	return nil
}

@(menu_separator={path="Edit", order=99})
@(menu_item={path="Edit/Project Settings...", order=100, shortcut=""})
open_project_settings :: proc() {
	wnd.open("project_settings")
}
