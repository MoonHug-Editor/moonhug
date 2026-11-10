package scenarios

// The Project window's context menu: the Assets menu up to its database
// band. An item tied to asset types (`ext` on @(menu_item)) is there only for
// a file of such a type, and what is about the whole asset database is in
// the main menu only.

import "core:fmt"
import "core:testing"

@(test)
project_context_menu_shows_what_fits_the_selected_asset :: proc(t: ^testing.T) {
	r := begin(t)
	meshes :: "plugins/essentials/assets/meshes/"
	for file in ([]string{"Sphere.glb", "Sphere.glb.meta", "Cube.glb", "Cube.glb.meta"}) {
		project_copy(r, fmt.tprintf("%s%s", meshes, file), fmt.tprintf("assets/%s", file))
	}
	project_copy(r, "plugins/app/assets/demo_sub_assets/demo_sub_assets.scene", "assets/demo.scene")
	editor_start(r)
	frames(r, 5)
	call(r, "ping_asset", `{"path":"assets/demo.scene"}`)
	frames(r, 3)

	// Right-click on a row's name, `at` points into the row: it is selected
	// and the menu opens there. A menu opens down and right of the click and
	// stays open, so a later click has to be left of an earlier one to reach
	// its row. Twice: with a menu open, the first click only closes it.
	menu_on :: proc(r: ^Run, t: ^testing.T, row_text: string, at: f64) -> bool {
		row, found := item_rect(r, "Project", row_text)
		if !testing.expectf(t, found, "the Project window lists %s", row_text) do return false
		for _ in 0 ..< 2 {
			call(r, "input", fmt.tprintf(`{{"steps":[{{"type":"move","x":%v,"y":%v}},{{"type":"wait","frames":1}},{{"type":"down","button":"right"}},{{"type":"up","button":"right"}},{{"type":"wait","frames":3}}]}}`, row.x + at, row.y + row[3] / 2))
		}
		return true
	}
	shows :: proc(r: ^Run, item: string) -> bool {
		_, found := item_rect(r, "popup", item)
		return found
	}


	// A model: Extract Assets, and nothing that is for scenes.
	if !menu_on(r, t, "Cube.glb", 60) do return
	testing.expect(t, shows(r, "Extract Assets"), "a model's menu has Extract Assets")
	testing.expect(t, !shows(r, "Open Scene Additive"), "and no Open Scene Additive")
	testing.expect(t, shows(r, "Rename") && shows(r, "Duplicate") && shows(r, "Create"), "with the items for any asset and the Create submenu")
	testing.expect(t, !shows(r, "Refresh AssetDB"), "Refresh AssetDB is not in the Project window's menu")
	testing.expect(t, !shows(r, "Duplicate as Asset"), "nor is an item for sub-assets")
	_, refused, _ := call_raw(r, "invoke_menu", `{"path":"Assets/Open Scene Additive"}`)
	testing.expect(t, refused != "", "Open Scene Additive cannot run on a model")

	// A scene: Open Scene Additive, and nothing that is for models.
	if !menu_on(r, t, "demo.scene", 40) do return
	testing.expect(t, shows(r, "Open Scene Additive"), "a scene's menu has Open Scene Additive")
	testing.expect(t, !shows(r, "Extract Assets"), "and no Extract Assets")
	testing.expect(t, !shows(r, "Refresh AssetDB"), "nor Refresh AssetDB")

	// The main menu keeps Refresh AssetDB.
	refreshed, code, _ := call_raw(r, "invoke_menu", `{"path":"Assets/Refresh AssetDB"}`)
	testing.expectf(t, code == "" && as_bool(at(refreshed, "invoked")), "Refresh AssetDB runs from the main menu")
	for message in log_errors(r) do testing.expectf(t, false, "the editor reported: %s", message)
	editor_quit(r)
}
