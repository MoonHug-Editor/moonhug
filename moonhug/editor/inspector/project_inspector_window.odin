package inspector

// The Project Inspector window (@(editor_window)). Each instance shows an
// asset, its import settings or a package, and has its own lock: a locked
// instance keeps what it shows, unsaved edits included, while the project
// selection moves on (route_targets).
//
// The first instance ("Project Inspector") keeps its state in `_primary`,
// which `inspectorData` points to outside any draw: the project view's
// routing, the bridge and the tests read and write it there. Another
// instance, opened from Add Tab ("Project Inspector/2"), has its own state.
// Drawing an instance points `inspectorData` at its state for the draw.

import "base:runtime"
import "moonhug:editor/session"
import wnd "moonhug:editor/window"
import core "moonhug:libs/core"

PROJECT_INSPECTOR :: "Project Inspector"

@(private) _primary: InspectorData
@(private) _primary_locked: bool

// Another instance's state, in its wnd.Window.
@(private = "file")
_Instance :: struct {
	data:   InspectorData,
	locked: bool,
}

@(editor_window={id="Project Inspector", title="Project Inspector", icon="DESCRIPTION", width=360, height=480, closed=project_inspector_window_closed})
project_inspector_window_draw :: proc(w: ^wnd.Window) {
	inspectorData = _data_of(w)
	defer inspectorData = &_primary
	_draw_project_inspector()
}

project_inspector_window_closed :: proc(w: ^wnd.Window) {
	inst := (^_Instance)(w.data)
	if inst == nil do return
	_data_free(&inst.data)
	free(inst, runtime.default_allocator())
	w.data = nil
}

// The state of the instance whose key is `key`, nil when none is open (the
// first instance's always exists).
project_inspector_data :: proc(key: string) -> ^InspectorData {
	if key == PROJECT_INSPECTOR do return &_primary
	w := wnd.find(key)
	if w == nil do return nil
	return _data_of(w)
}

// The lock of the instance whose key is `key`, for its padlock.
project_inspector_lock :: proc(key: string) -> ^bool {
	if key == PROJECT_INSPECTOR do return &_primary_locked
	w := wnd.find(key)
	if w == nil do return nil
	_data_of(w)
	return &(^_Instance)(w.data).locked
}

// The state of every instance the project selection retargets: the unlocked
// ones, the first one even while its window is closed. The project view
// points `inspectorData` at each in turn and loads the target into it.
route_targets :: proc(allocator := context.temp_allocator) -> []^InspectorData {
	out := make([dynamic]^InspectorData, allocator)
	if !_primary_locked do append(&out, &_primary)
	for w in wnd.instances(PROJECT_INSPECTOR) {
		if w.key == PROJECT_INSPECTOR do continue
		_data_of(w)
		if inst := (^_Instance)(w.data); !inst.locked do append(&out, &inst.data)
	}
	return out[:]
}

// Points `inspectorData` back at the first instance, after routing.
inspector_data_reset :: proc() {
	inspectorData = &_primary
}

// The state of every instance, open or the first one, for a change that
// reaches all of them: a document replaced by undo, an asset that left.
@(private)
_all_data :: proc(allocator := context.temp_allocator) -> []^InspectorData {
	out := make([dynamic]^InspectorData, allocator)
	append(&out, &_primary)
	for w in wnd.instances(PROJECT_INSPECTOR) {
		if w.key == PROJECT_INSPECTOR do continue
		append(&out, _data_of(w))
	}
	return out[:]
}

// The asset the Project Inspector instance shows, locked or not.
@(view_document={view="Project Inspector"})
project_inspector_document :: proc(view: session.View) -> core.Asset_GUID {
	data := project_inspector_data(view.key)
	if data == nil do return {}
	doc := data.doc
	if data.mode != .Asset || doc == nil || doc.kind != .File do return {}
	return doc.guid
}

@(private = "file")
_data_of :: proc(w: ^wnd.Window) -> ^InspectorData {
	if w.key == PROJECT_INSPECTOR do return &_primary
	if w.data == nil do w.data = new(_Instance, runtime.default_allocator())
	return &(^_Instance)(w.data).data
}

// What an instance's state owns, on the default allocator like the load
// procs that fill it.
@(private)
_data_free :: proc(data: ^InspectorData) {
	context.allocator = runtime.default_allocator()
	delete(data.filePath)
	delete(data.packageName)
	delete(data.statusMessage)
	plugin_manifest_free(&data.packageManifest)
	data^ = {}
}
