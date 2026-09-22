package editor

// Opening a scene from the editor goes through editor_open_scene, so the
// three places that used to spell the same four lines agree, and so the
// Recent Scenes list sees every open. The list is guids, not paths, so a
// moved scene stays reachable. It lives in editor_settings and persists with
// it.
//
// Recent Scenes is a DYNAMIC menu (menu.MenuEntryKind.Dynamic): its items
// exist only at draw time, so it is drawn by a proc rather than registered.

import "base:runtime"
import "core:encoding/uuid"
import "core:path/filepath"
import "core:strings"
import im "moonhug:external/odin-imgui"
import "moonhug:engine"
import "moonhug:editor/undo"
import "moonhug:editor/widgets"

RECENT_SCENES_MAX :: 10

// Fresh navigation to `path`: the nested-scene edit stack resets, undo for
// the scenes being replaced is purged, and the scene becomes active.
editor_open_scene :: proc(path: string) {
	undo.purge_scenes(undo.get())
	hierarchy_edit_stack_clear()
	scene := engine.scene_load_single_path(path)
	engine.sm_scene_set_active(scene)
	if scene != nil do _recent_scenes_push(path)
}

@(private = "file")
_recent_scenes_push :: proc(path: string) {
	guid, ok := engine.asset_db_get_guid(path)
	if !ok do return
	// The list is loaded by json.unmarshal under the default allocator and
	// saved from here, so every string in it is owned by that one allocator.
	context.allocator = runtime.default_allocator()
	guid_str := uuid.to_string(guid)
	list := &editor_settings.recent_scene_guids
	for g, i in list {
		if g == guid_str {
			ordered_remove(list, i)
			delete(g)
			break
		}
	}
	inject_at(list, 0, guid_str)
	for len(list) > RECENT_SCENES_MAX {
		delete(pop(list))
	}
}

@(menu_dynamic={path="File/Recent Scenes", order=2})
_recent_scenes_menu :: proc() {
	list := editor_settings.recent_scene_guids
	shown := 0
	for guid_str in list {
		guid, perr := uuid.read(guid_str)
		if perr != nil do continue
		path, ok := engine.asset_db_get_path(guid)
		if !ok do continue // deleted since: skipped, dropped on the next push
		label := strings.clone_to_cstring(strings.trim_suffix(filepath.base(path), ".scene"), context.temp_allocator)
		im.PushIDInt(i32(shown))
		if im.MenuItem(label) do editor_open_scene(path)
		widgets.tooltip(strings.clone_to_cstring(path, context.temp_allocator), im.HoveredFlags_ForTooltip)
		im.PopID()
		shown += 1
	}
	if shown == 0 {
		im.BeginDisabled()
		im.MenuItem("No recent scenes")
		im.EndDisabled()
	}
}
