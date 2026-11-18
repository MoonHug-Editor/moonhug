package scenarios

// Small editor behaviours in a real editor: the Console row's right-click
// menu, and the editor's state saved while it runs, not only at quit.

import "core:encoding/json"
import "core:fmt"
import "core:testing"
import "core:time"

@(test)
console_row_menu_and_settings_saved_while_running :: proc(t: ^testing.T) {
	r := begin(t)
	project_write(r, "assets/Main.scene", `{"root": 1, "next_local_id": 2, "transforms": [{"local_id": 1, "name": "Main", "is_active": true, "position": [0,0,0], "rotation": [0,0,0,1], "scale": [1,1,1], "render_layer": 1, "parent": {"pptr": {"local_id": 0, "guid": "00000000-0000-0000-0000-000000000000"}}, "children": [], "components": []}], "nested_scenes": [], "breadcrumbs": [], "components": []}`)
	editor_start(r)
	call(r, "open_scene", `{"path":"assets/Main.scene"}`)
	frames(r, 3)

	// A right click on a Console row opens its menu, and a pick closes it.
	window_open(r, "Console")
	frames(r, 2)
	row, has_row := item_rect(r, "Console", "Bridge listening")
	if !testing.expect(t, has_row, "the bridge's own message is a Console row") do return
	call(r, "input", fmt.tprintf(`{{"steps":[{{"type":"move","x":%v,"y":%v}},{{"type":"wait","frames":1}},{{"type":"down","button":"right"}},{{"type":"up","button":"right"}},{{"type":"wait","frames":3}}]}}`, row.x + row[2] / 2, row.y + row[3] / 2))
	for label in ([]string{"Copy With Source", "Copy All Shown"}) {
		_, shown := item_rect(r, "popup", label)
		testing.expectf(t, shown, "the row's menu offers %q", label)
	}
	pick, has_pick := item_rect(r, "popup", "Copy With Source")
	if has_pick {
		click(r, pick.x + pick[2] / 2, pick.y + pick[3] / 2)
		frames(r, 3)
		_, still := item_rect(r, "popup", "Copy With Source")
		testing.expect(t, !still, "picking an item closes the menu")
	}

	// A window opened now is in the settings file a few seconds later, with
	// the editor still running.
	key := window_open(r, "Project Inspector", another = true)
	time.sleep(7 * time.Second)
	frames(r, 3)
	saved, _ := at(project_json(r, "UserSettings/editor_settings.json"), "open_window_ids").(json.Array)
	found := false
	for v in saved do if as_string(v) == key do found = true
	testing.expectf(t, found, "the new window %q is saved while the editor runs: %v", key, saved)

	// And again after another change: the second write replaces the first.
	second := window_open(r, "Project Inspector", another = true)
	time.sleep(6 * time.Second)
	frames(r, 3)
	saved, _ = at(project_json(r, "UserSettings/editor_settings.json"), "open_window_ids").(json.Array)
	found = false
	for v in saved do if as_string(v) == second do found = true
	testing.expectf(t, found, "the second new window %q is saved too: %v", second, saved)

	for message in log_errors(r) do testing.expectf(t, false, "the editor reported: %s", message)
	editor_quit(r)
}
