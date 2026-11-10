package scenarios

// Scenarios of a scene file's sub-assets (plugins/engine/scene_sub_assets.odin): a scene
// whose materials and noise maps live in the scene file.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// The sub-assets demo is one scene file. In a project that holds only
// that file and the two meshes it draws, it opens, reports nothing wrong and
// renders: every material and texture in it comes from the scene itself.
@(test)
sub_assets_demo_scene_renders :: proc(t: ^testing.T) {
	r := begin(t)
	meshes :: "plugins/essentials/assets/meshes/"
	for file in ([]string{"Sphere.glb", "Sphere.glb.meta", "Cube.glb", "Cube.glb.meta"}) {
		project_copy(r, fmt.tprintf("%s%s", meshes, file), fmt.tprintf("assets/%s", file))
	}
	project_copy(r, "plugins/app/assets/demo_sub_assets/demo_sub_assets.scene", "assets/sub_assets_demo.scene")
	editor_start(r)
	call(r, "open_scene", `{"path":"assets/sub_assets_demo.scene"}`)
	frames(r, 10)

	for name in ([]string{"Marble", "Clouds", "Lava", "Scales", "Floor"}) {
		found := call(r, "list_objects", fmt.tprintf(`{{"name":%q,"component":"MeshRenderer"}}`, name))
		objects, _ := at(found, "objects").(json.Array)
		testing.expectf(t, len(objects) == 1, "the scene has %s with a MeshRenderer", name)
	}
	shot := call(r, "screenshot", `{"target":"game","max_size":16}`)
	testing.expectf(t, as_int(at(shot, "width")) > 1, "the game renders")
	stats := call(r, "render_stats", `{"frames":10}`)
	testing.expectf(t, as_int(at(stats, "last", "draw_calls")) >= 5, "the meshes draw, %v draw calls", at(stats, "last", "draw_calls"))
	for message in log_errors(r) do testing.expectf(t, false, "the editor reported: %s", message)
	editor_quit(r)
}

// A material a scene file holds is edited through its document, as the Project
// Inspector does. The change is the scene's: it shows the scene as edited,
// the scene's save writes it into the scene file, and it is there after a
// restart.
@(test)
sub_asset_material_edit_is_saved_with_its_scene :: proc(t: ^testing.T) {
	r := begin(t)
	SCENE :: "assets/sub_assets_demo.scene"
	meshes :: "plugins/essentials/assets/meshes/"
	for file in ([]string{"Sphere.glb", "Sphere.glb.meta", "Cube.glb", "Cube.glb.meta"}) {
		project_copy(r, fmt.tprintf("%s%s", meshes, file), fmt.tprintf("assets/%s", file))
	}
	project_copy(r, "plugins/app/assets/demo_sub_assets/demo_sub_assets.scene", SCENE)
	marble := as_int(at(_sub_asset_record(r, SCENE, "Marble"), "local_id"))
	if !testing.expectf(t, marble != 0, "the demo scene holds a material named Marble") do return
	editor_start(r)
	call(r, "open_scene", fmt.tprintf(`{{"path":%q}}`, SCENE))
	frames(r, 5)

	doc := call(r, "asset_document", fmt.tprintf(`{{"path":%q,"sub_id":%d}}`, SCENE, marble))
	testing.expectf(t, as_int(at(doc, "sub_id")) == marble, "the document is the sub-asset's")
	testing.expectf(t, as_f64(at(doc, "values", "color", 1)) == 1, "the material starts white, green is %v", at(doc, "values", "color", 1))

	call(r, "asset_document_set", fmt.tprintf(`{{"path":%q,"sub_id":%d,"values":{{"color":[1,0,0,1]}}}}`, SCENE, marble))
	frames(r, 3)
	doc = call(r, "asset_document", fmt.tprintf(`{{"path":%q,"sub_id":%d}}`, SCENE, marble))
	testing.expectf(t, as_f64(at(doc, "values", "color", 0)) == 1 && as_f64(at(doc, "values", "color", 1)) == 0, "the document holds the new color")
	testing.expectf(t, as_int(at(doc, "values", "texture", "local_id")) != 0, "its texture reference is kept")
	testing.expectf(t, as_string(at(doc, "values", "texture", "guid")) != ZERO_GUID, "in the document the reference names the scene's file")
	testing.expectf(t, as_f64(at(_sub_asset_record(r, SCENE, "Marble"), "data", "color", 1)) == 1, "the file is untouched until the scene is saved")

	call(r, "invoke_menu", `{"path":"File/Save"}`)
	frames(r, 3)
	saved := _sub_asset_record(r, SCENE, "Marble")
	testing.expectf(t, as_f64(at(saved, "data", "color", 0)) == 1 && as_f64(at(saved, "data", "color", 1)) == 0, "the scene's save writes the material's new color")
	testing.expectf(t, as_int(at(saved, "data", "texture", "local_id")) != 0, "and keeps its reference to the scene's noise map")
	testing.expectf(t, as_string(at(saved, "data", "texture", "guid")) == ZERO_GUID, "written without the file's guid, got %v", at(saved, "data", "texture", "guid"))

	editor_restart(r)
	frames(r, 5)
	doc = call(r, "asset_document", fmt.tprintf(`{{"path":%q,"sub_id":%d}}`, SCENE, marble))
	testing.expectf(t, as_f64(at(doc, "values", "color", 0)) == 1 && as_f64(at(doc, "values", "color", 1)) == 0, "the color is there after a restart")
	for message in log_errors(r) do testing.expectf(t, false, "the editor reported: %s", message)
	editor_quit(r)
}

@(private = "file")
ZERO_GUID :: "00000000-0000-0000-0000-000000000000"

// A MeshRenderer's material slot that holds a material of the scene names it,
// and its arrow unfolds the material under the slot, where its own texture
// slot names the scene's noise map it uses.
@(test)
sub_asset_material_unfolds_under_its_slot :: proc(t: ^testing.T) {
	r := begin(t)
	// A short name: the unfolded material is indented, and a reference row
	// cuts a label that does not fit.
	SCENE :: "assets/demo.scene"
	meshes :: "plugins/essentials/assets/meshes/"
	for file in ([]string{"Sphere.glb", "Sphere.glb.meta", "Cube.glb", "Cube.glb.meta"}) {
		project_copy(r, fmt.tprintf("%s%s", meshes, file), fmt.tprintf("assets/%s", file))
	}
	project_copy(r, "plugins/app/assets/demo_sub_assets/demo_sub_assets.scene", SCENE)
	editor_start(r)
	call(r, "open_scene", fmt.tprintf(`{{"path":%q}}`, SCENE))
	frames(r, 5)
	call(r, "select", `{"name":"Marble"}`)
	window_open(r, "Inspector")
	frames(r, 3)

	// The materials list starts folded.
	list, found := item_rect(r, "Inspector", "materials")
	if !testing.expectf(t, found, "the Inspector shows the MeshRenderer's materials") do return
	click(r, list.x + 4, list.y + list[3] / 2)
	slot, named := item_rect(r, "Inspector", "demo / Marble")
	if !testing.expectf(t, named, "the slot names the material by its scene and its name") do return
	_, unfolded := item_rect(r, "Inspector", "Marble Noise")
	testing.expectf(t, !unfolded, "the material is folded until its arrow is clicked")

	// The arrow sits left of the slot's remove button, at the row's end.
	win, listed := window_rect(r, "Inspector")
	if !testing.expectf(t, listed, "the Inspector is a listed window") do return
	click(r, win.x + win[2] - 49, slot.y + slot[3] / 2)
	_, unfolded = item_rect(r, "Inspector", "Marble Noise")
	testing.expectf(t, unfolded, "the arrow unfolds the material, whose texture slot names the scene's noise map")

	// A click on the slot's value pings the material's own row in the
	// Project window: its scene unfolds to show it.
	_, rows := item_rect(r, "Project", "Clouds Noise")
	testing.expectf(t, !rows, "the scene is folded in the Project window")
	// The text run starts at the row's grip: the value is at its end.
	value_x := slot.x + slot[2] - 8
	click(r, value_x, slot.y + slot[3] / 2)
	_, rows = item_rect(r, "Project", "Clouds Noise")
	testing.expectf(t, rows, "the ping unfolds the scene to the material's row")
	// A double click selects the material, not its scene: the Project
	// Inspector shows the material's color.
	call(r, "input", fmt.tprintf(`{{"steps":[{{"type":"move","x":%v,"y":%v}},{{"type":"wait","frames":1}},{{"type":"down"}},{{"type":"up"}},{{"type":"down"}},{{"type":"up"}},{{"type":"wait","frames":4}}]}}`, value_x, slot.y + slot[3] / 2))
	window_open(r, "Project Inspector")
	frames(r, 3)
	_, shown := item_rect(r, "Project Inspector", "color")
	testing.expectf(t, shown, "a double click shows the material in the Project Inspector")
	for message in log_errors(r) do testing.expectf(t, false, "the editor reported: %s", message)
	editor_quit(r)
}

// The record of the sub-asset named `name` in the scene file `rel` of
// the project, nil for none.
@(private = "file")
_sub_asset_record :: proc(r: ^Run, rel: string, name: string) -> json.Value {
	records, _ := at(project_json(r, rel), "assets").(json.Array)
	for a in records do if as_string(at(a, "name")) == name do return a
	return nil
}

// A scene's sub-asset is removed, renamed, created and copied in the editor:
// Delete and Rename of the Assets menu act on the selected sub-asset, a
// material slot's picker makes a new one and a copy of the one it holds,
// undo takes each back, and the scene's save writes the result.
@(test)
sub_asset_is_deleted_renamed_and_created :: proc(t: ^testing.T) {
	r := begin(t)
	SCENE :: "assets/demo.scene"
	meshes :: "plugins/essentials/assets/meshes/"
	for file in ([]string{"Sphere.glb", "Sphere.glb.meta", "Cube.glb", "Cube.glb.meta"}) {
		project_copy(r, fmt.tprintf("%s%s", meshes, file), fmt.tprintf("assets/%s", file))
	}
	project_copy(r, "plugins/app/assets/demo_sub_assets/demo_sub_assets.scene", SCENE)
	marble := as_int(at(_sub_asset_record(r, SCENE, "Marble"), "local_id"))
	if !testing.expectf(t, marble != 0, "the demo scene holds a material named Marble") do return
	project_write(r, "assets/Red.mat", `{"__type_guid":"4d201ba5-2097-48bb-abd3-1a79e4f6f6f4","color":[1,0,0,1]}`)
	editor_start(r)
	call(r, "open_scene", fmt.tprintf(`{{"path":%q}}`, SCENE))
	frames(r, 5)
	select_marble := fmt.tprintf(`{{"path":%q,"select":true,"sub_id":%d}}`, SCENE, marble)
	marble_doc := fmt.tprintf(`{{"path":%q,"sub_id":%d}}`, SCENE, marble)

	// Delete removes the selected sub-asset, not its scene. Undo brings it back.
	call(r, "ping_asset", select_marble)
	frames(r, 3)
	asked := call(r, "invoke_menu", `{"path":"Assets/Delete"}`)
	testing.expectf(t, as_string(at(asked, "dialog")) == "Delete selected sub-asset?", "Delete asks first, about the sub-asset, got %q", as_string(at(asked, "dialog")))
	_, still, _ := call_raw(r, "asset_document", marble_doc)
	testing.expectf(t, still == "", "nothing is removed before the answer")
	call(r, "dialog", `{"press":"Delete"}`)
	frames(r, 3)
	testing.expectf(t, !as_bool(at(call(r, "dialog"), "open")), "no second dialog asks about the scene file")
	_, gone, _ := call_raw(r, "asset_document", marble_doc)
	testing.expectf(t, gone != "", "the deleted material has no document")
	testing.expect(t, os.exists(project_path(r, SCENE)), "the scene file stays")
	call(r, "invoke_menu", `{"path":"Edit/Undo"}`)
	frames(r, 3)
	doc := call(r, "asset_document", marble_doc)
	testing.expectf(t, as_int(at(doc, "sub_id")) == marble, "undo brings the material back under its id")

	// Rename names it in place, in the Project window.
	call(r, "ping_asset", select_marble)
	frames(r, 3)
	call(r, "invoke_menu", `{"path":"Assets/Rename"}`)
	frames(r, 3)
	call(r, "input", `{"steps":[{"type":"text","text":"Stone"},{"type":"wait","frames":2},{"type":"key","name":"Enter"},{"type":"key","name":"Enter","down":false},{"type":"wait","frames":3}]}`)
	call(r, "invoke_menu", `{"path":"File/Save"}`)
	frames(r, 3)
	testing.expectf(t, as_int(at(_sub_asset_record(r, SCENE, "Stone"), "local_id")) == marble, "the scene's save writes the new name")

	// Duplicate copies the selected sub-asset inside its scene, an undo step.
	call(r, "ping_asset", select_marble)
	frames(r, 3)
	call(r, "invoke_menu", `{"path":"Assets/Duplicate"}`)
	frames(r, 3)
	call(r, "invoke_menu", `{"path":"File/Save"}`)
	frames(r, 3)
	copy_id := as_int(at(_sub_asset_record(r, SCENE, "Stone 1"), "local_id"))
	copy_doc := fmt.tprintf(`{{"path":%q,"sub_id":%d}}`, SCENE, copy_id)
	testing.expectf(t, copy_id != 0 && copy_id != marble, "Duplicate adds a copy to the scene")
	call(r, "invoke_menu", `{"path":"Edit/Undo"}`)
	frames(r, 3)
	_, undone, _ := call_raw(r, "asset_document", copy_doc)
	testing.expectf(t, undone != "", "undo takes the copy back")
	call(r, "invoke_menu", `{"path":"Edit/Redo"}`)
	frames(r, 3)
	_, redone, _ := call_raw(r, "asset_document", copy_doc)
	testing.expectf(t, redone == "", "redo makes it again under the same id")

	// Duplicate as Asset makes a file of the selected sub-asset, beside its
	// scene. The file uses the scene's noise map, named by the scene's guid.
	call(r, "ping_asset", select_marble)
	frames(r, 3)
	call(r, "invoke_menu", `{"path":"Assets/Duplicate as Asset"}`)
	frames(r, 5)
	if testing.expect(t, os.exists(project_path(r, "assets/Stone.mat")), "Duplicate as Asset writes the material as a file named after it") {
		file := project_json(r, "assets/Stone.mat")
		testing.expectf(t, as_int(at(file, "texture", "local_id")) == as_int(at(_sub_asset_record(r, SCENE, "Stone"), "data", "texture", "local_id")), "the file keeps the material's texture, got %v", at(file, "texture"))
		testing.expectf(t, as_string(at(file, "texture", "guid")) != ZERO_GUID, "named by the scene's file")
	}

	// Assets > Create with a sub-asset selected adds the new asset to its
	// scene and opens its name for typing.
	call(r, "ping_asset", select_marble)
	frames(r, 3)
	call(r, "invoke_menu", `{"path":"Assets/Create/Noise Map"}`)
	frames(r, 3)
	call(r, "input", `{"steps":[{"type":"text","text":"Fog"},{"type":"wait","frames":2},{"type":"key","name":"Enter"},{"type":"key","name":"Enter","down":false},{"type":"wait","frames":3}]}`)
	testing.expect(t, !os.exists(project_path(r, "assets/New Noise Map.noise")), "no file is made")

	// New Material in the slot's picker adds a material to the scene and
	// puts it in the slot.
	call(r, "select", `{"name":"Marble"}`)
	window_open(r, "Inspector")
	frames(r, 3)
	list, found := item_rect(r, "Inspector", "materials")
	if !testing.expectf(t, found, "the Inspector shows the MeshRenderer's materials") do return
	click(r, list.x + 4, list.y + list[3] / 2)
	slot, named := item_rect(r, "Inspector", "demo / Stone")
	if !testing.expectf(t, named, "the slot names the renamed material") do return
	win, _ := window_rect(r, "Inspector")
	// The picker button sits left of the slot's arrow.
	click(r, win.x + win[2] - 69, slot.y + slot[3] / 2)
	_, local := item_rect(r, "popup", "demo / Floor")
	testing.expectf(t, local, "the picker offers the scene's other materials")
	row, offered := item_rect(r, "popup", "New Material (sub-asset)")
	if !testing.expectf(t, offered, "the picker offers a new material") do return
	click(r, row.x + 4, row.y + row[3] / 2)
	_, set := item_rect(r, "Inspector", "demo / Material")
	testing.expectf(t, set, "the slot holds the new material")
	// One undo step: the slot gets its material back and the new one is gone.
	call(r, "invoke_menu", `{"path":"Edit/Undo"}`)
	frames(r, 3)
	_, back := item_rect(r, "Inspector", "demo / Stone")
	testing.expectf(t, back, "undo puts the slot's material back")
	call(r, "invoke_menu", `{"path":"Edit/Redo"}`)
	frames(r, 3)
	_, set = item_rect(r, "Inspector", "demo / Material")
	testing.expectf(t, set, "redo makes the material again and puts it in the slot")
	// Copy (sub-asset) gives the slot a copy of the material it holds.
	slot, _ = item_rect(r, "Inspector", "demo / Material")
	click(r, win.x + win[2] - 69, slot.y + slot[3] / 2)
	row, offered = item_rect(r, "popup", "Copy (sub-asset)")
	if !testing.expectf(t, offered, "the picker offers a copy of the slot's material") do return
	click(r, row.x + 4, row.y + row[3] / 2)
	_, set = item_rect(r, "Inspector", "demo / Material 1")
	testing.expectf(t, set, "the slot holds the copy")

	// Of a material file, Copy (sub-asset) puts a copy into the scene.
	slot, _ = item_rect(r, "Inspector", "demo / Material 1")
	click(r, win.x + win[2] - 69, slot.y + slot[3] / 2)
	row, offered = item_rect(r, "popup", "Red.mat")
	if !testing.expectf(t, offered, "the picker offers the material file") do return
	click(r, row.x + 4, row.y + row[3] / 2)
	slot, set = item_rect(r, "Inspector", "Red.mat")
	if !testing.expectf(t, set, "the slot holds the file") do return
	click(r, win.x + win[2] - 69, slot.y + slot[3] / 2)
	row, offered = item_rect(r, "popup", "Copy (sub-asset)")
	if !testing.expectf(t, offered, "the picker offers a copy of the file") do return
	click(r, row.x + 4, row.y + row[3] / 2)
	_, set = item_rect(r, "Inspector", "demo / Red")
	testing.expectf(t, set, "the slot holds the scene's copy of the file")

	call(r, "invoke_menu", `{"path":"File/Save"}`)
	frames(r, 3)
	embedded := _sub_asset_record(r, SCENE, "Red")
	testing.expectf(t, as_string(at(embedded, "type")) == "mat" && as_f64(at(embedded, "data", "color", 1)) == 0, "the scene's save writes the copy with the file's color, got %v", embedded)
	made := _sub_asset_record(r, SCENE, "Material")
	testing.expectf(t, as_string(at(made, "type")) == "mat", "the scene's save writes the new material, got %v", made)
	testing.expectf(t, as_int(at(made, "local_id")) != marble, "under an id of its own")
	copied := _sub_asset_record(r, SCENE, "Material 1")
	testing.expectf(t, as_string(at(copied, "type")) == "mat" && as_int(at(copied, "local_id")) != as_int(at(made, "local_id")), "and its copy, got %v", copied)
	fog := _sub_asset_record(r, SCENE, "Fog")
	testing.expectf(t, as_string(at(fog, "type")) == "noise", "the scene's save writes the noise map made from the Assets menu, got %v", fog)
	duplicate := _sub_asset_record(r, SCENE, "Stone 1")
	testing.expectf(t, as_string(at(duplicate, "type")) == "mat" && as_int(at(duplicate, "local_id")) != marble, "and the duplicate of the renamed material, got %v", duplicate)
	testing.expectf(t, as_int(at(duplicate, "data", "texture", "local_id")) == as_int(at(_sub_asset_record(r, SCENE, "Stone"), "data", "texture", "local_id")), "which uses the same noise map of the scene")
	for message in log_errors(r) do testing.expectf(t, false, "the editor reported: %s", message)
	editor_quit(r)
}

// A sub-asset of a scene that is not open is edited like a file: its
// document holds the edit, Save writes it into the scene's file, and the
// rest of the file stays as it was.
@(test)
sub_asset_of_a_closed_scene_is_saved_into_its_file :: proc(t: ^testing.T) {
	r := begin(t)
	SCENE :: "assets/demo.scene"
	meshes :: "plugins/essentials/assets/meshes/"
	for file in ([]string{"Sphere.glb", "Sphere.glb.meta", "Cube.glb", "Cube.glb.meta"}) {
		project_copy(r, fmt.tprintf("%s%s", meshes, file), fmt.tprintf("assets/%s", file))
	}
	project_copy(r, "plugins/app/assets/demo_sub_assets/demo_sub_assets.scene", SCENE)
	before := project_json(r, SCENE)
	marble := as_int(at(_sub_asset_record(r, SCENE, "Marble"), "local_id"))
	if !testing.expectf(t, marble != 0, "the demo scene holds a material named Marble") do return
	editor_start(r)
	frames(r, 5)
	state := call(r, "editor_state")
	testing.expectf(t, as_string(at(state, "scene")) != SCENE, "the demo scene is not open, the editor shows %v", at(state, "scene"))
	marble_doc := fmt.tprintf(`{{"path":%q,"sub_id":%d}}`, SCENE, marble)

	call(r, "asset_document_set", fmt.tprintf(`{{"path":%q,"sub_id":%d,"values":{{"color":[1,0,0,1]}}}}`, SCENE, marble))
	frames(r, 3)
	doc := call(r, "asset_document", marble_doc)
	testing.expectf(t, as_f64(at(doc, "values", "color", 1)) == 0, "the document holds the new color")
	testing.expectf(t, as_f64(at(_sub_asset_record(r, SCENE, "Marble"), "data", "color", 1)) == 1, "the file is untouched until Save")

	call(r, "invoke_menu", `{"path":"File/Save"}`)
	frames(r, 5)
	saved := _sub_asset_record(r, SCENE, "Marble")
	testing.expectf(t, as_f64(at(saved, "data", "color", 0)) == 1 && as_f64(at(saved, "data", "color", 1)) == 0, "Save writes the color into the scene's file, got %v", at(saved, "data", "color"))
	testing.expectf(t, as_int(at(saved, "data", "texture", "local_id")) != 0 && as_string(at(saved, "data", "texture", "guid")) == ZERO_GUID, "its reference to the scene's noise map is written without the file's guid, got %v", at(saved, "data", "texture"))
	after := project_json(r, SCENE)
	old_transforms, _ := at(before, "transforms").(json.Array)
	new_transforms, _ := at(after, "transforms").(json.Array)
	old_assets, _ := at(before, "assets").(json.Array)
	new_assets, _ := at(after, "assets").(json.Array)
	testing.expectf(t, len(new_transforms) == len(old_transforms) && len(new_assets) == len(old_assets), "the file keeps its objects and its other sub-assets: %d and %d", len(new_transforms), len(new_assets))
	testing.expectf(t, as_string(at(after, "transforms", 0, "name")) == as_string(at(before, "transforms", 0, "name")), "and their content")

	// An edit not saved when the scene is opened moves into the scene, and
	// the scene's save writes it.
	call(r, "asset_document_set", fmt.tprintf(`{{"path":%q,"sub_id":%d,"values":{{"color":[0,1,0,1]}}}}`, SCENE, marble))
	frames(r, 3)
	call(r, "open_scene", fmt.tprintf(`{{"path":%q}}`, SCENE))
	frames(r, 5)
	doc = call(r, "asset_document", marble_doc)
	testing.expectf(t, as_f64(at(doc, "values", "color", 0)) == 0 && as_f64(at(doc, "values", "color", 1)) == 1, "the opened scene's material has the edit, got %v", at(doc, "values", "color"))
	testing.expectf(t, as_f64(at(_sub_asset_record(r, SCENE, "Marble"), "data", "color", 0)) == 1, "the file still has the saved color")
	call(r, "invoke_menu", `{"path":"File/Save"}`)
	frames(r, 5)
	testing.expectf(t, as_f64(at(_sub_asset_record(r, SCENE, "Marble"), "data", "color", 1)) == 1 && as_f64(at(_sub_asset_record(r, SCENE, "Marble"), "data", "color", 0)) == 0, "the scene's save writes the edit")
	for message in log_errors(r) do testing.expectf(t, false, "the editor reported: %s", message)
	editor_quit(r)
}

// The sub-assets of a scene that is not open are managed like files: Rename,
// Duplicate, Create and Delete write into the scene's file at once, with no
// scene opened and nothing else in the file changed.
@(test)
sub_assets_of_a_closed_scene_are_managed_like_files :: proc(t: ^testing.T) {
	r := begin(t)
	SCENE :: "assets/demo.scene"
	meshes :: "plugins/essentials/assets/meshes/"
	for file in ([]string{"Sphere.glb", "Sphere.glb.meta", "Cube.glb", "Cube.glb.meta"}) {
		project_copy(r, fmt.tprintf("%s%s", meshes, file), fmt.tprintf("assets/%s", file))
	}
	project_copy(r, "plugins/app/assets/demo_sub_assets/demo_sub_assets.scene", SCENE)
	before := project_json(r, SCENE)
	marble := as_int(at(_sub_asset_record(r, SCENE, "Marble"), "local_id"))
	if !testing.expectf(t, marble != 0, "the demo scene holds a material named Marble") do return
	editor_start(r)
	frames(r, 5)
	testing.expectf(t, as_string(at(call(r, "editor_state"), "scene")) != SCENE, "the demo scene is not open")
	select :: proc(r: ^Run, id: i64) {
		call(r, "ping_asset", fmt.tprintf(`{{"path":%q,"select":true,"sub_id":%d}}`, SCENE, id))
		frames(r, 3)
	}
	// Braces doubled: it is a format string.
	TYPE_AND_ENTER :: `{{"steps":[{{"type":"text","text":%q}},{{"type":"wait","frames":2}},{{"type":"key","name":"Enter"}},{{"type":"key","name":"Enter","down":false}},{{"type":"wait","frames":4}}]}}`

	// Rename.
	select(r, marble)
	call(r, "invoke_menu", `{"path":"Assets/Rename"}`)
	frames(r, 3)
	call(r, "input", fmt.tprintf(TYPE_AND_ENTER, "Stone"))
	testing.expectf(t, as_int(at(_sub_asset_record(r, SCENE, "Stone"), "local_id")) == marble, "Rename writes the name into the file")

	// Duplicate.
	select(r, marble)
	call(r, "invoke_menu", `{"path":"Assets/Duplicate"}`)
	frames(r, 4)
	copied := _sub_asset_record(r, SCENE, "Stone 1")
	copy_id := as_int(at(copied, "local_id"))
	testing.expectf(t, copy_id != 0 && copy_id != marble && as_string(at(copied, "type")) == "mat", "Duplicate writes a copy into the file, got %v", copied)
	testing.expectf(t, as_string(at(copied, "data", "texture", "guid")) == ZERO_GUID && as_int(at(copied, "data", "texture", "local_id")) != 0, "which uses the scene's noise map, written without the file's guid")

	// Create.
	select(r, marble)
	call(r, "invoke_menu", `{"path":"Assets/Create/Noise Map"}`)
	frames(r, 4)
	call(r, "input", fmt.tprintf(TYPE_AND_ENTER, "Fog"))
	fog := _sub_asset_record(r, SCENE, "Fog")
	testing.expectf(t, as_string(at(fog, "type")) == "noise" && as_int(at(fog, "local_id")) != 0, "Create writes a new noise map into the file, got %v", fog)
	testing.expect(t, !os.exists(project_path(r, "assets/New Noise Map.noise")), "and makes no file")

	// Delete asks, and says undo does not restore it.
	select(r, copy_id)
	asked := call(r, "invoke_menu", `{"path":"Assets/Delete"}`)
	testing.expectf(t, as_string(at(asked, "dialog")) == "Delete selected sub-asset?", "Delete asks first, got %q", as_string(at(asked, "dialog")))
	testing.expectf(t, strings.contains(as_string(at(call(r, "dialog"), "description")), "undo does not restore"), "and says undo does not restore it, as its file is not open")
	call(r, "dialog", `{"press":"Delete"}`)
	frames(r, 4)
	testing.expectf(t, _sub_asset_record(r, SCENE, "Stone 1") == nil, "Delete removes the record from the file")

	after := project_json(r, SCENE)
	old_transforms, _ := at(before, "transforms").(json.Array)
	new_transforms, _ := at(after, "transforms").(json.Array)
	old_assets, _ := at(before, "assets").(json.Array)
	new_assets, _ := at(after, "assets").(json.Array)
	testing.expectf(t, len(new_transforms) == len(old_transforms), "the file keeps its objects: %d of %d", len(new_transforms), len(old_transforms))
	testing.expectf(t, len(new_assets) == len(old_assets) + 1, "and has one sub-asset more: the noise map")
	testing.expectf(t, as_string(at(call(r, "editor_state"), "scene")) != SCENE, "the scene was never opened")
	for message in log_errors(r) do testing.expectf(t, false, "the editor reported: %s", message)
	editor_quit(r)
}

// Copy (embedded) on a material slot gives the slot a copy of its material
// as an asset of its own, written inside the slot: one undo step, saved in the
// scene file where the reference was, and there again after a restart.
@(test)
embedded_asset_is_stored_inside_its_slot :: proc(t: ^testing.T) {
	r := begin(t)
	SCENE :: "assets/demo.scene"
	meshes :: "plugins/essentials/assets/meshes/"
	for file in ([]string{"Sphere.glb", "Sphere.glb.meta", "Cube.glb", "Cube.glb.meta"}) {
		project_copy(r, fmt.tprintf("%s%s", meshes, file), fmt.tprintf("assets/%s", file))
	}
	project_copy(r, "plugins/app/assets/demo_sub_assets/demo_sub_assets.scene", SCENE)
	records_before, _ := at(project_json(r, SCENE), "assets").(json.Array)
	editor_start(r)
	call(r, "open_scene", fmt.tprintf(`{{"path":%q}}`, SCENE))
	frames(r, 5)
	call(r, "select", `{"name":"Marble"}`)
	window_open(r, "Inspector")
	frames(r, 3)
	list, found := item_rect(r, "Inspector", "materials")
	if !testing.expectf(t, found, "the Inspector shows the MeshRenderer's materials") do return
	click(r, list.x + 4, list.y + list[3] / 2)
	slot, named := item_rect(r, "Inspector", "demo / Marble")
	if !testing.expectf(t, named, "the slot names the scene's material") do return
	win, _ := window_rect(r, "Inspector")
	click(r, win.x + win[2] - 69, slot.y + slot[3] / 2)
	row, offered := item_rect(r, "popup", "Copy (embedded)")
	if !testing.expectf(t, offered, "the picker offers an embedded copy") do return
	click(r, row.x + 4, row.y + row[3] / 2)
	_, embedded := item_rect(r, "Inspector", "Material (embedded)")
	testing.expectf(t, embedded, "the slot holds an embedded material")

	// One undo step.
	call(r, "invoke_menu", `{"path":"Edit/Undo"}`)
	frames(r, 3)
	_, back := item_rect(r, "Inspector", "demo / Marble")
	testing.expectf(t, back, "undo puts the reference back")
	call(r, "invoke_menu", `{"path":"Edit/Redo"}`)
	frames(r, 3)
	_, embedded = item_rect(r, "Inspector", "Material (embedded)")
	testing.expectf(t, embedded, "redo makes the slot embedded again")

	// The scene file holds the material's data in the slot.
	call(r, "invoke_menu", `{"path":"File/Save"}`)
	frames(r, 5)
	saved := project_json(r, SCENE)
	slots := 0
	components, _ := at(saved, "components").(json.Array)
	for c in components {
		materials, _ := at(c, "materials").(json.Array)
		for m in materials {
			if as_string(at(m, "embedded")) != "mat" do continue
			slots += 1
			testing.expectf(t, as_f64(at(m, "data", "color", 0)) == 1, "with the material's color, got %v", at(m, "data", "color"))
			testing.expectf(t, as_int(at(m, "data", "texture", "local_id")) != 0, "and its texture, got %v", at(m, "data", "texture"))
		}
	}
	testing.expectf(t, slots == 1, "one slot of the saved scene holds an embedded material, found %d", slots)
	records_after, _ := at(saved, "assets").(json.Array)
	testing.expectf(t, len(records_after) == len(records_before), "the scene's sub-assets are as they were")

	editor_restart(r)
	frames(r, 5)
	call(r, "select", `{"name":"Marble"}`)
	frames(r, 3)
	list, found = item_rect(r, "Inspector", "materials")
	if found {
		_, shown := item_rect(r, "Inspector", "Material (embedded)")
		if !shown do click(r, list.x + 4, list.y + list[3] / 2)
	}
	_, embedded = item_rect(r, "Inspector", "Material (embedded)")
	testing.expectf(t, embedded, "the slot is embedded after a restart")

	// An empty slot gets a new embedded material.
	slot, _ = item_rect(r, "Inspector", "Material (embedded)")
	click(r, win.x + win[2] - 69, slot.y + slot[3] / 2)
	row, offered = item_rect(r, "popup", "None")
	if !testing.expectf(t, offered, "the picker offers None") do return
	click(r, row.x + 4, row.y + row[3] / 2)
	_, embedded = item_rect(r, "Inspector", "Material (embedded)")
	testing.expectf(t, !embedded, "None empties the slot")
	click(r, win.x + win[2] - 69, slot.y + slot[3] / 2)
	_, copy := item_rect(r, "popup", "Copy (embedded)")
	testing.expectf(t, !copy, "an empty slot has nothing to copy")
	row, offered = item_rect(r, "popup", "New Material (embedded)")
	if !testing.expectf(t, offered, "the picker offers a new embedded material for an empty slot") do return
	click(r, row.x + 4, row.y + row[3] / 2)
	_, embedded = item_rect(r, "Inspector", "Material (embedded)")
	testing.expectf(t, embedded, "the slot holds a new embedded material")
	// Saved, so Quit has nothing to ask about.
	call(r, "invoke_menu", `{"path":"File/Save"}`)
	frames(r, 5)
	for message in log_errors(r) do testing.expectf(t, false, "the editor reported: %s", message)
	editor_quit(r)
}
